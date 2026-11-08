import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/ui/chat_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<List<String>>> pump(WidgetTester tester, McpCall call, {bool rememberable = true, String note = ''}) async {
  tester.view.physicalSize = const Size(411, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final answers = <List<String>>[];
  await tester.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ToolApprovalCard(
          call: call,
          tile: ToolApproval.tile(call, rememberable: rememberable, note: note),
          onAnswer: (selected, _) => answers.add(selected),
        ),
      ),
    ),
  ));
  return answers;
}

void main() {
  final long = '${'void main() {\n  print("長い内容");\n}\n' * 30}end';
  final push = McpCall('mcp_github__create_or_update_file', {'owner': 'keusidan', 'path': 'lib/a.dart', 'content': long});

  testWidgets('a tool is shown by server and name, with the arguments one to a line, a long one folded', (tester) async {
    await pump(tester, push);
    expect(find.text('この道具を実行しますか？'), findsOneWidget);
    expect(find.text('github · create_or_update_file'), findsOneWidget);
    expect(find.text('owner'), findsOneWidget);
    expect(find.text('keusidan'), findsOneWidget);
    expect(find.text('lib/a.dart'), findsOneWidget);
    expect(find.textContaining('…（全部で ${long.length} 文字'), findsOneWidget, reason: 'the long content is cut, and says how long it is');
    expect(find.text('全文を見る（${long.length} 文字）'), findsOneWidget);

    await tester.tap(find.text('全文を見る（${long.length} 文字）'));
    await tester.pump();
    expect(find.text('閉じる'), findsOneWidget);
    expect(find.textContaining('print("長い内容");', findRichText: true), findsWidgets, reason: 'the whole text is in a scrollable box');
    expect(find.textContaining('…（全部で'), findsNothing);
    await tester.tap(find.text('閉じる'));
    await tester.pump();
    expect(find.text('全文を見る（${long.length} 文字）'), findsOneWidget);
  });

  testWidgets('three buttons for a tool, and each answers once and only once', (tester) async {
    final answers = await pump(tester, push);
    expect(find.text(ToolApproval.approve), findsOneWidget);
    expect(find.text(ToolApproval.approveAlways), findsOneWidget);
    expect(find.text(ToolApproval.reject), findsOneWidget);

    await tester.tap(find.text(ToolApproval.approveAlways));
    await tester.pump();
    expect(answers, [
      [ToolApproval.approveAlways],
    ]);
    // the card turns to "running" and the buttons stop answering (a second tap used to start the tool twice)
    expect(find.text('実行しています…'), findsOneWidget);
    await tester.tap(find.text('実行しています…'), warnIfMissed: false);
    await tester.tap(find.text(ToolApproval.reject), warnIfMissed: false);
    await tester.pump();
    expect(answers, hasLength(1));
  });

  testWidgets('pressing やめる does not claim anything is running', (tester) async {
    final answers = await pump(tester, push);
    await tester.tap(find.text(ToolApproval.reject));
    await tester.pump();
    expect(answers, [
      [ToolApproval.reject],
    ]);
    expect(find.text('実行しています…'), findsNothing);
    expect(find.text(ToolApproval.approve), findsOneWidget);
    await tester.tap(find.text(ToolApproval.approve), warnIfMissed: false);
    await tester.pump();
    expect(answers, hasLength(1), reason: 'the card is answered');
  });

  testWidgets('pressing 実行する says it is running and cannot be pressed again', (tester) async {
    final answers = await pump(tester, push);
    await tester.tap(find.text(ToolApproval.approve));
    await tester.pump();
    expect(find.text('実行しています…'), findsOneWidget);
    await tester.tap(find.text('実行しています…'));
    await tester.pump();
    expect(answers, [
      [ToolApproval.approve],
    ]);
  });

  testWidgets('a command is shown as the command, with where it runs, and the reason when it asks after reading from outside', (tester) async {
    const shell = McpCall(Protocol.runCommandName, {'command': 'pip install requests', 'cwd': '/workspace/app', 'timeout_seconds': 90});
    await pump(tester, shell, note: '検索や外部ツールの結果を読んだあとなので、確認します');
    expect(find.text('このコマンドを実行しますか？'), findsOneWidget);
    expect(find.textContaining('\$ pip install requests', findRichText: true), findsOneWidget);
    expect(find.text('場所: /workspace/app・最大 90 秒'), findsOneWidget);
    expect(find.text('検索や外部ツールの結果を読んだあとなので、確認します'), findsOneWidget);
    expect(find.text(ToolApproval.approveAlways), findsNothing, reason: 'a command cannot be remembered');
    expect(find.text(ToolApproval.approve), findsOneWidget);
    expect(find.text(ToolApproval.reject), findsOneWidget);
  });

  testWidgets('a tool with no arguments says so', (tester) async {
    await pump(tester, const McpCall('mcp_x__list_things', {}), rememberable: false);
    expect(find.text('（引数なし）'), findsOneWidget);
    expect(find.text(ToolApproval.approveAlways), findsNothing);
  });
}
