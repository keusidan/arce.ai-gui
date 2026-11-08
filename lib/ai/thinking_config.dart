/// Whether the model thinks before it answers, for a model whose provider lets the request say so.
enum ThinkingMode {
  /// Follow the app: the chat's 思考 switch, and the 速度⇔精度 slider (thinking is off at the fast end).
  auto,
  on,
  off,
}

/// How thinking is written into the request. Providers disagree, and what the makers publish (the
/// model cards) names the settings — a thinking mode, a reasoning effort, GLM's `clear_thinking` —
/// but not always the field of every host that serves the model. So the shape is a choice, and
/// nothing is sent until one is chosen.
enum ThinkingFormat {
  /// Nothing is added: the provider's own default applies (DeepSeek and GLM think by default),
  /// and the chat's thinking switch does not reach this model.
  none,

  /// DeepSeek's own API: `thinking: {type: enabled|disabled}` and `reasoning_effort`.
  deepseekApi,

  /// Z.ai's API for GLM: `thinking: {type, clear_thinking}` and `reasoning_effort`.
  zaiApi,

  /// Servers that render the model's chat template (vLLM, SGLang, Together, DeepInfra …):
  /// `chat_template_kwargs` with the template's own switches.
  chatTemplate,

  /// OpenAI's form: only `reasoning_effort` (low / medium / high).
  openaiEffort,

  /// OpenRouter's form (and routers that copy it): a `reasoning` object with the effort
  /// (`low` / `medium` / `high`), or `enabled: false`. Written from OpenRouter's published request
  /// shape, which could not be opened from the build environment: check it on a real request.
  openRouter,
}

/// Whether the thinking of the earlier replies goes back to the provider with the conversation.
///
/// Most models are trained to see only the answers of the past, and a longer prompt costs money.
/// DeepSeek's encoding guide (V4.1) keeps the reasoning of every earlier turn when tools are in use,
/// and GLM-5 has `clear_thinking: false` for the same ("preserved thinking"); a model that was
/// trained that way acts on a conversation without its own reasoning as if it had forgotten why.
enum ReasoningReplay {
  /// DeepSeek and GLM models, while the tools go as function calling; nothing for the others.
  auto,
  always,
  never,
}

/// The thinking settings of one model.
class ThinkingConfig {
  const ThinkingConfig({
    this.mode = ThinkingMode.auto,
    this.format = ThinkingFormat.none,
    this.effort = '',
    this.clearThinking,
    this.replay = ReasoningReplay.auto,
  });

  static const none = ThinkingConfig();

  final ThinkingMode mode;
  final ThinkingFormat format;

  /// `low` / `high` / `max`, or a number 1–100 (DeepSeek V4.1's budget); empty derives it from the
  /// 速度⇔精度 slider.
  final String effort;

  /// GLM: keep the earlier reasoning in the context (`false`) or drop it (`true`, for chat); null
  /// leaves the model's default (the chat template's is `false`; the card says to pass `true` for
  /// chat).
  final bool? clearThinking;

  /// Whether earlier thinking is sent back with the conversation (see [ReasoningReplay]).
  final ReasoningReplay replay;

  bool get isDefault =>
      mode == ThinkingMode.auto &&
      format == ThinkingFormat.none &&
      effort.isEmpty &&
      clearThinking == null &&
      replay == ReasoningReplay.auto;

  ThinkingConfig copyWith({
    ThinkingMode? mode,
    ThinkingFormat? format,
    String? effort,
    Object? clearThinking = _keep,
    ReasoningReplay? replay,
  }) => ThinkingConfig(
        mode: mode ?? this.mode,
        format: format ?? this.format,
        effort: effort ?? this.effort,
        clearThinking: identical(clearThinking, _keep) ? this.clearThinking : clearThinking as bool?,
        replay: replay ?? this.replay,
      );

  static const _keep = Object();

