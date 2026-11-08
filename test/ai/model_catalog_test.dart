import 'package:arce_ai/ai/model_catalog.dart';
import 'package:arce_ai/ai/model_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('作成元の判定', () {
    test('スラッシュの前を作成元として読む。呼び名の違いは寄せる', () {
      expect(ModelCatalog.vendorKey('anthropic/claude-opus-4.5'), 'anthropic');
      expect(ModelCatalog.vendorKey('google/gemini-2.5-pro'), 'google');
      expect(ModelCatalog.vendorKey('meta-llama/Llama-3.3-70B'), 'meta');
      expect(ModelCatalog.vendorKey('x-ai/grok-4'), 'xai');
      expect(ModelCatalog.vendorKey('deepseek-ai/DeepSeek-V4.1-Flash'), 'deepseek');
      expect(ModelCatalog.vendorKey('openai/gpt-oss-120b:free'), 'openai');
      expect(ModelCatalog.vendorKey('someone/new-model'), 'someone');
    });

    test('スラッシュのない名前は、名前の付け方から読む', () {
      expect(ModelCatalog.vendorKey('claude-sonnet-5'), 'anthropic');
      expect(ModelCatalog.vendorKey('gemini-2.5-flash'), 'google');
      expect(ModelCatalog.vendorKey('models/gemini-2.5-pro'), 'google');
      expect(ModelCatalog.vendorKey('gpt-4o-mini'), 'openai');
      expect(ModelCatalog.vendorKey('o3-mini'), 'openai');
      expect(ModelCatalog.vendorKey('codex-auto-review'), 'openai');
      expect(ModelCatalog.vendorKey('mixtral-8x7b'), 'mistral');
      expect(ModelCatalog.vendorKey('qwen3-coder'), 'qwen');
      expect(ModelCatalog.vendorKey('glm-5.3'), 'zhipu');
      expect(ModelCatalog.vendorKey('my-own-model'), 'other');
    });

    test('名前が o で始まるだけのモデルを OpenAI にしない', () {
      expect(ModelCatalog.vendorKey('orca-mini'), 'other');
      expect(ModelCatalog.vendorKey('o1'), 'openai');
    });
  });

  group('検索', () {
    test('空白で区切った語がすべて入っていれば一致し、大文字小文字は区別しない', () {
      expect(ModelCatalog.matches('anthropic/claude-opus-4.5', 'claude opus'), isTrue);
      expect(ModelCatalog.matches('anthropic/claude-opus-4.5', 'OPUS 4.5'), isTrue);
      expect(ModelCatalog.matches('anthropic/claude-opus-4.5', 'sonnet'), isFalse);
      expect(ModelCatalog.matches('anything', ''), isTrue);
      expect(ModelCatalog.matches('anything', '   '), isTrue);
    });
  });

  group('グループ分け', () {
    final ids = [
      'zzz/model',
      'deepseek/deepseek-chat',
      'google/gemini-2.5-pro',
      'anthropic/claude-sonnet-5',
      'anthropic/claude-opus-5',
      'codex-auto-review',
      'free-text-model',
    ];

    test('よく探される作成元が先、そのほかは名前順、「その他」は最後。中の順は渡した順', () {
      final groups = ModelCatalog.group(ids);
      expect([for (final g in groups) g.key], ['anthropic', 'google', 'openai', 'deepseek', 'zzz', 'other']);
      expect(groups.first.ids, ['anthropic/claude-sonnet-5', 'anthropic/claude-opus-5']);
      expect(groups.first.label, startsWith('Claude'));
      expect(groups.last.label, 'その他');
      expect(groups[4].label, 'Zzz');
    });

    test('検索で絞ると、残りのないグループは出ない', () {
      final groups = ModelCatalog.group(ids, query: 'claude');
      expect([for (final g in groups) g.key], ['anthropic']);
      expect(groups.single.ids.length, 2);
      expect(ModelCatalog.group(ids, query: 'no such model'), isEmpty);
    });
  });

  group('ModelInfo の保存', () {
    test('上限と能力を往復する。空の項目は書かない', () {
      const info = ModelInfo('a/b', contextTokens: 200000, maxOutputTokens: 8192, vision: true, tools: false);
      final back = ModelInfo.fromJson(info.toJson())!;
      expect(back.id, 'a/b');
      expect(back.contextTokens, 200000);
      expect(back.maxOutputTokens, 8192);
      expect(back.vision, isTrue);
      expect(back.tools, isFalse);
      expect(back.reasoning, isNull);
      expect(const ModelInfo('x').toJson(), {'id': 'x'});
    });

    test('壊れた項目は捨てる', () {
      expect(ModelInfo.fromJson('text'), isNull);
      expect(ModelInfo.fromJson({'ctx': 10}), isNull);
      expect(ModelInfo.fromJson({'id': '  '}), isNull);
      expect(ModelInfo.fromJson({'id': 'x', 'ctx': -5})!.contextTokens, isNull);
    });
  });
}
