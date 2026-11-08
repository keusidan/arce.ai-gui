import 'dart:convert';

import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/model_list_check.dart';
import 'package:arce_ai/ai/openai_compatible.dart';
import 'package:arce_ai/ai/provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const list = [
    ModelInfo('gemini-2.5-flash', chat: true),
    ModelInfo('gemini-2.5-pro', chat: true),
    ModelInfo('text-embedding-004', chat: false),
    ModelInfo('gpt-like'),
  ];

  group('judging a model by the list the key can read', () {
    test('a model that is not in the list is out, and the id is read the way the list writes it', () {
      final out = ModelListCheck.judge('gemini-1.0-pro', list)!;
      expect((out.finding, out.isBlocked), (ListFinding.absent, true));
      expect(out.reason, contains('モデル一覧にありません'));
      expect(ModelListCheck.judge('models/gemini-2.5-pro', list)!.finding, ListFinding.listed, reason: 'models/ in front is the same model');
      expect(ModelListCheck.judge('gemini-2.5-pro', [const ModelInfo('models/gemini-2.5-pro')])!.finding, ListFinding.listed);
    });

    test('a model the list says does no chat is out', () {
      final out = ModelListCheck.judge('text-embedding-004', list)!;
      expect(out.finding, ListFinding.notChat);
      expect(out.isBlocked, isTrue);
      expect(out.reason, contains('generateContent'));
    });

    test('a listed model is listed, not "usable": a list says nothing about a free tier\'s quota; one the list does not describe is listed too', () {
      for (final id in ['gemini-2.5-flash', 'gpt-like']) {
        final verdict = ModelListCheck.judge(id, list)!;
        expect((verdict.finding, verdict.isBlocked), (ListFinding.listed, false), reason: id);
      }
    });

    test('a list that could not be read or is empty says nothing', () {
      expect(ModelListCheck.judge('x', null), isNull);
      expect(ModelListCheck.judge('x', const []), isNull);
    });
  });

  group('Gemini\'s own list', () {
    test('which endpoints are Gemini\'s, and the native list\'s address', () {
      expect(GeminiModels.isGemini('https://generativelanguage.googleapis.com/v1beta/openai'), isTrue);
      expect(GeminiModels.isGemini('https://generativelanguage.googleapis.com/v1beta/openai/'), isTrue);
      expect(GeminiModels.isGemini('https://api.openai.com/v1'), isFalse);
      expect(GeminiModels.isGemini('https://generativelanguage.googleapis.com.evil.example/v1'), isFalse);
      expect(GeminiModels.isGemini('not a url'), isFalse);
      expect(GeminiModels.listUri('https://generativelanguage.googleapis.com/v1beta/openai')!.toString(), 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000');
      expect(GeminiModels.listUri('https://generativelanguage.googleapis.com/v1beta/openai/', pageToken: 'abc')!.toString(), 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&pageToken=abc');
      expect(GeminiModels.listUri('https://generativelanguage.googleapis.com/v1/openai')!.path, '/v1/models');
      expect(GeminiModels.listUri('https://generativelanguage.googleapis.com')!.path, '/v1beta/models', reason: 'no version: the default one');
      expect(GeminiModels.listUri('https://api.openai.com/v1'), isNull);
    });

    test('the list is read from the native endpoint with the key in x-goog-api-key, page by page, and the methods say which models chat', () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        final first = request.url.queryParameters['pageToken'] == null;
        return http.Response(
          jsonEncode({
            'models': first
                ? [
                    {'name': 'models/gemini-2.5-pro', 'supportedGenerationMethods': ['generateContent', 'countTokens'], 'inputTokenLimit': 1048576, 'outputTokenLimit': 65536},
                    {'name': 'models/text-embedding-004', 'supportedGenerationMethods': ['embedContent']},
                  ]
                : [
                    {'name': 'models/gemini-2.5-flash', 'supportedGenerationMethods': ['generateContent', 'streamGenerateContent']},
                  ],
            if (first) 'nextPageToken': 'page2',
          }),
          200,
        );
      });
      final provider = OpenAiCompatibleProvider(
        id: 'g',
        label: 'Gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        model: 'gemini-2.5-pro',
        apiKey: 'AIza-key',
        client: client,
      );
      final models = await provider.fetchKeyModels();
      expect(seen, hasLength(2));
      expect(seen.first.url.toString(), 'https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000');
      expect(seen.last.url.queryParameters['pageToken'], 'page2');
      for (final request in seen) {
        expect(request.headers['x-goog-api-key'], 'AIza-key');
        expect(request.headers.containsKey('Authorization'), isFalse, reason: 'the key is in Gemini\'s own header here');
      }
      expect(models.map((m) => m.id).toList(), ['gemini-2.5-flash', 'gemini-2.5-pro', 'text-embedding-004']);
      expect({for (final m in models) m.id: m.chat}, {'gemini-2.5-flash': true, 'gemini-2.5-pro': true, 'text-embedding-004': false});
      expect(models.firstWhere((m) => m.id == 'gemini-2.5-pro').contextTokens, 1048576);
    });

    test('the list that gives a model its limits is Gemini\'s own too: the OpenAI-style one has only ids', () async {
      late http.Request seen;
      final provider = OpenAiCompatibleProvider(
        id: 'g',
        label: 'Gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        model: 'gemini-2.5-flash',
        apiKey: 'AIza-key',
        client: MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'models': [
                {'name': 'models/gemini-2.5-flash', 'inputTokenLimit': 1048576, 'outputTokenLimit': 65536, 'supportedGenerationMethods': ['generateContent']},
              ],
            }),
            200,
          );
        }),
      );
      final infos = await provider.fetchModelInfos();
      expect(seen.url.path, '/v1beta/models');
      final flash = infos.single;
      expect((flash.id, flash.contextTokens, flash.maxOutputTokens), ('gemini-2.5-flash', 1048576, 65536));
    });

    test('any other endpoint reads the OpenAI-style list, with the bearer key', () async {
      late http.Request seen;
      final provider = OpenAiCompatibleProvider(
        id: 'o',
        label: 'Other',
        baseUrl: 'https://api.example/v1',
        model: 'm',
        apiKey: 'sk-1',
        client: MockClient((request) async {
          seen = request;
          return http.Response('{"data":[{"id":"a"},{"id":"b"}]}', 200);
        }),
      );
      expect((await provider.fetchKeyModels()).map((m) => m.id).toList(), ['a', 'b']);
      expect(seen.url.toString(), 'https://api.example/v1/models');
      expect(seen.headers['Authorization'], 'Bearer sk-1');
    });

    test('a refused key is an error with its status (the caller says "the key", not "the model")', () async {
      final provider = OpenAiCompatibleProvider(
        id: 'g',
        label: 'Gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        model: 'm',
        apiKey: 'bad',
        client: MockClient((_) async => http.Response('{"error":{"message":"API key not valid"}}', 400)),
      );
      await expectLater(provider.fetchKeyModels(), throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 400)));
      final denied = OpenAiCompatibleProvider(
        id: 'g',
        label: 'Gemini',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
        model: 'm',
        client: MockClient((_) async => http.Response('{"error":{"message":"denied"}}', 403)),
      );
      await expectLater(denied.fetchKeyModels(), throwsA(isA<AiProviderException>().having((e) => e.statusCode, 'status', 403)));
    });
  });

  group('the parser', () {
    test('reads the supported methods of Gemini, in either spelling, and leaves chat unknown without them', () {
      expect(ModelInfoParser.parseOne({'name': 'models/a', 'supportedGenerationMethods': ['generateContent']})!.chat, isTrue);
      expect(ModelInfoParser.parseOne({'name': 'models/a', 'supported_generation_methods': ['streamGenerateContent']})!.chat, isTrue);
      expect(ModelInfoParser.parseOne({'name': 'models/a', 'supportedGenerationMethods': ['embedContent', 'predict']})!.chat, isFalse);
      expect(ModelInfoParser.parseOne({'id': 'a'})!.chat, isNull);
      expect(ModelInfoParser.parseOne({'id': 'a', 'supportedGenerationMethods': <String>[]})!.chat, isNull);
    });

    test('the flag survives the save of a provider\'s catalog, and an old save without it still loads', () {
      const info = ModelInfo('a', chat: false);
      expect(ModelInfo.fromJson(info.toJson())!.chat, isFalse);
      expect(ModelInfo.fromJson({'id': 'a'})!.chat, isNull);
      expect(const ModelInfo('a').toJson().containsKey('chat'), isFalse);
    });
  });
}