  Map<String, Object?> toJson() => {
        if (mode != ThinkingMode.auto) 'mode': mode.name,
        if (format != ThinkingFormat.none) 'format': format.name,
        if (effort.isNotEmpty) 'effort': effort,
        if (clearThinking != null) 'clearThinking': clearThinking,
        if (replay != ReasoningReplay.auto) 'replay': replay.name,
      };

  factory ThinkingConfig.fromJson(Object? json) {
    if (json is! Map) return none;
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final v in values) {
        if (v.name == name) return v;
      }
      return fallback;
    }

    return ThinkingConfig(
      mode: pick(ThinkingMode.values, json['mode'], ThinkingMode.auto),
      format: pick(ThinkingFormat.values, json['format'], ThinkingFormat.none),
      effort: json['effort'] is String ? (json['effort']! as String).trim() : '',
      clearThinking: json['clearThinking'] is bool ? json['clearThinking']! as bool : null,
      replay: pick(ReasoningReplay.values, json['replay'], ReasoningReplay.auto),
    );
  }
}

/// Turns a model's [ThinkingConfig] into the fields of the request.
abstract final class ThinkingRequest {
  /// The reasoning effort the 速度⇔精度 slider means: the fast half is `low`, the middle `high`, the
  /// accurate end `max` (the chat already turns thinking off below a quarter).
  static String levelFor(double speedAccuracy) => speedAccuracy >= 0.85
      ? 'max'
      : speedAccuracy >= 0.5
          ? 'high'
          : 'low';

  /// [appThinking] is whether the chat wants thinking now (its switch, and the slider not at the
  /// fast end). The fields are merged into the request body before the provider's own override.
  static Map<String, Object?> fields(ThinkingConfig config, {required bool appThinking, required double speedAccuracy}) {
    if (config.format == ThinkingFormat.none) return const {};
    final on = switch (config.mode) {
      ThinkingMode.on => true,
      ThinkingMode.off => false,
      ThinkingMode.auto => appThinking,
    };
    final Object effort = _effort(config.effort) ?? levelFor(speedAccuracy);
    switch (config.format) {
      case ThinkingFormat.none:
        return const {};
      case ThinkingFormat.deepseekApi:
        return {
          'thinking': {'type': on ? 'enabled' : 'disabled'},
          if (on) 'reasoning_effort': effort,
        };
      case ThinkingFormat.zaiApi:
        return {
          'thinking': {
            'type': on ? 'enabled' : 'disabled',
            if (config.clearThinking != null) 'clear_thinking': config.clearThinking,
          },
          if (on) 'reasoning_effort': effort,
        };
      case ThinkingFormat.chatTemplate:
        // each model's template reads the switch it knows (`thinking`, `enable_thinking`,
        // `thinking_mode`); one it does not know is ignored
        return {
          'chat_template_kwargs': {
            'thinking': on,
            'enable_thinking': on,
            'thinking_mode': on ? 'thinking' : 'chat',
            if (on) 'reasoning_effort': effort,
            if (config.clearThinking != null) 'clear_thinking': config.clearThinking,
          },
        };
      case ThinkingFormat.openaiEffort:
        // OpenAI knows low / medium / high only
        if (!on) return const {};
        return {'reasoning_effort': effort == 'max' ? 'high' : effort};
      case ThinkingFormat.openRouter:
        if (!on) {
          return const {
            'reasoning': {'enabled': false},
          };
        }
        return {
          'reasoning': {'effort': _threeLevels(effort)},
        };
    }
  }

  /// low / medium / high, for the forms that know only those: `max` is `high`, a number (1–100) is
  /// cut into thirds, any other word is passed as it is.
  static String _threeLevels(Object effort) {
    if (effort is int) return effort <= 33 ? 'low' : (effort <= 66 ? 'medium' : 'high');
    final word = '$effort';
    return word == 'max' ? 'high' : word;
  }

