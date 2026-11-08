import 'dart:async';

import '../core/generation.dart';
import 'model_availability.dart';
import 'provider.dart';

/// What the probe found for one model.
class ProbeOutcome {
  const ProbeOutcome(this.modelId, this.verdict);

  final String modelId;
  final AvailabilityVerdict verdict;
}

/// What a probe did, for the screen.
class ProbeReport {
  const ProbeReport({required this.outcomes, this.notRun = 0, this.keyRejected = false, this.cancelled = false});

  /// In the order the models were given.
  final List<ProbeOutcome> outcomes;

  /// Models that were not asked because the probe stopped (the key was refused, or it was cancelled).
  final int notRun;

  /// The key was refused: the probe stopped, because it says nothing about the models.
  final bool keyRejected;
  final bool cancelled;

  int count(ModelAvailability a) => outcomes.where((o) => o.verdict.availability == a).length;

  /// One or two sentences: how many models can be used, which cannot, what is left unknown.
  String summary() {
    if (keyRejected) {
      return 'APIキーが受け付けられなかったので、確認をやめました（モデルのことは分かっていません）。キーを確かめてください';
    }
    final parts = <String>[
      '使える ${count(ModelAvailability.usable)}',
      '使えない ${count(ModelAvailability.blocked)}',
      if (count(ModelAvailability.temporary) > 0) '一時的な失敗 ${count(ModelAvailability.temporary)}（あとでもう一度）',
      if (count(ModelAvailability.unknown) > 0) '判断できない ${count(ModelAvailability.unknown)}',
    ];
    return '${outcomes.length} 個を確かめました：${parts.join('・')}'
        '${cancelled ? '。途中でやめました（残り $notRun 個）' : ''}';
  }
}

/// Finds out which models of a provider this key can use, by asking each one for the shortest answer.
///
/// Every request is real and counts against the key's limits (a free tier counts it too), so the caller
/// asks the user first and passes only the models it means to ask. A model is asked with one word, no
/// tools and the smallest reply; the answer itself is thrown away. Only the verdict is kept.
abstract final class ModelProbe {
  /// Asks [modelIds] with [ask] (which completes when the model answered and throws what the provider
  /// answered otherwise), [concurrency] at a time. Each question is given up after [timeout]. The probe
  /// stops starting new questions when the key is refused (a 401 is the key's fault, not the model's) or
  /// when [cancelled] says so; questions already on their way finish.
  static Future<ProbeReport> run({
    required List<String> modelIds,
    required Future<void> Function(String modelId) ask,
    int concurrency = 3,
    Duration timeout = const Duration(seconds: 30),
    void Function(ProbeOutcome outcome, int done, int total)? onOutcome,
    bool Function()? cancelled,
  }) async {
    final ids = modelIds.toSet().toList();
    final results = <String, ProbeOutcome>{};
    var next = 0;
    var keyRejected = false;
    var wasCancelled = false;

    Future<void> worker() async {
      while (!keyRejected && next < ids.length) {
        if (cancelled?.call() ?? false) {
          wasCancelled = true;
          return;
        }
        final id = ids[next++];
        final verdict = await _one(id, ask, timeout);
        final outcome = ProbeOutcome(id, verdict);
        results[id] = outcome;
        if (verdict.availability == ModelAvailability.keyRejected) keyRejected = true;
        onOutcome?.call(outcome, results.length, ids.length);
      }
    }

    final workers = concurrency.clamp(1, ids.isEmpty ? 1 : ids.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return ProbeReport(
      outcomes: [
        for (final id in ids)
          if (results[id] != null) results[id]!,
      ],
      notRun: ids.length - results.length,
      keyRejected: keyRejected,
      cancelled: wasCancelled,
    );
  }

  static Future<AvailabilityVerdict> _one(String id, Future<void> Function(String) ask, Duration timeout) async {
    try {
      await ask(id).timeout(timeout);
      return AvailabilityVerdict.usable;
    } catch (error) {
      return AvailabilityClassifier.classifyError(error);
    }
  }

  /// The question the probe sends through [provider]: one word, no tools, the smallest reply. Returns when
  /// the first piece of an answer (or the end of it) has come; a failure is thrown as the provider threw it.
  ///
  /// With [abortAfter] the request itself is dropped when that time has passed (the connection is closed),
  /// instead of being left to run on after the probe has given up on it.
  static Future<void> askOnce(AiProvider provider, {Duration? abortAfter}) async {
    // the clock is stopped when the question is over, so nothing is left running behind it
    final stop = Completer<void>();
    final timer = abortAfter == null ? null : Timer(abortAfter, () => stop.complete());
    try {
      final request = AiRequest(
        messages: const [AiMessage(AiRole.user, text: 'hi')],
        model: provider.modelId,
        maxTokens: 1,
        temperature: 0,
        topP: 1,
        abort: abortAfter == null ? null : stop.future,
      );
      await for (final delta in provider.stream(request)) {
        // a request that was dropped says it was cancelled: that is the time running out, not an answer
        if (delta is StopDelta && delta.reason == FinishReason.cancelled) throw TimeoutException('時間切れ', abortAfter);
        // anything the model sent back means it answered; the rest of the reply is not wanted
        if (delta is TextDelta || delta is ReasoningDelta || delta is ToolCallDelta || delta is StopDelta) return;
      }
    } finally {
      timer?.cancel();
    }
  }
}
