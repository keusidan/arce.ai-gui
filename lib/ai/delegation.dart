import 'dart:async';

import '../core/coding_plan.dart';
import '../core/engine.dart';
import '../core/plan_graph.dart';
import '../core/protocol.dart';
import '../core/run_progress.dart';
import '../core/tool_runtime.dart';
import 'provider.dart';
import 'roles.dart';

/// What one chat's 分担モード remembers between its rounds: the reports of the last investigation (by the planner's task
/// id, so a part that is built gets its own report) and whether the user has answered since (approved the design).
class DelegateSession {
  DelegateSession(this.userInputs);

  /// How many times the user has written or answered in this chat so far (it only grows).
  final int Function() userInputs;

  /// The reports of the last investigation, by task id.
  final reports = <String, String>{};

  /// [userInputs] when the last investigation ended; null before the first one.
  int? reportedAt;

  bool get investigated => reportedAt != null;

  /// The user has answered (written or picked a choice) since the last investigation ended.
  bool get approved => reportedAt != null && userInputs() > reportedAt!;
}

/// Carries out the `delegate` tool of the 分担モード: the small jobs the planner model drew are
/// spread over the developer models, as many at the same time as the models and the settings allow,
/// each job starting as soon as the jobs it waits for are done and a model is free; what comes back
/// goes to the planner.
///
/// It decides nothing. How to split the work, whether the result is good and whether to send a job
/// back are the planner's calls; this class is the app's help with the calling: it holds the
/// developer models and their limits, runs the requests at the same time (a job that waits for
/// another is given its result), remembers each result under an id (so a job can be sent back with
/// `revise`), and shows the user the plan and the files. A developer is not asked questions back:
/// one that asks is told once to decide itself, and a model that fails hands its job to another.
class DelegateRunner {
  DelegateRunner({required this.settings, required this.developers});

  final CodingSettings Function() settings;

  /// The developer models now, in the order of the settings, without the ones that cannot be used
  /// (the provider was removed, the device model is not loaded).
  final List<RoleModel> Function() developers;

  static const _remembered = 200;

  final _results = <String, _Stored>{};
  var _count = 0;

