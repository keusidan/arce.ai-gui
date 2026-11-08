import 'dart:convert';

import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/services/app_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_test.dart' show makeApp;

const _sse = 'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
const _limit0 =
    '[{"error":{"code":429,"message":"You exceeded your current quota. * Quota exceeded for metric: generate_content_free_tier_requests, limit: 0, model: gemini-2.5-pro","status":"RESOURCE_EXHAUSTED"}}]';

const gemini = ProviderConfig(
  id: 'gem',
  label: 'Gemini',
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
  models: [ModelConfig(id: 'gemini-2.5-flash', name: 'flash'), ModelConfig(id: 'gemini-2.5-pro', name: 'pro'), ModelConfig(id: 'gemini-1.0-pro', name: 'old')],
);

/// Gemini as the app sees it: the native list for the key, and chat requests (the ones that are counted).
class FakeGemini {
  FakeGemini({this.list, this.listStatus = 200, this.chat = const {}});

  /// The `models` of the native list; null: the list answers with [listStatus] only.
  final List<Map<String, Object?>>? list;
  final int listStatus;
  final Map<String, (int, String)> chat;

  final listRequests = <http.Request>[];
  final chatModels = <String>[];

  http.Client client() => MockClient.streaming((request, bodyStream) async {
        final body = utf8.decode(await bodyStream.expand((x) => x).toList());
        if (request.url.path.endsWith('chat/completions')) {
          final model = (jsonDecode(body) as Map)['model'] as String;
          chatModels.add(model);
          final (status, text) = chat[model] ?? (200, _sse);
          return http.StreamedResponse(Stream.value(utf8.encode(text)), status, request: request);
        }
        // Gemini's own list (the OpenAI-style list the app reads when a provider is saved is another path)
        if (request.url.path == '/v1beta/models') {
          listRequests.add(request as http.Request);
          if (list == null || listStatus != 200) {
            return http.StreamedResponse(Stream.value(utf8.encode('{"error":{"message":"x"}}')), listStatus, request: request);
          }
          return http.StreamedResponse(Stream.value(utf8.encode(jsonEncode({'models': list}))), 200, request: request);
        }
        return http.StreamedResponse(Stream.value(utf8.encode('{"data":[]}')), 200, request: request);
      });
}

Map<String, Object?> entry(String id, {List<String> methods = const ['generateContent']}) => {'name': 'models/$id', 'supportedGenerationMethods': methods};

Future<AppController> appWith(WidgetTester tester, FakeGemini fake, {bool asks = false}) async {
  final app = await makeApp(tester);
  await app.settings.update((s) => s.copyWith(autoCheckSelectedModel: false, modelCheckAsksToo: asks));
  app.providers.clientFactory = fake.client;
  await app.providers.save(gemini);
  await tester.runAsync(() => app.providers.setKey('gem', 'AIza-free-tier'));
  await app.providers.setActive('gem');
  return app;
}

