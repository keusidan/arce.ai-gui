/// A group of model ids that come from one maker, for the model list's tree.
class ModelGroup {
  const ModelGroup(this.key, this.label, this.ids);

  /// `anthropic`, `google`, … (`other` for what has no maker the app knows).
  final String key;

  /// What the list shows above the models.
  final String label;
  final List<String> ids;
}

/// Sorting a provider's model list by maker, and searching it.
///
/// A provider that fronts many services (OpenRouter and the like) lists hundreds of models with
/// ids such as `anthropic/claude-sonnet-5`; a provider of one maker lists bare ids such as
/// `gemini-2.5-pro`. The maker is read from the part before the slash, or else from the name.
abstract final class ModelCatalog {
  /// The order of the groups: the makers people look for first, then the rest by name, then `other`.
  static const _order = ['anthropic', 'google', 'openai', 'deepseek', 'xai', 'meta', 'mistral', 'qwen', 'zhipu', 'moonshot'];

  static const _labels = {
    'anthropic': 'Claude（Anthropic）',
    'google': 'Gemini・Gemma（Google）',
    'openai': 'OpenAI（GPT・o シリーズ）',
    'deepseek': 'DeepSeek',
    'xai': 'Grok（xAI）',
    'meta': 'Llama（Meta）',
    'mistral': 'Mistral',
    'qwen': 'Qwen（Alibaba）',
    'zhipu': 'GLM（Z.ai）',
    'moonshot': 'Kimi（Moonshot）',
    'other': 'その他',
  };

  /// Prefixes some providers write differently from the maker's own name.
  static const _aliases = {
    'claude': 'anthropic',
    'gemini': 'google',
    'gemma': 'google',
    'models': 'google',
    'gpt': 'openai',
    'chatgpt': 'openai',
    'meta-llama': 'meta',
    'llama': 'meta',
    'x-ai': 'xai',
    'grok': 'xai',
    'mistralai': 'mistral',
    'z-ai': 'zhipu',
    'zai-org': 'zhipu',
    'glm': 'zhipu',
    'moonshotai': 'moonshot',
    'kimi': 'moonshot',
    'alibaba': 'qwen',
    'deepseek-ai': 'deepseek',
  };

  static final _byName = <(RegExp, String)>[
    (RegExp(r'^claude'), 'anthropic'),
    (RegExp(r'^(gemini|gemma|learnlm|palm)'), 'google'),
    (RegExp(r'^(gpt|chatgpt|codex|o[1-9](-|$)|text-embedding|dall-e|whisper|davinci)'), 'openai'),
    (RegExp(r'^deepseek'), 'deepseek'),
    (RegExp(r'^grok'), 'xai'),
    (RegExp(r'^(llama|meta-llama)'), 'meta'),
    (RegExp(r'^(mistral|mixtral|codestral|ministral|pixtral|magistral|devstral)'), 'mistral'),
    (RegExp(r'^(qwen|qwq)'), 'qwen'),
    (RegExp(r'^glm'), 'zhipu'),
    (RegExp(r'^kimi'), 'moonshot'),
  ];

  /// The maker's key of [id].
  static String vendorKey(String id) {
    var name = id.trim().toLowerCase();
    if (name.startsWith('models/')) name = name.substring('models/'.length);
    final slash = name.indexOf('/');
    if (slash > 0) {
      final prefix = name.substring(0, slash).split(':').first;
      return _aliases[prefix] ?? prefix;
    }
    for (final (pattern, key) in _byName) {
      if (pattern.hasMatch(name)) return key;
    }
    return 'other';
  }

  /// What the list shows for a group key; an unknown maker is shown by its own name.
  static String vendorLabel(String key) {
    final known = _labels[key];
    if (known != null) return known;
    if (key.isEmpty) return _labels['other']!;
    return key[0].toUpperCase() + key.substring(1);
  }

  /// True when every word of [query] (separated by spaces) is somewhere in [id], in any case.
  /// An empty query matches everything.
  static bool matches(String id, String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final lower = id.toLowerCase();
    return words.every(lower.contains);
  }

  /// [ids] filtered by [query] and grouped by maker. Inside a group the ids stay in the order
  /// given; the groups follow [_order], then the other makers by name, then `other`.
  static List<ModelGroup> group(Iterable<String> ids, {String query = ''}) {
    final byKey = <String, List<String>>{};
    for (final id in ids) {
      if (!matches(id, query)) continue;
      byKey.putIfAbsent(vendorKey(id), () => []).add(id);
    }
    int rank(String key) {
      if (key == 'other') return 1000;
      final i = _order.indexOf(key);
      return i >= 0 ? i : 100;
    }

    final keys = byKey.keys.toList()
      ..sort((a, b) {
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.compareTo(b);
      });
    return [for (final key in keys) ModelGroup(key, vendorLabel(key), byKey[key]!)];
  }
}
