import 'dart:convert';

import 'model_info.dart';
import 'thinking_config.dart';

/// How the tools and their results travel to a model.
enum ToolStyle {
  /// Function calling when the provider offers it, the text form otherwise.
  auto,

  /// Function calling: the tools go as `tools`, a call is an assistant `tool_calls`, its result a
  /// `tool` message. The tool instructions are not repeated in the system prompt.
  native,

  /// The Qwen text form on every provider: the tools are described in the system prompt, a call is
  /// `<tool_call>` in the reply and its result a `<tool_response>` in the next user message.
  text,
}

/// One model of a provider, with the sampling settings and the extra prompt it needs.
///
/// A provider usually offers many models, and each one may want a different temperature or a
/// different system prompt. Keeping them together means switching model is one tap, and the
/// per-model settings travel with the model instead of being typed again.
class ModelConfig {
  const ModelConfig({
    required this.id,
    required this.name,
    this.params = const {},
    this.prompt = '',
    this.vision,
    this.contextTokens,
    this.maxOutputTokens,
    this.thinking = ThinkingConfig.none,
    this.toolStyle = ToolStyle.auto,
  });

  /// The name the API expects (`gpt-4o-mini`, `openai/gpt-oss-120b`, ...).
  final String id;

  /// What the settings screen shows; the id itself when the user did not name it.
  final String name;

  /// Overrides for the request body: `temperature`, `topP`, `maxTokens` and any other number the
  /// provider understands. Empty means the app's own value is used.
  final Map<String, double> params;

  /// Added as a system message in front of every request for this model.
  final String prompt;

  /// Whether the model takes images; null while the user has not said, then [guessVision] decides.
  final bool? vision;

  /// The model's context window (prompt and reply together) and its longest reply, when known:
  /// from the provider's model list or from the model's own config, or typed by the user.
  /// Null means not known; the maker's recommendation (`ModelHints`) fills in where it has one.
  final int? contextTokens;
  final int? maxOutputTokens;

  /// How thinking is asked for in the request (see [ThinkingConfig]); nothing is sent by default.
  final ThinkingConfig thinking;

  /// How tools reach the model (see [ToolStyle]).
  final ToolStyle toolStyle;

  /// What the chat acts on: the user's answer, or a guess from the model's name.
  bool get supportsImages => vision ?? guessVision(id);

  /// A guess from well-known model families, only for a model the user has not set. A wrong guess
  /// costs one error from the provider and is fixed with the switch in the model's settings.
  static bool guessVision(String id) => _visionNames.hasMatch(id.toLowerCase());

  static final _visionNames = RegExp(
    r'gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-5|claude|gemini|gemma-?3|llava|vision|pixtral|llama-?4|'
    r'minicpm-v|internvl|molmo|qwen.*omni|(^|[-_/:.])vl([-_/:.]|$)',
  );

  static int? _positive(Object? value) => value is num && value > 0 ? value.toInt() : null;

  double? param(String key) => params[key];

  int? intParam(String key) {
    final value = params[key];
    return value?.round();
  }

  ModelConfig copyWith({
    String? name,
    Map<String, double>? params,
    String? prompt,
    bool? vision,
    ThinkingConfig? thinking,
    ToolStyle? toolStyle,
  }) => ModelConfig(
    id: id,
    name: name ?? this.name,
    params: params ?? this.params,
    prompt: prompt ?? this.prompt,
    vision: vision ?? this.vision,
    contextTokens: contextTokens,
    maxOutputTokens: maxOutputTokens,
    thinking: thinking ?? this.thinking,
    toolStyle: toolStyle ?? this.toolStyle,
  );

  /// The same model with exactly these limits; null clears one (copyWith cannot).
  ModelConfig withLimits({int? contextTokens, int? maxOutputTokens}) => ModelConfig(
    id: id,
    name: name,
    params: params,
    prompt: prompt,
    vision: vision,
    contextTokens: contextTokens,
    maxOutputTokens: maxOutputTokens,
    thinking: thinking,
    toolStyle: toolStyle,
  );

