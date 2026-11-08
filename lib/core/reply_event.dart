import 'chat_controller.dart';
import 'generation.dart';

/// What the user is told about a reply when they are not looking at it.
enum ReplyEventKind {
  /// The reply stopped for a question or an approval: nothing goes on until the user answers.
  needsYou,
  done,
  failed,
}

class ReplyEvent {
  const ReplyEvent(this.kind, this.title, this.body);
  final ReplyEventKind kind;
  final String title;
  final String body;
}

/// Turns the changes of one chat's state into [ReplyEvent]s: one per reply that ends or stops for
/// the user, and none for a state that was only loaded (an opened conversation that was waiting for
/// an answer is not news). A stop pressed by the user is not an event either.
class ReplyWatch {
  bool _wasRunning = false;

  /// Call with every new state; returns the event this change is, if any.
  ReplyEvent? update(ChatState state) {
    final running = state.isGenerating;
    final was = _wasRunning;
    _wasRunning = running;
    if (running || !was) return null;
    switch (state.task) {
      case TaskState.userWait:
        final last = state.messages.isEmpty ? null : state.messages.last;
        final tile = state.pendingQuestion;
        final what = tile?.title ?? '';
        return ReplyEvent(
          ReplyEventKind.needsYou,
          last?.tool != null || last?.settings != null || last?.provider != null ? '確認が必要です' : '答えが必要です',
          _clip(what),
        );
      case TaskState.completed:
        final reply = state.messages.lastWhere(
          (m) => m.role == Role.assistant && m.text.trim().isNotEmpty,
          orElse: () => const UiMessage(id: -1, role: Role.assistant, text: ''),
        );
        return ReplyEvent(ReplyEventKind.done, '返信が終わりました', _clip(reply.text));
      case TaskState.error:
        return ReplyEvent(ReplyEventKind.failed, '失敗しました', _clip(state.error ?? ''));
      default:
        return null;
    }
  }

  /// One line, short enough for a notification.
  static String _clip(String text, [int max = 90]) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= max ? line : '${line.substring(0, max - 1)}…';
  }
}
