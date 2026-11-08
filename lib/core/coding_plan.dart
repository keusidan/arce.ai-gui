import 'protocol.dart';

/// The settings of the 分担モード: which models take which role and how far the work is split.
///
/// The planner is the model that answers the user. It decides the design and the number of parts (分担数), has the
/// developer models look into their parts and report (`delegate`, phase investigate), shows the user the design made of
/// the reports, and only when the user approves has them build their parts (phase build). It reads what comes back and
/// sends work back if it is wrong. The app carries the parts out (as many at once as the planner and the limit say),
/// waits until all of them are done, and keeps the build behind the user's approval. A model is named by
/// `providerId|modelId` (`local|` is the model on the device); empty means none was chosen.
class CodingSettings {
  const CodingSettings({
    this.enabled = false,
    this.planner = '',
    this.plannerFollowsModel = true,
    this.developer = '',
    this.moreDevelopers = const [],
    this.maxTasks = 8,
    this.parallel = 4,
    this.reviewRounds = 1,
    this.developerMaxTokens = 0,
    this.resultChars = 12000,
    this.investigateFirst = true,
    this.maxWorkers = 4,
  });

  /// The parts are looked into and reported on first, and built only after the user has answered (approved the
  /// design). Off: the planner may build at once.
  final bool investigateFirst;

  /// The most parts that run at the same time (the 分担数 the planner may choose). The planner may propose more to the
  /// user; it cannot go past this.
  final int maxWorkers;

  final bool enabled;
  final String planner;

  /// The planner is the model in use (the one picked in the chat), whatever [planner] says. Without
  /// this, switching the model in the chat changed nothing for the coding agent: its requests kept
  /// going to the planner chosen on the settings screen.
  final bool plannerFollowsModel;

  /// The developer model, and more of them: the jobs of one call are spread over all of them, so
  /// several models write at the same time.
  final String developer;
  final List<String> moreDevelopers;

  /// Every developer model, the first one first, without empty entries and repeats.
  List<String> get developers => <String>{
        if (developer.isNotEmpty) developer,
        for (final d in moreDevelopers)
          if (d.trim().isNotEmpty) d.trim(),
      }.toList();

  /// Most jobs one `delegate` call may carry; the planner is told, and the rest is refused.
  final int maxTasks;

  /// How many requests run at the same time on one developer model (the device model always runs one).
  final int parallel;

  /// How many times the planner is told it may send work back for fixes. 0 tells it not to review.
  final int reviewRounds;

  /// The longest reply of one developer job; 0 lets the model's own settings decide (the maker's
  /// recommendation, then what the role usually needs). A reasoning model spends part of the
  /// budget on thinking, so a small fixed number cuts its answer short.
  final int developerMaxTokens;

  /// How much of each developer result the planner reads. The user sees all of it.
  final int resultChars;

  /// Whether the developers have a model and the planner is known (the model in use, or one chosen),
  /// so the work can be handed over at all.
  bool get isReady => enabled && developers.isNotEmpty && (plannerFollowsModel || planner.isNotEmpty);

  static const localProvider = 'local';

  /// `provider|model` of a reference, or null for an empty or malformed one.
  static (String provider, String model)? parseRef(String ref) {
    final at = ref.indexOf('|');
    if (at <= 0) return null;
    return (ref.substring(0, at), ref.substring(at + 1));
  }

  static String ref(String provider, String model) => '$provider|$model';
}

/// The wording the planner and the developer are given.
abstract final class CodingPrompts {
  /// What the planner is told about its team, added to its instructions while the 分担モード is on.
  static String plannerInstructions({required int maxTasks, required int reviewRounds, bool investigateFirst = true, int maxWorkers = 4}) => '''
分担モード (split mode): you lead a team of developer models that work at the same time. You design and split, they investigate and build, you check.
- For a question, a clarification, or a job of a few lines, answer yourself and do not use delegate.
${investigateFirst ? '''- For anything bigger, work in rounds:
  1. Design it and choose the number of parts that run at the same time (workers, the 分担数, at most $maxWorkers). Call delegate with phase "investigate": each developer looks into its part and reports. You get every report together, once all are done.
  2. Combine the reports into the design and show it to the user: the diagram, what each part does, the risks, and the 分担数. If the work looks bigger or slower than planned, propose more parts (more workers, or a finer split) here. Then ask with ask_user whether to build it (options such as 実装する / 設計を直す, with free input), and wait for the answer.
  3. If the user wants changes, revise the design and go back to 1 (investigate again). If the user approves, call delegate with phase "build" with the same task ids, so each developer gets its own report, and wait until every part is done.
  delegate with phase "build" is refused until the user has answered after the last investigation.''' : '- For anything bigger, call delegate once (phase "build").'}
- Split the work into many SMALL goals (one file, or one group of functions, each), at most $maxTasks per call. Fine-grained jobs finish sooner and fit cheap models.
- Draw the split in plan as a Mermaid flowchart: flowchart TD, one node per job written id["title"], and an arrow a --> b only when b really needs the result of a. Jobs with no arrow into them start at once on different models, so keep as many independent as you can; a job that waits is given the results it waits for. Give the same id to the node and to the task.
- Jobs that run at the same time cannot see each other: write every name, signature and data format they must agree on into summary and into each task that touches it. Each task's instructions must let a developer who sees nothing else implement it; each task produces whole files.
- The developers decide every detail themselves and do not ask you; you get the results only. Do not write the implementation yourself, and do not copy their files into your answer: the user sees them as they come in.
- Read what comes back. ${reviewRounds <= 0 ? 'Do not send work back; accept the result.' : 'If something is really wrong (a missing file, interfaces that do not match, wrong behaviour), call delegate again with revise set to that result\'s id and exactly what to change, at most $reviewRounds times.'}
- To have a command-line coding agent in the Linux environment build it instead (for example opencode, only when the user asks for that): write this same plan to /workspace/PLAN.md with run_command (the flowchart, then each task with its instructions and files), start the agent on that file with shell_session (or with run_command when the agent has a one-shot mode), and read its screen until it is done. The diagram says what depends on what, so tell it to follow it.
- Finish with a short summary of what was built and anything the user must do. Reply in the user's language.''';

