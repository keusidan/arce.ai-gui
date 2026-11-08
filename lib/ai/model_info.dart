/// What a provider says about one of its models. Everything but [id] is optional: providers
/// differ a lot in what their model list carries, and a missing value is simply not known.
class ModelInfo {
  const ModelInfo(this.id, {this.contextTokens, this.maxOutputTokens, this.vision, this.tools, this.reasoning, this.chat});

  final String id;

  /// The context window, prompt and reply together.
  final int? contextTokens;

  /// The longest reply the provider allows.
  final int? maxOutputTokens;
  final bool? vision;
  final bool? tools;
  final bool? reasoning;

  /// Whether the model does chat (text generation): Gemini's list says which methods each model supports
  /// (`generateContent`...); an embedding or an image model has none of them. Null: the list does not say.
  final bool? chat;

  bool get hasLimits => contextTokens != null || maxOutputTokens != null;

  /// Short keys: a provider can list hundreds of models and the list is kept in the settings.
  Map<String, Object?> toJson() => {
        'id': id,
        if (contextTokens != null) 'ctx': contextTokens,
        if (maxOutputTokens != null) 'out': maxOutputTokens,
        if (vision != null) 'vision': vision,
        if (tools != null) 'tools': tools,
        if (reasoning != null) 'reasoning': reasoning,
        if (chat != null) 'chat': chat,
      };

  /// Null for an entry without an id (a damaged save).
  static ModelInfo? fromJson(Object? json) {
    if (json is! Map || json['id'] is! String || (json['id'] as String).trim().isEmpty) return null;
    int? positive(Object? v) => v is num && v > 0 ? v.toInt() : null;
    bool? flag(Object? v) => v is bool ? v : null;
    return ModelInfo(
      json['id'] as String,
      contextTokens: positive(json['ctx']),
      maxOutputTokens: positive(json['out']),
      vision: flag(json['vision']),
      tools: flag(json['tools']),
      reasoning: flag(json['reasoning']),
      chat: flag(json['chat']),
    );
  }
}

/// Reads the model lists and model files that providers publish.
///
/// There is no standard for the limits: the OpenAI list has only ids, and each service adds its own
/// fields. The names below are the ones documented by the services themselves (OpenRouter,
/// Mistral, Groq, Together, vLLM, LM Studio, Gemini); a field that is not there is left unknown.
/// The ambiguous `max_tokens` is deliberately not read: some services mean the context by it,
/// some the reply.
abstract final class ModelInfoParser {
  /// An OpenAI-style `{"data": [...]}`, a `{"models": [...]}`, or a bare list.
  static List<ModelInfo> parseList(Object? decoded) {
    final Object? items = decoded is Map ? (decoded['data'] ?? decoded['models']) : decoded;
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map) ...[?parseOne(item.cast<String, Object?>())],
    ];
  }

  static ModelInfo? parseOne(Map<String, Object?> m) {
    final rawId = m['id'] ?? m['name'] ?? m['model'];
    if (rawId is! String || rawId.trim().isEmpty) return null;
    // Gemini lists "models/gemini-2.5-pro"; the API wants the part after it
    final id = rawId.startsWith('models/') ? rawId.substring('models/'.length) : rawId;

    final nested = <Map<String, Object?>>[
      m,
      for (final key in const ['top_provider', 'metadata', 'limits', 'context']) ...[?_map(m[key])],
    ];
    int? context;
    int? output;
    for (final source in nested) {
      context ??= _firstInt(source, const [
        'context_length',
        'context_window',
        'max_context_length',
        'max_model_len',
        'inputTokenLimit',
        'max_input_tokens',
        'context_size',
      ]);
      output ??= _firstInt(source, const ['max_completion_tokens', 'max_output_tokens', 'outputTokenLimit']);
    }

    final capabilities = _map(m['capabilities']);
    final parameters = _strings(m['supported_parameters']);
    // Gemini: `supportedGenerationMethods` (the Gemini API reference of models.list)
    final methods = _strings(m['supportedGenerationMethods'] ?? m['supported_generation_methods']);
    final inputs = _strings(_map(m['architecture'])?['input_modalities'] ?? m['input_modalities'] ?? m['modalities']);
    return ModelInfo(
      id,
      contextTokens: context,
      maxOutputTokens: output,
      vision: _flag(capabilities?['vision']) ?? _flag(m['supports_vision']) ?? (inputs.isEmpty ? null : inputs.contains('image')),
      tools: _flag(capabilities?['function_calling']) ??
          _flag(m['supports_tools']) ??
          (parameters.isEmpty ? null : parameters.contains('tools')),
      reasoning: _flag(capabilities?['reasoning']) ??
          (parameters.isEmpty ? null : parameters.contains('reasoning') || parameters.contains('include_reasoning')),
      chat: methods.isEmpty ? null : methods.any((method) => method == 'generatecontent' || method == 'streamgeneratecontent'),
    );
  }

  /// The context length in a Hugging Face `config.json`: `max_position_embeddings`, at the top or
  /// inside the text part of a multimodal model (DeepSeek-V4.1 keeps it in `text_config`).
  static int? contextFromHubConfig(Object? decoded) {
    if (decoded is! Map) return null;
    final config = decoded.cast<String, Object?>();
    for (final source in [config, ...[for (final key in const ['text_config', 'llm_config', 'language_config']) ?_map(config[key])]]) {
      final value = _firstInt(source, const ['max_position_embeddings', 'max_sequence_length', 'seq_length']);
      if (value != null) return value;
    }
    return null;
  }

  /// Whether [modelId] looks like a Hugging Face repository (`owner/name`), so its config can be
  /// asked for. Anything with other characters, or a path, is not sent anywhere.
  static bool isHubId(String modelId) => RegExp(r'^[A-Za-z0-9][\w.\-]*/[A-Za-z0-9][\w.\-]*$').hasMatch(modelId);

  static Map<String, Object?>? _map(Object? value) => value is Map ? value.cast<String, Object?>() : null;

  static List<String> _strings(Object? value) => [
        if (value is List)
          for (final v in value)
            if (v is String) v.toLowerCase(),
      ];

  static bool? _flag(Object? value) => value is bool ? value : null;

  static int? _firstInt(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is num && value > 0) return value.toInt();
    }
    return null;
  }
}
