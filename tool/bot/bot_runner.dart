// The bot's run: read the thread, ask the model, check what it wrote, answer, and when a change was
// asked for, put it on a branch of its own as a draft pull request. GitHub and the model are behind two
// small interfaces, so the whole run is tested with fakes (test/tool/bot_runner_test.dart).
import 'bot_core.dart';

/// An issue or a pull request, as the bot reads it.
class ThreadInfo {
  const ThreadInfo({
    required this.title,
    required this.body,
    required this.isPullRequest,
    this.headRef = '',
    this.headIsThisRepository = false,
    this.open = true,
  });

  final String title;
  final String body;
  final bool isPullRequest;

  /// For a pull request: its branch, and whether that branch is in this repository (not a fork).
  final String headRef;
  final bool headIsThisRepository;
  final bool open;
}

/// What the bot needs of GitHub. The real one calls the REST API with the app's token.
abstract class BotGitHub {
  Future<ThreadInfo> thread(int number);

  /// The newest comments of the thread, oldest first, as (author, text).
  Future<List<(String author, String text)>> comments(int number, {int limit = 20});

  Future<String> defaultBranch();

  /// Every file path at [ref].
  Future<List<String>> paths(String ref);

  /// The text of [path] at [ref]; null when there is no such file or it is not text.
  Future<String?> fileText(String path, String ref);

  /// Puts [edits] on [branch] as one commit (the branch is made from [baseRef] when it is new) and
  /// returns the commit's id.
  Future<String> commit({required String branch, required String baseRef, required String message, required List<BotEdit> edits});

  /// A draft pull request from [head] into [base]; its address.
  Future<String> openDraftPullRequest({required String head, required String base, required String title, required String body});

  Future<void> comment(int number, String body);
}

/// What the bot needs of a model: the text of its answer to a system and a user message.
abstract class BotModel {
  Future<String> ask({required String system, required String user});
}

/// What a run did, for the log (and the tests).
class BotOutcome {
  const BotOutcome({required this.reply, this.pullRequest, this.branch, this.rejected = const {}, this.skipped = ''});

  final String reply;
  final String? pullRequest;
  final String? branch;
  final Map<String, String> rejected;

  /// Why nothing was done, when that is so.
  final String skipped;
}

class BotRunner {
  BotRunner({required this.github, required this.model, this.limits = const BotLimits(), this.dryRun = false, void Function(String)? log})
      : _log = log ?? ((_) {});

  final BotGitHub github;
  final BotModel model;
  final BotLimits limits;

  /// Nothing is written to GitHub (no commit, no pull request, no comment): the log says what would be.
  final bool dryRun;
  final void Function(String) _log;

  Future<BotOutcome> run(BotEvent event) async {
    if (!BotPolicy.mayRun(event)) {
      return const BotOutcome(reply: '', skipped: 'not called by someone who may call the bot');
    }
    final thread = await github.thread(event.number);
    if (!thread.open) return const BotOutcome(reply: '', skipped: 'the thread is closed');
    final comments = await github.comments(event.number);
    final base = await github.defaultBranch();
    final tree = await github.paths(base);
    final instruction = BotPolicy.instruction(event.body);

    final files = <String, String>{};
    BotAnswer? answer;
    var rounds = 0;
    while (true) {
      rounds++;
      final text = await model.ask(
        system: BotPrompt.system(limits),
        user: BotPrompt.thread(
          title: thread.title,
          body: thread.body,
          comments: comments,
          instruction: instruction,
          tree: tree,
          files: files,
        ),
      );
      answer = BotAnswer.parse(text);
      if (answer == null) {
        _log('the model gave no usable answer (round $rounds)');
        return _finish(event, 'I could not make a usable answer this time. Please ask again, more narrowly.', const {}, null, null);
      }
      if (answer.needFiles.isEmpty || rounds >= limits.maxRounds) break;
      var read = 0;
      for (final path in answer.needFiles) {
        if (files.length >= limits.maxFilesRead) break;
        if (files.containsKey(path) || !tree.contains(path) || BotLimits.isSecretFile(path)) continue;
        final text = await github.fileText(path, base);
        if (text == null) continue;
        files[path] = text.length > limits.maxReadBytes ? '${text.substring(0, limits.maxReadBytes)}\n[… cut]' : text;
        read++;
      }
      if (read == 0) {
        // it asked for nothing it could have: it answers with what it has
        files['(note)'] = 'None of the files you asked for could be read. Answer with what you have.';
      }
    }

    // it kept asking for files and never answered: say so, instead of posting an empty comment
    if (answer.reply.isEmpty && answer.edits.isEmpty) {
      return _finish(event, 'I asked to read more files than I am allowed to, so I could not answer. Please ask again, more narrowly.', const {}, null, null);
    }
    // the model may ask for files and answer in one object: what it asked for after the last round is ignored
    final check = EditCheck.of(answer.edits, limits);
    final canChange = !thread.isPullRequest || (thread.headIsThisRepository && thread.headRef.startsWith('bot/'));
    if (answer.edits.isEmpty) return _finish(event, answer.reply, const {}, null, null);
    if (!canChange) {
      return _finish(
        event,
        '${answer.reply}\n\n_I do not push to a pull request that is not my own, so I made no change._',
        const {},
        null,
        null,
      );
    }
    if (!check.any) {
      final why = check.overall ?? 'every file was refused';
      return _finish(event, '${answer.reply}\n\n_I made no change: $why._', check.rejected, null, null);
    }

    final branch = thread.isPullRequest ? thread.headRef : BotPrompt.branchFor(event.number, thread.title);
    final title = answer.title.isEmpty ? 'Bot: ${thread.title}' : answer.title;
    final message = '$title\n\nAsked by ${event.authorLogin} in #${event.number}.\nWritten by a model; not run, not reviewed: read it before merging.';
    if (dryRun) {
      _log('dry run: would commit ${check.accepted.map((e) => e.path).join(', ')} to $branch');
      return _finish(event, answer.reply, check.rejected, null, branch);
    }
    await github.commit(branch: branch, baseRef: base, message: message, edits: check.accepted);
    String? pull;
    if (!thread.isPullRequest) {
      pull = await github.openDraftPullRequest(
        head: branch,
        base: base,
        title: title,
        body: '${answer.body.isEmpty ? answer.reply : answer.body}\n\nCloses #${event.number} once it is reviewed and merged.\n\n---\n'
            '_Written by a model on request of @${event.authorLogin}. It was not run. Read the diff before merging._',
      );
    }
    return _finish(event, answer.reply, check.rejected, pull, branch);
  }

  Future<BotOutcome> _finish(BotEvent event, String reply, Map<String, String> rejected, String? pull, String? branch) async {
    final b = StringBuffer(reply.trim());
    if (branch != null) {
      b
        ..write('\n\n')
        ..write(dryRun ? 'Dry run: nothing was written. It would go on `$branch`.' : (pull != null ? 'I opened a draft pull request: $pull' : 'I pushed the change to `$branch`.'));
    }
    if (rejected.isNotEmpty) {
      b.write('\n\nNot written:');
      for (final entry in rejected.entries) {
        b.write('\n- `${entry.key}`: ${entry.value}');
      }
    }
    final text = b.toString();
    if (dryRun) {
      _log('dry run: would comment:\n$text');
    } else {
      await github.comment(event.number, text);
    }
    return BotOutcome(reply: text, pullRequest: pull, branch: branch, rejected: rejected);
  }
}
