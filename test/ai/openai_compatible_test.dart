import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/core/attachments.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A server that answers one chat request with the given SSE chunks.
OpenAiCompatibleProvider providerWith(
  List<String> chunks, {
  int status = 200,
  String errorBody = '',
  void Function(http.BaseRequest request)? onRequest,
  String body = '',
  List<List<int>>? byteChunks,
}) {
  final client = MockClient.streaming((request, _) async {
    onRequest?.call(request);
    if (status != 200) return http.StreamedResponse(Stream.value(utf8.encode(errorBody)), status, request: request);
    return http.StreamedResponse(
      Stream.fromIterable(byteChunks ?? chunks.map(utf8.encode)),
      200,
      headers: const {'content-type': 'text/event-stream'},
      request: request,
    );
  });
  return OpenAiCompatibleProvider(
    id: 'test',
    label: 'テスト',
    baseUrl: 'https://api.example/v1/',
    model: 'test-model',
    apiKey: 'sk-test',
    client: client,
    body: body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>,
  );
}

/// A client that hands the request to a function, and notes whether it could be aborted.
class _AbortableClient extends http.BaseClient {
  _AbortableClient(this._answer);
  final http.StreamedResponse Function(http.AbortableRequest request) _answer;
  bool sawAbortTrigger = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final abortable = request as http.AbortableRequest;
    sawAbortTrigger = abortable.abortTrigger != null;
    return _answer(abortable);
  }
}

String event(Map<String, Object?> json) => 'data: ${jsonEncode(json)}\n\n';

String textEvent(String text) => event({
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    });

