import 'dart:convert';

/// Models the app knows how to treat specially, from what their makers publish.
enum ModelFamily { deepseek, glm, other }

/// What the maker recommends for a model, used only where the user has set nothing.
class ModelHint {
  const ModelHint({
    required this.family,
    required this.label,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.contextTokens,
  });

  final ModelFamily family;

  /// Shown next to the model's settings, so the user can see why a value applies.
  final String label;
  final double? temperature;
  final double? topP;

  /// The reply length the maker recommends (a reasoning model spends part of it on thinking).
  final int? maxTokens;
  final int? contextTokens;
}

/// The maker's recommended settings, read from the model cards (Hugging Face):
///
/// * DeepSeek-V4.1-Flash(-1017): `temperature` 1.0, `top_p` 1.0, `context_window` 1M tokens,
///   `max_tokens` ≥ 256K.
/// * GLM-5.3: its evaluations use `temperature` 1.0 with `top_p` 0.95 (or 1.0), up to 128K
///   (`128000`) new tokens, under a 1M context (`max_position_embeddings` 1048576).
///
/// Only these families, and only the versions the cards describe, have a hint. A model without one
/// is left to the app's own values.
abstract final class ModelHints {
  static ModelFamily familyOf(String modelId) {
    final id = modelId.toLowerCase();
    if (id.contains('deepseek')) return ModelFamily.deepseek;
    if (RegExp(r'(^|[^a-z])glm[-_ ]?\d').hasMatch(id)) return ModelFamily.glm;
    return ModelFamily.other;
  }

  static ModelHint? of(String modelId) {
    final id = modelId.toLowerCase();
    switch (familyOf(id)) {
      case ModelFamily.deepseek:
        // V4 and V4.1 (`deepseek-v4-flash`, `DeepSeek-V4.1-Flash-1017`); older ones differ
        if (!RegExp(r'v4').hasMatch(id)) return null;
        return const ModelHint(
          family: ModelFamily.deepseek,
          label: 'DeepSeek V4 の推奨（公式モデルカード）: temperature 1.0 / top_p 1.0 / 最大 256K / コンテキスト 1M',
          temperature: 1.0,
          topP: 1.0,
          maxTokens: 262144,
          contextTokens: 1048576,
        );
      case ModelFamily.glm:
        // GLM-5 and later; the card describes 5.x
        final major = int.tryParse(RegExp(r'glm[-_ ]?(\d+)').firstMatch(id)?.group(1) ?? '');
        if (major == null || major < 5) return null;
        return const ModelHint(
          family: ModelFamily.glm,
          label: 'GLM-5 の推奨（公式モデルカード）: temperature 1.0 / top_p 0.95 / 最大 128K / コンテキスト 1M',
          temperature: 1.0,
          topP: 0.95,
          maxTokens: 128000,
          contextTokens: 1048576,
        );
      case ModelFamily.other:
        return null;
    }
  }

  /// A rough count of the tokens in [text]: a third of its UTF-8 bytes. Japanese takes about a
  /// token per character (3 bytes), English about a third of one (1 byte), so this is close for
  /// both and errs on the side of a longer prompt.
  static int estimateTokens(String text) => (utf8.encode(text).length / 3).ceil();

  /// The `max_tokens` to send.
  ///
  /// The model's own setting wins. Next, a length the user set in the settings ([requested]);
  /// otherwise the maker's recommendation, then (with [useModelMax]) the model's own largest reply
  /// ([maxOutput], read from the provider's list), then [requested] (the app's one default for all). The result never
  /// exceeds the model's largest reply ([maxOutput]) or what is left of its [context] after the
  /// prompt ([promptTokens]): a provider refuses a request that does not fit.
  static int resolveMaxTokens({
    required int? modelSetting,
    required bool requestedIsUserSet,
    required int requested,
    required ModelHint? hint,
    required int? maxOutput,
    required int? context,
    required int promptTokens,
    bool useModelMax = false,
  }) {
    final own = useModelMax && maxOutput != null && maxOutput > 0 ? maxOutput : null;
    var tokens = modelSetting ?? (requestedIsUserSet ? requested : (hint?.maxTokens ?? own ?? requested));
    if (maxOutput != null && maxOutput > 0 && tokens > maxOutput) tokens = maxOutput;
    final window = context ?? hint?.contextTokens;
    if (window != null && window > 0) {
      // a prompt that fills the window leaves little room, but never less than a short answer;
      // and a small number the user chose is kept as it is
      final room = window - promptTokens - _margin;
      final allowed = room < _floor ? _floor : room;
      if (tokens > allowed) tokens = allowed;
    }
    return tokens;
  }

  /// Left for the provider's own overhead (the chat template, the tool definitions).
  static const _margin = 512;
  static const _floor = 256;
}
