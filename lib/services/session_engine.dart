import 'dart:async';

import '../ai/routing_engine.dart';
import '../core/engine.dart';
import '../core/generation.dart';

/// Who may use what only one chat can use at a time: the device model (one set of weights and one
/// KV cache). Online models are not shared like this; the coding mode's developer model, when it is
/// the device model, takes the lease for the time of its work.
class ExclusiveLease {
  Object? _owner;

  bool get isHeld => _owner != null;

  /// True when [owner] has the lease now (it already had it, or nobody did).
  bool acquire(Object owner) {
    if (_owner != null && _owner != owner) return false;
    _owner = owner;
    return true;
  }

  void release(Object owner) {
    if (_owner == owner) _owner = null;
  }
}

/// The engine of one chat. Several chats can generate at the same time (the others keep going in the
/// background while another one is on the screen), so a request must not stop, or be stopped by,
/// the request of another chat:
///
/// - an online model answers any number of chats at once; "stop" ends only this chat's stream;
/// - the device model answers one chat at a time. A second chat that asks
///   is told so, instead of mixing its prompt into the first one's cache.
class SessionEngine implements InferenceEngine {
  SessionEngine(this._router, this._lease);

  final RoutingEngine _router;
  final ExclusiveLease _lease;

  bool _cancelled = false;

  /// Completes when [cancel] is called, so a reply that is waiting for the model's next word (a model
  /// that thinks for a long time sends nothing) stops at once, not at the next word.
  var _cancelSignal = Completer<void>();

  /// Whether the request in progress is answered by the device model.
  bool _exclusive = false;

  @override
  bool get isLoaded => _router.isLoaded;

  @override
  Future<void> load(LoadParams params) => _router.load(params);

  @override
  Future<void> unload() => _router.unload();

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) async* {
    _cancelled = false;
    _cancelSignal = Completer<void>();
    // the online request is told to drop its connection when the user stops (see GenerateRequest.abort)
    request = request.withAbort(_cancelSignal.future);
    _exclusive = _router.usesDevice(request);
    if (_exclusive && !_lease.acquire(this)) {
      throw EngineException('ローカルモデル（または分担）を、ほかのチャットが使っています。そのチャットの生成が終わってから、もう一度送ってください');
    }
    try {
      var finished = false;
      if (_exclusive) {
        // the device engine ends the stream itself once it has been told to stop
        await for (final event in _router.generate(request)) {
          if (event is Finished) finished = true;
          yield event;
        }
      } else {
        // an online request is dropped here: its engine is shared, and is not told to stop. The wait
        // for the next event ends as soon as the user stops, even when the model is silent.
        final events = StreamIterator(_router.generate(request));
        try {
          final signal = _cancelSignal;
          while (await Future.any<bool>([events.moveNext(), signal.future.then((_) => false)])) {
            final event = events.current;
            if (event is Finished) finished = true;
            yield event;
          }
        } finally {
          // not waited for: the stream below may be suspended in a wait that only the dropped
          // connection ends
          unawaited(events.cancel());
        }
        if (_cancelled && !finished) yield const Finished(FinishReason.cancelled);
      }
    } finally {
      if (_exclusive) _lease.release(this);
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    if (!_cancelSignal.isCompleted) _cancelSignal.complete();
    // only what this chat is using is stopped: stopping the shared online engine would end the
    // replies of the other chats too
    if (_exclusive) _router.local.cancel();
  }
}