  /// A developer in the investigation round: it looks into its part and reports, and writes no implementation.
  static const investigator = '''
You are a developer on a team, in the investigation round. Look into exactly the part you are given, using the plan's decisions, and report. Do not write the implementation yet: it is built after the user approves the design.
Write a short report with these headings:
- What to do: the changes your part needs, step by step.
- Files: the files you would write or change, and the functions or classes in them.
- Interfaces: the names, signatures and data formats the other parts must agree on with yours.
- Risks and open points: what could go wrong, and any decision the plan did not make (make the most reasonable choice and say it).
- Size: small, medium or large, and whether your part should be split further or given more workers.
Nobody is available to answer you: decide yourself. Reply in the user's language.''';

  static const developer = '''
You are a developer on a team. Implement exactly the task you are given, using the plan's decisions. Nobody is available to answer you: decide every detail yourself.
- Output complete, runnable files. Put each file in its own fenced code block with the language (```python, ```html ...); write a line "File: <path>" just before the block when a path is given.
- If something is unclear, make the most reasonable choice and say so in one line. Do not ask. Only when it is impossible to go on without a decision that was not given, answer with one line that starts with "QUESTION:" and nothing else.
- When the task lists results of the jobs it waited for, build on them exactly: use their names, signatures and files as they are.
- Keep any explanation to one or two sentences after the code.
Reply in the user's language.''';

  /// Said to a developer that asked a question, once: the planner is not asked, the developer decides.
  static const decideYourself =
      'Nobody can answer this. Decide yourself with the most reasonable choice, say which in one line, and output the complete files now.';

  /// The text of a developer's question, or null when [answer] is not one. A question is the whole
  /// answer: it starts with `QUESTION:` (case does not matter).
  static String? questionIn(String answer) {
    final match = RegExp(r'^question\s*[:：]\s*(.+)$', caseSensitive: false, dotAll: true).firstMatch(answer.trim());
    final question = match?.group(1)?.trim();
    return question == null || question.isEmpty ? null : question;
  }

  /// The paths a developer named in "File: path" lines, in order, without repeats.
  static List<String> filesIn(String answer) {
    final seen = <String>{};
    for (final m in RegExp(r'^\s*File\s*[:：]\s*`?([^\s`]+)`?\s*$', multiLine: true).allMatches(answer)) {
      seen.add(m.group(1)!);
    }
    return seen.toList();
  }

  /// What a developer is asked, for one job.
  ///
  /// [given] are the results of the jobs this one waited for (id -> title and answer): it builds on them.
  static String developerTask(
    String summary,
    DelegateTask task, {
    List<(String id, String title, String answer)> given = const [],
    String report = '',
  }) {
    final b = StringBuffer();
    if (summary.trim().isNotEmpty) {
      b
        ..writeln('# The plan (shared by every task)')
        ..writeln(summary.trim())
        ..writeln();
    }
    for (final (id, title, answer) in given) {
      b
        ..writeln('# Result of the job you waited for: $id — $title')
        ..writeln(answer.trim())
        ..writeln();
    }
    if (report.trim().isNotEmpty) {
      b
        ..writeln('# Your own investigation report (the user approved the design made of it)')
        ..writeln(report.trim())
        ..writeln();
    }
    b
      ..writeln('# Your task: ${task.title}')
      ..writeln(task.instructions.trim());
    if (task.files.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Files to write: ${task.files.join(', ')}');
    }
    return b.toString();
  }

  /// What a developer is told when its earlier answer has to be corrected.
  static String correction(String feedback) =>
      'Reviewer feedback:\n${feedback.trim()}\n\nFix it and output the complete corrected files.';
}