void main() {
  const request = AiRequest(
    messages: [
      AiMessage(AiRole.system, text: 'あなたは助手です。'),
      AiMessage(AiRole.user, text: 'こんにちは'),
    ],
  );

  group('本文と終わり方', () {
    test('本文を順に流し、使い方と stop を最後に返す', () async {
      final provider = providerWith([
        textEvent('こん'),
        textEvent('にちは'),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 3},
        }),
        'data: [DONE]\n\n',
      ]);

      final deltas = await provider.stream(request).toList();

      expect(
        [for (final d in deltas) if (d is TextDelta) d.text],
        ['こん', 'にちは'],
      );
      final usage = deltas.whereType<UsageDelta>().single;
      expect(usage.promptTokens, 12);
      expect(usage.completionTokens, 3);
      expect(deltas.last, isA<StopDelta>());
      expect((deltas.last as StopDelta).reason, FinishReason.eog);
    });

    test('プロバイダのキャッシュから読んだトークン数は、書いてあれば読む（OpenAI 形式・DeepSeek 形式）', () async {
      expect(
        OpenAiCompatibleProvider.cachedTokensOf({
          'prompt_tokens': 2006,
          'prompt_tokens_details': {'cached_tokens': 1920},
        }),
        1920,
      );
      expect(OpenAiCompatibleProvider.cachedTokensOf({'prompt_tokens': 9, 'prompt_cache_hit_tokens': 7, 'prompt_cache_miss_tokens': 2}), 7);
      expect(OpenAiCompatibleProvider.cachedTokensOf({'prompt_tokens': 9, 'prompt_tokens_details': {'audio_tokens': 0}}), isNull);
      expect(OpenAiCompatibleProvider.cachedTokensOf({'prompt_tokens': 9}), isNull, reason: 'a provider that says nothing');

      final provider = providerWith([
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
          ],
          'usage': {
            'prompt_tokens': 2006,
            'completion_tokens': 3,
            'prompt_tokens_details': {'cached_tokens': 1920},
          },
        }),
        'data: [DONE]\n\n',
      ]);
      final usage = (await provider.stream(request).toList()).whereType<UsageDelta>().single;
      expect(usage.cachedTokens, 1920);
    });

    test('考えた過程は ReasoningDelta として分ける', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {'reasoning_content': 'まず考える'},
            },
          ],
        }),
        textEvent('答え'),
      ]);

      final deltas = await provider.stream(request).toList();
      final reasoning = deltas.whereType<ReasoningDelta>().single;
      expect(reasoning.text, 'まず考える');
      expect([for (final d in deltas) if (d is TextDelta) d.text], ['答え']);
    });

    test('トークン上限で切れたら length として返す', () async {
      final provider = providerWith([
        textEvent('途中'),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'length'},
          ],
        }),
      ]);

      final deltas = await provider.stream(request).toList();
      expect((deltas.last as StopDelta).reason, FinishReason.length);
    });

    test('イベントが chunk の境目で切れても読める', () async {
      final whole = textEvent('こんにちは') +
          event({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
          });
      // a network chunk boundary in the middle of the JSON
      final provider = providerWith([whole.substring(0, 20), whole.substring(20)]);

      final deltas = await provider.stream(request).toList();
      expect([for (final d in deltas) if (d is TextDelta) d.text], ['こんにちは']);
      expect(deltas.last, isA<StopDelta>());
    });
  });

  group('文字の途中での切れ目', () {
    test('日本語の1文字の途中（バイトの境目）で chunk が切れても読める', () async {
      final bytes = utf8.encode(textEvent('こんにちは、世界') +
          event({
            'choices': [
              {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
            ],
          }));
      // every cut position, including the ones inside a three-byte character
      for (var cut = 1; cut < bytes.length; cut += 1) {
        final provider = providerWith(const [], byteChunks: [bytes.sublist(0, cut), bytes.sublist(cut)]);
        final deltas = await provider.stream(request).toList();
        expect([for (final d in deltas) if (d is TextDelta) d.text].join(), 'こんにちは、世界', reason: 'cut at $cut');
      }
    });

    test('1バイトずつ届いても読める', () async {
      final bytes = utf8.encode(textEvent('日本語の返事'));
      final provider = providerWith(const [], byteChunks: [for (final b in bytes) [b]]);
      final deltas = await provider.stream(request).toList();
      expect([for (final d in deltas) if (d is TextDelta) d.text].join(), '日本語の返事');
    });
  });

  test('停止（abort）で、モデルが黙っていても接続を切り、返信を「止めた」で終える', () async {
    // a server that sends nothing until the request is aborted, as a model that is still thinking
    final silent = StreamController<List<int>>();
    final client = _AbortableClient((request) {
      request.abortTrigger?.then((_) => silent.addError(http.RequestAbortedException(request.url)));
      return http.StreamedResponse(silent.stream, 200, request: request);
    });
    final provider = OpenAiCompatibleProvider(id: 't', label: 'テスト', baseUrl: 'https://api.example/v1/', model: 'm', apiKey: 'k', client: client);
    final abort = Completer<void>();
    final done = provider.stream(AiRequest(messages: const [AiMessage(AiRole.user, text: 'x')], abort: abort.future)).toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    abort.complete();
    final deltas = await done.timeout(const Duration(seconds: 2));
    expect(deltas.whereType<StopDelta>().single.reason, FinishReason.cancelled);
    expect(client.sawAbortTrigger, isTrue, reason: 'the request carries the trigger');
  });

  group('道具の呼び出し', () {
    Map<String, Object?> callChunk(List<Map<String, Object?>> calls) => {
          'choices': [
            {
              'delta': {'tool_calls': calls},
            },
          ],
        };

    test('呼び出しに付いた extra_content（Gemini 3 の思考署名）は、そのまま取っておき、次の送信の tool_calls に入れる', () async {
      const signature = {
        'google': {'thought_signature': 'c2lnbmF0dXJl'},
      };
      final provider = providerWith([
        event(callChunk([
          {'index': 0, 'id': 'call_a', 'function': {'name': 'web_search', 'arguments': '{"query":"x"}'}, 'extra_content': signature},
        ])),
      ]);
      final call = (await provider.stream(request).toList()).whereType<ToolCallDelta>().single;
      expect(call.extraContent, signature);

      Map<String, Object?>? sent;
      final echo = providerWith(
        [textEvent('ok')],
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      await echo
          .stream(AiRequest(messages: [
            const AiMessage(AiRole.user, text: '調べて'),
            AiMessage(AiRole.assistant, toolCalls: [call]),
            const AiMessage(AiRole.tool, text: '結果', toolCallId: 'call_a'),
          ]))
          .toList();
      final assistant = (sent!['messages']! as List)[1] as Map;
      expect((assistant['tool_calls'] as List).single['extra_content'], signature);
    });

    test('署名の無い呼び出しには extra_content を足さない', () async {
      Map<String, Object?>? sent;
      final echo = providerWith([textEvent('ok')], onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>);
      await echo
          .stream(const AiRequest(messages: [
            AiMessage(AiRole.user, text: 'x'),
            AiMessage(AiRole.assistant, toolCalls: [ToolCallDelta(id: 'a', name: 'get_time', argumentsJson: '{}')]),
            AiMessage(AiRole.tool, text: 'r', toolCallId: 'a'),
          ]))
          .toList();
      expect(((sent!['messages']! as List)[1] as Map)['tool_calls'][0].containsKey('extra_content'), isFalse);
    });

    test('失敗の本文が Gemini のようにリストで包まれていても、メッセージを出す。形が分からなければ本文の頭を出す', () async {
      final wrapped = providerWith(const [], status: 400, errorBody: jsonEncode([
        {
          'error': {'code': 400, 'message': 'Function call is missing a thought_signature in functionCall parts.', 'status': 'INVALID_ARGUMENT'},
        },
      ]));
      await expectLater(
        wrapped.stream(request).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', allOf(contains('HTTP 400'), contains('thought_signature')))),
      );
      final unknown = providerWith(const [], status: 400, errorBody: jsonEncode({'detail': {'x': 1}}));
      await expectLater(
        unknown.stream(request).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', contains('"detail"'))),
      );
    });

    test('Gemini: 同じ index 0 で id だけが違う複数の呼び出しは、別々の呼び出しになる', () async {
      final provider = providerWith([
        event(callChunk([
          {'index': 0, 'id': 'call_a', 'function': {'name': 'web_search', 'arguments': '{"query":"arce.ai github"}'}},
        ])),
        event(callChunk([
          {'index': 0, 'id': 'call_b', 'function': {'name': 'web_search', 'arguments': '{"query":"arce.ai リポジトリ"}'}},
        ])),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }),
      ]);
      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect(calls.map((c) => c.id), ['call_a', 'call_b']);
      expect(calls.map((c) => c.argumentsJson), ['{"query":"arce.ai github"}', '{"query":"arce.ai リポジトリ"}']);
    });

    test('1 つの呼び出しの引数が分かれて届くときは、同じ id が続いても 1 つのまま', () async {
      final provider = providerWith([
        event(callChunk([
          {'index': 0, 'id': 'call_a', 'function': {'name': 'web_search', 'arguments': '{"que'}},
        ])),
        event(callChunk([
          {'index': 0, 'id': 'call_a', 'function': {'arguments': 'ry":"x"}'}},
        ])),
      ]);
      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect(calls, hasLength(1));
      expect(calls.single.argumentsJson, '{"query":"x"}');
    });

    test('id が無く、引数が {...}{...} とつながって届いた同じ道具の呼び出しは、分けて返す', () async {
      final provider = providerWith([
        event(callChunk([
          {'index': 0, 'function': {'name': 'web_search', 'arguments': '{"query":"a}"}'}},
        ])),
        event(callChunk([
          {'index': 0, 'function': {'arguments': '{"query":"b"}'}},
        ])),
      ]);
      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect(calls.map((c) => c.argumentsJson), ['{"query":"a}"}', '{"query":"b"}']);
    });

    test('splitObjects: 文字列の中の括弧は数えず、オブジェクトでないものが混ざれば分けない', () {
      expect(splitObjects('{"a":"}{"}'), ['{"a":"}{"}']);
      expect(splitObjects('{"a":1} {"b":2}'), ['{"a":1}', '{"b":2}']);
      expect(splitObjects('{"a":1}x{"b":2}'), ['{"a":1}x{"b":2}']);
      expect(splitObjects('{"a":1'), ['{"a":1']);
      expect(splitObjects('{}'), ['{}']);
    });

    test('分割されて届いた引数を組み立て、完成した時点で1つ返す', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'function': {'name': 'web_search', 'arguments': '{"que'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'function': {'arguments': 'ry":"天気"}'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }),
      ]);

      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect(calls, hasLength(1));
      expect(calls.single.name, 'web_search');
      expect(calls.single.id, 'call_1');
      expect(jsonDecode(calls.single.argumentsJson), {'query': '天気'});
    });

    test('2つ同時に呼ばれたら index の順に返す', () async {
      final provider = providerWith([
        event({
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 1,
                    'id': 'b',
                    'function': {'name': 'get_time', 'arguments': '{}'},
                  },
                  {
                    'index': 0,
                    'id': 'a',
                    'function': {'name': 'get_weather', 'arguments': '{"city":"東京"}'},
                  },
                ],
              },
            },
          ],
        }),
        event({
          'choices': [
            {'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
          ],
        }),
      ]);

      final calls = (await provider.stream(request).toList()).whereType<ToolCallDelta>().toList();
      expect([for (final c in calls) c.name], ['get_weather', 'get_time']);
    });
  });

  group('送る内容', () {
    test('モデル・履歴・道具の定義を OpenAI の形で送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok')],
        onRequest: (request) => sent = jsonDecode((request as http.Request).body) as Map<String, Object?>,
      );

      await provider
          .stream(const AiRequest(
            messages: [
              AiMessage(AiRole.system, text: 'system'),
              AiMessage(AiRole.user, text: 'これは何'),
              AiMessage(AiRole.assistant, toolCalls: [
                ToolCallDelta(id: 'call_1', name: 'get_time', argumentsJson: '{"timezone":"Asia/Tokyo"}'),
              ]),
              AiMessage(AiRole.tool, text: '2026-10-20T22:00:00Z', toolCallId: 'call_1'),
            ],
            tools: [
              AiToolSpec(
                name: 'get_time',
                description: 'いまの時刻',
                parameters: {
                  'type': 'object',
                  'properties': {
                    'timezone': {'type': 'string'},
                  },
                },
              ),
            ],
          ))
          .toList();

      expect(sent!['model'], 'test-model');
      expect(sent!['stream'], isTrue);
      final messages = (sent!['messages'] as List).cast<Map<String, Object?>>();
      expect([for (final m in messages) m['role']], ['system', 'user', 'assistant', 'tool']);
      expect(messages.last['tool_call_id'], 'call_1');
      final calls = (messages[2]['tool_calls'] as List).cast<Map<String, Object?>>();
      expect((calls.single['function'] as Map)['name'], 'get_time');
      final tools = (sent!['tools'] as List).cast<Map<String, Object?>>();
      expect((tools.single['function'] as Map)['name'], 'get_time');
      expect(sent!.containsKey('stream_options'), isTrue);
    });

    test('接続先の違いはヘッダーと body の上書きで吸収する', () async {
      http.BaseRequest? seen;
      final provider = providerWith(
        [textEvent('ok')],
        body: '{"thinking":{"type":"enabled"}}',
        onRequest: (request) => seen = request,
      );

      await provider.stream(request).toList();

      final sent = jsonDecode((seen as http.Request).body) as Map<String, Object?>;
      expect(sent['thinking'], {'type': 'enabled'});
      expect(sent['model'], 'test-model', reason: 'overrides add fields, they do not replace the request');
    });

    test('道具を送らない設定なら tools を付けない', () async {
      Map<String, Object?>? sent;
      final client = MockClient.streaming((request, _) async {
        sent = jsonDecode((request as http.Request).body) as Map<String, Object?>;
        return http.StreamedResponse(Stream.value(utf8.encode(textEvent('ok'))), 200, request: request);
      });
      final provider = OpenAiCompatibleProvider(
        id: 'local',
        label: 'ローカル互換',
        baseUrl: 'http://127.0.0.1:11434/v1',
        model: 'qwen',
        client: client,
        supportsTools: false,
      );

      await provider
          .stream(const AiRequest(
            messages: [AiMessage(AiRole.user, text: 'hi')],
            tools: [
              AiToolSpec(name: 'x', description: '', parameters: {'type': 'object'}),
            ],
          ))
          .toList();

      expect(sent!.containsKey('tools'), isFalse);
    });
  });

  group('失敗', () {
    test('キーが拒否されたら、その旨を返す', () async {
      final provider = providerWith(
        const [],
        status: 401,
        errorBody: jsonEncode({
          'error': {'message': 'Incorrect API key provided'},
        }),
      );

      await expectLater(
        provider.stream(request).toList(),
        throwsA(isA<AiProviderException>().having(
          (e) => e.message,
          'message',
          allOf(contains('APIキー'), contains('Incorrect API key')),
        )),
      );
    });

    test('接続先が無いときは URL を疑うよう伝える', () async {
      final provider = providerWith(const [], status: 404, errorBody: 'not found');

      await expectLater(
        provider.stream(request).toList(),
        throwsA(isA<AiProviderException>().having((e) => e.message, 'message', contains('URL'))),
      );
    });

    test('接続確認は /models を叩く', () async {
      late Uri seen;
      final client = MockClient((request) async {
        seen = request.url;
        return http.Response('{"data":[]}', 200);
      });
      final provider = OpenAiCompatibleProvider(
        id: 'test',
        label: 'テスト',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        apiKey: 'sk-test',
        client: client,
      );

      await provider.verify();
      expect(seen.toString(), 'https://api.example/v1/models');
    });
  });

  group('思考の項目', () {
    test('モデルの項目は本体に入り、提供元の上書きがそれより強い', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        body: jsonEncode({'reasoning_effort': 'low', 'top_k': 5}),
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      await provider
          .stream(const AiRequest(
            messages: [AiMessage(AiRole.user, text: 'こんにちは')],
            extraBody: {
              'thinking': {'type': 'enabled'},
              'reasoning_effort': 'max',
            },
          ))
          .toList();
      expect(sent!['thinking'], {'type': 'enabled'});
      expect(sent!['reasoning_effort'], 'low', reason: 'the provider\'s own override comes last');
      expect(sent!['top_k'], 5);
    });
  });

  group('モデル一覧', () {
    test('上限と画像対応を、提供元の一覧から読む。IDの順に並べる', () async {
      final provider = providerWith([
        jsonEncode({
          'data': [
            {'id': 'zeta', 'context_length': 8192},
            {
              'id': 'alpha',
              'context_length': 1048576,
              'architecture': {'input_modalities': ['text', 'image']},
              'top_provider': {'max_completion_tokens': 262144},
            },
          ],
        }),
      ]);
      final infos = await provider.fetchModelInfos();
      expect([for (final i in infos) i.id], ['alpha', 'zeta']);
      expect(infos.first.contextTokens, 1048576);
      expect(infos.first.maxOutputTokens, 262144);
      expect(infos.first.vision, isTrue);
      expect(infos.last.maxOutputTokens, isNull);
    });

    test('名前だけの一覧は、これまでどおり listModels で読める', () async {
      final provider = providerWith([jsonEncode({'data': [{'id': 'b'}, {'id': 'a'}]})]);
      expect(await provider.listModels(), ['a', 'b']);
    });

    test('読めない応答と、エラーの応答は、そのまま見せられる理由で失敗する', () async {
      await expectLater(providerWith(['<html>']).fetchModelInfos(), throwsA(isA<AiProviderException>()));
      await expectLater(providerWith(const [], status: 401, errorBody: '{}').fetchModelInfos(), throwsA(isA<AiProviderException>()));
    });
  });

  group('画像', () {
    test('画像つきのメッセージは、本文と画像の並びとして送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      final image = ImageData('image/png', Uint8List.fromList([1, 2, 3]));
      await provider
          .stream(AiRequest(messages: [AiMessage(AiRole.user, text: 'これは何？', images: [image])]))
          .toList();
      final content = ((sent!['messages']! as List).single as Map)['content'] as List;
      expect(content[0], {'type': 'text', 'text': 'これは何？'});
      expect(content[1], {
        'type': 'image_url',
        'image_url': {'url': 'data:image/png;base64,AQID'},
      });
    });

    test('画像のないメッセージは、これまでどおり文字列のまま送る', () async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok'), 'data: [DONE]\n\n'],
        onRequest: (r) => sent = jsonDecode((r as http.Request).body) as Map<String, Object?>,
      );
      await provider.stream(request).toList();
      expect(((sent!['messages']! as List).last as Map)['content'], 'こんにちは');
    });

    test('画像に対応するかは、モデルの設定、なければ名前から決まる', () {
      OpenAiCompatibleProvider with_(String model, {ModelConfig? config}) => OpenAiCompatibleProvider(
            id: 't',
            label: 't',
            baseUrl: 'https://x/v1',
            model: model,
            modelConfig: config,
          );
      expect(with_('gpt-4o-mini').capabilities.vision, isTrue);
      expect(with_('qwen2.5-vl-7b').capabilities.vision, isTrue);
      expect(with_('deepseek-chat').capabilities.vision, isFalse);
      expect(with_('gpt-oss-120b').capabilities.vision, isFalse);
      // the user's choice wins over the guess, both ways
      expect(with_('gpt-4o', config: const ModelConfig(id: 'gpt-4o', name: 'x', vision: false)).capabilities.vision, isFalse);
      expect(with_('my-model', config: const ModelConfig(id: 'my-model', name: 'x', vision: true)).capabilities.vision, isTrue);
    });
  });

  group('思考を返す（reasoning_content）', () {
    Future<List<Map<String, Object?>>> send(List<AiMessage> messages) async {
      Map<String, Object?>? sent;
      final provider = providerWith(
        [textEvent('ok')],
        onRequest: (request) => sent = jsonDecode((request as http.Request).body) as Map<String, Object?>,
      );
      await provider.stream(AiRequest(messages: messages)).toList();
      return (sent!['messages'] as List).cast<Map<String, Object?>>();
    }

    test('思考のある assistant メッセージは reasoning_content を付け、無いものには付けない', () async {
      final messages = await send(const [
        AiMessage(AiRole.user, text: 'x'),
        AiMessage(AiRole.assistant, text: '調べます', reasoning: '時刻を知りたい', toolCalls: [
          ToolCallDelta(id: 'call_1', name: 'get_time', argumentsJson: '{}'),
        ]),
        AiMessage(AiRole.tool, text: '12:00', toolCallId: 'call_1'),
        AiMessage(AiRole.assistant, text: '正午です', reasoning: '答えられる'),
        AiMessage(AiRole.user, text: 'もう一度'),
        AiMessage(AiRole.assistant, text: '了解'),
      ]);
      expect(messages[1]['reasoning_content'], '時刻を知りたい');
      expect(messages[3]['reasoning_content'], '答えられる');
      expect(messages[5].containsKey('reasoning_content'), isFalse);
      expect(messages[0].containsKey('reasoning_content'), isFalse);
    });

    test('空白だけの思考は送らない', () async {
      final messages = await send(const [AiMessage(AiRole.assistant, text: 'a', reasoning: '  \n')]);
      expect(messages.single.containsKey('reasoning_content'), isFalse);
    });
  });
}
