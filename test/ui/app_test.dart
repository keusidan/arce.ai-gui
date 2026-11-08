import 'dart:convert';
import 'dart:io';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/thinking_config.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/releases.dart';
import 'package:arce_ai/core/reply_event.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/services/reply_notifier.dart';
import 'package:arce_ai/services/settings.dart';
import 'package:arce_ai/services/update_service.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/ui/chat_widgets.dart' show PromptTokenLine;
import 'package:arce_ai/ui/provider_widgets.dart';
import 'package:arce_ai/ui/theme.dart';
import 'package:arce_ai/ui/thinking_sheet.dart';
import 'package:arce_ai/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

Future<AppController> makeApp(WidgetTester tester, {http.Client? reportClient, ReplyNotifier? notifier, Directory? workspace}) async {
  SharedPreferences.setMockInitialValues({
    // no network in tests: skip the automatic update check
    'settings.v1': '{"autoUpdateCheck":false,"autoCheckSelectedModel":false}',
  });
  late AppController app;
  late Directory dir;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('arce_ui_test');
    final settings = await SettingsStore.load();
    app = await AppController.create(
      supportDirectory: dir,
      updateService: UpdateService(settings, currentVersion: const Version(0, 4, 0)),
      reportClient: reportClient,
      notifier: notifier,
      workspaceDirectory: workspace,
    );
  });
  addTearDown(() async {
    // Close the database before removing the folder: Windows will not delete a file that is still
    // open (Linux allows it), which is why only the Windows runner failed these three tests.
    app.history.close();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // a handle can outlive close() for a moment; the system cleans the temp folder
    }
  });
  return app;
}

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('phone layout: welcome screen, bottom bar, and a demo reply', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ARCE.AI へようこそ'), findsOneWidget);
    expect(find.text('生成物'), findsOneWidget, reason: 'bottom navigation');
    expect(find.text('ダークモード'), findsNothing, reason: 'no sidebar on a phone');

    await tester.enterText(find.byType(TextField), 'こんにちは');
    await tester.pump();
    await tester.tap(find.text('送信'));
    await tester.pump();
    // the demo engine streams a few characters at a time
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.textContaining('受け取りました', findRichText: true), findsWidgets);
    expect(app.chat.state.messages.length, 2);
    expect(find.text('こんにちは'), findsWidgets);
  });

  testWidgets('desktop layout: sidebar with navigation, and dark mode switch', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ダークモード'), findsOneWidget);
    expect(find.text('ローカルAIインストール'), findsOneWidget);

    await tester.tap(find.text('モデル管理').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.page, AppPage.models);
    expect(find.text('このOSでは、モデルを読み込めません'), findsOneWidget);
    expect(find.textContaining('基本モデルをダウンロード'), findsOneWidget, reason: 'a PC downloads models too');
    // every catalog model has a download button that works here (loading stays on Android)
    final downloads = find.widgetWithText(PrimaryButton, 'ダウンロード');
    expect(downloads, findsWidgets);
    expect(tester.widget<PrimaryButton>(downloads.first).onTap, isNotNull);

    await app.settings.update((s) => s.copyWith(theme: ThemeMode.dark));
    await tester.pump(); // builds the frame that starts the theme animation
    await tester.pump(const Duration(milliseconds: 500));
    final context = tester.element(find.byType(Scaffold).first);
    expect(Theme.of(context).brightness, Brightness.dark);
  });

  testWidgets('settings page: the groups are buttons, two to a row, and nothing else is on the first screen', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    expect(find.text('思考の表示'), findsNothing, reason: 'no group is open on the first screen');
    expect(find.byKey(const ValueKey('settings-back')), findsNothing);

    final buttons = [for (final section in SettingsSection.values) find.byKey(ValueKey('settings-group-${section.name}'))];
    expect(SettingsSection.values, hasLength(12));
    for (final button in buttons) {
      expect(button, findsOneWidget);
    }
    // two columns: the buttons share only two left edges, and as many rows as needed
    final lefts = {for (final button in buttons) tester.getTopLeft(button).dx.round()};
    final tops = {for (final button in buttons) tester.getTopLeft(button).dy.round()};
    expect(lefts, hasLength(2));
    expect(tops, hasLength(6));
    final width = tester.getSize(buttons.first).width;
    expect(lefts.reduce((a, b) => a > b ? a : b) - lefts.reduce((a, b) => a < b ? a : b), greaterThan(width), reason: 'side by side, not overlapping');
    // each button has its icon and its name
    expect(find.descendant(of: buttons.first, matching: find.byType(ArceIcon)), findsOneWidget);
    expect(find.descendant(of: buttons.first, matching: find.text('オンライン接続（プロバイダ）')), findsOneWidget);
  });

  testWidgets('settings page: the two buttons of a row are equally tall and their lower edges line up, however long the text (narrow phone, larger text)', (tester) async {
    for (final (size, scale) in [(const Size(360, 800), 1.0), (const Size(360, 800), 1.3), (const Size(411, 860), 1.3), (const Size(1280, 800), 1.0)]) {
      setSize(tester, size);
      final app = await makeApp(tester);
      await app.settings.update((s) => s.copyWith(fontScale: scale));
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();
      app.goTo(AppPage.settings);
      await tester.pumpAndSettle();
      final buttons = [for (final section in SettingsSection.values) find.byKey(ValueKey('settings-group-${section.name}'))];
      for (var i = 0; i < buttons.length; i += 2) {
        final left = tester.getRect(buttons[i]);
        final right = tester.getRect(buttons[i + 1]);
        expect(left.top, right.top, reason: 'row ${i ~/ 2} at $size x$scale');
        expect(left.bottom, right.bottom, reason: 'row ${i ~/ 2} at $size x$scale: the lower edges line up');
        expect(left.height, greaterThanOrEqualTo(128));
      }
      // the right-hand buttons end where the page's column ends: nothing sticks out
      expect(tester.getRect(buttons.last).right, lessThanOrEqualTo(size.width));
    }
  });

  testWidgets('settings page: a button moves to the group\'s own screen, which shows only its settings; back returns to the buttons', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-group-basic')));
    await tester.pumpAndSettle();
    expect(find.text('思考の表示'), findsOneWidget);
    expect(find.text('HyperLoad'), findsNothing, reason: 'the local model group is not mixed in');
    expect(find.text('Context Length'), findsNothing);
    expect(find.text('口調'), findsOneWidget, reason: 'the answer settings are common to both kinds of model, so they are here');
    expect(find.text('最大トークン数（共通）'), findsOneWidget);
    expect(find.text('SearXNG のアドレス'), findsNothing, reason: 'search has a group of its own');
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-group-local')), findsNothing, reason: 'the buttons are not on a group\'s screen');

    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(find.text('思考の表示'), findsNothing);
    expect(find.byKey(const ValueKey('settings-group-local')), findsOneWidget);

    // another group, and a switch inside it changes the settings
    await tester.tap(find.byKey(const ValueKey('settings-group-local')));
    await tester.pumpAndSettle();
    expect(find.text('HyperLoad'), findsOneWidget);
    expect(find.text('Context Length'), findsOneWidget);
    expect(find.text('思考の表示'), findsNothing);
    expect(app.settings.value.hyperLoad, isFalse);
    await app.settings.update((s) => s.copyWith(hyperLoad: true));
    await tester.pump();
    expect(app.settings.value.hyperLoad, isTrue);
  });

  testWidgets('settings page: the search field lists the matching rows of every group; a result opens its group; clearing brings the buttons back; nothing scrolls', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-search')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-group-local')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'トークン');
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-group-local')), findsNothing, reason: 'the results take the place of the buttons');
    expect(find.byKey(const ValueKey('settings-hit-0')), findsOneWidget);

    // a word that matches nothing
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'zzzzqqqq');
    await tester.pump();
    expect(find.textContaining('見つかりませんでした'), findsOneWidget);

    // full-width letters and hiragana for katakana still find it; a result opens the screen of its group
    await tester.enterText(find.byKey(const ValueKey('settings-search')), 'ｔｉｍｅｏｕｔ');
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-hit-0')), findsOneWidget);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels;
    await tester.tap(find.byKey(const ValueKey('settings-hit-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget, reason: 'a group\'s screen is open');
    expect(find.byKey(const ValueKey('settings-search')), findsNothing);
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first).position.pixels, scroll, reason: 'opening a result scrolls nothing');

    // back: the field is empty again and the buttons are there
    await tester.tap(find.byKey(const ValueKey('settings-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-group-local')), findsOneWidget);

    // the clear button
    await tester.enterText(find.byKey(const ValueKey('settings-search')), '通知');
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-group-local')), findsNothing);
    await tester.tap(find.byTooltip('検索をやめる'));
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-group-local')), findsOneWidget);
  });

  testWidgets('settings page: the system\'s back returns from a group to the buttons, and the page keeps its place in the app', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    // a button below the fold is brought into view by hand, then pressed
    await tester.ensureVisible(find.byKey(const ValueKey('settings-group-reports')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-group-reports')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-back')), findsNothing, reason: 'back went to the buttons');
    expect(find.byKey(const ValueKey('settings-group-reports')), findsOneWidget);
    expect(app.page, AppPage.settings, reason: 'it did not leave the settings');

    // going to another page and back shows the buttons again, not the group that was last open
    await tester.ensureVisible(find.byKey(const ValueKey('settings-group-reports')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-group-reports')));
    await tester.pumpAndSettle();
    app.goTo(AppPage.chat);
    await tester.pumpAndSettle();
    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-group-reports')), findsOneWidget);
  });

  testWidgets('settings page: opening a group does not scroll anything, and the group starts at its top', (tester) async {
    // a short window, so that the buttons below the fold are far down
    setSize(tester, const Size(411, 520));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.goTo(AppPage.settings);
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    ScrollPosition position() => tester.state<ScrollableState>(scrollable).position;
    expect(position().pixels, 0);

    // scroll the buttons down by hand, then press one that is on the screen
    await tester.drag(scrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(position().pixels, greaterThan(0));
    final reports = find.byKey(const ValueKey('settings-group-reports'));
    await tester.ensureVisible(reports);
    await tester.pumpAndSettle();
    await tester.tap(reports);
    await tester.pumpAndSettle();
    // the group's screen is a new one: it starts at the top, and nothing moved to follow the press
    expect(position().pixels, 0);
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('settings-back'))).dy, lessThan(120), reason: 'the header is at the top of the screen');
  });

  testWidgets('settings page: openSettings (the sidebar, the banner, the 分担 button) opens that group\'s screen directly, also from another page', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(app.page, AppPage.chat);

    app.openSettings(SettingsSection.online);
    await tester.pumpAndSettle();
    expect(app.page, AppPage.settings);
    expect(find.text('追加プロンプト'), findsOneWidget);
    expect(find.text('top_k'), findsNothing, reason: 'top_k is a device model setting');
    expect(find.text('Context Length'), findsNothing);
    expect(find.byKey(const ValueKey('settings-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-group-local')), findsNothing);

    // asked for again while the page is open: it moves to that group
    app.openSettings(SettingsSection.local);
    await tester.pumpAndSettle();
    expect(find.text('HyperLoad'), findsOneWidget);
    expect(find.text('Context Length'), findsOneWidget);
    expect(find.text('モデルの上限を自動で調べる'), findsNothing, reason: 'the online group is gone');
    expect(app.settingsSection.value, isNull, reason: 'the request was taken');
  });

  testWidgets('settings page: the KV cache file settings appear once the switch is on', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.local);
    await tester.pumpAndSettle();
    expect(find.text('KV キャッシュをファイルに保存'), findsOneWidget);
    expect(find.text('保存の上限（合計）'), findsNothing, reason: 'hidden while it is off');

    await app.settings.update((s) => s.copyWith(kvSnapshotEnabled: true));
    await tester.pumpAndSettle();
    expect(find.text('保存の上限（合計）'), findsOneWidget);
    expect(find.text('保存する最小の長さ'), findsOneWidget);
    expect(find.text('この端末（OS）では保存できません'), findsOneWidget, reason: 'there is no device engine in a test');
  });

  testWidgets('settings page: the online group has the model lookup switches, and a 256K length can be typed', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.online);
    await tester.pumpAndSettle();
    expect(find.text('モデルの上限を自動で調べる'), findsOneWidget);
    expect(find.text('Hugging Face からも調べる'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, '2048'), '262144');
    await tester.pump();
    expect(app.settings.value.onlineMaxTokens, 262144, reason: 'the old 32768 ceiling is gone');
  });

  testWidgets('model editor: limits, the maker\'s note and a thinking format can be set and saved', (tester) async {
    setSize(tester, const Size(500, 2600));
    final app = await makeApp(tester);
    const config = ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'zai-org/GLM-5.3', name: 'GLM')],
    );
    await app.providers.save(config);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => ModelEditor(app: app, provider: config, model: config.models.single),
              ),
              child: const Text('開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開く'));
    await tester.pumpAndSettle();

    // the maker's recommendation is shown, and the empty fields show what applies
    expect(find.textContaining('GLM-5 の推奨（公式モデルカード）'), findsOneWidget);
    expect(find.textContaining('GLM-5.3（公式モデルカード）：reasoning_effort'), findsOneWidget);
    expect(find.text('送らない（提供元の既定）'), findsWidgets);
    expect(find.text('clear_thinking（GLM）'), findsNothing, reason: 'no format chosen yet');

    await tester.tap(find.text('おすすめの送り方を入れる'));
    await tester.pumpAndSettle();
    expect(find.textContaining('を選びました'), findsOneWidget);
    expect(find.text('clear_thinking（GLM）'), findsOneWidget);
    expect(find.text('true（過去の思考を捨てる・チャット向け）'), findsWidgets, reason: 'the GLM-5.3 card says to pass true for chat');

    // tools and earlier thinking: the defaults are shown, and a choice is kept
    expect(find.text('自動（提供元がツールに対応していれば function calling）'), findsOneWidget);
    expect(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'), findsOneWidget);
    await tester.ensureVisible(find.text('自動（提供元がツールに対応していれば function calling）'));
    await tester.tap(find.text('自動（提供元がツールに対応していれば function calling）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('テキスト形式（<tool_call> を本文に書く。Qwen 形式）').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'));
    await tester.tap(find.text('自動（DeepSeek・GLM で、ツールが function calling のとき返す）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返さない（答えだけを履歴に残す）').last);
    await tester.pumpAndSettle();

    // the empty context field shows the maker's 1M as its placeholder
    await tester.enterText(find.widgetWithText(TextField, '1048576'), '900000');
    await tester.enterText(find.widgetWithText(TextField, '例: 65536'), '131072');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3)); // the toast's timer

    final saved = app.providers.byId('host')!.models.single;
    expect(saved.thinking.format, ThinkingFormat.chatTemplate, reason: 'a Hugging Face name is served by a vLLM-like host');
    expect(saved.thinking.clearThinking, isTrue);
    expect(saved.contextTokens, 900000);
    expect(saved.maxOutputTokens, 131072);
    expect(saved.toolStyle, ToolStyle.text);
    expect(saved.thinking.replay, ReasoningReplay.never);
  });

  testWidgets('chat: the thinking menu chooses how an online model thinks, and says when nothing is sent', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(const ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'deepseek-v4-flash', name: 'ds')],
    ));
    await app.providers.setActive('host');
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(app.engine.isCloud, isTrue);

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考の送り方がまだ決まっていません'), findsOneWidget);
    expect(find.text('最大'), findsNothing, reason: 'no effort words until a format names them');

    // the name says DeepSeek: one button takes the suggestion
    await tester.tap(find.textContaining('「DeepSeek API」にする'));
    await tester.pumpAndSettle();
    ThinkingConfig stored() => app.providers.byId('host')!.models.single.thinking;
    expect(stored().format, ThinkingFormat.deepseekApi);
    expect(find.text('最大'), findsOneWidget);

    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(stored().mode, ThinkingMode.on);
    expect(stored().effort, 'high');

    await tester.tap(find.text('オフ'));
    await tester.pumpAndSettle();
    expect(stored().mode, ThinkingMode.off);

    await tester.tap(find.text('自動'));
    await tester.pumpAndSettle();
    expect(stored().mode, ThinkingMode.auto);
    expect(stored().effort, isEmpty);
  });

  testWidgets('chat: the thinking menu of the device model has the switch and the speed slider', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(app.engine.isCloud, isFalse);

    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();
    // one in the menu, and the chat's own beside the button (the same setting)
    expect(find.byType(Slider), findsNWidgets(2));
    expect(find.descendant(of: find.byType(ThinkingSheet), matching: find.byType(Slider)), findsOneWidget);
    expect(app.settings.value.thinkingExpanded, isTrue);
    await tester.tap(find.byType(ArceSwitch).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(app.settings.value.thinkingExpanded, isFalse);
  });

  testWidgets('settings page: coding mode asks for both models before it can work', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.coding);
    await tester.pumpAndSettle();
    expect(find.text('plan は、使用中のモデルに合わせる'), findsOneWidget);
    expect(find.text('plan のモデル'), findsNothing, reason: 'the planner follows the model in use, so there is nothing to choose');
    expect(find.text('coding のモデル'), findsOneWidget);
    expect(find.text('coding のモデルを追加'), findsOneWidget);
    expect(find.textContaining('coding のモデルを 1 つ以上選ぶと'), findsNothing, reason: 'no warning while the mode is off');

    await app.settings.update((s) => s.copyWith(codingPlanEnabled: true));
    await tester.pumpAndSettle();
    expect(find.textContaining('coding のモデルを 1 つ以上選ぶと'), findsOneWidget);
    expect(app.settings.value.coding.isReady, isFalse);

    await app.settings.update((s) => s.copyWith(developerModel: 'local|'));
    await tester.pumpAndSettle();
    expect(app.settings.value.coding.isReady, isTrue, reason: 'the planner is the model in use: only a developer is needed');
    expect(find.textContaining('coding のモデルを 1 つ以上選ぶと'), findsNothing);
    expect(find.textContaining('まだ読み込まれていません'), findsOneWidget, reason: 'the device model is not loaded in a test');

    // fixing the planner shows its field, and asks for one
    await app.settings.update((s) => s.copyWith(codingPlannerFollows: false));
    await tester.pumpAndSettle();
    expect(find.text('plan のモデル'), findsOneWidget);
    expect(find.textContaining('plan のモデルを選ぶか'), findsOneWidget);
    await app.settings.update((s) => s.copyWith(plannerModel: 'openai|gpt-4o'));
    await tester.pumpAndSettle();
    expect(app.settings.value.coding.isReady, isTrue);
  });

  testWidgets('coding mode: the planner is the model in use, so switching the model in the chat changes it too; a fixed planner stays', (tester) async {
    final app = await makeApp(tester);
    for (final id in ['p1', 'p2']) {
      await app.providers.save(ProviderConfig(id: id, label: id, baseUrl: 'https://example.com/v1', models: [ModelConfig(id: 'm', name: 'm')]));
    }
    GenerateRequest request(String agent) => GenerateRequest(
          prompt: 'x',
          toolCallSchema: null,
          thinking: false,
          maxTokens: 10,
          sampling: SamplingParams.qwen3NonThinking,
          agentId: agent,
        );
    await app.settings.update((s) => s.copyWith(codingPlanEnabled: true, developerModel: 'p2|m', plannerModel: 'p1|m'));
    expect(app.engine.planner!(request('coding')), isNull, reason: 'it follows the model in use: no separate engine answers');

    await app.settings.update((s) => s.copyWith(codingPlannerFollows: false));
    expect(app.engine.planner!(request('coding')), isNotNull, reason: 'a fixed planner answers the coding agent');
    expect(app.engine.planner!(request('general')), isNull, reason: 'only the coding agent hands work over');

    await app.settings.update((s) => s.copyWith(codingPlannerFollows: true, plannerModel: ''));
    expect(app.engine.planner!(request('coding')), isNull);
  });

  testWidgets('chat: the 分担 button turns the coding mode on and goes to its settings when it is not ready', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(app.settings.value.codingPlanEnabled, isFalse);
    await tester.tap(find.text('分担'));
    await tester.pumpAndSettle();
    expect(app.settings.value.codingPlanEnabled, isTrue);
    expect(app.page, AppPage.settings, reason: 'it cannot work yet, so the settings open');
    expect(find.text('coding のモデル'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // the toast's timer
  });

  testWidgets('settings page: the limits group lists what used to be fixed', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.limits);
    await tester.pumpAndSettle();
    expect(find.text('添付できるファイルの数'), findsOneWidget);
    expect(find.text('検索結果の件数'), findsNothing, reason: 'it moved to the search group');
    expect(find.text('オンラインモデルの応答のタイムアウト'), findsOneWidget);

    // a pill steps to the next value
    expect(app.settings.value.attachMaxFiles, 5);
    await tester.tap(find.text('5').first);
    await tester.pump();
    expect(app.settings.value.attachMaxFiles, 10);
  });

  testWidgets('settings page: the coding model is picked from a list that writes every name out in full', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await app.providers.save(
      const ProviderConfig(
        id: 'long',
        label: 'Some Very Long Provider Name',
        baseUrl: 'https://example.com/v1',
        models: [ModelConfig(id: 'vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2', name: 'vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2')],
      ),
    );
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    // the planner field shows only when the planner is fixed (by default it follows the model in use)
    await app.settings.update((s) => s.copyWith(codingPlannerFollows: false));
    app.openSettings(SettingsSection.coding);
    await tester.pumpAndSettle();
    await tester.tap(find.text('未選択').first);
    await tester.pumpAndSettle();

    // a tree with a search field: type a word of the provider and the model shows, written in full
    const model = 'vendor/an-extremely-long-model-name-that-no-narrow-field-can-show-v2';
    await tester.enterText(find.byType(TextField).last, 'long extremely');
    await tester.pumpAndSettle();
    expect(find.text(model), findsOneWidget, reason: 'the list shows the whole name, not an ellipsis');
    await tester.tap(find.text(model));
    await tester.pumpAndSettle();
    expect(app.settings.value.plannerModel, 'long|$model');
    const full = 'Some Very Long Provider Name · $model';
    expect(find.text(full), findsWidgets, reason: 'the field now shows the choice');
  });

  testWidgets('a chat can be left while it answers: it goes on in the background, is saved, and can be opened again', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'こんにちは');
    await tester.pump();
    await tester.tap(find.text('送信'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(app.chat.state.isGenerating, isTrue, reason: 'the reply is being written');

    // open a new chat while the first one is still answering: it is not refused any more
    app.newConversation();
    await tester.pump();
    expect(app.chat.state.messages, isEmpty, reason: 'the screen shows the new chat');
    expect(app.chat.state.isGenerating, isFalse);

    // the first chat finishes by itself and is saved
    await tester.pumpAndSettle(const Duration(seconds: 4));
    await tester.runAsync(() async {
      for (var i = 0; i < 60 && (app.conversations.isEmpty || app.conversations.single.generating); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await app.refreshConversations();
      }
    });
    expect(app.conversations, hasLength(1));
    final id = app.conversations.single.id;
    expect(app.isRunning(id), isFalse);

    // the writes are real file work: wait until the finished reply has been written
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        final saved = await app.history.get(id);
        if (saved != null && saved.messages.last.text.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    });
    // and it is the whole conversation that comes back
    await tester.runAsync(() => app.openConversation(id));
    await tester.pump();
    expect(app.conversationId, id);
    expect(app.chat.state.messages.length, 2, reason: 'the question and the finished reply');
    expect(app.chat.state.messages.last.text, isNotEmpty);
  });

  testWidgets('a new conversation gets its title from the model after the first answer; the first question is the title until then', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    final asked = <String>[];
    app.providers.clientFactory = () => MockClient.streaming((request, bodyStream) async {
      final body = await utf8.decodeStream(bodyStream);
      // the model list (read in the background when a provider is saved) is not a chat request
      if (!request.url.path.endsWith('chat/completions')) {
        return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, headers: const {'content-type': 'application/json'}, request: request);
      }
      asked.add(body);
      final isTitle = body.contains('Write a short title');
      final text = isTitle ? '「LCT の実装相談」' : 'Link-Cut Tree はこう書きます。';
      return http.StreamedResponse(
        Stream.value(utf8.encode('data: ${jsonEncode({
              'choices': [
                {'delta': {'content': text}},
              ],
            })}\n\ndata: [DONE]\n\n')),
        200,
        headers: const {'content-type': 'text/event-stream'},
        request: request,
      );
    });
    await app.providers.save(const ProviderConfig(
      id: 'host',
      label: 'ホスト',
      baseUrl: 'https://host.example/v1',
      models: [ModelConfig(id: 'm', name: 'm')],
    ));
    await app.providers.setActive('host');
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    await tester.runAsync(() async {
      await app.chat.send('Link-Cut Tree を実装してほしい');
      for (var i = 0; i < 100 && !app.conversations.any((c) => c.title == 'LCT の実装相談'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await app.refreshConversations();
      }
    });
    expect(asked, hasLength(2), reason: 'the answer, then the title');
    expect(app.conversations.single.title, 'LCT の実装相談', reason: 'the quotes of the model\'s answer are taken off');
    expect(app.currentTitle, 'LCT の実装相談', reason: 'the header shows it too');
    expect(asked.last, allOf(contains('Link-Cut Tree を実装してほしい'), contains('Link-Cut Tree はこう書きます')));

    // a second answer in the same conversation does not ask for another title
    await tester.runAsync(() async {
      await app.chat.send('もう少し詳しく');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(asked, hasLength(3), reason: 'only the answer');
  });

  testWidgets('with the setting off, or for the device model, no title is asked for', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    var calls = 0;
    app.providers.clientFactory = () => MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      if (!request.url.path.endsWith('chat/completions')) {
        return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, headers: const {'content-type': 'application/json'}, request: request);
      }
      calls++;
      return http.StreamedResponse(
        Stream.value(utf8.encode('data: ${jsonEncode({
              'choices': [
                {'delta': {'content': 'はい'}},
              ],
            })}\n\ndata: [DONE]\n\n')),
        200,
        headers: const {'content-type': 'text/event-stream'},
        request: request,
      );
    });
    await app.providers.save(const ProviderConfig(id: 'host', label: 'ホスト', baseUrl: 'https://host.example/v1', models: [ModelConfig(id: 'm', name: 'm')]));
    await app.providers.setActive('host');
    await app.settings.update((s) => s.copyWith(autoTitle: false));
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    await tester.runAsync(() async {
      await app.chat.send('こんにちは');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(calls, 1, reason: 'the setting is off: only the answer');
    expect(app.currentTitle, 'こんにちは');

    // the device model: nothing to write a title with
    await app.settings.update((s) => s.copyWith(autoTitle: true));
    await app.providers.setActive('local');
    app.newConversation();
    await tester.runAsync(() async {
      await app.chat.send('こんにちは');
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    expect(calls, 1, reason: 'the device model does not write titles by itself');
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a reply that fails in the app\'s own way is reported to the GitHub issue, without the conversation or the key', (tester) async {
    setSize(tester, const Size(411, 860));
    final issues = <Map<String, Object?>>[];
    final reportClient = MockClient((request) async {
      issues.add({'path': request.url.path, 'auth': request.headers['Authorization'], ...jsonDecode(request.body) as Map<String, Object?>});
      return http.Response(jsonEncode({'number': 7}), 201);
    });
    final app = await makeApp(tester, reportClient: reportClient);
    app.providers.clientFactory = () => MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      if (!request.url.path.endsWith('chat/completions')) {
        return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, headers: const {'content-type': 'application/json'}, request: request);
      }
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"error":{"message":"Unknown parameter: reasoning_content at https://host.example/v1/secret-path?key=abc sk-abcdefgh12345678"}}')),
        400,
        request: request,
      );
    });
    await app.providers.save(const ProviderConfig(id: 'host', label: 'ホスト', baseUrl: 'https://host.example/v1', models: [ModelConfig(id: 'm', name: 'm')]));
    await app.providers.setActive('host');
    // the secure storage is a platform channel: it needs the real event loop
    await tester.runAsync(() => app.settings.setIssueToken('github_pat_reporting'));
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    await tester.runAsync(() async {
      await app.chat.send('これは秘密の質問です');
      for (var i = 0; i < 100 && issues.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(issues, hasLength(1));
    final issue = issues.single;
    expect(issue['path'], '/repos/keusidan/arce.ai-gui/issues');
    expect(issue['auth'], 'Bearer github_pat_reporting');
    expect(issue['title'], allOf(startsWith('[auto/chat]'), contains('HTTP 400')));
    final text = '${issue['title']}\n${issue['body']}';
    expect(text, contains('host.example'), reason: 'the host of the provider is said');
    expect(text, contains('Unknown parameter'));
    expect(text, isNot(contains('これは秘密の質問です')), reason: 'no conversation');
    expect(text, isNot(contains('sk-abcdefgh')), reason: 'no key');
    expect(text, isNot(contains('secret-path')), reason: 'no path or query of the address');
    expect(text, isNot(contains('github_pat_reporting')));
  });

  testWidgets('what the user can fix is not reported (a wrong key, 429); nor is anything without a token', (tester) async {
    setSize(tester, const Size(411, 860));
    var reports = 0;
    final reportClient = MockClient((request) async {
      reports++;
      return http.Response(jsonEncode({'number': 1}), 201);
    });
    final app = await makeApp(tester, reportClient: reportClient);
    var status = 401;
    app.providers.clientFactory = () => MockClient.streaming((request, bodyStream) async {
      await bodyStream.drain<void>();
      if (!request.url.path.endsWith('chat/completions')) {
        return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, request: request);
      }
      return http.StreamedResponse(Stream.value(utf8.encode('{"error":{"message":"bad"}}')), status, request: request);
    });
    await app.providers.save(const ProviderConfig(id: 'host', label: 'ホスト', baseUrl: 'https://host.example/v1', models: [ModelConfig(id: 'm', name: 'm')]));
    await app.providers.setActive('host');
    // the secure storage is a platform channel: it needs the real event loop
    await tester.runAsync(() => app.settings.setIssueToken('github_pat_reporting'));
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    await tester.runAsync(() async {
      await app.chat.send('一つ目');
      app.newConversation();
      status = 429;
      await app.chat.send('二つ目');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    expect(reports, 0, reason: 'a wrong key and a rate limit are the user\'s to fix');

    // without a token, even the app's own errors stay on the device
    await tester.runAsync(() => app.settings.setIssueToken(''));
    await tester.runAsync(() async {
      app.newConversation();
      status = 400;
      await app.chat.send('三つ目');
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    expect(reports, 0);
    expect(app.errors.recent.first.status, contains('トークンが未設定'));
  });

  testWidgets('the text size is a setting and applies to the whole screen', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    double scale() => MediaQuery.of(tester.element(find.byType(Scaffold).first)).textScaler.scale(10) / 10;
    expect(scale(), closeTo(1.0, 0.001));

    await app.settings.update((s) => s.copyWith(fontScale: 1.5));
    await tester.pump();
    expect(scale(), closeTo(1.5, 0.001));
    expect(app.settings.value.toJson()['fontScale'], 1.5);
  });

  testWidgets('a reply is plain text over the whole width: no name, no role, no bubble, no model button', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'こんにちは');
    await tester.pump();
    await tester.tap(find.text('送信'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('こんにちは'), findsWidgets);
    expect(find.text('General Chat'), findsNothing, reason: 'the role of the agent is not written above a reply');
    expect(find.text('ARCE.AI'), findsWidgets, reason: 'only the app bar carries the name');
    expect(find.byTooltip('モデル管理'), findsNothing, reason: 'the model button of the input row is gone');
  });

  testWidgets('settings page: the search group has the server, the result count and the search APIs', (tester) async {
    setSize(tester, const Size(411, 1200));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.search);
    await tester.pumpAndSettle();
    expect(find.text('SearXNG のアドレス'), findsOneWidget);
    expect(find.text('検索結果の件数'), findsOneWidget);
    expect(find.text('検索 API'), findsOneWidget);
    expect(find.text('検索 API を追加'), findsOneWidget);
    expect(find.text('思考の表示'), findsNothing);
  });

  testWidgets('settings page: the sidebar lists the search settings', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('検索設定'), findsWidgets);
    expect(find.text('モデル全般設定'), findsWidgets);
    expect(find.text('回答の設定'), findsNothing);
    expect(find.text('開発者設定'), findsNothing);
  });

  testWidgets('a bottom sheet keeps its buttons above the navigation bar and the keyboard', (tester) async {
    late double plain, withBar, withKeyboard;
    Widget probe(MediaQueryData data, void Function(double) out) => MediaQuery(
          data: data,
          child: Builder(builder: (context) {
            out(sheetBottomPadding(context));
            return const SizedBox();
          }),
        );
    await tester.pumpWidget(probe(const MediaQueryData(), (v) => plain = v));
    await tester.pumpWidget(probe(const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 48)), (v) => withBar = v));
    await tester.pumpWidget(probe(const MediaQueryData(viewPadding: EdgeInsets.only(bottom: 48), viewInsets: EdgeInsets.only(bottom: 300)), (v) => withKeyboard = v));
    expect(plain, 16);
    expect(withBar, 64, reason: 'above the three-button bar');
    expect(withKeyboard, 316, reason: 'above the keyboard, which already covers the bar');
  });

  testWidgets('settings page: local and online model settings are kept apart', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.local);
    await tester.pumpAndSettle();
    expect(find.text('top_k'), findsOneWidget);
    expect(find.text('min_p'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '0.6 / 0.7（思考の有無で変わります）'), '0.3');
    await tester.pump();
    expect(app.settings.value.localTemperature, 0.3);
    expect(app.settings.value.onlineTemperature, -1, reason: 'the online setting is untouched');

    final local = app.settings.value.toGeneration(null);
    final online = app.settings.value.toGeneration(null, cloud: true);
    expect(local.temperature, 0.3);
    expect(online.temperature, isNull);
  });

  testWidgets('phone: the hamburger opens a drawer where the history can be searched', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    Map<String, Object?> conversation(String text) => {
          'messages': [
            {'id': 0, 'role': 'user', 'text': text, 'thinking': '', 'question': null, 'finish': null, 'activities': const [], 'agent': null, 'attachments': const [], 'time': 1700000000000},
            {'id': 1, 'role': 'assistant', 'text': '答え：$text', 'thinking': '', 'question': null, 'finish': 'eog', 'activities': const [], 'agent': null, 'attachments': const [], 'time': 1700000005000},
          ],
          'history': [
            {'type': 'user', 'text': text, 'toolCallJson': null},
            {'type': 'assistant', 'text': '答え：$text', 'toolCallJson': null},
          ],
          'nextId': 2,
        };
    await tester.runAsync(() async {
      await app.history.save(null, ConversationSnapshot.fromJson(conversation('りんごの話をして')), generating: false);
      await app.history.save(null, ConversationSnapshot.fromJson(conversation('明日の天気は？')), generating: false);
      await app.refreshConversations();
    });
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.byType(Drawer), findsNothing);
    await tester.tap(find.byTooltip('メニュー'));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('りんごの話をして'), findsOneWidget);
    expect(find.text('明日の天気は？'), findsOneWidget);

    final search = find.descendant(of: find.byType(Drawer), matching: find.byType(TextField));
    await tester.enterText(search, '天気');
    await tester.pump();
    expect(find.text('りんごの話をして'), findsNothing);
    expect(find.text('明日の天気は？'), findsOneWidget);

    // a word that is only in an answer finds the conversation too, with the matching line
    await tester.enterText(search, 'りんご');
    await tester.pump();
    // the title, and the matching line under it with the match highlighted
    expect(find.text('りんごの話をして'), findsWidgets);
    expect(find.text('明日の天気は？'), findsNothing);
    await tester.enterText(search, '答え');
    await tester.pump();
    expect(find.textContaining('答え：', findRichText: true), findsWidgets, reason: 'a word only in an answer still finds it');
    expect(find.text('明日の天気は？'), findsOneWidget, reason: 'its title, listed because its answer matches');

    await tester.enterText(search, 'ぶどう');
    await tester.pump();
    expect(find.textContaining('一致する会話はありません'), findsOneWidget);

    await tester.enterText(search, 'りんご');
    await tester.pump();
    await tester.tap(find.text('りんごの話をして').first);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing, reason: 'opening a conversation closes the drawer');
    expect(app.chat.state.messages.first.text, 'りんごの話をして');
  });

  testWidgets('desktop: the hamburger hides and shows the sidebar', (tester) async {
    setSize(tester, const Size(1280, 800));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    expect(find.text('ダークモード'), findsOneWidget);
    await tester.tap(find.byTooltip('サイドバーを開閉'));
    await tester.pump();
    expect(find.text('ダークモード'), findsNothing);
    await tester.tap(find.byTooltip('サイドバーを開閉'));
    await tester.pump();
    expect(find.text('ダークモード'), findsOneWidget);
  });

  testWidgets('under the input: the size of the next request in tokens, with what is typed counted, and the model\'s context when it is known', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await app.providers.save(const ProviderConfig(
      id: 'p',
      label: 'P',
      baseUrl: 'https://example.com/v1',
      models: [ModelConfig(id: 'm', name: 'm', contextTokens: 8000)],
    ));
    await app.providers.setActive('p');
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    String? line() {
      final f = find.byKey(const ValueKey('prompt-tokens'));
      return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
    }

    expect(line(), isNotNull);
    expect(line(), allOf(startsWith('約 '), contains('トークン（会話 0・入力 0・'), contains('／文脈 8,000（')));
    final empty = RegExp(r'約 ([\d,]+)').firstMatch(line()!)!.group(1)!.replaceAll(',', '');

    await tester.enterText(find.byType(TextField).first, 'あ' * 600);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    final typed = RegExp(r'約 ([\d,]+)').firstMatch(line()!)!.group(1)!.replaceAll(',', '');
    expect(int.parse(typed), greaterThan(int.parse(empty) + 400), reason: 'what is typed is in the count before it is sent');
    expect(line(), isNot(contains('入力 0')));
    await tester.pump(const Duration(seconds: 1));
  });

  test('the token line is written the way it is read: grouped digits, the parts, and the context when it is known', () {
    expect(PromptTokenLine.group(1234567), '1,234,567');
    expect(PromptTokenLine.group(12), '12');
    expect(
      PromptTokenLine.describe(const PromptTokens(system: 1500, tools: 2500, conversation: 8000, draft: 340, context: 131072)),
      '約 12,340 トークン（会話 8,000・入力 340・指示 1,500・道具 2,500）／文脈 131,072（9%）',
    );
    expect(PromptTokenLine.describe(const PromptTokens(system: 1, tools: 2, conversation: 3, draft: 4)), '約 10 トークン（会話 3・入力 4・指示 1・道具 2）');
    expect(const PromptTokens(system: 50, tools: 0, conversation: 0, draft: 0, context: 100).ratio, .5);
    expect(const PromptTokens(system: 50, tools: 0, conversation: 0, draft: 0).ratio, isNull);
  });

  testWidgets('the header has no settings icon (the bar below, or the sidebar, already has 設定)', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(find.byTooltip('設定'), findsNothing);
    expect(find.text('設定'), findsWidgets, reason: 'the bottom bar still opens it');
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    expect(app.page, AppPage.settings);

    setSize(tester, const Size(1280, 800));
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    expect(find.byTooltip('設定'), findsNothing);
    expect(find.text('設定'), findsWidgets, reason: 'the sidebar still has it');
  });

  testWidgets('settings: the tools that are not asked about again are listed, and one can be taken out', (tester) async {
    setSize(tester, const Size(411, 2400));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    app.openSettings(SettingsSection.mcp);
    await tester.pumpAndSettle();
    expect(find.text('確認しない道具'), findsNothing, reason: 'nothing is remembered yet');

    await app.settings.update((x) => x.copyWith(approvedTools: ['mcp_github__push_files', 'mcp_kaggle__SubmitToCompetition']));
    await tester.pumpAndSettle();
    expect(find.text('確認しない道具'), findsOneWidget);
    expect(find.text('github · push_files'), findsOneWidget);
    expect(find.text('kaggle · SubmitToCompetition'), findsOneWidget);

    await tester.tap(find.byTooltip('外す（また確認する）').first);
    await tester.pumpAndSettle();
    expect(app.settings.value.approvedTools, ['mcp_kaggle__SubmitToCompetition']);
    expect(find.text('github · push_files'), findsNothing);
  });

  group('notifications about a reply', () {
    testWidgets('the app in front of the chat: nothing; away: one when the reply is finished; each kind has its own setting', (tester) async {
      final shown = <ReplyEventKind>[];
      final app = await makeApp(tester, notifier: _FakeNotifier(shown));
      await tester.pumpWidget(ArceApp(app: app));
      await tester.pump();

      await tester.runAsync(() => app.chat.send('こんにちは'));
      expect(shown, isEmpty, reason: 'the user is looking at this chat');

      app.inForeground = false;
      await tester.runAsync(() => app.chat.send('もう一度'));
      expect(shown, [ReplyEventKind.done]);

      await app.settings.update((s) => s.copyWith(notifyDone: false));
      await tester.runAsync(() => app.chat.send('三度目'));
      expect(shown, [ReplyEventKind.done], reason: 'finished replies are switched off');

      await app.settings.update((s) => s.copyWith(notifyDone: true, notifyOnlyAway: false));
      app.inForeground = true;
      await tester.runAsync(() => app.chat.send('四度目'));
      expect(shown, [ReplyEventKind.done, ReplyEventKind.done], reason: 'with "only away" off, the front chat notifies too');
    });
  });
}

class _FakeNotifier extends ReplyNotifier {
  _FakeNotifier(this.shown);
  final List<ReplyEventKind> shown;

  @override
  bool get supported => true;

  @override
  Future<bool> allowed() async => true;

  @override
  Future<void> show(ReplyEvent event, {String group = ''}) async => shown.add(event.kind);
}
