// Entry point of the bot (run by .github/workflows/bot.yml): `dart run tool/bot/bot.dart`.
//
// Environment: GITHUB_REPOSITORY, GITHUB_TOKEN (the GitHub App's token), GITHUB_EVENT_PATH,
// GITHUB_EVENT_NAME, BOT_API_URL, BOT_API_KEY, BOT_MODEL; optional BOT_EXTRA_BODY (JSON),
// BOT_ALLOWED_PATHS (space separated), BOT_DRY_RUN (`true`), BOT_ISSUE and BOT_INSTRUCTION (a manual run).
import 'dart:convert';
import 'dart:io';

import 'bot_core.dart';
import 'bot_github.dart';
import 'bot_model.dart';
import 'bot_runner.dart';

Future<void> main() async {
  String need(String name) {
    final value = Platform.environment[name] ?? '';
    if (value.isEmpty) {
      stderr.writeln('The bot needs $name (a secret or a variable of the repository).');
      exit(2);
    }
    return value;
  }

  final env = Platform.environment;
  final dryRun = env['BOT_DRY_RUN'] == 'true';
  final BotEvent? event;
  if (env['GITHUB_EVENT_NAME'] == 'workflow_dispatch') {
    // a manual run: the maintainer who pressed the button is the one who asks (the repository's own rules decide who may)
    final issue = int.tryParse(env['BOT_ISSUE'] ?? '');
    if (issue == null) {
      stderr.writeln('BOT_ISSUE must be the number of an issue or pull request.');
      exit(2);
    }
    event = BotEvent(
      number: issue,
      isPullRequest: false,
      body: '${BotPolicy.mention} ${env['BOT_INSTRUCTION'] ?? ''}',
      authorLogin: env['GITHUB_ACTOR'] ?? 'maintainer',
      authorAssociation: 'COLLABORATOR',
      authorIsBot: false,
    );
  } else {
    event = BotEvent.fromIssueComment(jsonDecode(File(need('GITHUB_EVENT_PATH')).readAsStringSync()));
  }
  if (event == null) {
    stdout.writeln('Not a comment event: nothing to do.');
    return;
  }
  if (!BotPolicy.mayRun(event)) {
    stdout.writeln('Not called by someone who may call the bot (${event.authorLogin}, ${event.authorAssociation}): nothing to do.');
    return;
  }

  Map<String, Object?> extra = const {};
  final extraText = env['BOT_EXTRA_BODY'] ?? '';
  if (extraText.trim().isNotEmpty) {
    final decoded = jsonDecode(extraText);
    if (decoded is Map) extra = decoded.cast<String, Object?>();
  }
  final allowed = (env['BOT_ALLOWED_PATHS'] ?? '').split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();

  final runner = BotRunner(
    github: RestGitHub(repository: need('GITHUB_REPOSITORY'), token: need('GITHUB_TOKEN')),
    model: OpenAiChatModel(url: need('BOT_API_URL'), apiKey: need('BOT_API_KEY'), model: need('BOT_MODEL'), extraBody: extra),
    limits: BotLimits(allowedPrefixes: allowed.isEmpty ? BotLimits.defaultAllowed : allowed),
    dryRun: dryRun,
    log: stdout.writeln,
  );
  try {
    final outcome = await runner.run(event);
    stdout.writeln(outcome.skipped.isNotEmpty ? 'Skipped: ${outcome.skipped}' : 'Done.${outcome.pullRequest == null ? '' : ' ${outcome.pullRequest}'}');
  } catch (e) {
    // say it on the thread too, without anything secret: the error text comes from GitHub or the model
    stderr.writeln('The bot failed: $e');
    if (!dryRun) {
      try {
        await RestGitHub(repository: need('GITHUB_REPOSITORY'), token: need('GITHUB_TOKEN')).comment(event.number, 'The bot failed: ${e.toString().split('\n').first}');
      } catch (_) {
        // nothing more to do
      }
    }
    exit(1);
  }
}
