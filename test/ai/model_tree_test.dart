import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/model_tree.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';

ProviderConfig orca() => ProviderConfig(
      id: 'orca',
      label: 'OrcaRouter',
      baseUrl: 'https://orca.example/v1',
      models: const [ModelConfig(id: 'anthropic/claude-opus-5', name: 'x', contextTokens: 200000)],
      catalog: const [
        ModelInfo('anthropic/claude-opus-5', contextTokens: 200000),
        ModelInfo('anthropic/claude-sonnet-5', contextTokens: 200000, maxOutputTokens: 64000, vision: true),
        ModelInfo('google/gemini-2.5-pro', contextTokens: 1048576),
        ModelInfo('deepseek/deepseek-chat'),
        ModelInfo('openai/gpt-oss-120b', reasoning: true),
        ModelInfo('codex-auto-review'),
        ModelInfo('mistralai/mistral-large'),
        ModelInfo('x-ai/grok-4'),
        ModelInfo('meta-llama/llama-4'),
        ModelInfo('qwen/qwen3-coder'),
      ],
    );

const small = ProviderConfig(
  id: 'groq',
  label: 'Groq',
  baseUrl: 'https://groq.example/v1',
  models: [ModelConfig(id: 'llama-3.3-70b', name: 'llama'), ModelConfig(id: 'qwen3-32b', name: 'qwen')],
);

void main() {
  test('上限の表示：10進の丸い数も、2のべき乗も、丸い数に見せる', () {
    expect(ModelTrees.sizeLabel(200000), '200K');
    expect(ModelTrees.sizeLabel(131072), '128K');
    expect(ModelTrees.sizeLabel(8192), '8K');
    expect(ModelTrees.sizeLabel(32768), '32K');
    expect(ModelTrees.sizeLabel(1000000), '1M');
    expect(ModelTrees.sizeLabel(1048576), '1M');
    expect(ModelTrees.sizeLabel(512), '512');
  });

  test('モデルの説明は、分かっていることだけを並べる', () {
    expect(ModelTrees.infoLine(context: 200000, output: 64000, vision: true, reasoning: true), '文脈 200K · 出力 64K · 画像 · 思考');
    expect(ModelTrees.infoLine(), '');
    expect(ModelTrees.infoLine(vision: false), '');
  });

  group('提供元のモデル', () {
    test('作成元ごとのフォルダに分かれ、モデルの名前から作成元の接頭辞を除く。設定済みの印が付く', () {
      final tree = ModelTrees.forProvider(orca());
      final labels = [for (final n in tree.nodes) n.key];
      expect(labels.first, 'maker:anthropic');
      expect(labels, ['maker:anthropic', 'maker:google', 'maker:openai', 'maker:deepseek', 'maker:xai', 'maker:meta', 'maker:mistral', 'maker:qwen']);
      final claude = tree.nodes.first;
      expect([for (final l in claude.leaves) l.title], ['claude-opus-5', 'claude-sonnet-5']);
      expect(claude.leaves.first.badge, '設定済み');
      expect(claude.leaves.last.badge, isNull);
      expect(claude.leaves.last.key, 'anthropic/claude-sonnet-5', reason: 'the key stays the whole id');
      expect(claude.leaves.last.subtitle, '文脈 200K · 出力 64K · 画像');
      expect(tree.nodes.fold<int>(0, (n, node) => n + node.count), 10);
    });

    test('検索で絞ると、一致したモデルのフォルダだけが残る', () {
      final tree = ModelTrees.forProvider(orca(), query: 'claude');
      expect(tree.nodes.length, 1);
      expect(tree.nodes.single.count, 2);
      expect(ModelTrees.forProvider(orca(), query: 'zzz').isEmpty, isTrue);
    });

    test('最近使ったモデルは先頭のフォルダに出る。この提供元のものだけ、一覧にあるものだけ', () {
      final tree = ModelTrees.forProvider(orca(), recent: const ['groq|llama', 'orca|google/gemini-2.5-pro', 'orca|gone']);
      expect(tree.nodes.first.key, 'recent');
      expect([for (final l in tree.nodes.first.leaves) l.key], ['google/gemini-2.5-pro']);
      expect(tree.nodes.first.leaves.single.title, 'google/gemini-2.5-pro', reason: 'in "recent" the maker is not in a folder name, so the whole id is shown');
    });
  });

  group('用途ごとのモデル選択（分担モード）', () {
    test('ローカルモデルなどは先頭に単独で、続いて最近使った順、そのあと提供元ごと', () {
      final tree = ModelTrees.forPicker(
        [orca(), small],
        recent: const ['groq|qwen3-32b', 'orca|google/gemini-2.5-pro'],
        rootLeaves: const [TreeLeaf('', '未選択'), TreeLeaf('local|', 'ローカルモデル')],
      );
      expect([for (final l in tree.rootLeaves) l.key], ['', 'local|']);
      expect([for (final n in tree.nodes) n.key], ['recent', 'p:orca', 'p:groq']);
      expect([for (final l in tree.nodes.first.leaves) l.key], ['groq|qwen3-32b', 'orca|google/gemini-2.5-pro']);
      expect(tree.nodes.first.leaves.first.title, 'Groq · qwen3-32b');
    });

    test('モデルの少ない提供元は平らに、多い提供元は作成元のフォルダに分ける', () {
      final tree = ModelTrees.forPicker([orca(), small]);
      final orcaNode = tree.nodes.firstWhere((n) => n.key == 'p:orca');
      final groqNode = tree.nodes.firstWhere((n) => n.key == 'p:groq');
      expect(orcaNode.children, isNotEmpty);
      expect(orcaNode.leaves, isEmpty);
      expect(groqNode.leaves.length, 2);
      expect(groqNode.children, isEmpty);
      expect(orcaNode.children.first.leaves.first.key, 'orca|anthropic/claude-opus-5');
    });

    test('検索は、提供元の名前にも一致する', () {
      final tree = ModelTrees.forPicker([orca(), small], query: 'orca claude');
      expect(tree.nodes.map((n) => n.key), ['p:orca']);
      expect(tree.nodes.single.count, 2);
      expect(ModelTrees.forPicker([orca(), small], query: 'groq').nodes.single.key, 'p:groq');
    });

    test('検索のとき、単独のモデルも名前で絞る', () {
      final tree = ModelTrees.forPicker(
        [small],
        query: 'ローカル',
        rootLeaves: const [TreeLeaf('', '未選択'), TreeLeaf('local|', 'ローカルモデル')],
      );
      expect([for (final l in tree.rootLeaves) l.key], ['local|']);
    });

    test('contains は、フォルダの下のモデルまで調べる', () {
      final tree = ModelTrees.forPicker([orca(), small]);
      final orcaNode = tree.nodes.firstWhere((n) => n.key == 'p:orca');
      expect(orcaNode.contains('orca|x-ai/grok-4'), isTrue);
      expect(orcaNode.contains('groq|qwen3-32b'), isFalse);
    });
  });
}