  /// Runs [call]. [stop] completes when the user stops the reply. A job for the device model needs
  /// [acquireDevice] to succeed (one chat at a time) and gives it back through [releaseDevice];
  /// without it the other models do the work. [meter] is told each request to a developer model and
  /// each job that ends, so the screen shows that the work goes on.
  Future<ToolOutcome> run(
    Delegate call, {
    required Future<void> stop,
    bool Function()? acquireDevice,
    void Function()? releaseDevice,
    RunMeter? meter,
    DelegateSession? session,
  }) async {
    final s = settings();
    final investigate = call.phase == DelegatePhase.investigate || (call.phase == null && s.investigateFirst && !(session?.approved ?? false));
    // the build waits for the user: after an investigation, and after the user answered it
    if (!investigate && s.investigateFirst && session != null) {
      if (!session.investigated) {
        return const ToolOutcome(
          'Not built: investigate first. Call delegate with phase "investigate" (the same tasks), show the user the design made of the reports, and ask with ask_user whether to build it.',
          ToolActivity('Delegate', '実装の前に、担当を調べます', failed: true),
        );
      }
      if (!session.approved) {
        return const ToolOutcome(
          'Not built: the user has not answered since the reports came. Show the design and ask with ask_user whether to build it (or what to change), and wait for the answer.',
          ToolActivity('Delegate', '実装は、あなたの確認のあとです', failed: true),
        );
      }
    }
    var models = developers();
    if (models.isEmpty) {
      return const ToolOutcome(
        'The developer models are not available now (their provider was removed or is incomplete, or the device model is not loaded). Do the work yourself.',
        ToolActivity('Delegate', 'coding のモデルが使えません', failed: true),
      );
    }
    var device = false;
    if (models.any((m) => m.usesDevice) && acquireDevice != null) {
      if (acquireDevice()) {
        device = true;
      } else {
        // one chat at a time on the device: the other developers take the jobs
        models = [for (final m in models) if (!m.usesDevice) m];
        if (models.isEmpty) {
          return const ToolOutcome(
            'The device model is being used by another chat. Try again when it is done, or do the work yourself.',
            ToolActivity('Delegate', 'ローカルモデルを、ほかのチャットが使っています', failed: true),
          );
        }
      }
    }

    var stopped = false;
    unawaited(stop.then((_) {
      stopped = true;
      for (final m in models) {
        m.cancel();
      }
    }));

    try {
      final limit = s.maxTasks.clamp(1, Protocol.maxDelegateTasks);
      final accepted = _withIds(call.tasks.take(limit));
      final refused = call.tasks.length - accepted.length;
      // the 分担数: what the planner asked for, within the setting
      final maxWorkers = s.maxWorkers < 1 ? 1 : s.maxWorkers;
      final workers = (call.workers ?? maxWorkers).clamp(1, maxWorkers);
      final pool = _Pool(models, s.parallel, total: workers);
      final unknownRevise = <String>[];

      var ended = 0;
      final running = <String>[];
      void report() => meter?.stage(
        '${investigate ? 'coding が担当を調べています' : 'coding が実装しています'}（$ended/${accepted.length} 件完了・分担数 $workers）',
        detail: running.isEmpty ? '' : '${investigate ? '調査中' : '作業中'}: ${running.join('、')}',
      );
      report();

      // a job is given a result id (d1 ...) now, in the order the planner wrote them
      final resultIds = {for (final t in accepted) t.id: 'd${++_count}'};
      final futures = <String, Future<_Stored>>{};
      final waiting = [...accepted];
      // a future is made for a job once those of the jobs it waits for exist (the parser refused cycles)
      while (waiting.isNotEmpty) {
        final ready = [
          for (final t in waiting)
            if (t.dependsOn.where(resultIds.containsKey).every(futures.containsKey)) t,
        ];
        if (ready.isEmpty) break;
        for (final task in ready) {
          waiting.remove(task);
          final id = resultIds[task.id]!;
          final before = task.revise == null ? null : _results[task.revise];
          if (task.revise != null && before == null) unknownRevise.add(task.revise!);
          final base = before?.task ?? task;
          final summary = before?.summary ?? call.summary;
          final title = task.title.trim().isEmpty ? base.title : task.title;
          final deps = [for (final d in task.dependsOn) if (futures.containsKey(d)) d];
          futures[task.id] = () async {
            final results = await Future.wait([for (final d in deps) futures[d]!]);
            if (stopped) return _Stored(id, task.id, title, summary, base, '（停止しました）', failed: true);
            final failedBefore = [for (final r in results) if (r.failed) r.id];
            if (failedBefore.isNotEmpty) {
              ended++;
              report();
              return _Stored(id, task.id, title, summary, base, '（前の仕事 ${failedBefore.join('、')} が失敗したため、実行しませんでした）', failed: true);
            }
            final messages = [
              AiMessage(AiRole.system, text: investigate ? CodingPrompts.investigator : CodingPrompts.developer),
              AiMessage(
                AiRole.user,
                text: CodingPrompts.developerTask(
                  summary,
                  base,
                  given: [for (final r in results) (r.id, r.title, _cut(r.output, s.resultChars))],
                  // a part that is built gets its own report of the approved investigation
                  report: investigate ? '' : (session?.reports[task.id] ?? ''),
                ),
              ),
              if (before != null) ...[
                AiMessage(AiRole.assistant, text: before.output),
                AiMessage(AiRole.user, text: CodingPrompts.correction(task.instructions)),
              ],
            ];
            return _runJob(
              pool: pool,
              id: id,
              taskId: task.id,
              title: title,
              summary: summary,
              base: base,
              messages: messages,
              s: s,
              isStopped: () => stopped,
              meter: meter,
              investigate: investigate,
              onStart: () {
                running.add(title);
                report();
              },
              onEnd: () {
                running.remove(title);
                ended++;
                report();
              },
            );
          }();
        }
      }
      // jobs that wait for something that is not in this call (cut by the limit): they cannot start
      for (final task in waiting) {
        futures[task.id] = Future.value(
          _Stored(resultIds[task.id]!, task.id, task.title, call.summary, task, '（待つはずの仕事がこの呼び出しに無いため、実行しませんでした）', failed: true),
        );
      }
      final done = [for (final t in accepted) await futures[t.id]!];
      for (final result in done) {
        if (!result.failed) {
          _results[result.id] = result;
          while (_results.length > _remembered) {
            _results.remove(_results.keys.first);
          }
        }
      }

      if (investigate && session != null && !stopped) {
        session.reports
          ..clear()
          ..addAll({for (final r in done) if (!r.failed) r.taskId: r.output});
        session.reportedAt = session.userInputs();
      }
      final response = StringBuffer(
        stopped
            ? 'The user stopped the work. What was finished:\n'
            : investigate
                ? 'Investigation reports, all ${done.length} of them (nothing is built yet; the task ids are yours):\n'
                : 'Developer results (to correct one, call delegate with revise set to its result id; the task ids are yours):\n',
      );
      if (call.workers != null && call.workers! > maxWorkers) {
        response.writeln('You asked for ${call.workers} workers; the setting allows $maxWorkers (分担数の上限). If the work needs more, propose it to the user: they can raise it in 詳細設定 → 分担モード.');
      }
      for (final r in done) {
        final files = CodingPrompts.filesIn(r.output);
        response
          ..writeln()
          ..writeln('## ${r.id} (${r.taskId}): ${r.title}${r.failed ? ' — FAILED' : ''}${files.isEmpty ? '' : ' — files: ${files.join(', ')}'}')
          ..writeln(_cut(r.output, s.resultChars, forUser: true));
      }
      if (done.every((r) => r.failed) && !stopped) {
        response
          ..writeln()
          ..writeln('Every developer job failed. Do the work yourself, or try again with simpler jobs.');
      }
      if (refused > 0) {
        response
          ..writeln()
          ..writeln('$refused task(s) were not run: at most $limit per call. Send them in another call.');
      }
      if (unknownRevise.isNotEmpty) {
        response
          ..writeln()
          ..writeln('No earlier result has the id ${unknownRevise.join(', ')}; the task was run as a new one.');
      }
      if (investigate && !stopped) {
        response
          ..writeln()
          ..write(s.investigateFirst
              ? 'Now combine these reports into the design and show it to the user: the diagram, what each part does, the risks, and the number of parts (workers). If it looks bigger or slower than planned, propose more workers or a finer split. Then ask with ask_user whether to build it (for example 実装する / 設計を直す, with free input) and wait. If they want changes, revise and investigate again; if they approve, call delegate with phase "build" and the same task ids. The user already sees the reports: do not copy them.'
              : 'Read the reports and build with phase "build" and the same task ids. The user already sees the reports: do not copy them.');
      } else {
        response
          ..writeln()
          ..write('The user already sees these files. Do not copy them into your answer.');
      }

      final used = {for (final r in done) if (r.model.isNotEmpty) r.model};
      final shown = StringBuffer('> ${investigate ? '調査' : '実装'}: ${done.length} 件を、分担数 $workers・${used.isEmpty ? '（実行なし）' : used.join('・')} で並列に\n');
      if (done.length > 1) {
        final plan = call.plan.trim().isNotEmpty
            ? call.plan.trim()
            : PlanGraph.build(
                [for (final t in accepted) (t.id, t.title)],
                {for (final t in accepted) t.id: t.dependsOn},
              );
        shown
          ..writeln()
          ..writeln('```mermaid')
          ..writeln(_fence(plan))
          ..writeln('```');
      }
      for (final r in done) {
        shown
          ..writeln()
          ..writeln('### ${r.title}${r.model.isEmpty ? '' : '（${r.model}）'}')
          ..writeln()
          ..writeln(r.output);
      }

      return ToolOutcome(
        response.toString(),
        ToolActivity(
          'Delegate',
          '${stopped ? '停止: ' : ''}${investigate ? '調査' : '実装'}（分担数 $workers・coding ${models.length} 個に ${done.length} 件）: ${done.map((r) => r.title).join('、')}',
          failed: done.every((r) => r.failed),
        ),
        shown: shown.toString(),
      );
    } finally {
      if (device) releaseDevice?.call();
    }
  }

