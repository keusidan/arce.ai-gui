import 'dart:async';

import 'package:arce_ai/ai/delegation.dart';
import 'package:arce_ai/core/coding_plan.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'delegation_test.dart' show FakeDeveloper;

/// The rounds of the 分担モード: investigate (reports, all of them), the user's answer, then build.
void main() {
  /// The planner's call as it writes it, through the app's own parser.
  Delegate call(String arguments) {
    final r = ToolCallParser.parse('{"name":"delegate","arguments":$arguments}', [Protocol.delegate]);
    expect(r, isA<ParseOk>(), reason: arguments);
    return (r as ParseOk).call as Delegate;
  }

  const tasks = '"tasks":[{"id":"ui","title":"画面","instructions":"画面を作る"},{"id":"api","title":"API","instructions":"API を作る"},{"id":"db","title":"保存","instructions":"保存を作る"}]';

  late int inputs;
  late DelegateSession session;
  setUp(() {
    inputs = 0;
    session = DelegateSession(() => inputs);
  });

  DelegateRunner runner(FakeDeveloper dev, {CodingSettings settings = const CodingSettings(enabled: true, developer: 'd|m', maxWorkers: 4)}) =>
      DelegateRunner(settings: () => settings, developers: () => [dev]);

  test('the planner writes the phase and the number of workers; anything else is the planner\'s to fix', () {
    expect(call('{"phase":"investigate","workers":3,$tasks}').phase, DelegatePhase.investigate);
    expect(call('{"phase":"build",$tasks}').phase, DelegatePhase.build);
    expect(call('{$tasks}').phase, isNull, reason: 'the setting decides');
    expect(call('{"workers":3.0,$tasks}').workers, 3);
    for (final bad in ['{"phase":"deploy",$tasks}', '{"workers":0,$tasks}', '{"workers":"3",$tasks}', '{"workers":2.5,$tasks}']) {
      expect(ToolCallParser.parse('{"name":"delegate","arguments":$bad}', [Protocol.delegate]), isA<ParseInvalid>(), reason: bad);
    }
  });

  test('investigate: every part reports (no code is asked for), the planner gets all the reports at once, and is told to ask the user', () async {
    final finished = <String>[];
    final dev = FakeDeveloper((m) async {
      final title = RegExp(r'# Your task: (\S+)').firstMatch(m[1].text)!.group(1)!;
      // the parts end at different times: the answer still waits for all of them
      await Future<void>.delayed(Duration(milliseconds: title == 'API' ? 60 : 5));
      finished.add(title);
      return '- What to do: $title の手順\n- Size: small';
    });
    final out = await runner(dev).run(call('{"phase":"investigate",$tasks}'), stop: Completer<void>().future, session: session);
    expect(finished, hasLength(3), reason: 'it waited for every part');
    // each developer was told to look into its part and report, not to write it
    for (final asked in dev.calls) {
      expect(asked.first.text, allOf(contains('investigation round'), contains('Do not write the implementation')));
    }
    expect(out.response, allOf(contains('Investigation reports, all 3'), contains('画面 の手順'), contains('API の手順'), contains('保存 の手順')));
    expect(out.response, allOf(contains('ask_user'), contains('phase "build"')));
    expect(out.shown, allOf(contains('> 調査: 3 件を'), contains('API の手順')), reason: 'the user sees the reports');
    expect(out.activity.summary, startsWith('調査'));
    expect(session.reports.keys, unorderedEquals(['ui', 'api', 'db']));
  });

  test('build is refused before an investigation, and before the user has answered after it', () async {
    final dev = FakeDeveloper((_) => '```dart\nvoid main() {}\n```');
    final r = runner(dev);
    final none = await r.run(call('{"phase":"build",$tasks}'), stop: Completer<void>().future, session: session);
    expect(none.activity.failed, isTrue);
    expect(none.response, contains('investigate first'));
    expect(dev.calls, isEmpty, reason: 'nothing was built');

    await r.run(call('{"phase":"investigate",$tasks}'), stop: Completer<void>().future, session: session);
    final asked = dev.calls.length;
    final early = await r.run(call('{"phase":"build",$tasks}'), stop: Completer<void>().future, session: session);
    expect(early.activity.failed, isTrue);
    expect(early.response, contains('has not answered'));
    expect(dev.calls.length, asked, reason: 'still nothing built');
  });

  test('after the user answered, each part is built with its own report, and the result goes back as before', () async {
    final dev = FakeDeveloper((m) {
      final investigating = m.first.text.contains('investigation round');
      final title = RegExp(r'# Your task: (\S+)').firstMatch(m[1].text)!.group(1)!;
      return investigating ? 'REPORT-$title' : 'File: $title.dart\n```dart\n// $title\n```';
    });
    final r = runner(dev);
    await r.run(call('{"phase":"investigate",$tasks}'), stop: Completer<void>().future, session: session);
    inputs++; // the user answered the question card: 実装する
    dev.calls.clear();
    final built = await r.run(call('{"phase":"build",$tasks}'), stop: Completer<void>().future, session: session);
    expect(built.activity.failed, isFalse);
    expect(dev.calls, hasLength(3));
    for (final asked in dev.calls) {
      final title = RegExp(r'# Your task: (\S+)').firstMatch(asked[1].text)!.group(1)!;
      expect(asked[1].text, contains('Your own investigation report'), reason: title);
      expect(asked[1].text, contains('REPORT-$title'), reason: 'its own report, not another part\'s');
      expect(asked.first.text, isNot(contains('investigation round')));
    }
    expect(built.shown, contains('> 実装: 3 件を'));
    expect(built.response, contains('Developer results'));
  });

  test('without a phase the setting decides: investigate first, then build once the user answered', () async {
    final dev = FakeDeveloper((m) => m.first.text.contains('investigation round') ? 'REPORT' : 'CODE');
    final r = runner(dev);
    expect((await r.run(call('{$tasks}'), stop: Completer<void>().future, session: session)).shown, contains('> 調査'));
    inputs++;
    expect((await r.run(call('{$tasks}'), stop: Completer<void>().future, session: session)).shown, contains('> 実装'));
    // with the setting off, it builds at once
    final off = runner(dev, settings: const CodingSettings(enabled: true, developer: 'd|m', investigateFirst: false));
    expect((await off.run(call('{$tasks}'), stop: Completer<void>().future, session: DelegateSession(() => 0))).shown, contains('> 実装'));
  });

  test('the 分担数: what the planner asked for, within the setting; asking for more is answered with how to get it', () async {
    var running = 0;
    var peak = 0;
    final dev = FakeDeveloper((_) async {
      running++;
      if (running > peak) peak = running;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      running--;
      return 'REPORT';
    }, maxParallel: 8);
    const six = '"tasks":[{"title":"a","instructions":"a"},{"title":"b","instructions":"b"},{"title":"c","instructions":"c"},{"title":"d","instructions":"d"},{"title":"e","instructions":"e"},{"title":"f","instructions":"f"}]';
    final settings = const CodingSettings(enabled: true, developer: 'd|m', parallel: 8, maxWorkers: 3, maxTasks: 8);
    final two = await runner(dev, settings: settings).run(call('{"phase":"investigate","workers":2,$six}'), stop: Completer<void>().future, session: session);
    expect(peak, 2, reason: 'the planner chose 2');
    expect(two.shown, contains('分担数 2'));
    peak = 0;
    final many = await runner(dev, settings: settings).run(call('{"phase":"investigate","workers":10,$six}'), stop: Completer<void>().future, session: session);
    expect(peak, 3, reason: 'the setting allows 3');
    expect(many.response, allOf(contains('You asked for 10 workers'), contains('allows 3'), contains('propose it to the user')));
  });

  test('the planner is told the rounds, the limit of workers, and that it may propose more', () {
    final on = CodingPrompts.plannerInstructions(maxTasks: 8, reviewRounds: 1, maxWorkers: 6);
    expect(on, allOf(contains('phase "investigate"'), contains('ask_user'), contains('phase "build"'), contains('at most 6'), contains('propose more parts')));
    final off = CodingPrompts.plannerInstructions(maxTasks: 8, reviewRounds: 1, investigateFirst: false);
    expect(off, isNot(contains('phase "investigate"')));
  });

  test('a message or an answer of the user counts; it is what lets the build go', () {
    final s = DelegateSession(() => inputs);
    expect(s.approved, isFalse);
    s.reportedAt = inputs;
    expect(s.approved, isFalse);
    inputs++;
    expect(s.approved, isTrue);
  });
}
