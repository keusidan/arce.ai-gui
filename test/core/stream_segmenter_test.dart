import 'package:arce_ai/core/stream_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

/// Joins adjacent deltas of the same kind so assertions don't depend on chunking.
List<Object> merged(List<StreamEvent> events) {
  final out = <Object>[];
  for (final e in events) {
    final last = out.isEmpty ? null : out.last;
    if (last is PlainText && e is PlainText) {
      out[out.length - 1] = PlainText(last.text + e.text);
    } else if (last is ThinkingText && e is ThinkingText) {
      out[out.length - 1] = ThinkingText(last.text + e.text);
    } else if (last is ToolCallDelta && e is ToolCallDelta) {
      out[out.length - 1] = ToolCallDelta(last.text + e.text);
    } else {
      out.add(e);
    }
  }
  return out;
}

List<StreamEvent> run(List<String> pieces) {
  final s = StreamSegmenter();
  return [for (final p in pieces) ...s.feed(p), ...s.finish()];
}

String describe(Object e) => switch (e) {
      ThinkingText(:final text) => 'think:$text',
      PlainText(:final text) => 'text:$text',
      ToolCallStart() => 'start',
      ToolCallDelta(:final text) => 'delta:$text',
      ToolCallEnd(:final json) => 'end:$json',
      _ => '?',
    };

void main() {
  List<String> view(List<StreamEvent> events) => merged(events).map(describe).toList();

  test('splits thinking from the answer', () {
    expect(view(run(['<think>plan</think>answer'])), ['think:plan', 'text:answer']);
  });

  test('handles tags split across pieces', () {
    expect(view(run(['<th', 'ink>pl', 'an</thi', 'nk>ans', 'wer'])), ['think:plan', 'text:answer']);
  });

  test('holds back a possible tag until it is decided', () {
    final s = StreamSegmenter();
    expect(s.feed('a <thi').map(describe), ['text:a ']);
    // "<thi" turned out not to be a tag: it must come back as text, not be lost
    expect(view([...s.feed('n b'), ...s.finish()]), ['text:<thin b']);
  });

  test('emits a complete tool call', () {
    final events = view(run(['Let me ask.<tool_call>\n{"name":', '"ask_user"}\n</tool_', 'call>']));
    expect(events.first, 'text:Let me ask.');
    expect(events[1], 'start');
    expect(events.last, 'end:{"name":"ask_user"}');
  });

  test('reports a tool call cut off by the token limit', () {
    final s = StreamSegmenter()
      ..feed('<tool_call>{"name":"ask')
      ..finish();
    expect(s.isInsideToolCall, isTrue);
  });

  test('passes multibyte text through untouched', () {
    expect(view(run(['こんにちは', '🙂', '<'])), ['text:こんにちは🙂<']);
  });
}
