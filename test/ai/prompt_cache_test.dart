import 'dart:convert';

import 'package:arce_ai/ai/cloud_engine.dart';
import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/engine.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/prompt.dart';
import 'package:arce_ai/services/provider_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chat_controller_test.dart' show ScriptedEngine;

/// A server that answers its requests one after the other with the given (status, body), and keeps the
/// request bodies it was sent.
class FakeServer {
  FakeServer(this.answers);

  final List<(int, String)> answers;
  final bodies = <Map<String, Object?>>[];

  http.Client get client => MockClient.streaming((request, stream) async {
        bodies.add(jsonDecode(await stream.bytesToString()) as Map<String, Object?>);
        final (status, body) = answers[(bodies.length - 1).clamp(0, answers.length - 1)];
        return http.StreamedResponse(Stream.value(utf8.encode(body)), status, request: request);
      });
}

const _ok = (200, 'data: {"choices":[{"delta":{"content":"はい"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');
const _refused = (400, '{"error":{"message":"Unrecognized request argument supplied: prompt_cache_key","type":"invalid_request_error"}}');

OpenAiCompatibleProvider provider(
  FakeServer server, {
  bool cache = false,
  String field = ProviderConfig.defaultPromptCacheField,
  Map<String, Object?> body = const {},
  void Function(String)? onRefused,
}) =>
    OpenAiCompatibleProvider(
      id: 'p',
      label: 'テスト',
      baseUrl: 'https://api.example/v1',
      model: 'm',
      client: server.client,
      promptCache: cache,
      promptCacheField: field,
      body: body,
      onCacheRefused: onRefused,
    );

AiRequest request({String? key = 'arce-abc'}) => AiRequest(messages: const [AiMessage(AiRole.user, text: 'こんにちは')], cacheKey: key);

Future<List<Delta>> run(OpenAiCompatibleProvider p, AiRequest r) => p.stream(r).toList();

