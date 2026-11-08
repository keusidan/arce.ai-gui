import 'dart:async';

import 'package:arce_ai/ai/delegation.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/roles.dart';
import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/run_progress.dart';
import 'package:flutter_test/flutter_test.dart';

/// A developer model that answers from a script, and records what it was asked and how many
/// requests were running at once.
class FakeDeveloper implements RoleModel {
  FakeDeveloper(this.answer, {this.maxParallel = 4, this.usesDevice = false, this.delay = Duration.zero, this.name = '開発・テスト'});

  final String name;

  final FutureOr<String> Function(List<AiMessage> messages) answer;
  final Duration delay;

  @override
  final int maxParallel;
  @override
  final bool usesDevice;
  @override
  String get label => name;

  final calls = <List<AiMessage>>[];
  var running = 0;
  var peak = 0;
  var cancelCalls = 0;

  @override
  Future<String> ask(
    List<AiMessage> messages, {
    required int maxTokens,
    required bool Function() cancelled,
    double temperature = 0.3,
    int autoTokens = 4096,
  }) async {
    calls.add(messages);
    running++;
    if (running > peak) peak = running;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await answer(messages);
    } finally {
      running--;
    }
  }

  @override
  void cancel() => cancelCalls++;
}

Delegate delegateOf(int n, {String summary = '共有の決めごと'}) => Delegate(
      summary: summary,
      tasks: [for (var i = 1; i <= n; i++) DelegateTask(title: 'タスク$i', instructions: '$i を作る')],
    );

DelegateRunner runnerOf(FakeDeveloper? dev, {List<FakeDeveloper> more = const [], int maxTasks = 4, int parallel = 3, int resultChars = 12000}) => DelegateRunner(
      settings: () => CodingSettings(investigateFirst: false, enabled: true, planner: 'p|m', developer: 'd|m', maxTasks: maxTasks, parallel: parallel, resultChars: resultChars),
      developers: () => [?dev, ...more],
    );

final never = Completer<void>().future;

