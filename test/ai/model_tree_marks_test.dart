import 'package:arce_ai/ai/model_availability.dart';
import 'package:arce_ai/ai/model_info.dart';
import 'package:arce_ai/ai/model_tree.dart';
import 'package:arce_ai/ai/provider_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Gemini key of the free tier: some models answer, one has no quota, one is not there.
const gemini = ProviderConfig(
  id: 'gemini',
  label: 'Gemini',
  baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
  models: [ModelConfig(id: 'gemini-2.5-flash', name: 'flash')],
  catalog: [
    ModelInfo('gemini-2.5-flash'),
    ModelInfo('gemini-2.5-pro'),
    ModelInfo('gemini-2.0-flash'),
    ModelInfo('gemini-3-pro-preview'),
  ],
);

const openai = ProviderConfig(
  id: 'openai',
  label: 'OpenAI',
  baseUrl: 'https://api.openai.com/v1',
  models: [ModelConfig(id: 'gpt-4o', name: 'gpt'), ModelConfig(id: 'gpt-5-pro', name: 'gpt5')],
);

AvailabilityRecord blocked([String reason = '無料枠では 0']) => AvailabilityRecord(ModelAvailability.blocked, reason, 1);
const usable = AvailabilityRecord(ModelAvailability.usable, '', 1);

ModelMarks marks(Map<String, AvailabilityRecord> known, {bool hide = false}) =>
    ModelMarks(lookup: (provider, model) => known['$provider|$model'], hideBlocked: hide);

List<String> titles(TreeNode node) => [for (final l in node.leaves) l.title];

