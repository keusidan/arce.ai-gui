import 'dart:convert';

import 'prompt.dart';

/// What the user decided about keeping a long conversation inside the model's context window.
class CompactionSettings {
  const CompactionSettings({
    this.enabled = true,
    this.atPercent = 80,
    this.keepTurns = 4,
    this.summaryChars = 3000,
    this.toolResultChars = 1500,
  });

  final bool enabled;

  /// The request is compacted when it would take more than this share of the context (percent).
  final int atPercent;

  /// The last this-many messages of the user (and everything after them) are kept as they are.
  final int keepTurns;

  /// How long the summary may be, in characters; the model is asked to stay under it.
  final int summaryChars;

  /// A tool's answer older than the kept part is cut to this many characters before anything else.
  final int toolResultChars;
}

/// Makes room in a long conversation: first the old tool answers are cut short, then everything before
/// the last few messages of the user is replaced by a summary the model writes.
///
/// The pure part is here (where to cut, what to ask, how to put the summary back); asking the model is
/// [ChatController]'s. The summary goes into the *first message that is kept*, so the history still
/// alternates user / assistant and a provider never sees two user messages in a row because of it.
abstract final class Compaction {
  /// The notes the app writes into the history for the model (an unusable tool call, ...) start with this.
  static const feedbackPrefix = '[from the app]';

  static const summaryHeader =
      '[Summary of the earlier conversation. The app wrote it so the conversation fits the context window; '
      'treat it as what was said before.]';

  static const currentMessageHeader = '[The user\'s message that follows the summary]';

  /// A rough count of the tokens in [text]: a third of its UTF-8 bytes (the same rule as the token
  /// line under the input).
  static int estimateTokens(String text) => (utf8.encode(text).length / 3).ceil();

  /// A message the user wrote (not a note from the app).
  static bool isUserMessage(ChatMessage turn) => turn is UserTurn && !turn.text.startsWith(feedbackPrefix);

  /// Where the kept part of [history] starts: the [keepTurns]-th last message of the user. Null when
  /// there is nothing before it to summarize (the conversation has no more messages than are kept).
  static int? cutIndex(List<ChatMessage> history, int keepTurns) {
    final keep = keepTurns < 1 ? 1 : keepTurns;
    var seen = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      if (!isUserMessage(history[i])) continue;
      seen++;
      if (seen == keep) return i > 0 ? i : null;
    }
    return null;
  }

  /// [history] with the tool answers before [upTo] cut to [maxChars] each (the start is kept, and a
  /// line says how much was left out). The same list when nothing was long enough.
  static List<ChatMessage> clipToolResults(List<ChatMessage> history, int upTo, int maxChars) {
    if (maxChars < 1) return history;
    var changed = false;
    final out = <ChatMessage>[];
    for (var i = 0; i < history.length; i++) {
      final turn = history[i];
      if (i < upTo && turn is ToolResponseTurn && turn.text.length > maxChars + 80) {
        changed = true;
        final left = turn.text.length - maxChars;
        out.add(ToolResponseTurn('${turn.text.substring(0, maxChars)}\n[… $left characters left out to save room]'));
      } else {
        out.add(turn);
      }
    }
    return changed ? out : history;
  }

  /// The turns as plain text for the model that summarizes them. A turn longer than [turnChars] is cut
  /// (tool answers to [toolChars]); a tool call is one short line.
  static List<String> lines(List<ChatMessage> turns, {int turnChars = 6000, int toolChars = 1500}) {
    String cut(String text, int max) => text.length <= max ? text : '${text.substring(0, max)} […]';
    final out = <String>[];
    for (final turn in turns) {
      switch (turn) {
        case UserTurn(:final text):
          out.add('User: ${cut(text.trim(), turnChars)}');
        case AssistantTurn(:final text, :final toolCallJson):
          final said = text.trim();
          final call = toolCallJson == null ? '' : '[called a tool: ${cut(toolCallJson.replaceAll(RegExp(r'\s+'), ' '), 240)}]';
          final line = [if (said.isNotEmpty) cut(said, turnChars), if (call.isNotEmpty) call].join(' ');
          if (line.isNotEmpty) out.add('Assistant: $line');
        case ToolResponseTurn(:final text):
          out.add('Tool result: ${cut(text.trim(), toolChars)}');
      }
    }
    return out;
  }

  /// [lines] in groups of at most [maxChars] characters (a line longer than that is a group of its own,
  /// already cut by [lines]); a summary of a long conversation is written one group after another.
  static List<String> chunks(List<String> lines, int maxChars) {
    final out = <String>[];
    final current = StringBuffer();
    for (final line in lines) {
      if (current.isNotEmpty && current.length + line.length + 1 > maxChars) {
        out.add(current.toString());
        current.clear();
      }
      if (current.isNotEmpty) current.write('\n');
      current.write(line);
    }
    if (current.isNotEmpty) out.add(current.toString());
    return out;
  }

  static const instruction =
      'You summarize the earlier part of a conversation so that it can continue without it. '
      'Write in the language the user wrote in. Keep what the conversation still needs: what the user wants, '
      'decisions made and why, names of files, functions, settings and commands, numbers, errors that were '
      'found and how they were fixed, and what is still to be done. Leave out greetings and anything that was '
      'only a step on the way. Reply with the summary only.';

  /// What the summarizing model is asked for one group. [before] is the summary of the groups before it
  /// (empty for the first).
  static String request(String group, {String before = '', required int maxChars}) => [
        if (before.trim().isNotEmpty) 'Summary so far:\n${before.trim()}\n',
        'Conversation to add to the summary:\n$group\n',
        'Write the whole summary again, now including the conversation above. '
            'At most $maxChars characters.',
      ].join('\n');

  /// [history] with everything before [cut] replaced by [summary], which is written into the first
  /// message that is kept (at [cut], always a message of the user).
  static List<ChatMessage> replace(List<ChatMessage> history, int cut, String summary) {
    final first = history[cut];
    final text = first is UserTurn ? first.text : '';
    return [
      UserTurn('$summaryHeader\n${summary.trim()}\n\n$currentMessageHeader\n$text'),
      ...history.sublist(cut + 1),
    ];
  }

  /// A model's answer as the summary: its thinking and surrounding blanks removed; null when nothing is left.
  static String? clean(String answer) {
    final text = answer.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();
    return text.isEmpty ? null : text;
  }
}