  /// A typed effort: a number stays a number (DeepSeek V4.1's 1–100 budget), a word stays a word.
  static Object? _effort(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n != null) return n.clamp(1, 100);
    return t;
  }

  /// The format that suits a provider's address, for the hosts whose request shape is known:
  /// the maker's own API, or a router. Null when the address says nothing (then the model's name
  /// decides, see [suggestedFormat]). Only a suggestion: the user presses the button.
  static ThinkingFormat? suggestedFormatForHost(String baseUrl) {
    final host = (Uri.tryParse(baseUrl.trim())?.host ?? '').toLowerCase();
    if (host.isEmpty) return null;
    if (host.contains('openrouter')) return ThinkingFormat.openRouter;
    if (host.endsWith('deepseek.com')) return ThinkingFormat.deepseekApi;
    if (host.endsWith('z.ai') || host.endsWith('bigmodel.cn')) return ThinkingFormat.zaiApi;
    if (host.endsWith('openai.com')) return ThinkingFormat.openaiEffort;
    if (host.contains('deepinfra') || host.contains('together') || host.contains('fireworks')) return ThinkingFormat.chatTemplate;
    return null;
  }

  /// The effort words a [format] documents, for the choices of the chat's thinking menu: DeepSeek
  /// and Z.ai name `low` / `high` / `max`; the others take `low` / `medium` / `high` (and `max`,
  /// which they cut to `high`).
  static List<String> levelsFor(ThinkingFormat format) => switch (format) {
        ThinkingFormat.deepseekApi || ThinkingFormat.zaiApi => const ['low', 'high', 'max'],
        ThinkingFormat.none => const [],
        _ => const ['low', 'medium', 'high'],
      };

  /// What the chat's thinking menu shows as picked for [config]: `off`, `auto`, an effort word or
  /// number, or `on` (always on, with the effort left to the 速度⇔精度 slider, which the menu does not offer).
  static String choiceOf(ThinkingConfig config) {
    if (config.mode == ThinkingMode.off) return 'off';
    if (config.effort.isNotEmpty) return config.effort;
    return config.mode == ThinkingMode.on ? 'on' : 'auto';
  }

  /// [config] with the menu's [choice] applied (see [choiceOf]): `off` and `auto` set the mode, an
  /// effort word turns thinking on at that effort.
  static ThinkingConfig withChoice(ThinkingConfig config, String choice) => switch (choice) {
        'off' => config.copyWith(mode: ThinkingMode.off),
        'auto' => config.copyWith(mode: ThinkingMode.auto, effort: ''),
        _ => config.copyWith(mode: ThinkingMode.on, effort: choice),
      };

  /// [config] changed to [format]: an effort that the new format does not name (`medium` for
  /// DeepSeek's API) is dropped, so the request never carries a word the provider does not know.
  static ThinkingConfig withFormat(ThinkingConfig config, ThinkingFormat format) {
    final keep = config.effort.isEmpty || int.tryParse(config.effort) != null || levelsFor(format).contains(config.effort);
    final cleared = !keep || format == ThinkingFormat.none;
    return config.copyWith(format: format, effort: cleared ? '' : config.effort, mode: cleared && config.mode == ThinkingMode.on ? ThinkingMode.auto : config.mode);
  }

  /// The formats worth suggesting for [modelId], by how models are named: a Hugging Face name
  /// (`zai-org/GLM-5.3`) is served by a vLLM-like host, a bare name by the maker's own API.
  /// Only a suggestion: the user presses the button, and the hosts' fields are theirs to check.
  static ThinkingFormat suggestedFormat(String modelId, {required bool deepseek, required bool glm}) {
    final hubName = modelId.contains('/');
    if (deepseek) return hubName ? ThinkingFormat.chatTemplate : ThinkingFormat.deepseekApi;
    if (glm) return hubName ? ThinkingFormat.chatTemplate : ThinkingFormat.zaiApi;
    return ThinkingFormat.none;
  }
}
