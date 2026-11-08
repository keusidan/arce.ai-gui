import 'package:arce_ai/core/generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final policy = RetryPolicy(2);

  NextStep decide(FinishReason r, bool inside, String? semantic, int attempts) => policy.decide(
        r,
        endedInsideToolCall: inside,
        semanticError: semantic,
        attemptsSoFar: attempts,
      );

  test('regenerates only a cut-off tool call, up to the limit', () {
    expect((decide(FinishReason.length, true, null, 0) as Regenerate).attempt, 1);
    expect((decide(FinishReason.length, true, null, 1) as Regenerate).attempt, 2);
    expect((decide(FinishReason.length, true, null, 2) as Fail).reason, 'tool call cut off after 2 retries');
  });

  test('a long plain answer that hit the limit is kept, not regenerated', () {
    expect(decide(FinishReason.length, false, null, 0), isA<Done>());
  });

  test('semantic errors are reported instead of retried', () {
    expect((decide(FinishReason.eog, false, 'options are not distinct', 0) as Fail).reason, 'options are not distinct');
  });

  test('follows the question flow and rejects skipping states', () {
    final task = GenerationTask()
      ..moveTo(TaskState.thinking)
      ..moveTo(TaskState.userWait)
      ..moveTo(TaskState.generation)
      ..moveTo(TaskState.completed);
    expect(() => task.moveTo(TaskState.generation), throwsStateError);
    task
      ..moveTo(TaskState.waiting)
      ..moveTo(TaskState.userWait);
    // a question must be answered (-> generation) or cancelled, never silently completed
    expect(() => task.moveTo(TaskState.completed), throwsStateError);
  });
}
