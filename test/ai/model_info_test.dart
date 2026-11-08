import 'dart:convert';

import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:arce_ai/services/model_info_fetcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('モデル一覧の読み取り', () {
    test('OpenAI の形（id だけ）は、上限が分からないまま読む', () {
      final infos = ModelInfoParser.parseList({
        'object': 'list',
        'data': [
          {'id': 'gpt-4o', 'object': 'model'},
        ],
      });
      expect(infos.single.id, 'gpt-4o');
      expect(infos.single.hasLimits, isFalse);
      expect(infos.single.vision, isNull, reason: 'not known is not the same as no');
    });

    test('OpenRouter：context_length、top_provider.max_completion_tokens、画像・ツール・推論', () {
      final info = ModelInfoParser.parseList({
        'data': [
          {
            'id': 'deepseek/deepseek-v4-flash',
            'context_length': 1048576,
            'architecture': {'input_modalities': ['text', 'image'], 'output_modalities': ['text']},
            'top_provider': {'context_length': 1048576, 'max_completion_tokens': 262144, 'is_moderated': false},
            'supported_parameters': ['tools', 'tool_choice', 'reasoning', 'temperature'],
          },
        ],
      }).single;
      expect(info.contextTokens, 1048576);
      expect(info.maxOutputTokens, 262144);
      expect(info.vision, isTrue);
      expect(info.tools, isTrue);
      expect(info.reasoning, isTrue);
    });

    test('OpenRouter：画像なしのモデルは vision=false（入力の種類が分かっているとき）', () {
      final info = ModelInfoParser.parseList({
        'data': [
          {'id': 'x/text-only', 'architecture': {'input_modalities': ['text']}, 'supported_parameters': ['temperature']},
        ],
      }).single;
      expect(info.vision, isFalse);
      expect(info.tools, isFalse);
    });

    test('Mistral：max_context_length と capabilities', () {
      final info = ModelInfoParser.parseList({
        'object': 'list',
        'data': [
          {'id': 'pixtral-large-latest', 'max_context_length': 131072, 'capabilities': {'completion_chat': true, 'function_calling': true, 'vision': true}},
        ],
      }).single;
      expect(info.contextTokens, 131072);
      expect(info.vision, isTrue);
      expect(info.tools, isTrue);
    });

    test('Groq 風：context_window と max_completion_tokens', () {
      final info = ModelInfoParser.parseList({
        'data': [
          {'id': 'llama-3.3-70b-versatile', 'context_window': 131072, 'max_completion_tokens': 32768},
        ],
      }).single;
      expect(info.contextTokens, 131072);
      expect(info.maxOutputTokens, 32768);
    });

    test('vLLM：max_model_len ／ Gemini：models/ の接頭辞と inputTokenLimit・outputTokenLimit', () {
      expect(ModelInfoParser.parseList({'data': [{'id': 'my-model', 'max_model_len': 32768}]}).single.contextTokens, 32768);
      final gemini = ModelInfoParser.parseList({
        'models': [
          {'name': 'models/gemini-2.5-pro', 'inputTokenLimit': 1048576, 'outputTokenLimit': 65536},
        ],
      }).single;
      expect(gemini.id, 'gemini-2.5-pro');
      expect(gemini.contextTokens, 1048576);
      expect(gemini.maxOutputTokens, 65536);
    });

    test('配列だけの応答（Together など）と、壊れた要素', () {
      final infos = ModelInfoParser.parseList([
        {'id': 'a', 'context_length': 8192},
        'not a map',
        {'object': 'model'},
        {'id': ''},
        {'id': 'b'},
      ]);
      expect([for (final i in infos) i.id], ['a', 'b']);
      expect(ModelInfoParser.parseList('nope'), isEmpty);
      expect(ModelInfoParser.parseList({'data': 3}), isEmpty);
    });

    test('曖昧な max_tokens は、文脈とも出力とも読まない（サービスによって意味が違うため）', () {
      final info = ModelInfoParser.parseList({'data': [{'id': 'a', 'max_tokens': 4096}]}).single;
      expect(info.contextTokens, isNull);
      expect(info.maxOutputTokens, isNull);
    });

    test('0 や負の値は「分からない」として扱う', () {
      final info = ModelInfoParser.parseList({'data': [{'id': 'a', 'context_length': 0, 'max_completion_tokens': -1}]}).single;
      expect(info.hasLimits, isFalse);
    });
  });

  group('Hugging Face の config.json', () {
    test('max_position_embeddings を、上の階層でも text_config の中でも読む', () {
      expect(ModelInfoParser.contextFromHubConfig({'max_position_embeddings': 1048576}), 1048576, reason: 'GLM-5.3 keeps it at the top');
      expect(
        ModelInfoParser.contextFromHubConfig({'model_type': 'deepseek_v41', 'text_config': {'max_position_embeddings': 1048576}}),
        1048576,
        reason: 'DeepSeek-V4.1 keeps it in text_config',
      );
      expect(ModelInfoParser.contextFromHubConfig({'hidden_size': 1}), isNull);
      expect(ModelInfoParser.contextFromHubConfig('x'), isNull);
    });

    test('Hub の名前（owner/name）だけを送る', () {
      expect(ModelInfoParser.isHubId('deepseek-ai/DeepSeek-V4.1-Flash-1017'), isTrue);
      expect(ModelInfoParser.isHubId('zai-org/GLM-5.3'), isTrue);
      for (final id in ['gpt-4o', 'a/b/c', '../etc/passwd', 'a/../b', 'https://x.example/m', 'a b/c', '/x/y']) {
        expect(ModelInfoParser.isHubId(id), isFalse, reason: id);
      }
    });
  });

  group('調べて、モデルに反映する', () {
    MockClient hub(Map<String, Object?> files, List<String> asked) => MockClient((request) async {
          asked.add(request.url.toString());
          final body = files[request.url.path];
          return body == null ? http.Response('', 404) : http.Response(jsonEncode(body), 200);
        });

    test('Hub から文脈長を読む。他のホストへは行かない', () async {
      final asked = <String>[];
      final fetcher = ModelInfoFetcher(client: hub({'/zai-org/GLM-5.3/raw/main/config.json': {'max_position_embeddings': 1048576}}, asked));
      expect(await fetcher.contextFromHub('zai-org/GLM-5.3'), 1048576);
      expect(await fetcher.contextFromHub('gpt-4o'), isNull);
      expect(asked, ['https://huggingface.co/zai-org/GLM-5.3/raw/main/config.json'], reason: 'a name that is not a Hub repository is not sent');
      expect(await ModelInfoFetcher(client: hub({}, [])).contextFromHub('nobody/nothing'), isNull);
    });

    test('提供元の一覧が優先、足りない文脈長だけ Hub で補う', () async {
      final fetcher = ModelInfoFetcher(client: hub({'/a/m/raw/main/config.json': {'max_position_embeddings': 4096}}, []));
      const model = ModelConfig(id: 'a/m', name: 'm');
      final listedBoth = await fetcher.enrich(model, listed: [const ModelInfo('a/m', contextTokens: 1000, maxOutputTokens: 500)], useHub: true);
      expect(listedBoth.contextTokens, 1000, reason: 'the provider says so; the Hub is not asked');
      expect(listedBoth.maxOutputTokens, 500);

      final onlyOutput = await fetcher.enrich(model, listed: [const ModelInfo('a/m', maxOutputTokens: 500)], useHub: true);
      expect(onlyOutput.contextTokens, 4096, reason: 'the provider did not say: the Hub fills it');

      final hubOff = await fetcher.enrich(model, listed: const [], useHub: false);
      expect(hubOff.contextTokens, isNull, reason: 'the setting forbids asking the Hub');
    });

    test('ユーザーが入れた値は、通常の取得では消えない。「取得」ボタン（上書き）では更新される', () async {
      final fetcher = ModelInfoFetcher(client: hub({}, []));
      const typed = ModelConfig(id: 'm', name: 'm', contextTokens: 7777);
      const info = ModelInfo('m', contextTokens: 1000, maxOutputTokens: 500, vision: true);
      final quiet = await fetcher.enrich(typed, listed: [info], useHub: false);
      expect(quiet.contextTokens, 7777);
      expect(quiet.maxOutputTokens, 500, reason: 'what was empty is filled');
      expect(quiet.vision, isTrue);
      final forced = await fetcher.enrich(typed, listed: [info], useHub: false, overwrite: true);
      expect(forced.contextTokens, 1000);
    });

    test('提供元が言わなかったことで、既にある値を消さない', () async {
      final fetcher = ModelInfoFetcher(client: hub({}, []));
      const known = ModelConfig(id: 'm', name: 'm', contextTokens: 5000, vision: false);
      final result = await fetcher.enrich(known, listed: [const ModelInfo('m')], useHub: false, overwrite: true);
      expect(result.contextTokens, 5000);
      expect(result.vision, isFalse);
    });
  });

  group('モデルの設定に保存する', () {
    test('上限は書き出して読み戻せ、無いときは書き出さない。0 や壊れた値は無いものとする', () {
      const m = ModelConfig(id: 'm', name: 'm', contextTokens: 1048576, maxOutputTokens: 262144);
      final back = ModelConfig.fromJson(m.toJson());
      expect(back.contextTokens, 1048576);
      expect(back.maxOutputTokens, 262144);
      expect(const ModelConfig(id: 'm', name: 'm').toJson().containsKey('contextTokens'), isFalse);
      final damaged = ModelConfig.fromJson({'id': 'm', 'contextTokens': 0, 'maxOutputTokens': 'lots'});
      expect(damaged.contextTokens, isNull);
      expect(damaged.maxOutputTokens, isNull);
    });

    test('copyWith は上限を保ち、withLimits は指定どおりにする（null で消せる）', () {
      const m = ModelConfig(id: 'm', name: 'm', contextTokens: 100, maxOutputTokens: 50);
      expect(m.copyWith(name: 'n').contextTokens, 100);
      final cleared = m.withLimits(maxOutputTokens: 60);
      expect(cleared.contextTokens, isNull);
      expect(cleared.maxOutputTokens, 60);
    });
  });
}