  /// What [info] adds to this model. Values the model already has stay, unless [overwrite]
  /// (the user asked to fetch again); something the provider does not say is never erased.
  ModelConfig mergeInfo(ModelInfo info, {bool overwrite = false}) => ModelConfig(
    id: id,
    name: name,
    params: params,
    prompt: prompt,
    vision: overwrite ? (info.vision ?? vision) : (vision ?? info.vision),
    contextTokens: overwrite ? (info.contextTokens ?? contextTokens) : (contextTokens ?? info.contextTokens),
    maxOutputTokens: overwrite ? (info.maxOutputTokens ?? maxOutputTokens) : (maxOutputTokens ?? info.maxOutputTokens),
    thinking: thinking,
    toolStyle: toolStyle,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (params.isNotEmpty) 'params': params,
    if (prompt.trim().isNotEmpty) 'prompt': prompt,
    if (vision != null) 'vision': vision,
    if (contextTokens != null) 'contextTokens': contextTokens,
    if (maxOutputTokens != null) 'maxOutputTokens': maxOutputTokens,
    if (!thinking.isDefault) 'thinking': thinking.toJson(),
    if (toolStyle != ToolStyle.auto) 'toolStyle': toolStyle.name,
  };

  factory ModelConfig.fromJson(Map<String, Object?> json) {
    final id = json['id'] is String ? json['id']! as String : '';
    final rawParams = json['params'];
    return ModelConfig(
      id: id,
      name:
          json['name'] is String && (json['name']! as String).trim().isNotEmpty
          ? json['name']! as String
          : id,
      params: {
        if (rawParams is Map)
          for (final entry in rawParams.entries)
            if (entry.key is String && entry.value is num)
              entry.key as String: (entry.value! as num).toDouble(),
      },
      prompt: json['prompt'] is String ? json['prompt']! as String : '',
      vision: json['vision'] is bool ? json['vision']! as bool : null,
      contextTokens: _positive(json['contextTokens']),
      maxOutputTokens: _positive(json['maxOutputTokens']),
      thinking: ThinkingConfig.fromJson(json['thinking']),
      toolStyle: ToolStyle.values.asNameMap()[json['toolStyle']] ?? ToolStyle.auto,
    );
  }
}

