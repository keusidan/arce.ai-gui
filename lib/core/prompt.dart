import 'dart:convert';

import 'protocol.dart';

sealed class ChatMessage {
  const ChatMessage();

  Map<String, Object?> toJson();

  factory ChatMessage.fromJson(Map<String, Object?> json) {
    switch (json['type']) {
      case 'user':
        return UserTurn(json['text'] as String);
      case 'assistant':
        return AssistantTurn(json['text'] as String, json['toolCallJson'] as String?, json['reasoning'] as String?);
      case 'tool':
        return ToolResponseTurn(json['text'] as String);
    }
    throw FormatException('unknown message type ${json['type']}');
  }
}

class UserTurn extends ChatMessage {
  const UserTurn(this.text);
  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'user', 'text': text};
}

/// Past assistant turns keep only the answer; Qwen3 drops old reasoning from the context.
class AssistantTurn extends ChatMessage {
  const AssistantTurn(this.text, [this.toolCallJson, this.reasoning]);
  final String text;
  final String? toolCallJson;

  /// What the model thought before it answered. It is never part of the prompt text (the device
  /// model does not see it); a provider that wants it back (DeepSeek and GLM, when tools are in
  /// use) receives it beside the prompt (`GenerateRequest.reasoning`).
  final String? reasoning;

  @override
  Map<String, Object?> toJson() => {
        'type': 'assistant',
        'text': text,
        'toolCallJson': toolCallJson,
        if (reasoning != null && reasoning!.isNotEmpty) 'reasoning': reasoning,
      };
}

/// The user's answer to a tool call such as ask_user.
class ToolResponseTurn extends ChatMessage {
  const ToolResponseTurn(this.text);
  final String text;

  @override
  Map<String, Object?> toJson() => {'type': 'tool', 'text': text};
}

/// Builds a Qwen3 ChatML prompt.
///
/// The fixed system prompt and the user's tone request are kept apart: the tone text is
/// sanitised and placed in its own delimited section, so it can change how answers sound but
/// cannot close the system block or forge tool-call tags.
abstract final class ChatMlPromptBuilder {
  static const toneMaxChars = 200;

  static const _imStart = '<|im_start|>';
  static const _imEnd = '<|im_end|>';

  static const baseSystemPrompt = '''
You are ARCE.AI, a local assistant for coding and general questions.
Rules:
- Write replies in Markdown: lists, **bold**, tables for comparisons, and headings only in longer answers.
- Put every program or file in a fenced code block with its language, e.g. ```html.
- Only write code when the user clearly asks for it ("make", "implement", "write code", 作って, 実装して). Otherwise answer in prose.
- If you need a decision from the user before continuing, call the ask_user tool instead of guessing.
- Never wait with a fixed-duration sleep (e.g. sleep 5, sleep 30, or blind timers). Always wait for the actual response, process exit, or readiness condition to complete, while keeping an explicit timeout.
- Local commands in run_command that stay within the sandbox (/workspace and the container rootfs) run automatically without user approval; decide and run them directly (auto_execute: true), and only ask for approval (auto_execute: false) when an operation reaches outside the sandbox.
- Do not repeat the wording of your previous reply; rephrase unless exact repetition is required.''';

