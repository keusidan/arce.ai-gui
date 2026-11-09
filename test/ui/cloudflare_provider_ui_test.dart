import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_test.dart' show makeApp, setSize;
import 'prompt_cache_ui_test.dart' show field, save;

void main() {
  testWidgets('provider editor: Cloudflare AI Gateway is made from the account ID, the gateway and the token, with a first model', (tester) async {
    setSize(tester, const Size(411, 1600));
    final app = await makeApp(tester);
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();
    app.openSettings(SettingsSection.providers);
    await tester.pumpAndSettle();
    await tester.tap(find.text('プロバイダを追加'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('provider-kind-cloudflare')));
    await tester.pump();
    expect(field('Base URL'), findsNothing, reason: 'the address is made from the account ID');
    expect(find.text('モデル一覧を自動で取得'), findsNothing, reason: 'the API has no model list');

    // an account ID that would change the address is refused, and nothing is saved
    await tester.enterText(field('アカウント ID'), 'abc/../x');
    await save(tester);
    expect(app.providers.providers, isEmpty);
    expect(find.textContaining('アカウント ID'), findsWidgets);

    await tester.enterText(field('アカウント ID'), '0123456789abcdef0123456789abcdef');
    await tester.enterText(field('ゲートウェイ ID（任意）'), 'prod');
    await tester.enterText(field('API トークン'), 'cf-token');
    await tester.enterText(field('最初のモデル（任意。あとで「モデル」から足せます）'), 'openai/gpt-4.1');
    await save(tester);

    final saved = app.providers.providers.single;
    expect(saved.label, 'Cloudflare AI Gateway');
    expect(saved.baseUrl, 'https://api.cloudflare.com/client/v4/accounts/0123456789abcdef0123456789abcdef/ai/v1');
    expect(saved.headers, {'cf-aig-gateway-id': 'prod'});
    expect(saved.models.single.id, 'openai/gpt-4.1');
    expect(saved.autoFetchModels, isFalse);
    expect(app.providers.keyOf(saved.id), 'cf-token');

    // opened again, it is a Cloudflare provider with its account and gateway; the gateway is not shown twice
    await tester.tap(find.byTooltip('編集'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field('アカウント ID')).controller!.text, '0123456789abcdef0123456789abcdef');
    expect(tester.widget<TextField>(field('ゲートウェイ ID（任意）')).controller!.text, 'prod');
    expect(tester.widget<TextField>(field('追加ヘッダー（JSON・任意）')).controller!.text, isNot(contains('cf-aig-gateway-id')));
    await tester.enterText(field('ゲートウェイ ID（任意）'), '');
    await save(tester);
    expect(app.providers.providers.single.headers, {'cf-aig-gateway-id': 'default'});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 30));
  });
}
