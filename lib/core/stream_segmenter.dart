/// A piece of model output, classified by the block it belongs to.
sealed class StreamEvent {
  const StreamEvent();
}

class ThinkingText extends StreamEvent {
  const ThinkingText(this.text);
  final String text;
}

class PlainText extends StreamEvent {
  const PlainText(this.text);
  final String text;
}

class ToolCallStart extends StreamEvent {
  const ToolCallStart();
}

class ToolCallDelta extends StreamEvent {
  const ToolCallDelta(this.text);
  final String text;
}

/// [json] is the full body between the tags, not yet validated.
class ToolCallEnd extends StreamEvent {
  const ToolCallEnd(this.json);
  final String json;
}

enum _Block { text, thinking, toolCall }

/// Splits streamed model output into Thinking, plain text and tool-call blocks.
///
/// Qwen3 wraps reasoning in `<think>…</think>` and tool calls in `<tool_call>…</tool_call>`.
/// Tokens arrive in arbitrary pieces, so a tag can be split across two [feed] calls; the tail
/// that could still become a tag is held back until the next piece decides it.
class StreamSegmenter {
  static const thinkOpen = '<think>';
  static const thinkClose = '</think>';
  static const toolOpen = '<tool_call>';
  static const toolClose = '</tool_call>';

  _Block _block = _Block.text;
  String _pending = '';
  final StringBuffer _toolCall = StringBuffer();

  List<StreamEvent> feed(String piece) {
    _pending += piece;
    final events = <StreamEvent>[];
    while (true) {
      final candidates = switch (_block) {
        _Block.text => const [thinkOpen, toolOpen],
        _Block.thinking => const [thinkClose],
        _Block.toolCall => const [toolClose],
      };
      String? hitTag;
      var hitAt = -1;
      for (final tag in candidates) {
        final at = _pending.indexOf(tag);
        if (at >= 0 && (hitAt < 0 || at < hitAt)) {
          hitTag = tag;
          hitAt = at;
        }
      }

      if (hitTag == null) {
        final safe = _pending.length - _longestTagPrefixSuffix(candidates);
        _emit(_pending.substring(0, safe), events);
        _pending = _pending.substring(safe);
        return events;
      }

      _emit(_pending.substring(0, hitAt), events);
      _pending = _pending.substring(hitAt + hitTag.length);
      _transition(hitTag, events);
    }
  }

  /// Flushes whatever is held back once the stream has ended.
  List<StreamEvent> finish() {
    final events = <StreamEvent>[];
    _emit(_pending, events);
    _pending = '';
    return events;
  }

  /// True when the stream ended inside a tool call, i.e. the call was cut off.
  bool get isInsideToolCall => _block == _Block.toolCall;

  void _transition(String tag, List<StreamEvent> events) {
    switch (tag) {
      case thinkOpen:
        _block = _Block.thinking;
      case thinkClose:
        _block = _Block.text;
      case toolOpen:
        _block = _Block.toolCall;
        _toolCall.clear();
        events.add(const ToolCallStart());
      case toolClose:
        _block = _Block.text;
        events.add(ToolCallEnd(_toolCall.toString().trim()));
    }
  }

  void _emit(String text, List<StreamEvent> events) {
    if (text.isEmpty) return;
    switch (_block) {
      case _Block.text:
        events.add(PlainText(text));
      case _Block.thinking:
        events.add(ThinkingText(text));
      case _Block.toolCall:
        _toolCall.write(text);
        events.add(ToolCallDelta(text));
    }
  }

  /// Length of the longest suffix of the pending text that is a proper prefix of one of [tags].
  int _longestTagPrefixSuffix(List<String> tags) {
    var longest = 0;
    for (final tag in tags) {
      if (tag.length > longest) longest = tag.length;
    }
    final max = _pending.length < longest - 1 ? _pending.length : longest - 1;
    for (var len = max; len >= 1; len--) {
      final suffix = _pending.substring(_pending.length - len);
      if (tags.any((t) => t.startsWith(suffix))) return len;
    }
    return 0;
  }
}
