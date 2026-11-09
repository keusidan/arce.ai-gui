import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/app.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/page_blocks.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/chat_widgets.dart' show CodeCard;
import 'package:arce_ai/ui/embedded_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

/// A reply that holds code blocks, put on the screen as the model's last message.
Future<AppController> showing(WidgetTester tester, String reply, {Directory? workspace}) async {
  setSize(tester, const Size(411, 860));
  final app = await makeApp(tester, workspace: workspace);
  await tester.pumpWidget(ArceApp(app: app));
  await tester.pump();
  app.chat.restore(
    ConversationSnapshot(
      messages: [
        const UiMessage(id: 0, role: Role.user, text: '作って'),
        UiMessage(id: 1, role: Role.assistant, text: reply),
      ],
      history: const [],
      nextId: 2,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return app;
}

const _html = '```html\n<h1>こんにちは</h1><script>document.title="x"</script>\n```';

void main() {
  tearDown(() => EmbeddedPage.builder = null);

  testWidgets('an HTML block has a button that shows the page inside the chat, and another that closes it', (tester) async {
    final shown = <Uri>[];
    EmbeddedPage.builder = (context, address, height) {
      shown.add(address);
      return SizedBox(key: const ValueKey('page'), height: height, child: Text('PAGE ${address.path.length}'));
    };
    final app = await showing(tester, _html);
    expect(find.byKey(const ValueKey('page')), findsNothing, reason: 'nothing is drawn until it is asked for');
    expect(find.text('表示'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('page')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('page'))).height, 360, reason: 'the default height');
    final address = shown.last;
    expect((address.scheme, address.host), ('http', '127.0.0.1'), reason: 'the page is served by the app on this device only');
    expect(address.pathSegments.first, 'p');
    expect(address.pathSegments.last, matches(RegExp(r'^[0-9a-f]{32}$')), reason: 'an address no other app can guess');

    // the page is the code, served with the sandbox that gives it an origin of its own
    final text = await tester.runAsync(() async {
      HttpOverrides.global = null; // the test binding answers every request with 400: this one is the real local server
      final client = HttpClient();
      final request = await client.getUrl(address);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final sandbox = response.headers.value('content-security-policy');
      client.close();
      return (body, sandbox);
    });
    expect(text!.$1, contains('<h1>こんにちは</h1>'));
    expect(text.$2, allOf(contains('sandbox'), isNot(contains('allow-same-origin'))));

    expect(find.text('閉じる'), findsOneWidget);
    await tester.tap(find.text('閉じる'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('page')), findsNothing);
    await tester.runAsync(app.preview.dispose);
  });

  testWidgets('an SVG block is shown in a plain page; another language has no such button', (tester) async {
    Uri? address;
    EmbeddedPage.builder = (context, uri, height) {
      address = uri;
      return const SizedBox(key: ValueKey('page'), height: 10);
    };
    final app = await showing(tester, '```svg\n<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><circle cx="20" cy="20" r="18"/></svg>\n```\n\n```python\nprint(1)\n```');
    expect(find.text('表示'), findsOneWidget, reason: 'the svg block only');
    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    final body = await tester.runAsync(() async {
      HttpOverrides.global = null;
      final client = HttpClient();
      final response = await (await client.getUrl(address!)).close();
      final text = await response.transform(utf8.decoder).join();
      client.close();
      return text;
    });
    expect(body, allOf(contains('<!doctype html>'), contains('<circle'), contains('charset="utf-8"')));
    await tester.runAsync(app.preview.dispose);
  });

  testWidgets('the height is a setting, and 0 leaves the button out', (tester) async {
    EmbeddedPage.builder = (context, uri, height) => SizedBox(key: const ValueKey('page'), height: height);
    final app = await showing(tester, _html);
    await app.settings.update((s) => s.copyWith(inlinePreviewHeight: 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('表示'), findsNothing);
    expect(find.text('ブラウザ'), findsOneWidget, reason: 'the browser button stays');
    await app.settings.update((s) => s.copyWith(inlinePreviewHeight: 480));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await tester.tap(find.text('表示'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getSize(find.byKey(const ValueKey('page'))).height, 480);
    await tester.runAsync(app.preview.dispose);
  });

  /// Lets what is under way in real time (the server's answers, a file read) finish, and then the screen.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Presses "表示" of the one card that has it.
  Future<void> openCard(WidgetTester tester) async {
    await tester.tap(find.text('表示'));
    await settle(tester);
    await settle(tester);
  }

  /// The server that serves the folders is started outside the test's fake clock (a file read is real input and output).
  Future<void> startServer(WidgetTester tester, AppController app) => tester.runAsync(() => app.preview.publish('<p/>'));

  group('a page the tool show wrote into the reply', () {
    testWidgets('it is a card for the page, not code: the title, the buttons, no JSON; the page is the one that was written', (tester) async {
      Uri? address;
      EmbeddedPage.builder = (context, uri, height) {
        address = uri;
        return SizedBox(key: const ValueKey('page'), height: height);
      };
      final app = await showing(tester, '作りました。\n\n${PageBlocks.encode(const HtmlSource('<p>``` もある ```</p>', title: '電卓'))}\n\n以上です。');
      await startServer(tester, app);
      expect(find.text('電卓'), findsOneWidget);
      expect(find.textContaining('"html"', findRichText: true), findsNothing, reason: 'the JSON is not shown');
      expect(find.descendant(of: find.byType(CodeCard), matching: find.text('コピー')), findsNothing, reason: 'there is no code to copy');
      expect(find.byKey(const ValueKey('page')), findsNothing, reason: 'it opens by the button');
      await openCard(tester);
      expect(find.byKey(const ValueKey('page')), findsOneWidget);
      final body = await tester.runAsync(() async {
        HttpOverrides.global = null;
        final client = HttpClient();
        final response = await (await client.getUrl(address!)).close();
        final text = await response.transform(utf8.decoder).join();
        client.close();
        return text;
      });
      expect(body, '<p>``` もある ```</p>');
      await tester.runAsync(app.preview.dispose);
    });

    testWidgets('a port is drawn from this device\'s address; a file of the workspace is served from its folder', (tester) async {
      // real input and output does not run on the test's fake clock: the folder is made outside it
      final base = Directory.systemTemp.createTempSync('arce_view_ui');
      addTearDown(() => base.deleteSync(recursive: true));
      final workspace = Directory('${base.path}/workspace')..createSync();
      Directory('${workspace.path}/app').createSync();
      File('${workspace.path}/app/index.html').writeAsStringSync('<script src=app.js></script>');
      File('${workspace.path}/app/app.js').writeAsStringSync('var x = 1;');
      final drawn = <Uri>[];
      EmbeddedPage.builder = (context, uri, height) {
        drawn.add(uri);
        return SizedBox(key: ValueKey('page${drawn.length}'), height: 50);
      };
      final app = await showing(tester, PageBlocks.encode(const WorkspaceSource('app')), workspace: workspace);
      await startServer(tester, app);
      expect(find.text('/workspace/app'), findsOneWidget, reason: 'with no title the card says what it is');
      await openCard(tester);
      expect(drawn.single.pathSegments.first, 'w');
      final script = await tester.runAsync(() async {
        HttpOverrides.global = null;
        final client = HttpClient();
        final response = await (await client.getUrl(drawn.single.resolve('app.js'))).close();
        final text = await response.transform(utf8.decoder).join();
        client.close();
        return text;
      });
      expect(script, 'var x = 1;', reason: 'what the page asks for next comes from its folder');

      app.chat.restore(
        ConversationSnapshot(
          messages: [UiMessage(id: 1, role: Role.assistant, text: PageBlocks.encode(const PortSource(8080, path: '/viewer')))],
          history: const [],
          nextId: 2,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('127.0.0.1:8080/viewer'), findsOneWidget);
      await openCard(tester);
      expect(drawn.last.toString(), 'http://127.0.0.1:8080/viewer');
      await tester.runAsync(app.preview.dispose);
    });

    testWidgets('a page that is not in the workspace (a PC has one too now) the card says so', (tester) async {
      EmbeddedPage.builder = (context, uri, height) => SizedBox(key: const ValueKey('page'), height: height);
      await showing(tester, PageBlocks.encode(const WorkspaceSource('app')));
      await tester.tap(find.text('表示'));
      await settle(tester);
      expect(find.byKey(const ValueKey('page')), findsNothing);
      expect(find.textContaining('ワークスペースに、そのページがありません'), findsOneWidget, reason: 'the toast');
      await tester.pump(const Duration(seconds: 30)); // the toast goes
    });

    testWidgets('a block that holds nothing allowed stays plain code', (tester) async {
      await showing(tester, '```arce-view\n{"port":22}\n```');
      expect(find.text('表示'), findsNothing, reason: 'port 22 is not one a user serves on');
      expect(find.textContaining('{"port":22}', findRichText: true), findsOneWidget, reason: 'shown as the code it is');
    });

    testWidgets('a page opens by itself only when the setting says so, once', (tester) async {
      var drawn = 0;
      EmbeddedPage.builder = (context, uri, height) {
        drawn++;
        return SizedBox(key: const ValueKey('page'), height: height);
      };
      final app = await showing(tester, _html);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('page')), findsNothing, reason: 'off by default');
      await app.settings.update((s) => s.copyWith(autoShowPages: true));
      app.chat.restore(
        ConversationSnapshot(
          messages: [const UiMessage(id: 5, role: Role.assistant, text: _html)],
          history: const [],
          nextId: 6,
        ),
      );
      await settle(tester);
      await settle(tester);
      expect(find.byKey(const ValueKey('page')), findsOneWidget);
      expect(find.text('閉じる'), findsOneWidget);
      await tester.tap(find.text('閉じる'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('page')), findsNothing, reason: 'closed by the user: it does not come back by itself');
      expect(drawn, 1);
      await tester.runAsync(app.preview.dispose);
    });
  });
}