/// A provider the user added: where to send the request and which models it offers.
///
/// The API key is deliberately not a field. Keys live in the platform's secure storage under
/// [keyRef], so a settings file, a backup or a QR export never carries one.
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.label,
    required this.baseUrl,
    this.models = const [],
    this.headers = const {},
    this.body = const {},
    this.supportsTools = true,
    this.catalog = const [],
    this.catalogAt,
    this.autoFetchModels = true,
    this.promptCache = false,
    this.promptCacheField = defaultPromptCacheField,
  });

  /// The request field OpenAI documents for routing the requests of one conversation to the same cache.
  static const defaultPromptCacheField = 'prompt_cache_key';

  /// Stable id, also stored in the database (`conversations.provider_id`).
  final String id;

  /// What the settings screen and the chat header show.
  final String label;

  /// Everything before `/chat/completions`, e.g. `https://api.openai.com/v1`.
  final String baseUrl;

  /// The models this provider offers. Never empty once the provider is usable.
  final List<ModelConfig> models;

  /// Extra request headers and body fields, for services that differ from the OpenAI schema.
  final Map<String, String> headers;
  final Map<String, Object?> body;

  /// Whether the endpoint offers function calling.
  final bool supportsTools;

  /// Everything the provider's model list offered the last time it was read. [models] holds only
  /// the models the user has chosen or set up; picking one from here copies it into [models], so
  /// a list of hundreds of models does not make the settings long.
  final List<ModelInfo> catalog;

  /// When [catalog] was read (milliseconds since the epoch); null when it never was.
  final int? catalogAt;

  /// Read the model list by itself (when the provider is saved and now and then); a provider that
  /// has no list, or charges for asking, turns it off.
  final bool autoFetchModels;

  /// Send a hint for the provider's own prompt cache with every request of a conversation: the field
  /// [promptCacheField] with a key that is the same for the whole conversation. **Only what the app
  /// sends**: a provider that caches by itself (OpenAI, DeepSeek, Gemini's implicit cache) goes on doing
  /// so with this off, and the app cannot stop it. Off by default: a server that does not know the
  /// field may refuse the request (the app then turns the switch off by itself).
  final bool promptCache;

  /// The name of the field the cache hint goes in (for a server that calls it something else).
  final String promptCacheField;

  /// The ids the user can pick: the chosen models first, then what the catalog adds.
  List<String> get knownIds {
    final seen = <String>{};
    return [
      for (final model in models)
        if (seen.add(model.id)) model.id,
      for (final info in catalog)
        if (seen.add(info.id)) info.id,
    ];
  }

  ModelInfo? catalogInfo(String id) {
    for (final info in catalog) {
      if (info.id == id) return info;
    }
    return null;
  }

  /// The model [id] to use: the one set up here, or else a plain one made from the catalog (with
  /// what the provider says about its limits), or null when neither knows it.
  ModelConfig? resolveModel(String id) {
    final saved = modelById(id);
    if (saved != null) return saved;
    final info = catalogInfo(id);
    return info == null ? null : ModelConfig(id: id, name: id).mergeInfo(info);
  }

  /// Where the key for this provider is kept in the secure storage.
  String get keyRef => 'provider_key.$id';

  /// The first model, used when nothing else is selected.
  ModelConfig? get defaultModel => models.isEmpty ? null : models.first;

  ModelConfig? modelById(String id) {
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  /// The id of the first model, or an empty string; kept for the database column.
  String get model => defaultModel?.id ?? '';

  /// True when everything a request needs is set.
  bool get isComplete =>
      id.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      models.isNotEmpty &&
      (Uri.tryParse(baseUrl.trim())?.hasScheme ?? false);

  ProviderConfig copyWith({
    String? label,
    String? baseUrl,
    List<ModelConfig>? models,
    Map<String, String>? headers,
    Map<String, Object?>? body,
    bool? supportsTools,
    List<ModelInfo>? catalog,
    int? catalogAt,
    bool? autoFetchModels,
    bool? promptCache,
    String? promptCacheField,
  }) => ProviderConfig(
    id: id,
    label: label ?? this.label,
    baseUrl: baseUrl ?? this.baseUrl,
    models: models ?? this.models,
    headers: headers ?? this.headers,
    body: body ?? this.body,
    supportsTools: supportsTools ?? this.supportsTools,
    catalog: catalog ?? this.catalog,
    catalogAt: catalogAt ?? this.catalogAt,
    autoFetchModels: autoFetchModels ?? this.autoFetchModels,
    promptCache: promptCache ?? this.promptCache,
    promptCacheField: promptCacheField ?? this.promptCacheField,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'baseUrl': baseUrl,
    'models': [for (final model in models) model.toJson()],
    if (headers.isNotEmpty) 'headers': headers,
    if (body.isNotEmpty) 'body': body,
    if (!supportsTools) 'tools': false,
    if (catalog.isNotEmpty) 'catalog': [for (final info in catalog) info.toJson()],
    if (catalogAt != null) 'catalogAt': catalogAt,
    if (!autoFetchModels) 'autoFetch': false,
    if (promptCache) 'promptCache': true,
    if (promptCacheField != defaultPromptCacheField) 'promptCacheField': promptCacheField,
  };

  /// A field name that can go into a JSON body as it is; null for anything else (empty, spaces, odd characters).
  static String? _fieldName(Object? value) {
    if (value is! String) return null;
    final name = value.trim();
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}$').hasMatch(name)) return null;
    // a field the request already has: the key must never replace the model, the messages or the tools
    return _reservedFields.contains(name.toLowerCase()) ? null : name;
  }

  static const _reservedFields = {
    'model', 'messages', 'stream', 'stream_options', 'max_tokens', 'max_completion_tokens', 'temperature', 'top_p',
    'tools', 'tool_choice', 'n', 'stop',
  };

  /// Whether [name] is usable as the cache field (the editor checks it before it saves).
  static bool isValidCacheField(String name) => _fieldName(name) != null;

  /// Anything missing or wrongly typed falls back to a usable default, so an older or a damaged
  /// save still loads. [ProviderList.decode] drops what cannot be used at all.
  factory ProviderConfig.fromJson(Map<String, Object?> json) {
    String text(String key) => json[key] is String ? json[key]! as String : '';
    final rawHeaders = json['headers'];
    final rawModels = json['models'];
    final models = <ModelConfig>[
      if (rawModels is List)
        for (final entry in rawModels)
          if (entry is Map) ModelConfig.fromJson(entry.cast<String, Object?>()),
    ];
    // a save from before models existed keeps its one model, so nothing is lost on upgrade
    final legacy = text('model');
    final effective = models.where((m) => m.id.trim().isNotEmpty).toList();
    if (effective.isEmpty && legacy.trim().isNotEmpty) {
      effective.add(ModelConfig(id: legacy, name: legacy));
    }
    return ProviderConfig(
      id: text('id'),
      label: text('label'),
      baseUrl: text('baseUrl'),
      models: effective,
      headers: {
        if (rawHeaders is Map)
          for (final entry in rawHeaders.entries)
            if (entry.key is String && entry.value is String)
              entry.key as String: entry.value as String,
      },
      body: json['body'] is Map
          ? (json['body']! as Map).cast<String, Object?>()
          : const {},
      supportsTools: json['tools'] is bool ? json['tools']! as bool : true,
      catalog: [
        if (json['catalog'] is List)
          for (final entry in json['catalog']! as List) ...[?ModelInfo.fromJson(entry)],
      ],
      catalogAt: json['catalogAt'] is int ? json['catalogAt']! as int : null,
      autoFetchModels: json['autoFetch'] is bool ? json['autoFetch']! as bool : true,
      promptCache: json['promptCache'] is bool ? json['promptCache']! as bool : false,
      promptCacheField: _fieldName(json['promptCacheField']) ?? defaultPromptCacheField,
    );
  }
}

