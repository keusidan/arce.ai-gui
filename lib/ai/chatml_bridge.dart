import 'dart:convert';

import '../core/attachments.dart';
import '../core/engine.dart';
import '../core/prompt.dart';
import '../core/stream_segmenter.dart' hide ToolCallDelta;
import 'provider.dart';

/// Turns the ChatML prompt the chat builds into the messages a cloud provider expects, and turns
/// the provider's deltas back into the events the chat already understands.
///
/// One prompt is built for whichever engine answers, so the conversation must not change shape
/// between local and cloud: each block becomes a system / user / assistant message, and the
/// `<tool_call>` / `<tool_response>` conventions stay in the text exactly as the local model
/// receives them. Providers therefore see the same instructions the device would.
///
/// With `native`, the tool part of the conversation takes the shape function calling expects
/// instead: the instructions for the `<tool_call>` text are cut from the system prompt (the
/// definitions travel as `tools`), a call becomes an assistant message's `tool_calls`, and its
/// result a `tool` message. Models trained on that shape (DeepSeek, GLM and most others) follow
/// it better than the Qwen text form.
abstract final class ChatMlBridge {
  static const _start = '<|im_start|>';
  static const _end = '<|im_end|>';

  /// Sent after a reply that was already started ("続行"): a provider cannot be given a prefill,
  /// so the text written so far goes as the last assistant message and the model is asked to
  /// carry on from it.
  static const continuationNote =
      'Continue the answer above from exactly where it stops. '
      'Do not repeat what is already written and do not start over.';

  /// The messages of [prompt]. The reply block at the end is usually empty (it only means
  /// "answer now") and is dropped; a non-empty one is a continuation.
  ///
  /// A picture the user attached is marked in the text (see [ImageMarker]). When [vision] is true
  /// and the bytes are in [images] it goes to the provider as a picture; otherwise the marker
  /// becomes the file's name, so the model still knows something was attached.
  ///
  /// [reasoning] is what the model thought before each earlier reply (one entry per assistant
  /// block, oldest first); it is attached to those messages only when [replayReasoning] is set.
  static List<AiMessage> messages(
    String prompt, {
    Map<String, ImageData> images = const {},
    bool vision = false,
    bool native = false,
    List<String> reasoning = const [],
    bool replayReasoning = false,
  }) {
    final out = <AiMessage>[];
    var cursor = 0;
    var assistantIndex = 0;
    // the id of a call whose result has not come yet; a result takes it
    String? pendingCall;
    var nextCall = 1;

    while (cursor < prompt.length) {
      final open = prompt.indexOf(_start, cursor);
      if (open < 0) break;
      final bodyStart = open + _start.length;
      final close = prompt.indexOf(_end, bodyStart);
      final body = close < 0 ? prompt.substring(bodyStart) : prompt.substring(bodyStart, close);
      cursor = close < 0 ? prompt.length : close + _end.length;

      final newline = body.indexOf('\n');
      if (newline < 0) continue;
      final role = body.substring(0, newline).trim().toLowerCase();
      final text = body.substring(newline + 1);

      // The reply that is about to be written has no closing tag yet.
      if (close < 0) {
        final partial = _cleanAnswer(text);
        if (role == 'assistant' && partial.isNotEmpty) {
          out
            ..add(AiMessage(AiRole.assistant, text: partial))
            ..add(const AiMessage(AiRole.user, text: continuationNote));
        }
        break;
      }

      switch (role) {
        case 'system':
          out.add(AiMessage(AiRole.system, text: (native ? _withoutTools(text) : text).trim()));
        case 'user':
          final answer = native ? _toolResponse(text) : null;
          if (answer != null && pendingCall != null) {
            out.add(AiMessage(AiRole.tool, text: answer, toolCallId: pendingCall));
            pendingCall = null;
          } else {
            out.add(_user(text.trim(), images, vision));
          }
        case 'assistant':
          final thought = replayReasoning && assistantIndex < reasoning.length ? reasoning[assistantIndex] : '';
          assistantIndex++;
          final cleaned = _cleanAnswer(text);
          final call = native ? _toolCall(cleaned, 'call_$nextCall') : null;
          if (call == null) {
            out.add(AiMessage(AiRole.assistant, text: cleaned, reasoning: thought));
          } else {
            nextCall++;
            pendingCall = call.$2.id;
            out.add(AiMessage(AiRole.assistant, text: call.$1, toolCalls: [call.$2], reasoning: thought));
          }
      }
    }
    return native ? _closeOpenCalls(out) : out;
  }

  /// The system block without the tool instructions (they are the block's last part).
  static String _withoutTools(String system) {
    final at = system.indexOf(ChatMlPromptBuilder.toolsMarker);
    return at < 0 ? system : system.substring(0, at);
  }

  static final _toolCallTail = RegExp(r'\s*<tool_call>\s*([\s\S]*?)\s*</tool_call>\s*$');
  static final _toolResponseOnly = RegExp(r'^\s*<tool_response>\n?([\s\S]*?)\n?</tool_response>\s*$');

