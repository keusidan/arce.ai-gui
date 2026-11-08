import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/engine.dart';
import '../core/generation.dart';

/// The on-device engines of the Android build (llama.cpp and LiteRT-LM), reached through a
/// platform channel. The native side owns the model; this class only forwards calls and
/// turns the event stream back into [GenerationEvent]s.
class NativeEngine implements InferenceEngine, KvStatePersistence {
  static const _method = MethodChannel('ai.arce.app/engine');
  static const _events = EventChannel('ai.arce.app/engine/events');

  /// Only the Android build ships the native engines.
  static bool get isSupportedPlatform => Platform.isAndroid;

  bool _loaded = false;
  String? _backend;
  int _nextId = 0;
  StreamSubscription<dynamic>? _subscription;
  final _active = <int, StreamController<Map<Object?, Object?>>>{};

  @override
  bool get isLoaded => _loaded;

  /// "llama.cpp" or "LiteRT-LM (GPU)" for the status line.
  String? get backendName => _backend;

  void _listen() {
    _subscription ??= _events.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final controller = _active[event['id']];
      controller?.add(event);
    });
  }

  /// Compute devices llama.cpp was built with, e.g. "Vulkan0: ...". Empty when unknown.
  Future<List<String>> devices() async {
    try {
      return (await _method.invokeListMethod<String>('devices')) ?? const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<void> load(LoadParams params) async {
    try {
      final result = await _method.invokeMapMethod<String, Object?>('load', {
        'path': params.path,
        'contextLength': params.contextLength,
        'threads': params.threads,
        'batchSize': params.batchSize,
        'gpuLayers': params.gpuLayers,
        'kvType': params.kvCache.nativeCode,
      });
      _backend = result?['backend'] as String?;
      _loaded = true;
    } on PlatformException catch (e) {
      _loaded = false;
      _backend = null;
      throw EngineException(e.message ?? 'could not load the model');
    }
  }

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    _listen();
    final id = _nextId++;
    final events = StreamController<Map<Object?, Object?>>();
    _active[id] = events;
    late final StreamController<GenerationEvent> out;
    out = StreamController<GenerationEvent>(
      onListen: () {
        events.stream.listen((e) {
          switch (e['type']) {
            case 'piece':
              out.add(Piece(e['text'] as String));
            case 'done':
              out.add(Finished(_reason(e['reason'] as String?)));
              out.close();
            case 'error':
              out.addError(EngineException(e['message'] as String? ?? 'inference error'));
              out.close();
          }
        });
        _method.invokeMethod<void>('generate', {
          'id': id,
          'prompt': request.prompt,
          'toolSchema': request.toolCallSchema,
          'strictSchema': request.strictJsonSchema,
          'thinking': request.thinking,
          'maxTokens': request.maxTokens,
          'temperature': request.sampling.temperature,
          'topP': request.sampling.topP,
          'topK': request.sampling.topK,
          'minP': request.sampling.minP,
          'dry': request.sampling.dryMultiplier,
        }).catchError((Object e) {
          out.addError(EngineException(e is PlatformException ? (e.message ?? 'inference error') : '$e'));
          out.close();
        });
      },
      onCancel: () {
        // the consumer gave up (e.g. a timeout): stop the native side too
        _active.remove(id);
        events.close();
        _method.invokeMethod<void>('cancel').catchError((Object _) {});
      },
    );
    out.done.whenComplete(() {
      _active.remove(id);
      events.close();
    });
    return out.stream;
  }

  FinishReason _reason(String? name) => switch (name) {
        'eog' => FinishReason.eog,
        'length' => FinishReason.length,
        'cancelled' => FinishReason.cancelled,
        _ => FinishReason.error,
      };

  @override
  void cancel() {
    _method.invokeMethod<void>('cancel').catchError((Object _) {});
  }

  /// A failure is "nothing saved": the file is only a cache, so it never reaches the chat.
  @override
  Future<int> saveKvState(String path, {required int minTokens}) async {
    if (!_loaded) return 0;
    try {
      return (await _method.invokeMethod<int>('saveState', {'path': path, 'minTokens': minTokens})) ?? 0;
    } on PlatformException {
      return 0;
    }
  }

  @override
  Future<int> loadKvState(String path) async {
    if (!_loaded) return 0;
    try {
      return (await _method.invokeMethod<int>('loadState', {'path': path})) ?? 0;
    } on PlatformException {
      return 0;
    }
  }

  @override
  Future<void> unload() async {
    try {
      await _method.invokeMethod<void>('unload');
    } on PlatformException {
      // nothing left to free
    }
    _loaded = false;
    _backend = null;
  }
}