  /// One job: waits for a free model, asks it, tells it once to decide itself when it asks a question
  /// back, and gives the job to another model when this one fails.
  Future<_Stored> _runJob({
    required _Pool pool,
    required String id,
    required String taskId,
    required String title,
    required String summary,
    required DelegateTask base,
    required List<AiMessage> messages,
    required CodingSettings s,
    required bool Function() isStopped,
    required RunMeter? meter,
    required void Function() onStart,
    required void Function() onEnd,
    bool investigate = false,
  }) async {
    final tried = <int>{};
    var lastError = '';
    onStart();
    try {
      // the model that was asked first, then (when it failed) one more
      for (var attempt = 0; attempt < (pool.models.length > 1 ? 2 : 1); attempt++) {
        if (isStopped()) break;
        final index = await pool.acquire(avoid: tried);
        tried.add(index);
        final model = pool.models[index];
        try {
          meter?.developerRequest();
          var answer = await model.ask(
            messages,
            maxTokens: s.developerMaxTokens,
            autoTokens: 16384,
            cancelled: isStopped,
            temperature: 0.2,
          );
          if (!investigate && CodingPrompts.questionIn(answer) != null && !isStopped()) {
            // nobody answers a developer: it decides, once
            meter?.developerRequest();
            answer = await model.ask(
              [
                ...messages,
                AiMessage(AiRole.assistant, text: answer),
                const AiMessage(AiRole.user, text: CodingPrompts.decideYourself),
              ],
              maxTokens: s.developerMaxTokens,
              autoTokens: 16384,
              cancelled: isStopped,
              temperature: 0.2,
            );
          }
          answer = answer.trim();
          final question = investigate ? null : CodingPrompts.questionIn(answer);
          if (question != null) {
            return _Stored(id, taskId, title, summary, base, '（この coding は、決められないと答えました: $question）', failed: true, model: model.label);
          }
          if (answer.isEmpty && !isStopped()) {
            lastError = '空の答えが返りました';
            continue;
          }
          return _Stored(id, taskId, title, summary, base, answer, model: model.label);
        } on Object catch (e) {
          lastError = e is EngineException ? e.message : '$e';
        } finally {
          pool.release(index);
        }
      }
      if (isStopped()) return _Stored(id, taskId, title, summary, base, '（停止しました）', failed: true);
      return _Stored(id, taskId, title, summary, base, '（このタスクは失敗しました: $lastError）', failed: true);
    } finally {
      onEnd();
    }
  }