  /// The text before a trailing `<tool_call>` and the call it holds; null when the reply does not
  /// end with a readable call.
  static (String, ToolCallDelta)? _toolCall(String text, String id) {
    final match = _toolCallTail.firstMatch(text);
    if (match == null) return null;
    try {
      final decoded = jsonDecode(match.group(1)!);
      if (decoded is! Map || decoded['name'] is! String) return null;
      final arguments = decoded['arguments'];
      final extra = decoded['extra_content'];
      return (
        text.substring(0, match.start).trim(),
        ToolCallDelta(
          id: id,
          name: decoded['name'] as String,
          argumentsJson: jsonEncode(arguments is Map ? arguments : const {}),
          extraContent: extra is Map ? Map<String, Object?>.from(extra) : null,
        ),
      );
    } on FormatException {
      return null;
    }
  }

  /// The result inside a user block that is only a `<tool_response>`.
  static String? _toolResponse(String text) => _toolResponseOnly.firstMatch(text)?.group(1);

  /// A provider refuses an assistant `tool_calls` that no `tool` message follows (a conversation
  /// that was stopped before the call ran). Such a call goes back to being plain text.
  static List<AiMessage> _closeOpenCalls(List<AiMessage> messages) {
    return [
      for (var i = 0; i < messages.length; i++)
        if (messages[i].toolCalls.isNotEmpty && (i + 1 >= messages.length || messages[i + 1].role != AiRole.tool))
          AiMessage(
            AiRole.assistant,
            text: [
              messages[i].text,
              for (final call in messages[i].toolCalls)
                '${StreamSegmenter.toolOpen}{"name": ${jsonEncode(call.name)}, "arguments": ${call.argumentsJson}}${StreamSegmenter.toolClose}',
            ].where((s) => s.isNotEmpty).join('\n'),
            reasoning: messages[i].reasoning,
          )
        else
          messages[i],
    ];
  }

  static AiMessage _user(String text, Map<String, ImageData> images, bool vision) {
    final attached = <ImageData>[];
    final shown = text.replaceAllMapped(ImageMarker.pattern, (m) {
      final image = vision ? images[m.group(1)] : null;
      if (image != null) {
        attached.add(image);
        return '';
      }
      return '[画像: ${m.group(2)}]';
    });
    return AiMessage(AiRole.user, text: shown.trim(), images: attached);
  }

  /// Drops the empty thinking block the prompt starts a reply with, and the blank lines around it.
  static String _cleanAnswer(String text) {
    final trimmed = text.trim();
    final open = StreamSegmenter.thinkOpen.trim();
    final close = StreamSegmenter.thinkClose.trim();
    if (!trimmed.startsWith(open)) return trimmed;
    final end = trimmed.indexOf(close);
    if (end < 0 || trimmed.substring(0, end).trim() != open) return trimmed;
    return trimmed.substring(end + close.length).trim();
  }
}

/// Turns provider deltas into the events the chat pipeline already handles.
///
/// Thinking is wrapped in the tags [StreamSegmenter] looks for, and a native tool call is written
/// back as a `<tool_call>` body, so the segmenter and the tool-call parser read a cloud reply
/// exactly like a local one.
class CloudEventAdapter {
  bool _thinking = false;
  bool _finished = false;

  /// True once the provider said why it stopped.
  bool get isFinished => _finished;

  /// True between a reasoning delta and the reply text that follows it.
  bool get isThinking => _thinking;

  List<GenerationEvent> convert(Delta delta) {
    switch (delta) {
      case TextDelta(:final text):
        return [
          if (_thinking) ..._closeThinking(),
          if (text.isNotEmpty) Piece(text),
        ];
      case ReasoningDelta(:final text):
        return [
          if (!_thinking) ..._openThinking(),
          if (text.isNotEmpty) Piece(text),
        ];
      case ToolCallDelta(:final name, :final argumentsJson, :final extraContent):
        final arguments = argumentsJson.trim().isEmpty ? '{}' : argumentsJson;
        // extra_content rides along in the call's JSON (the parser reads name and arguments only), so it
        // is still there when the conversation goes back to the provider
        final extra = extraContent == null ? '' : ', "extra_content": ${jsonEncode(extraContent)}';
        return [
          ..._closeThinking(),
          Piece(
            '${StreamSegmenter.toolOpen}'
            '{"name": ${jsonEncode(name)}, "arguments": $arguments$extra}'
            '${StreamSegmenter.toolClose}',
          ),
        ];
      case UsageDelta(:final promptTokens, :final completionTokens, :final cachedTokens):
        // Token counts belong next to the message, not in the text.
        return [Usage(promptTokens: promptTokens, completionTokens: completionTokens, cachedTokens: cachedTokens)];
      case StopDelta(:final reason):
        _finished = true;
        return [..._closeThinking(), Finished(reason)];
    }
  }

  List<GenerationEvent> _openThinking() {
    _thinking = true;
    return const [Piece(StreamSegmenter.thinkOpen)];
  }

  List<GenerationEvent> _closeThinking() {
    if (!_thinking) return const [];
    _thinking = false;
    return const [Piece(StreamSegmenter.thinkClose)];
  }
}
