import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;

/// Presses 保存 and lets the saving (which waits for the secure storage) end before the sheet is looked at again.
Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.text('保存'));
  await tester.tap(find.text('保存'));
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
  await tester.pumpAndSettle();
}

Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

void main() {
  testWidgets('provider editor: the cache switch is off at first, shows the name of the field when it is on, and both are saved and shown again', (tester) async {
    setSize(tester, const Size(411, 1400));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    app.openSettings(SettingsSection.providers);
    await tester.pumpAndSettle();

    await tester.tap(find.text('プロバイダを追加'));
    await tester.pumpAndSettle();
    final switchTile = find.byKey(const ValueKey('provider-prompt-cache'));
    expect(switchTile, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse, reason: 'off by default: a server that does not know the field may refuse it');
    expect(find.textContaining('止まりません'), findsOneWidget, reason: 'the text says that the provider\'s own cache cannot be turned off by the app');
    expect(field('キャッシュの項目名'), findsNothing);

    await tester.tap(switchTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue);
    expect(field('キャッシュの項目名'), findsOneWidget);
    expect(tester.widget<TextField>(field('キャッシュの項目名')).controller!.text, 'prompt_cache_key');

    await tester.enterText(field('名前'), 'テスト提供元');
    await tester.enterText(field('Base URL'), 'https://api.example/v1');
    await save(tester);
    final saved = app.providers.providers.single;
    expect((saved.promptCache, saved.promptCacheField), (true, 'prompt_cache_key'));

    // opened again: the switch is on; the name is changed and saved
    await tester.tap(find.byTooltip('編集'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('provider-prompt-cache'))).value, isTrue);
    await tester.enterText(field('キャッシュの項目名'), 'cache_id');
    await save(tester);
    expect(app.providers.providers.single.promptCacheField, 'cache_id');

    // and off again
    await tester.tap(find.byTooltip('編集'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-prompt-cache')));
    await tester.pump();
    expect(field('キャッシュの項目名'), findsNothing);
    await save(tester);
    expect(app.providers.providers.single.promptCache, isFalse);
    expect(app.providers.providers.single.promptCacheField, 'cache_id', reason: 'the name is kept for when it is turned on again');
    // the saves started a read of the model list (a request with a timeout) and a toast with a timer: let them end
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('provider editor: a field name that cannot be used is refused with the reason, and nothing is saved', (tester) async {
    setSize(tester, const Size(411, 1400));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    app.openSettings(SettingsSection.providers);
    await tester.pumpAndSettle();
    await tester.tap(find.text('プロバイダを追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-prompt-cache')));
    await tester.pump();
    await tester.enterText(field('名前'), 'テスト提供元');
    await tester.enterText(field('Base URL'), 'https://api.example/v1');
    await tester.enterText(field('キャッシュの項目名'), 'a b');
    await save(tester);
    expect(find.textContaining('キャッシュの項目名は、英数字'), findsOneWidget);
    expect(app.providers.providers, isEmpty);
    expect(ProviderConfig.isValidCacheField('a b'), isFalse);
  });

  testWidgets('the key of a conversation: one per conversation, the same after it is saved, another for a new one, its id when it is opened again', (tester) async {
    setSize(tester, const Size(411, 860));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    String key() => app.chat.current.conversationKey!()!;
    final first = key();
    expect(first, matches(RegExp(r'^arce-[0-9a-f]{16}$')), reason: 'random: nothing about the user or the text');

    late String id;
    await tester.runAsync(() async {
      await app.chat.send('こんにちは');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      id = app.conversationId!;
    });
    expect(key(), first, reason: 'saving the conversation (it gets its id) does not change the key: that would start the cache over');

    app.newConversation();
    final second = key();
    expect(second, isNot(first));
    expect(second, matches(RegExp(r'^arce-[0-9a-f]{16}$')));

    await tester.runAsync(() => app.openConversation(id));
    expect(key(), 'arce-$id');
  });
}
