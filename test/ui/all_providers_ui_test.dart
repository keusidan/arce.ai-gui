import 'dart:convert';

import 'package:arce_ai/app.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:arce_ai/ui/shell.dart' show EnginePill;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show makeApp, setSize;
import 'prompt_cache_ui_test.dart' show field, save;

/// Two providers: Alpha lists two models, Beta's list fails.
http.Client _client() => MockClient((request) async {
      if (request.url.host == 'alpha.example' && request.url.path.endsWith('/models')) {
        return http.Response(jsonEncode({'data': [{'id': 'a1'}, {'id': 'a2'}]}), 200);
      }
      return http.Response('{"error":{"message":"down"}}', 500);
    });

void main() {
  testWidgets('providers pasted as JSON, every list read at once, and any of their models chosen from one tree', (tester) async {
    setSize(tester, const Size(1280, 1800));
    final app = await makeApp(tester);
    await app.settings.update((s) => s.copyWith(modelListAutoFetch: false));
    app.providers.clientFactory = _client;
    await tester.pumpWidget(ArceApp(app: app));
    await tester.pump();

    // 「JSON」: two providers at once, the keys go to the secure storage
    app.openSettings(SettingsSection.providers);
    await tester.pumpAndSettle();
    await tester.tap(find.text('プロバイダを追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('provider-kind-json')));
    await tester.pump();
    await tester.enterText(
      field('JSON'),
      jsonEncode([
        {'name': 'Alpha', 'baseUrl': 'https://alpha.example/v1', 'apiKey': 'ka'},
        {'name': 'Beta', 'baseUrl': 'https://beta.example/v1', 'models': ['b1'], 'headers': {'Authorization': 'Bearer kb'}},
      ]),
    );
    await save(tester);
    // two providers and two keys are saved before the sheet closes
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(app.providers.providers.map((p) => p.label), ['Alpha', 'Beta']);
    expect((app.providers.keyOf('alpha'), app.providers.keyOf('beta')), ('ka', 'kb'));

    // every list at once: one is read, the other says why not
    late String said;
    await tester.runAsync(() async => said = await app.refreshAllModelLists());
    expect(said, allOf(contains('1 件のプロバイダから、合計 2 件'), contains('Beta')));
    expect(app.providers.byId('alpha')!.knownIds, ['a1', 'a2']);

    // the model name above the chat opens one tree of every provider's models
    app.goTo(AppPage.chat);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(EnginePill).first);
    await tester.pumpAndSettle();
    expect(find.text('モデルを選ぶ'), findsOneWidget);
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsWidgets);
    await tester.enterText(find.byType(TextField).last, 'a2'); // the search opens the folders
    await tester.pumpAndSettle();
    await tester.tap(find.text('a2').last);
    await tester.pumpAndSettle();
    expect((app.providers.activeId, app.providers.activeModelId), ('alpha', 'a2'));
    await tester.pump(const Duration(seconds: 30));
  });
}