void main() {
  group('what the app sends', () {
    test('with the switch off nothing is sent for the cache, whatever the request carries', () async {
      final server = FakeServer([_ok]);
      await run(provider(server), request());
      expect(server.bodies.single.containsKey('prompt_cache_key'), isFalse);
      expect(jsonEncode(server.bodies.single), isNot(contains('arce-abc')));
    });

    test('with it on the field carries the key of the conversation', () async {
      final server = FakeServer([_ok]);
      await run(provider(server, cache: true), request());
      expect(server.bodies.single['prompt_cache_key'], 'arce-abc');
    });

    test('the same key in every request of a conversation, another for another one', () async {
      final server = FakeServer([_ok]);
      final p = provider(server, cache: true);
      await run(p, request(key: 'arce-one'));
      await run(p, request(key: 'arce-one'));
      await run(p, request(key: 'arce-two'));
      expect([for (final b in server.bodies) b['prompt_cache_key']], ['arce-one', 'arce-one', 'arce-two']);
    });

    test('a request that belongs to no conversation carries none (the app\'s own short requests)', () async {
      final server = FakeServer([_ok]);
      await run(provider(server, cache: true), request(key: null));
      await run(provider(server, cache: true), request(key: ''));
      expect(server.bodies.every((b) => !b.containsKey('prompt_cache_key')), isTrue);
    });

    test('the name of the field can be changed; the default name is then not sent', () async {
      final server = FakeServer([_ok]);
      await run(provider(server, cache: true, field: 'cache_id'), request());
      expect(server.bodies.single['cache_id'], 'arce-abc');
      expect(server.bodies.single.containsKey('prompt_cache_key'), isFalse);
    });

    test('a name that cannot be a field is not sent at all', () async {
      final server = FakeServer([_ok]);
      await run(provider(server, cache: true, field: 'a b'), request());
      await run(provider(server, cache: true, field: ''), request());
      expect(server.bodies.every((b) => !jsonEncode(b).contains('arce-abc')), isTrue);
    });

    test('the user\'s own body field of that name is theirs: it wins and the app adds nothing', () async {
      final server = FakeServer([_ok]);
      await run(provider(server, cache: true, body: {'prompt_cache_key': 'mine'}), request());
      expect(server.bodies.single['prompt_cache_key'], 'mine');
    });
  });

  group('a server that refuses the field', () {
    test('the request goes again without it, once, and the answer is the retry\'s; the app is told why', () async {
      final server = FakeServer([_refused, _ok]);
      final told = <String>[];
      final deltas = await run(provider(server, cache: true, onRefused: told.add), request());
      expect(server.bodies, hasLength(2));
      expect(server.bodies.first['prompt_cache_key'], 'arce-abc');
      expect(server.bodies.last.containsKey('prompt_cache_key'), isFalse);
      expect(deltas.whereType<TextDelta>().map((d) => d.text).join(), 'はい');
      expect(told, hasLength(1));
      expect(told.single, contains('prompt_cache_key'));
      expect(told.single, contains('オフ'));
    });

    test('422 is treated the same way', () async {
      final server = FakeServer([(422, '{"detail":"extra field prompt_cache_key not permitted"}'), _ok]);
      final told = <String>[];
      await run(provider(server, cache: true, onRefused: told.add), request());
      expect(server.bodies, hasLength(2));
      expect(told, hasLength(1));
    });

    test('a refusal names the configured field, not the default', () async {
      final server = FakeServer([(400, '{"error":"unknown parameter: cache_id"}'), _ok]);
      final told = <String>[];
      await run(provider(server, cache: true, field: 'cache_id', onRefused: told.add), request());
      expect(server.bodies.last.containsKey('cache_id'), isFalse);
      expect(told.single, contains('cache_id'));
    });

    test('the same provider object does not send it again after that', () async {
      final server = FakeServer([_refused, _ok, _ok]);
      final p = provider(server, cache: true);
      await run(p, request());
      await run(p, request());
      expect(server.bodies, hasLength(3));
      expect(server.bodies.last.containsKey('prompt_cache_key'), isFalse);
    });

    test('a 400 that does not name the field is an error as before: no retry, nothing turned off', () async {
      final server = FakeServer([(400, '{"error":{"message":"max_tokens is too large"}}')]);
      final told = <String>[];
      await expectLater(
        run(provider(server, cache: true, onRefused: told.add), request()),
        throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 400)),
      );
      expect(server.bodies, hasLength(1));
      expect(told, isEmpty);
    });

    test('with the switch off there is no retry, even if the body names the field (it is the user\'s own)', () async {
      final server = FakeServer([_refused]);
      await expectLater(run(provider(server, body: {'prompt_cache_key': 'mine'}), request()), throwsA(isA<AiProviderException>()));
      expect(server.bodies, hasLength(1));
      final again = FakeServer([_refused]);
      await expectLater(run(provider(again, cache: true, body: {'prompt_cache_key': 'mine'}), request()), throwsA(isA<AiProviderException>()));
      expect(again.bodies, hasLength(1), reason: 'the app did not send it, so it is not the one to take it away');
    });

    test('when the retry fails too, that failure is the one the user reads', () async {
      final server = FakeServer([_refused, (401, '{"error":{"message":"bad key"}}')]);
      await expectLater(
        run(provider(server, cache: true), request()),
        throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(server.bodies, hasLength(2));
    });
  });

  group('the setting of a provider', () {
    test('is off by default and not written; on is written; the name is written only when it is not the default', () {
      const plain = ProviderConfig(id: 'a', label: 'A', baseUrl: 'https://a.example/v1');
      expect(plain.promptCache, isFalse);
      expect(plain.promptCacheField, 'prompt_cache_key');
      expect(plain.toJson().containsKey('promptCache'), isFalse);
      expect(plain.toJson().containsKey('promptCacheField'), isFalse);
      final on = plain.copyWith(promptCache: true, promptCacheField: 'cache_id');
      expect(on.toJson()['promptCache'], true);
      expect(on.toJson()['promptCacheField'], 'cache_id');
      final back = ProviderConfig.fromJson(on.toJson());
      expect((back.promptCache, back.promptCacheField), (true, 'cache_id'));
      expect(plain.copyWith(label: 'B').promptCache, isFalse, reason: 'copyWith keeps it');
      expect(on.copyWith(label: 'B').promptCacheField, 'cache_id');
    });

    test('a save from before the switch loads with it off; wrong types and bad names fall back', () {
      final old = ProviderConfig.fromJson({'id': 'a', 'label': 'A', 'baseUrl': 'https://a.example/v1', 'models': []});
      expect((old.promptCache, old.promptCacheField), (false, 'prompt_cache_key'));
      final odd = ProviderConfig.fromJson({'id': 'a', 'label': 'A', 'baseUrl': 'https://a.example/v1', 'promptCache': 'yes', 'promptCacheField': 'a b'});
      expect((odd.promptCache, odd.promptCacheField), (false, 'prompt_cache_key'));
      final spaces = ProviderConfig.fromJson({'id': 'a', 'label': 'A', 'baseUrl': 'x', 'promptCacheField': '  cache_id '});
      expect(spaces.promptCacheField, 'cache_id');
      expect(ProviderConfig.isValidCacheField('prompt_cache_key'), isTrue);
      for (final bad in ['', ' ', 'a b', '1a', 'a=b', 'a"b', 'x' * 65, 'model', 'Messages', 'tools', 'stream', 'max_tokens']) {
        expect(ProviderConfig.isValidCacheField(bad), isFalse, reason: bad);
      }
    });

    test('survives the provider store: saved, read back, and an old save without it still loads', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProviderStore.load();
      await store.save(const ProviderConfig(
        id: 'a',
        label: 'A',
        baseUrl: 'https://a.example/v1',
        models: [ModelConfig(id: 'm', name: 'm')],
        promptCache: true,
        promptCacheField: 'cache_id',
      ));
      final again = await ProviderStore.load();
      expect((again.byId('a')!.promptCache, again.byId('a')!.promptCacheField), (true, 'cache_id'));
      SharedPreferences.setMockInitialValues({
        'providers.v1': jsonEncode([
          {'id': 'old', 'label': 'Old', 'baseUrl': 'https://old.example/v1', 'models': [{'id': 'm', 'name': 'm'}]},
        ]),
      });
      final old = await ProviderStore.load();
      expect(old.byId('old')!.promptCache, isFalse);
    });
  });

  group('the provider store', () {
    test('builds the provider with the switch and the name', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProviderStore.load();
      final server = FakeServer([_ok]);
      store.clientFactory = () => server.client;
      const config = ProviderConfig(
        id: 'a',
        label: 'A',
        baseUrl: 'https://a.example/v1',
        models: [ModelConfig(id: 'm', name: 'm')],
        promptCache: true,
        promptCacheField: 'cache_id',
      );
      await store.save(config);
      await store.build(config).stream(request()).toList();
      expect(server.bodies.single['cache_id'], 'arce-abc');
    });

    test('a refusal turns the switch off for good (kept in place in the list), and says why', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProviderStore.load();
      const a = ProviderConfig(id: 'a', label: 'エー', baseUrl: 'https://a.example/v1', models: [ModelConfig(id: 'm', name: 'm')], promptCache: true);
      const b = ProviderConfig(id: 'b', label: 'ビー', baseUrl: 'https://b.example/v1', models: [ModelConfig(id: 'm', name: 'm')]);
      await store.save(a);
      await store.save(b);
      final server = FakeServer([_refused, _ok]);
      store.clientFactory = () => server.client;
      final notices = <String>[];
      store.onNotice = notices.add;
      await store.build(a).stream(request()).toList();
      await Future<void>.delayed(Duration.zero);
      expect(store.byId('a')!.promptCache, isFalse);
      expect([for (final p in store.providers) p.id], ['a', 'b'], reason: 'it keeps its place: a save would have moved it to the end');
      expect(notices.single, allOf(contains('エー'), contains('prompt_cache_key')));
      expect((await ProviderStore.load()).byId('a')!.promptCache, isFalse, reason: 'kept');
      // the next provider built from it sends nothing for the cache
      await store.build(store.byId('a')!).stream(request()).toList();
      expect(server.bodies.last.containsKey('prompt_cache_key'), isFalse);
    });

    test('setPromptCache leaves an unknown provider alone, and a provider that already has that value', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await ProviderStore.load();
      var changes = 0;
      store.addListener(() => changes++);
      await store.setPromptCache('nobody', true);
      await store.save(const ProviderConfig(id: 'a', label: 'A', baseUrl: 'https://a.example/v1'));
      final before = changes;
      await store.setPromptCache('a', false);
      expect(changes, before, reason: 'nothing changed: nothing told');
      await store.setPromptCache('a', true);
      expect(store.byId('a')!.promptCache, isTrue);
    });
  });

  group('the key travels from the conversation to the provider', () {
    test('the chat puts the key of its conversation on every request, and none when it has no key', () async {
      final first = ScriptedEngine([('一つ目', FinishReason.eog), ('二つ目', FinishReason.eog)]);
      final chat = ChatController(first, conversationKey: () => 'arce-one');
      await chat.send('こんにちは');
      await chat.send('もう一度');
      expect([for (final r in first.requests) r.conversationKey], ['arce-one', 'arce-one']);

      final other = ScriptedEngine([('三つ目', FinishReason.eog)]);
      await ChatController(other, conversationKey: () => 'arce-two').send('別の会話');
      expect(other.requests.single.conversationKey, 'arce-two');

      final none = ScriptedEngine([('四つ目', FinishReason.eog)]);
      await ChatController(none).send('キーなし');
      expect(none.requests.single.conversationKey, isNull);
      final nothing = ScriptedEngine([('五つ目', FinishReason.eog)]);
      await ChatController(nothing, conversationKey: () => null).send('null');
      expect(nothing.requests.single.conversationKey, isNull);
    });

    test('GenerateRequest keeps it through withAbort, and CloudEngine passes it on as AiRequest.cacheKey', () async {
      final seen = <AiRequest>[];
      final engine = CloudEngine(RecordingProvider(seen));
      const sampling = SamplingParams(temperature: 0.3, topP: 0.9, topK: 20, minP: 0);
      final prompt = ChatMlPromptBuilder.build(const [UserTurn('こんにちは')], const [], null, false);
      final generate = GenerateRequest(
        prompt: prompt,
        toolCallSchema: null,
        thinking: false,
        maxTokens: 64,
        sampling: sampling,
        conversationKey: 'arce-xyz',
      );
      expect(generate.withAbort(Future<void>.value()).conversationKey, 'arce-xyz');
      await engine.generate(generate).toList();
      expect(seen.single.cacheKey, 'arce-xyz');
      seen.clear();
      await engine.generate(GenerateRequest(prompt: prompt, toolCallSchema: null, thinking: false, maxTokens: 64, sampling: sampling)).toList();
      expect(seen.single.cacheKey, isNull);
    });
  });
}

class RecordingProvider implements AiProvider {
  RecordingProvider(this.seen);
  final List<AiRequest> seen;

  @override
  String get id => 'rec';
  @override
  String get label => 'rec';
  @override
  String get modelId => '';
  @override
  ModelConfig? get modelConfig => null;
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities();
  @override
  Future<void> verify() async {}
  @override
  Stream<Delta> stream(AiRequest request) async* {
    seen.add(request);
    yield const StopDelta(FinishReason.eog);
  }
}
