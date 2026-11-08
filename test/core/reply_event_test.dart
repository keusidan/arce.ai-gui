import 'package:arce_ai/core/chat_controller.dart';
import 'package:arce_ai/core/generation.dart';
import 'package:arce_ai/core/protocol.dart';
import 'package:arce_ai/core/reply_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const user = UiMessage(id: 0, role: Role.user, text: '作って');
  const answer = UiMessage(id: 1, role: Role.assistant, text: '作りました\n\n  できました');
  const running = ChatState(messages: [user], task: TaskState.generation);

  test('a reply that ends is an event once; the same state again is not', () {
    final watch = ReplyWatch();
    expect(watch.update(running), isNull);
    final event = watch.update(const ChatState(messages: [user, answer], task: TaskState.completed))!;
    expect(event.kind, ReplyEventKind.done);
    expect(event.body, '作りました できました', reason: 'one line');
    expect(watch.update(const ChatState(messages: [user, answer], task: TaskState.completed)), isNull);
  });

  test('a conversation that is only opened, even one that waits for an answer, is not news', () {
    final waiting = UiMessage(
      id: 1,
      role: Role.assistant,
      text: '',
      question: ToolApproval.tile(const McpCall('mcp_x__y', {})),
      tool: const McpCall('mcp_x__y', {}),
    );
    expect(ReplyWatch().update(ChatState(messages: [user, waiting], task: TaskState.userWait)), isNull);
  });

  test('a reply that stops for an approval says that a confirmation is needed, with the question', () {
    final watch = ReplyWatch()..update(running);
    const call = McpCall('mcp_gh__push_files', {'path': 'a'});
    final card = UiMessage(id: 1, role: Role.assistant, text: '', question: ToolApproval.tile(call), tool: call);
    final event = watch.update(ChatState(messages: [user, card], task: TaskState.userWait))!;
    expect(event.kind, ReplyEventKind.needsYou);
    expect(event.title, '確認が必要です');
    expect(event.body, isNotEmpty);
  });

  test('a question from the model is "an answer is needed"', () {
    final watch = ReplyWatch()..update(running);
    const ask = UiMessage(
      id: 1,
      role: Role.assistant,
      text: '',
      question: QuestionTile(title: 'どの言語？', options: ['Kotlin'], allowFreeInput: true, multiSelect: false),
    );
    final event = watch.update(const ChatState(messages: [user, ask], task: TaskState.userWait))!;
    expect(event.title, '答えが必要です');
    expect(event.body, 'どの言語？');
  });

  test('a failure carries the reason, cut to one short line', () {
    final watch = ReplyWatch()..update(running);
    final event = watch.update(ChatState(messages: const [user], task: TaskState.error, error: 'x' * 300))!;
    expect(event.kind, ReplyEventKind.failed);
    expect(event.body.length, 90);
    expect(event.body, endsWith('…'));
  });

  test('a stop is not an event', () {
    final watch = ReplyWatch()..update(running);
    expect(watch.update(const ChatState(messages: [user, answer], task: TaskState.cancelled)), isNull);
  });

  test('the steps of one reply (tool, thinking, generation) are not events', () {
    final watch = ReplyWatch();
    for (final task in [TaskState.thinking, TaskState.search, TaskState.generation, TaskState.thinking]) {
      expect(watch.update(ChatState(messages: const [user], task: task)), isNull);
    }
  });
}