void main() {
  testWidgets('choosing a Gemini model reads its limits from the key\'s own list (once, for the limits and the check together)', (tester) async {
    final fake = FakeGemini(list: [
      {'name': 'models/gemini-2.5-flash', 'inputTokenLimit': 1048576, 'outputTokenLimit': 65536, 'supportedGenerationMethods': ['generateContent']},
    ]);
    final app = await appWith(tester, fake);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300)); // the limits are looked up when the provider is chosen
      await app.checkModels('gem', ['gemini-2.5-flash']);
    });
    final model = app.providers.byId('gem')!.models.firstWhere((m) => m.id == 'gemini-2.5-flash');
    expect((model.contextTokens, model.maxOutputTokens), (1048576, 65536), reason: 'the limits the app asks for with no length set');
    expect(fake.listRequests, hasLength(1));
  });

  testWidgets('the key\'s list decides: a model that is not in it, or does no chat, is marked; a listed one is not; no chat request was sent', (tester) async {
    final fake = FakeGemini(list: [entry('gemini-2.5-flash'), entry('gemini-2.5-pro'), entry('text-embedding-004', methods: ['embedContent'])]);
    final app = await appWith(tester, fake);
    late Map<String, String> lines;
    await tester.runAsync(() async => lines = await app.checkModels('gem', ['gemini-2.5-flash', 'gemini-1.0-pro', 'text-embedding-004']));
    expect(fake.chatModels, isEmpty, reason: 'the list is free: no question was asked');
    expect(fake.listRequests, hasLength(1));
    expect(lines['gemini-2.5-flash'], contains('一覧にあります'));
    expect(lines['gemini-1.0-pro'], allOf(contains('使えません'), contains('モデル一覧にありません')));
    expect(lines['text-embedding-004'], allOf(contains('使えません'), contains('generateContent')));
    expect(app.modelMarks.of('gem', 'gemini-1.0-pro')!.isBlocked, isTrue);
    expect(app.modelMarks.of('gem', 'text-embedding-004')!.isBlocked, isTrue);
    expect(app.modelMarks.of('gem', 'gemini-2.5-flash'), isNull, reason: 'listed is not "confirmed usable": the plan may still refuse it');
  });

  testWidgets('with the setting on, a listed model is asked too, and a free tier\'s "limit: 0" shows; a model the list does not have is not asked', (tester) async {
    final fake = FakeGemini(list: [entry('gemini-2.5-flash'), entry('gemini-2.5-pro')], chat: {'gemini-2.5-pro': (429, _limit0)});
    final app = await appWith(tester, fake, asks: true);
    late Map<String, String> lines;
    await tester.runAsync(() async => lines = await app.checkModels('gem', ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-1.0-pro']));
    expect(fake.chatModels.toSet(), {'gemini-2.5-flash', 'gemini-2.5-pro'}, reason: 'not the one the list lacks');
    expect(lines['gemini-2.5-flash'], contains('使えます'));
    expect(lines['gemini-2.5-pro'], contains('使えません'));
    expect(lines['gemini-1.0-pro'], contains('モデル一覧にありません'));
    expect(app.modelMarks.of('gem', 'gemini-2.5-flash')!.isUsable, isTrue);
    expect(app.modelMarks.of('gem', 'gemini-2.5-pro')!.isBlocked, isTrue);
  });

  testWidgets('a list that cannot be read, or is empty, makes it ask the models instead', (tester) async {
    for (final fake in [FakeGemini(list: null, listStatus: 500, chat: {'gemini-2.5-pro': (429, _limit0)}), FakeGemini(list: const [], chat: {'gemini-2.5-pro': (429, _limit0)})]) {
      final app = await appWith(tester, fake);
      late Map<String, String> lines;
      await tester.runAsync(() async => lines = await app.checkModels('gem', ['gemini-2.5-flash', 'gemini-2.5-pro']));
      expect(fake.chatModels.toSet(), {'gemini-2.5-flash', 'gemini-2.5-pro'});
      expect(lines['gemini-2.5-flash'], contains('使えます'));
      expect(lines['gemini-2.5-pro'], contains('使えません'));
    }
  });

  testWidgets('a refused key is said once and nothing is marked or asked', (tester) async {
    for (final status in [401, 403]) {
      final fake = FakeGemini(list: null, listStatus: status);
      final app = await appWith(tester, fake);
      late Map<String, String> lines;
      await tester.runAsync(() async => lines = await app.checkModels('gem', ['gemini-2.5-flash', 'gemini-2.5-pro']));
      expect(lines.keys, ['']);
      expect(lines[''], contains('APIキーが受け付けられなかった'));
      expect(fake.chatModels, isEmpty);
      expect(app.availability.length, 0);
    }
  });

  testWidgets('the button\'s check reads the list afresh each time; choosing a model uses what was read', (tester) async {
    final fake = FakeGemini(list: [entry('gemini-2.5-flash'), entry('gemini-2.5-pro')]);
    final app = await appWith(tester, fake);
    await tester.runAsync(() async {
      await app.checkModels('gem', ['gemini-2.5-flash']);
      await app.checkModels('gem', ['gemini-2.5-pro']);
    });
    expect(fake.listRequests, hasLength(1), reason: 'the second check used the list that was read');
    await tester.runAsync(() => app.checkModels('gem', ['gemini-2.5-pro'], refreshList: true));
    expect(fake.listRequests, hasLength(2));
  });

  testWidgets('the button checks the models that are set up and says it model by model, with the list only (no chat request)', (tester) async {
    final fake = FakeGemini(list: [entry('gemini-2.5-flash')]);
    final app = await appWith(tester, fake);
    await app.providers.selectModel('gem', 'gemini-2.5-pro');
    late String text;
    await tester.runAsync(() async => text = await app.checkConfiguredModels());
    expect(text, contains('Gemini · gemini-2.5-pro：使えません（このキーのモデル一覧にありません'));
    expect(fake.chatModels, isEmpty);
  });

  testWidgets('choosing a model: a model the key\'s list does not have is said at once, with no chat request', (tester) async {
    final fake = FakeGemini(list: [entry('gemini-2.5-flash'), entry('gemini-2.5-pro')]);
    final app = await appWith(tester, fake);
    await app.settings.update((s) => s.copyWith(autoCheckSelectedModel: true));
    await app.providers.selectModel('gem', 'gemini-1.0-pro');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect(app.toast.value, allOf(contains('gemini-1.0-pro'), contains('使えない可能性があります'), contains('モデル一覧にありません')));
    expect(fake.chatModels, isEmpty);
    await tester.pump(const Duration(seconds: 30));
  });
}
