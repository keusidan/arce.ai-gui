import 'dart:async';
import 'dart:convert';

import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/ai/provider_import.dart';
import 'package:arce_ai/ai/responses_provider.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _jsonResponse(Object body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  group('OpenAiResponsesProvider', () {
    test('Sail Flex スタイルで background: true と metadata.completion_window: flex を送り、HTTP 202 のあと GET で完了までポーリングする', () async {
      final seenRequests = <(String, String, Map<String, Object?>?)>[];
      var pollCount = 0;
      final client = MockClient((request) async {
        final decoded = request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map<String, Object?>;
        seenRequests.add((request.method, request.url.path, decoded));
        if (request.method == 'POST' && request.url.path.endsWith('/responses')) {
          return _jsonResponse({'id': 'resp_123', 'status': 'queued'}, 202);
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/responses/resp_123')) {
          pollCount++;
          if (pollCount == 1) {
            return _jsonResponse({'id': 'resp_123', 'status': 'in_progress'});
          }
          return _jsonResponse({
            'id': 'resp_123',
            'status': 'completed',
            'usage': {
              'input_tokens': 120,
              'output_tokens': 45,
              'input_tokens_details': {'cached_tokens': 60},
            },
            'output': [
              {
                'type': 'reasoning',
                'summary': [
                  {'type': 'summary_text', 'text': '深い思考'},
                ],
              },
              {
                'type': 'function_call',
                'call_id': 'call_1',
                'name': 'get_time',
                'arguments': '{"timezone":"Asia/Tokyo"}',
              },
              {
                'type': 'message',
                'content': [
                  {'type': 'output_text', 'text': '最終回答です'},
                ],
              },
            ],
          });
        }
        return http.Response('not found', 404);
      });

      final provider = OpenAiResponsesProvider(
        id: 'sail',
        label: 'Sail',
        baseUrl: 'https://api.sail.example/v1',
        model: 'sail-model',
        modelConfig: const ModelConfig(
          id: 'sail-model',
          name: 'sail-model',
          serviceTier: 'flex',
        ),
        apiKey: 'sk-test',
        useBackground: false,
        pollInterval: const Duration(milliseconds: 5),
        client: client,
      );

      final events = await provider
          .stream(
            const AiRequest(
              messages: [
                AiMessage(AiRole.system, text: 'sys'),
                AiMessage(AiRole.user, text: 'hi'),
              ],
              tools: [
                AiToolSpec(
                  name: 'get_time',
                  description: '時刻',
                  parameters: {'type': 'object'},
                ),
              ],
            ),
          )
          .toList();

      expect(seenRequests.first.$1, 'POST');
      expect(seenRequests.first.$2, '/v1/responses');
      final postBody = seenRequests.first.$3!;
      expect(postBody['background'], isTrue);
      expect(postBody['metadata'], {'completion_window': 'flex'});
      expect((postBody['tools'] as List).single, {
        'type': 'function',
        'name': 'get_time',
        'description': '時刻',
        'parameters': {'type': 'object'},
      });
      expect(pollCount, 2);

      final usage = events.whereType<UsageDelta>().single;
      expect((usage.promptTokens, usage.completionTokens, usage.cachedTokens), (
        120,
        45,
        60,
      ));
      expect(events.whereType<ReasoningDelta>().single.text, '深い思考');
      expect(events.whereType<ToolCallDelta>().single.name, 'get_time');
      expect(events.whereType<TextDelta>().single.text, '最終回答です');
      expect(events.whereType<StopDelta>().single.reason, FinishReason.eog);
    });

    test('incomplete 時は途中出力を返して FinishReason.length にし、failed 時は例外を投げる', () async {
      final incompleteClient = MockClient((request) async {
        return _jsonResponse({
          'id': 'resp_inc',
          'status': 'incomplete',
          'output_text': '途中の文章',
        });
      });
      final incProvider = OpenAiResponsesProvider(
        id: 'p',
        label: 'p',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        client: incompleteClient,
      );
      final incEvents = await incProvider
          .stream(const AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')]))
          .toList();
      expect(incEvents.whereType<TextDelta>().single.text, '途中の文章');
      expect(incEvents.whereType<StopDelta>().single.reason, FinishReason.length);

      final failedClient = MockClient((request) async {
        return _jsonResponse({
          'id': 'resp_fail',
          'status': 'failed',
          'error': {'message': 'execution failed'},
        });
      });
      final failProvider = OpenAiResponsesProvider(
        id: 'p',
        label: 'p',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        client: failedClient,
      );
      await expectLater(
        () => failProvider
            .stream(const AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')]))
            .toList(),
        throwsA(
          isA<AiProviderException>().having(
            (e) => e.message,
            'message',
            contains('execution failed'),
          ),
        ),
      );
    });

    test('ポーリング中の 429/503 はリトライで回復し、上限超過時は失敗する', () async {
      var attempt = 0;
      final recoveringClient = MockClient((request) async {
        if (request.method == 'POST') {
          return _jsonResponse({'id': 'resp_retry', 'status': 'queued'}, 202);
        }
        attempt++;
        if (attempt <= 2) {
          return http.Response('temporary', attempt == 1 ? 429 : 503);
        }
        return _jsonResponse({'id': 'resp_retry', 'status': 'completed', 'output_text': 'ok'});
      });
      final recovering = OpenAiResponsesProvider(
        id: 'p',
        label: 'p',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        useBackground: true,
        pollInterval: const Duration(milliseconds: 5),
        client: recoveringClient,
      );
      final events = await recovering
          .stream(const AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')]))
          .toList();
      expect(events.whereType<TextDelta>().single.text, 'ok');
      expect(attempt, 3);

      final exhaustingClient = MockClient((request) async {
        if (request.method == 'POST') {
          return _jsonResponse({'id': 'resp_dead', 'status': 'queued'}, 202);
        }
        return http.Response('still down', 503);
      });
      final exhausting = OpenAiResponsesProvider(
        id: 'p',
        label: 'p',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        useBackground: true,
        pollInterval: const Duration(milliseconds: 2),
        client: exhaustingClient,
      );
      await expectLater(
        () => exhausting
            .stream(const AiRequest(messages: [AiMessage(AiRole.user, text: 'hi')]))
            .toList(),
        throwsA(isA<AiProviderException>()),
      );
    });

    test('abort 時は POST /responses/{id}/cancel を送り cancelled を返す', () async {
      var cancelCalled = false;
      final client = MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/responses')) {
          return _jsonResponse({'id': 'resp_abort', 'status': 'in_progress'}, 202);
        }
        if (request.method == 'POST' &&
            request.url.path.endsWith('/responses/resp_abort/cancel')) {
          cancelCalled = true;
          return _jsonResponse({'id': 'resp_abort', 'status': 'cancelled'});
        }
        return http.Response('unexpected', 500);
      });
      final abort = Completer<void>();
      final provider = OpenAiResponsesProvider(
        id: 'p',
        label: 'p',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        useBackground: true,
        pollInterval: const Duration(seconds: 5),
        client: client,
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 15), abort.complete),
      );
      final events = await provider
          .stream(
            AiRequest(
              messages: const [AiMessage(AiRole.user, text: 'hi')],
              abort: abort.future,
            ),
          )
          .toList();
      expect(cancelCalled, isTrue);
      expect(events.whereType<StopDelta>().single.reason, FinishReason.cancelled);
    });

    test('ProviderConfig と ProviderImport が responses / background / /responses URL を往復保持する', () {
      const config = ProviderConfig(
        id: 'sail',
        label: 'Sail',
        baseUrl: 'https://api.sail.example/v1',
        api: ProviderApi.responses,
        background: true,
        models: [ModelConfig(id: 'sail-1', name: 'sail-1', serviceTier: 'flex')],
      );
      final decoded = ProviderConfig.fromJson(config.toJson());
      expect(decoded.api, ProviderApi.responses);
      expect(decoded.background, isTrue);

      final plainJson = const ProviderConfig(
        id: 'c',
        label: 'c',
        baseUrl: 'https://api.example/v1',
      ).toJson();
      expect(plainJson.containsKey('api'), isFalse);
      expect(plainJson.containsKey('background'), isFalse);

      final importedFromUrl = ProviderImport.parse(
        jsonEncode({
          'name': 'Sail',
          'baseUrl': 'https://api.sail.example/v1/responses',
          'background': true,
          'models': [
            {'id': 'sail-1', 'service_tier': 'flex'},
          ],
        }),
        const [],
      ).single.config;
      expect(importedFromUrl.baseUrl, 'https://api.sail.example/v1');
      expect(importedFromUrl.api, ProviderApi.responses);
      expect(importedFromUrl.background, isTrue);
      expect(importedFromUrl.models.single.serviceTier, 'flex');
    });
  });
}
