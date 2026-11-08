import 'dart:async';

import 'provider.dart';
import 'thinking_config.dart';

/// Has a model write the title of a conversation, from its first question and answer.
abstract final class TitleMaker {
  /// What the model is told. It answers with the title only.
  static String instruction(int maxChars) =>
      'Write a short title for this conversation, in the language the user wrote in. '
      'At most $maxChars characters. Reply with the title only: no quotes, no "Title:", no full stop.';

  /// How much of the question and of the answer the model reads: the start says what it is about.
  static const _readChars = 600;

  /// The title [provider] gives to the conversation that began with [question] and [answer], or null
  /// when it gave nothing usable (an error, silence, an empty line). Never throws: a title is a
  /// nicety, and the conversation has a title of its own (the question) without it.
  static Future<String?> make(
    AiProvider provider, {
    required String question,
    required String answer,
    int maxChars = 30,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final model = provider.modelConfig;
    final request = AiRequest(
      messages: [
        AiMessage(AiRole.system, text: instruction(maxChars)),
        AiMessage(AiRole.user, text: 'User:\n${_cut(question)}\n\nAssistant:\n${_cut(answer)}'),
      ],
      model: provider.modelId,
      // a title is a few words; a reasoning model that cannot be told not to think still needs room
      maxTokens: 1024,
      temperature: 0.3,
      extraBody: ThinkingRequest.fields(model?.thinking ?? ThinkingConfig.none, appThinking: false, speedAccuracy: 0),
    );
    try {
      final text = StringBuffer();
      await for (final delta in provider.stream(request).timeout(timeout)) {
        if (delta is TextDelta) text.write(delta.text);
      }
      return clean(text.toString(), maxChars: maxChars);
    } on Object {
      return null;
    }
  }

  static String _cut(String text) {
    final t = text.trim();
    return t.length > _readChars ? t.substring(0, _readChars) : t;
  }

  /// The title in a model's answer: the first line, without the quotes, the "Title:" label and the
  /// Markdown marks it may have put around it, cut to [maxChars]; null when nothing is left.
  static String? clean(String answer, {int maxChars = 30}) {
    // a reasoning model's thinking, when it came in the text
    var text = answer.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    for (final line in text.split('\n')) {
      if (line.trim().isNotEmpty) {
        text = line.trim();
        break;
      }
    }
    text = text
        .replaceFirst(RegExp(r'^(title|タイトル)\s*[:：]\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'^#+\s*'), '')
        .replaceAll(RegExp(r'[*_`]'), '')
        .trim();
    // quotes (ASCII, curly, Japanese brackets) around the whole title
    const pairs = {'"': '"', "'": "'", '“': '”', '「': '」', '『': '』', '【': '】', '《': '》'};
    while (text.length >= 2 && pairs[text[0]] == text[text.length - 1]) {
      text = text.substring(1, text.length - 1).trim();
    }
    text = text.replaceAll(RegExp(r'[。．.!！]+$'), '').trim();
    if (text.isEmpty) return null;
    final chars = text.runes.toList();
    return chars.length > maxChars ? String.fromCharCodes(chars.take(maxChars)) : text;
  }
}
