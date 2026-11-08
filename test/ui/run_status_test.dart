import 'package:arce_ai/core/run_progress.dart';
import 'package:arce_ai/ui/chat_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, RunProgress progress) => tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: RunStatus(progress: progress)),
    ));

void main() {
  testWidgets('while the reply goes on: the step, the line more, the numbers and a clock that counts', (tester) async {
    final started = DateTime.now().millisecondsSinceEpoch - 65000;
    await pump(
      tester,
      RunProgress(
        startedAtMs: started,
        stage: 'plan が考えています',
        detail: 'アルゴリズムを選ぶ',
        modelRequests: 2,
        developerRequests: 1,
        toolRuns: 1,
        round: 2,
      ),
    );
    expect(find.text('plan が考えています'), findsOneWidget);
    expect(find.text('アルゴリズムを選ぶ'), findsOneWidget);
    expect(find.textContaining('2 回目の返信 · 通信 3 回（plan 2・coding 1） · ツール 1 回 · 1:0'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('1:0'), findsOneWidget, reason: 'the clock moves by itself, without a new message');
    // the timer is cancelled when the widget goes (no pending timer is left at the end of the test)
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('when it is over: one quiet line with the totals, and nothing to spin', (tester) async {
    await pump(tester, const RunProgress(startedAtMs: 0, finishedAtMs: 84000, modelRequests: 3, developerRequests: 2));
    expect(find.text('通信 5 回（plan 3・coding 2） · 所要 1:24'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a reply that sent nothing leaves no line', (tester) async {
    await pump(tester, const RunProgress(startedAtMs: 0, finishedAtMs: 10));
    expect(find.byType(Text), findsNothing);
  });
}