  /// [assistantPrefill] is the answer so far when continuing a reply that stopped early
  /// (the "続行" action): the model picks up exactly where the text ends.
  /// [thinkingPrefill] resumes an unfinished `<think>` block when the reply stopped during reasoning.
  static String build(
    List<ChatMessage> history,
    List<ToolDefinition> tools,
    String? tone,
    bool thinking, {
    String assistantPrefill = '',
    String thinkingPrefill = '',
    // Agent role, reply-length limit and similar app-side rules; never user-editable.
    List<String> extraInstructions = const [],
  }) {
    final b = StringBuffer()
      ..write(_imStart)
      ..write('system\n')
      ..write(baseSystemPrompt);
    for (final line in extraInstructions.where((s) => s.trim().isNotEmpty)) {
      b
        ..write('\n- ')
        ..write(line);
    }
    final cleanTone = sanitizeTone(tone);
    if (cleanTone != null) {
      b
        ..write('\n\n# Tone\nThe user asked for this speaking style. '
            'It only affects wording, never the rules above.\n<tone>')
        ..write(cleanTone)
        ..write('</tone>');
    }
    if (tools.isNotEmpty) _appendTools(b, tools);
    b
      ..write(_imEnd)
      ..write('\n');

    for (final message in history) {
      switch (message) {
        case UserTurn():
          _turn(b, 'user', message.text);
        case AssistantTurn():
          final call = message.toolCallJson;
          _turn(b, 'assistant', message.text + (call == null ? '' : '\n<tool_call>\n$call\n</tool_call>'));
        case ToolResponseTurn():
          _turn(b, 'user', '<tool_response>\n${message.text}\n</tool_response>');
      }
    }

    b
      ..write(_imStart)
      ..write('assistant\n');
    // Qwen3's own template disables reasoning by pre-filling an empty think block.
    // A continuation with partial answer also skips reasoning; an unfinished thinking block resumes inside <think>.
    if (thinkingPrefill.isNotEmpty) {
      if (assistantPrefill.isNotEmpty) {
        b
          ..write('<think>\n')
          ..write(thinkingPrefill)
          ..write('\n</think>\n\n')
          ..write(assistantPrefill);
      } else {
        b
          ..write('<think>\n')
          ..write(thinkingPrefill);
      }
    } else {
      if (!thinking || assistantPrefill.isNotEmpty) b.write('<think>\n\n</think>\n\n');
      b.write(assistantPrefill);
    }
    return b.toString();
  }

  /// Strips anything that could act as a control sequence and caps the length.
  static String? sanitizeTone(String? tone) {
    if (tone == null || tone.trim().isEmpty) return null;
    var t = tone
        .replaceAll(RegExp(r'<\|[^|]*\|>'), '')
        .replaceAll(RegExp(r'</?(tone|think|tool_call|tool_response|tools)>', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (t.length > toneMaxChars) t = t.substring(0, toneMaxChars);
    return t.isEmpty ? null : t;
  }

  static void _turn(StringBuffer b, String role, String text) {
    b
      ..write(_imStart)
      ..write(role)
      ..write('\n')
      ..write(text)
      ..write(_imEnd)
      ..write('\n');
  }

  /// Where the tool instructions begin in the system block. They are its last part, so a bridge
  /// that sends the tools another way cuts from here.
  static const toolsMarker = '\n\n# Tools\n\n';

  /// A list of allowed values longer than this is not written into the prompt (it stays in the grammar
  /// that constrains the call, and in the checks of the call): `update_settings` lists every setting name
  /// there, which was most of the 3,400 tokens of tool definitions a device model had to read before it
  /// could answer, minutes on a phone.
  static const longEnumLimit = 24;

  /// Said after a description whose list of allowed values was left out of the prompt.
  static const longEnumNote = 'Some fields take one of many names that are not listed here; the call is '
      'only accepted with a valid name, and get_settings lists the names of the settings.';

  /// [schema] without its `enum` lists of more than [longEnumLimit] values, and whether any was removed.
  static ({Object? value, bool changed}) _withoutLongEnums(Object? schema) {
    var changed = false;
    Object? walk(Object? node) {
      if (node is Map) {
        final out = <String, Object?>{};
        node.forEach((key, value) {
          if (key == 'enum' && value is List && value.length > longEnumLimit) {
            changed = true;
          } else {
            out['$key'] = walk(value);
          }
        });
        return out;
      }
      if (node is List) return [for (final item in node) walk(item)];
      return node;
    }

    final value = walk(schema);
    return (value: value, changed: changed);
  }

  static void _appendTools(StringBuffer b, List<ToolDefinition> tools) {
    b
      ..write(toolsMarker)
      ..write('You may call one or more functions to assist with the user query.\n\n')
      ..write('You are provided with function signatures within <tools></tools> XML tags:\n<tools>');
    for (final tool in tools) {
      final shortened = _withoutLongEnums(tool.parameters);
      final signature = {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': shortened.changed ? '${tool.description} $longEnumNote' : tool.description,
          'parameters': shortened.value,
        },
      };
      b
        ..write('\n')
        ..write(jsonEncode(signature));
    }
    b
      ..write('\n</tools>\n\n')
      ..write('For each function call, return a json object with function name and arguments '
          'within <tool_call></tool_call> XML tags:\n')
      ..write('<tool_call>\n{"name": <function-name>, "arguments": <args-json-object>}\n</tool_call>');
  }
}