void main() {
  group('one provider\'s models', () {
    test('without marks nothing changes', () {
      final tree = ModelTrees.forProvider(gemini);
      final leaves = [for (final n in tree.nodes) ...n.leaves];
      expect(leaves.every((l) => l.mark == null && !l.isBlocked), isTrue);
    });

    test('a leaf carries what is known about it', () {
      final tree = ModelTrees.forProvider(gemini, marks: marks({'gemini|gemini-2.5-pro': blocked(), 'gemini|gemini-2.5-flash': usable}));
      final leaves = {for (final n in tree.nodes) for (final l in n.leaves) l.key: l};
      expect(leaves['gemini-2.5-pro']!.isBlocked, isTrue);
      expect(leaves['gemini-2.5-pro']!.mark!.reason, '無料枠では 0');
      expect(leaves['gemini-2.5-flash']!.mark!.isUsable, isTrue);
      expect(leaves['gemini-2.0-flash']!.mark, isNull, reason: 'not checked: nothing is said');
    });

    test('models that cannot be used come after the others in their folder, the order of the rest is kept', () {
      final plain = ModelTrees.forProvider(gemini);
      final before = titles(plain.nodes.first);
      expect(before, ['gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.0-flash', 'gemini-3-pro-preview']);
      final marked = ModelTrees.forProvider(gemini, marks: marks({'gemini|gemini-2.5-flash': blocked(), 'gemini|gemini-2.0-flash': blocked()}));
      expect(titles(marked.nodes.first), ['gemini-2.5-pro', 'gemini-3-pro-preview', 'gemini-2.5-flash', 'gemini-2.0-flash']);
    });

    test('hidden when the setting says so, but the model in use stays', () {
      final known = {'gemini|gemini-2.5-pro': blocked(), 'gemini|gemini-2.0-flash': blocked()};
      final hidden = ModelTrees.forProvider(gemini, marks: marks(known, hide: true));
      expect(titles(hidden.nodes.first), ['gemini-2.5-flash', 'gemini-3-pro-preview']);
      final keepsInUse = ModelTrees.forProvider(gemini, marks: marks(known, hide: true), keepKey: 'gemini-2.5-pro');
      expect(titles(keepsInUse.nodes.first), ['gemini-2.5-flash', 'gemini-3-pro-preview', 'gemini-2.5-pro'], reason: 'what answers must be seen, last and greyed');
      expect(keepsInUse.nodes.first.leaves.last.isBlocked, isTrue);
    });

    test('a folder whose models are all hidden is not shown', () {
      const only = ProviderConfig(id: 'p', label: 'P', baseUrl: 'https://p.example', models: [ModelConfig(id: 'google/gemini-x', name: 'x'), ModelConfig(id: 'openai/gpt-x', name: 'y')]);
      final tree = ModelTrees.forProvider(only, marks: marks({'p|google/gemini-x': blocked()}, hide: true));
      expect([for (final n in tree.nodes) n.key], ['maker:openai']);
      final all = ModelTrees.forProvider(only, marks: marks({'p|google/gemini-x': blocked(), 'p|openai/gpt-x': blocked()}, hide: true));
      expect(all.isEmpty, isTrue);
    });

    test('the "recent" folder is arranged the same way', () {
      final tree = ModelTrees.forProvider(
        gemini,
        recent: const ['gemini|gemini-2.5-pro', 'gemini|gemini-2.5-flash'],
        marks: marks({'gemini|gemini-2.5-pro': blocked()}),
      );
      expect(tree.nodes.first.key, 'recent');
      expect(titles(tree.nodes.first), ['gemini-2.5-flash', 'gemini-2.5-pro']);
    });
  });

  group('the models of every provider (the coding pickers, the fallback rules)', () {
    test('marks are looked up by provider and model, and keys stay provider|model', () {
      final tree = ModelTrees.forPicker([gemini, openai], marks: marks({'gemini|gemini-2.5-pro': blocked(), 'openai|gpt-5-pro': blocked('キーにありません')}));
      final leaves = {for (final n in tree.nodes) for (final l in _all(n)) l.key: l};
      expect(leaves['gemini|gemini-2.5-pro']!.isBlocked, isTrue);
      expect(leaves['openai|gpt-5-pro']!.mark!.reason, 'キーにありません');
      expect(leaves['openai|gpt-4o']!.mark, isNull);
      expect(leaves['gemini|gemini-2.5-flash']!.mark, isNull);
    });

    test('the same model id under two providers is not mixed up', () {
      const a = ProviderConfig(id: 'a', label: 'A', baseUrl: 'https://a.example', models: [ModelConfig(id: 'm', name: 'm')]);
      const b = ProviderConfig(id: 'b', label: 'B', baseUrl: 'https://b.example', models: [ModelConfig(id: 'm', name: 'm')]);
      final tree = ModelTrees.forPicker([a, b], marks: marks({'a|m': blocked()}));
      final leaves = {for (final n in tree.nodes) for (final l in _all(n)) l.key: l};
      expect(leaves['a|m']!.isBlocked, isTrue);
      expect(leaves['b|m']!.mark, isNull);
    });

    test('the unusable ones go last in a provider; hidden ones are gone, a provider with none left is not listed; the one chosen stays', () {
      final known = {'openai|gpt-4o': blocked(), 'openai|gpt-5-pro': blocked()};
      final last = ModelTrees.forPicker([openai], marks: marks({'openai|gpt-4o': blocked()}));
      expect(last.nodes.single.leaves.map((l) => l.key), ['openai|gpt-5-pro', 'openai|gpt-4o']);
      final hidden = ModelTrees.forPicker([gemini, openai], marks: marks(known, hide: true));
      expect([for (final n in hidden.nodes) n.key], ['p:gemini'], reason: 'every model of OpenAI is hidden: the provider is not listed');
      final chosen = ModelTrees.forPicker([gemini, openai], marks: marks(known, hide: true), keepKey: 'openai|gpt-4o');
      expect(chosen.nodes.last.leaves.map((l) => l.key), ['openai|gpt-4o']);
    });

    test('the choices the caller adds on top (not chosen, the device model) are never touched', () {
      final tree = ModelTrees.forPicker(
        [openai],
        rootLeaves: const [TreeLeaf('', '未選択'), TreeLeaf('local|', 'ローカルモデル')],
        marks: marks({'openai|gpt-4o': blocked()}, hide: true),
      );
      expect(tree.rootLeaves.map((l) => l.key), ['', 'local|']);
    });
  });
}

Iterable<TreeLeaf> _all(TreeNode node) => [...node.leaves, for (final child in node.children) ..._all(child)];