  /// The parser gives every job an id; a job made some other way gets one here, and a repeated id is
  /// replaced, so that two jobs are never the same node.
  static List<DelegateTask> _withIds(Iterable<DelegateTask> tasks) {
    final seen = <String>{};
    final out = <DelegateTask>[];
    for (final t in tasks) {
      var id = t.id;
      if (id.isEmpty || seen.contains(id)) {
        var n = out.length + 1;
        while (seen.contains(id = 't$n')) {
          n++;
        }
      }
      seen.add(id);
      out.add(id == t.id
          ? t
          : DelegateTask(id: id, title: t.title, instructions: t.instructions, files: t.files, revise: t.revise, dependsOn: t.dependsOn));
    }
    return out;
  }

  static String _cut(String text, int chars, {bool forUser = false}) => chars > 0 && text.length > chars
      ? '${text.substring(0, chars)}\n[… ${text.length - chars} more characters${forUser ? ', which the user can read' : ''} …]'
      : text;

  /// A fence inside the plan would end the code block that shows it.
  static String _fence(String plan) => plan.replaceAll('```', "'''");
}

/// The developer models and how many requests each takes at the same time. A job asks for a model
/// and gets the least busy one that has room; with none free it waits for one.
class _Pool {
  _Pool(this.models, int perModel, {int total = 1 << 20})
      : _capacity = [for (final m in models) m.maxParallel < 1 ? 1 : (perModel < m.maxParallel ? perModel : m.maxParallel).clamp(1, 1 << 20)],
        _running = List.filled(models.length, 0),
        _total = total < 1 ? 1 : total;

  /// The 分担数: the most jobs running at once over all the models.
  final int _total;

  final List<RoleModel> models;
  final List<int> _capacity;
  final List<int> _running;
  final _waiting = <Completer<void>>[];

  /// The index of a model with room. [avoid] are models that already failed this job: they are chosen
  /// only when no other has room, or none other exists.
  Future<int> acquire({Set<int> avoid = const {}}) async {
    while (true) {
      final busy = _running.fold(0, (a, b) => a + b);
      final free = busy >= _total ? <int>[] : [for (var i = 0; i < models.length; i++) if (_running[i] < _capacity[i]) i];
      final preferred = [for (final i in free) if (!avoid.contains(i)) i];
      final choices = preferred.isNotEmpty ? preferred : (models.length > 1 && avoid.length < models.length ? <int>[] : free);
      if (choices.isNotEmpty) {
        choices.sort((a, b) {
          final byLoad = (_running[a] / _capacity[a]).compareTo(_running[b] / _capacity[b]);
          return byLoad != 0 ? byLoad : a.compareTo(b);
        });
        _running[choices.first]++;
        return choices.first;
      }
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    }
  }

  void release(int index) {
    _running[index]--;
    final waiting = List.of(_waiting);
    _waiting.clear();
    for (final w in waiting) {
      w.complete();
    }
  }
}

class _Stored {
  const _Stored(this.id, this.taskId, this.title, this.summary, this.task, this.output, {this.failed = false, this.model = ''});

  /// The result id the planner uses to send the job back (`d3`).
  final String id;

  /// The planner's own id of the job in this call (`a`).
  final String taskId;
  final String title;
  final String summary;

  /// The job as first given: a correction runs this again with the earlier answer and the feedback.
  final DelegateTask task;
  final String output;
  final bool failed;

  /// The model that answered, for the screen.
  final String model;
}
