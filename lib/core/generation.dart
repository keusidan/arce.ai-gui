/// States of one generation, per spec §15.
enum TaskState {
  waiting,
  search,
  thinking,
  userWait,
  generation,
  completed,
  error,
  cancelled;

  bool get isTerminal => this == completed || this == error || this == cancelled;
}

/// Why the engine stopped producing tokens.
enum FinishReason {
  /// The model emitted an end-of-generation token.
  eog,

  /// The token budget ran out; output may be cut off mid-block.
  length,
  cancelled,
  error,
}

/// What to do after a generation ends, per spec §26/§44.
sealed class NextStep {
  const NextStep();
}

class Done extends NextStep {
  const Done();
}

/// Output was cut off inside a structured block: run the same generation again.
class Regenerate extends NextStep {
  const Regenerate(this.attempt);
  final int attempt;
}

class Fail extends NextStep {
  const Fail(this.reason);
  final String reason;
}

class RetryPolicy {
  RetryPolicy(this.maxAttempts) : assert(maxAttempts >= 0);
  final int maxAttempts;

  /// Only a cut-off structured block is regenerated. GBNF already guarantees the JSON syntax,
  /// so there is nothing to "repair"; a semantic error is surfaced instead of looping.
  NextStep decide(
    FinishReason reason, {
    required bool endedInsideToolCall,
    required String? semanticError,
    required int attemptsSoFar,
  }) {
    if (reason == FinishReason.cancelled) return const Done();
    if (reason == FinishReason.error) return const Fail('inference error');
    if (reason == FinishReason.length && endedInsideToolCall) {
      return attemptsSoFar < maxAttempts
          ? Regenerate(attemptsSoFar + 1)
          : Fail('tool call cut off after $attemptsSoFar retries');
    }
    if (semanticError != null) return Fail(semanticError);
    return const Done();
  }
}

class GenerationTask {
  TaskState _state = TaskState.waiting;
  TaskState get state => _state;

  void moveTo(TaskState next) {
    if (next == _state) return;
    if (_state.isTerminal && next != TaskState.waiting) {
      throw StateError('task already ended in $_state');
    }
    if (!_allowed[_state]!.contains(next)) {
      throw StateError('illegal transition $_state -> $next');
    }
    _state = next;
  }

  static const _allowed = <TaskState, Set<TaskState>>{
    TaskState.waiting: {
      TaskState.search,
      TaskState.thinking,
      TaskState.generation,
      TaskState.userWait,
      TaskState.completed,
      TaskState.error,
      TaskState.cancelled,
    },
    TaskState.search: {TaskState.thinking, TaskState.generation, TaskState.error, TaskState.cancelled},
    TaskState.thinking: {
      TaskState.generation,
      TaskState.userWait,
      TaskState.completed,
      TaskState.error,
      TaskState.cancelled,
    },
    TaskState.generation: {
      TaskState.thinking,
      TaskState.userWait,
      TaskState.completed,
      TaskState.error,
      TaskState.cancelled,
    },
    TaskState.userWait: {TaskState.generation, TaskState.thinking, TaskState.cancelled},
    TaskState.completed: {TaskState.waiting},
    TaskState.error: {TaskState.waiting},
    TaskState.cancelled: {TaskState.waiting},
  };
}