/// The two free-form fields of a provider (extra headers and extra request fields), as the user
/// types them in the editor: one JSON object each.
abstract final class ProviderExtras {
  /// Header names that would carry a secret. Settings are kept in plain storage and travel in
  /// backups; a secret belongs in the API key field, which goes to the secure storage.
  static final _secretName = RegExp(r'authorization|api[-_ ]?key|token|secret|password|cookie', caseSensitive: false);

  /// `{"HTTP-Referer": "https://example.com"}` → the map; empty text → none. Throws a
  /// [FormatException] whose message can be shown as it is.
  static Map<String, String> parseHeaders(String text) {
    final object = _object(text, 'ヘッダー');
    final out = <String, String>{};
    for (final entry in object.entries) {
      if (entry.value is! String) throw FormatException('ヘッダー ${entry.key} の値は文字列にしてください');
      if (_secretName.hasMatch(entry.key)) {
        throw FormatException('ヘッダー ${entry.key} は機密情報になりえます。キーは「APIキー」の欄に入れてください（安全な領域に保存されます）');
      }
      out[entry.key] = entry.value! as String;
    }
    return out;
  }

  /// `{"reasoning_effort": "low"}` → the map; sent with every request and written over the app's
  /// own fields. Throws a [FormatException] whose message can be shown as it is.
  static Map<String, Object?> parseBody(String text) => _object(text, 'リクエスト項目');

  /// The map as the editor shows it; empty when there is nothing to show.
  static String show(Map<String, Object?> map) =>
      map.isEmpty ? '' : const JsonEncoder.withIndent('  ').convert(map);

  static Map<String, Object?> _object(String text, String what) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const {};
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw FormatException('$whatは JSON のオブジェクトで書いてください（例: {"名前": "値"}）');
    }
    if (decoded is! Map) throw FormatException('$whatは JSON のオブジェクトで書いてください（例: {"名前": "値"}）');
    return decoded.cast<String, Object?>();
  }
}

/// The provider list as one JSON document, the way the settings store keeps it.
abstract final class ProviderList {
  /// The on-device model: a provider like any other, and never an implicit fallback.
  static const localId = 'local';

  static List<ProviderConfig> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <ProviderConfig>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final config = ProviderConfig.fromJson(entry.cast<String, Object?>());
        // an id of its own, and a base URL: without either the entry cannot be used or saved
        if (config.id.trim().isEmpty ||
            config.id == localId ||
            config.baseUrl.trim().isEmpty) {
          continue;
        }
        out.add(config);
      }
      return out;
    } catch (_) {
      // a damaged list must not stop the app; the user can add the providers again
      return const [];
    }
  }

  static String encode(List<ProviderConfig> providers) =>
      jsonEncode([for (final p in providers) p.toJson()]);

  /// A new id from the label, so the id is readable in the database; a suffix keeps it unique.
  static String idFor(String label, Iterable<ProviderConfig> existing) {
    final stem = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = stem.isEmpty ? 'provider' : stem;
    final taken = {for (final p in existing) p.id}..add(localId);
    if (!taken.contains(base)) return base;
    for (var n = 2; ; n++) {
      final candidate = '$base-$n';
      if (!taken.contains(candidate)) return candidate;
    }
  }
}