void main() {
  test('仕事は同時に走り、結果は番号つきで plan に返り、ファイルはユーザーに見せる分として別に返る', () async {
    final dev = FakeDeveloper((m) => '```python\nprint(${m.length})\n```', delay: const Duration(milliseconds: 20));
    final outcome = await runnerOf(dev).run(delegateOf(3), stop: never);

    expect(dev.calls, hasLength(3));
    expect(dev.peak, 3, reason: 'the three jobs ran at the same time');
    expect(outcome.response, allOf(contains('## d1 (t1): タスク1'), contains('## d2 (t2): タスク2'), contains('## d3 (t3): タスク3')));
    expect(outcome.response, contains('Do not copy them into your answer'));
    expect(outcome.shown, allOf(contains('> 実装: 3 件を、分担数 4・開発・テスト で並列に'), contains('### タスク1'), contains('print(')));
    expect(outcome.activity.tool, 'Delegate');
    expect(outcome.activity.failed, isFalse);
  });

  Delegate planOf(List<(String id, String title, List<String> after)> jobs, {String plan = ''}) => Delegate(
        summary: '決めごと',
        plan: plan,
        tasks: [for (final (id, title, after) in jobs) DelegateTask(id: id, title: title, instructions: '$title を作る', dependsOn: after)],
      );

  test('待つ仕事は、前の仕事が終わってから始まり、その結果を渡される。待たない仕事は、そのあいだも同時に走る', () async {
    final events = <String>[];
    final dev = FakeDeveloper((m) async {
      final title = RegExp(r'# Your task: (.+)').firstMatch(m[1].text)!.group(1)!;
      events.add('start:$title');
      await Future<void>.delayed(Duration(milliseconds: title == 'モデル' ? 60 : 10));
      events.add('end:$title');
      return 'File: $title.py\n```python\n# $title\n```';
    });
    final outcome = await runnerOf(dev).run(
      planOf([('a', 'モデル', []), ('b', '画面', ['a']), ('c', '設定', [])]),
      stop: never,
    );
    expect(events.indexOf('start:画面'), greaterThan(events.indexOf('end:モデル')), reason: '画面 waits for モデル');
    expect(events.indexOf('start:設定'), lessThan(events.indexOf('end:モデル')), reason: '設定 does not wait, it runs while モデル runs');
    final screen = dev.calls.firstWhere((m) => m[1].text.contains('# Your task: 画面'));
    expect(screen[1].text, allOf(contains('# Result of the job you waited for: d1 — モデル'), contains('# モデル')));
    final other = dev.calls.firstWhere((m) => m[1].text.contains('# Your task: 設定'));
    expect(other[1].text, isNot(contains('Result of the job you waited for')));
    expect(outcome.response, contains('files: モデル.py'));
  });

  test('前の仕事が失敗したら、それを待つ仕事は実行せず、そう伝える', () async {
    final dev = FakeDeveloper((m) {
      if (m[1].text.contains('# Your task: 土台')) throw EngineException('HTTP 500');
      return 'できた';
    });
    final outcome = await runnerOf(dev).run(planOf([('a', '土台', []), ('b', '上物', ['a']), ('c', '別件', [])]), stop: never);
    expect(dev.calls.where((m) => m[1].text.contains('# Your task: 上物')), isEmpty, reason: 'not asked at all');
    expect(outcome.response, contains('前の仕事 d1 が失敗したため、実行しませんでした'));
    expect(outcome.response, contains('## d3 (c): 別件\nできた'), reason: 'the independent job still ran');
    expect(outcome.activity.failed, isFalse, reason: 'one of three worked');
  });

  test('coding が複数あれば、仕事は分け合って同時に走る。1 つの模型の同時数は、設定とモデルの上限の小さいほう', () async {
    final a = FakeDeveloper((m) => 'A', delay: const Duration(milliseconds: 25), name: 'モデルA', maxParallel: 2);
    final b = FakeDeveloper((m) => 'B', delay: const Duration(milliseconds: 25), name: 'モデルB', maxParallel: 2);
    final outcome = await runnerOf(a, more: [b], parallel: 8).run(delegateOf(4), stop: never);
    expect(a.calls, hasLength(2));
    expect(b.calls, hasLength(2));
    expect(a.peak, 2);
    expect(b.peak, 2);
    expect(outcome.shown, allOf(contains('4 件を、分担数 4・モデルA・モデルB で並列に'), contains('（モデルA）'), contains('（モデルB）')));
    expect(outcome.activity.summary, contains('coding 2 個に 4 件'));
  });

  test('1 つのモデルが失敗したら、その仕事は別のモデルに渡る', () async {
    final broken = FakeDeveloper((m) => throw EngineException('HTTP 503'), name: '壊れた');
    final good = FakeDeveloper((m) => '直った', name: '動く');
    final outcome = await runnerOf(broken, more: [good]).run(delegateOf(1), stop: never);
    expect(good.calls, hasLength(1));
    expect(outcome.response, contains('直った'));
    expect(outcome.shown, contains('（動く）'));
    expect(outcome.activity.failed, isFalse);
  });

  test('質問で返ってきたら、plan には聞かず、決めて作るよう 1 回だけ伝える。それでも質問なら、その仕事は失敗として返す', () async {
    var n = 0;
    final dev = FakeDeveloper((m) => ++n == 1 ? 'QUESTION: どの言語ですか？' : 'Python で作りました');
    final outcome = await runnerOf(dev).run(delegateOf(1), stop: never);
    expect(dev.calls, hasLength(2));
    expect(dev.calls.last.last.text, CodingPrompts.decideYourself);
    expect(dev.calls.last[dev.calls.last.length - 2].text, 'QUESTION: どの言語ですか？', reason: 'the question is in the conversation');
    expect(outcome.response, contains('Python で作りました'));

    final stubborn = FakeDeveloper((m) => 'question: まだ決められない');
    final failed = await runnerOf(stubborn).run(delegateOf(1), stop: never);
    expect(stubborn.calls, hasLength(2), reason: 'told once, not for ever');
    expect(failed.response, allOf(contains('FAILED'), contains('決められないと答えました: まだ決められない')));
    expect(failed.activity.failed, isTrue);
  });

  test('分割の図：plan の図があればそれを、無ければ依存から描いて、ユーザーに見せる。仕事が 1 つなら出さない', () async {
    final dev = FakeDeveloper((m) => 'ok');
    final drawn = await runnerOf(dev).run(planOf([('a', '土台', []), ('b', '上物', ['a'])]), stop: never);
    expect(drawn.shown, allOf(contains('```mermaid'), contains('flowchart TD'), contains('a["土台"]'), contains('a --> b')));
    const own = 'flowchart LR\n  a["土台"] --> b["上物"]';
    final written = await runnerOf(dev).run(planOf([('a', '土台', []), ('b', '上物', ['a'])], plan: own), stop: never);
    expect(written.shown, contains('flowchart LR'));
    final single = await runnerOf(dev).run(delegateOf(1), stop: never);
    expect(single.shown, isNot(contains('mermaid')));
  });

  test('人数の上限で切られた仕事を待つ仕事は、実行せずに伝える', () async {
    final dev = FakeDeveloper((m) => 'ok');
    final outcome = await runnerOf(dev, maxTasks: 1).run(planOf([('a', '一つ目', []), ('b', '二つ目', ['a'])]), stop: never);
    expect(outcome.response, contains('1 task(s) were not run'));
    expect(dev.calls, hasLength(1));
  });

  test('進み具合：coding への要求の数と、終わった件数が、途中でも分かる', () async {
    final meter = RunMeter()..begin();
    final stages = <String>[];
    meter.onChange = (p) {
      if (p != null && (stages.isEmpty || stages.last != p.stage)) stages.add(p.stage);
    };
    final dev = FakeDeveloper((m) => 'ok', delay: const Duration(milliseconds: 10));
    await runnerOf(dev).run(delegateOf(3), stop: never, meter: meter);

    expect(meter.progress!.developerRequests, 3);
    expect(stages.first, 'coding が実装しています（0/3 件完了・分担数 4）');
    expect(stages.last, 'coding が実装しています（3/3 件完了・分担数 4）');
    expect(stages, contains('coding が実装しています（1/3 件完了・分担数 4）'));
    expect(meter.progress!.counts, '通信 3 回（plan 0・coding 3）');
  });

  test('coding には、要約とそのタスクだけが渡る（ほかのタスクは見えない）', () async {
    final dev = FakeDeveloper((m) => 'ok');
    await runnerOf(dev).run(delegateOf(2, summary: '決めごとX'), stop: never);
    final first = dev.calls.firstWhere((m) => m[1].text.contains('1 を作る'));
    expect(first[0].role, AiRole.system);
    expect(first[1].text, allOf(contains('決めごとX'), contains('1 を作る'), isNot(contains('2 を作る'))));
  });

  test('同時に走らせる数は、設定と coding の上限の小さいほう。ローカルモデルは 1', () async {
    final limited = FakeDeveloper((m) => 'ok', delay: const Duration(milliseconds: 10));
    await runnerOf(limited, parallel: 2).run(delegateOf(4), stop: never);
    expect(limited.peak, 2);

    final device = FakeDeveloper((m) => 'ok', maxParallel: 1, usesDevice: true, delay: const Duration(milliseconds: 10));
    await runnerOf(device, parallel: 8).run(delegateOf(4), stop: never, acquireDevice: () => true, releaseDevice: () {});
    expect(device.peak, 1);
  });

  test('1 回の依頼に入れられる数を超えた分は断り、何件断ったかを plan に伝える', () async {
    final dev = FakeDeveloper((m) => 'ok');
    final outcome = await runnerOf(dev, maxTasks: 2).run(delegateOf(5), stop: never);
    expect(dev.calls, hasLength(2));
    expect(outcome.response, contains('3 task(s) were not run: at most 2 per call'));
  });

  test('1 件が失敗しても、ほかの結果は返る。失敗はその件の結果として書かれる', () async {
    final dev = FakeDeveloper((m) {
      if (m[1].text.contains('2 を作る')) throw EngineException('HTTP 500');
      return 'できた';
    });
    final outcome = await runnerOf(dev).run(delegateOf(3), stop: never);
    expect(outcome.response, contains('できた'));
    expect(outcome.response, contains('このタスクは失敗しました: HTTP 500'));
    expect(outcome.activity.failed, isFalse, reason: 'only when every job failed');

    final allBad = await runnerOf(FakeDeveloper((m) => throw EngineException('x'))).run(delegateOf(2), stop: never);
    expect(allBad.activity.failed, isTrue);
  });

  test('revise: 前の結果の番号を指すと、前の答えと直す内容が、元のタスクといっしょに渡る', () async {
    final dev = FakeDeveloper((m) => m.length == 2 ? '最初の答え' : '直した答え');
    final runner = runnerOf(dev);
    await runner.run(delegateOf(1, summary: '決めごと'), stop: never);

    final fixed = await runner.run(
      const Delegate(summary: '別の要約', tasks: [DelegateTask(title: '直し', instructions: '関数名を add に', revise: 'd1')]),
      stop: never,
    );
    final messages = dev.calls.last;
    expect(messages.map((m) => m.role), [AiRole.system, AiRole.user, AiRole.assistant, AiRole.user]);
    expect(messages[1].text, allOf(contains('決めごと'), contains('1 を作る')), reason: 'the first job and plan, as first given');
    expect(messages[2].text, '最初の答え');
    expect(messages[3].text, contains('関数名を add に'));
    expect(fixed.response, contains('直した答え'));
  });

  test('知らない番号の revise は、新しいタスクとして走らせ、そう伝える', () async {
    final dev = FakeDeveloper((m) => 'ok');
    final outcome = await runnerOf(dev).run(
      const Delegate(summary: '', tasks: [DelegateTask(title: 't', instructions: 'やる', revise: 'd99')]),
      stop: never,
    );
    expect(dev.calls.single, hasLength(2), reason: 'no earlier answer was given');
    expect(outcome.response, contains('No earlier result has the id d99'));
  });

  test('plan が読む結果は、設定の長さで切る。ユーザーに見せる分は切らない', () async {
    final dev = FakeDeveloper((m) => 'あ' * 5000);
    final outcome = await runnerOf(dev, resultChars: 1000).run(delegateOf(1), stop: never);
    expect(outcome.response, contains('4000 more characters'));
    expect(outcome.response.length, lessThan(2000));
    expect(outcome.shown, contains('あ' * 5000));
  });

  test('停止されたら coding を止め、終わった分だけを返す', () async {
    final stop = Completer<void>();
    final dev = FakeDeveloper((m) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return '途中';
    }, delay: Duration.zero);
    final running = runnerOf(dev).run(delegateOf(2), stop: stop.future);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    stop.complete();
    final outcome = await running;
    expect(dev.cancelCalls, 1);
    expect(outcome.response, contains('The user stopped the work'));
    expect(outcome.activity.summary, startsWith('停止'));
  });

  test('coding が使えないときは、plan に自分でやるよう伝える', () async {
    final outcome = await runnerOf(null).run(delegateOf(1), stop: never);
    expect(outcome.activity.failed, isTrue);
    expect(outcome.response, contains('Do the work yourself'));
  });

  test('ローカルモデルが coding の役で、ほかのチャットが使っているなら、使えないと伝える。使ったあとは返す', () async {
    final dev = FakeDeveloper((m) => 'ok', maxParallel: 1, usesDevice: true);
    var released = 0;
    final busy = await runnerOf(dev).run(delegateOf(1), stop: never, acquireDevice: () => false, releaseDevice: () => released++);
    expect(busy.response, contains('being used by another chat'));
    expect(dev.calls, isEmpty);
    expect(released, 0, reason: 'it was never taken');

    final done = await runnerOf(dev).run(delegateOf(1), stop: never, acquireDevice: () => true, releaseDevice: () => released++);
    expect(done.response, contains('ok'));
    expect(released, 1);
  });
}
