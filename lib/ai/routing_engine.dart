import '../core/engine.dart';
import 'cloud_engine.dart';
import 'provider.dart';

/// Sends each request to either the device model or a cloud provider, so the chat never has to
/// know which one answers.
///
/// Either one can be the one in use: the local model is not a fallback and the cloud is not a
/// special case. The choice is reported through [isCloud] and [cloudProvider] for the screen.
class RoutingEngine implements InferenceEngine {
  RoutingEngine({required this.local, required this.cloud});

  /// The on-device model (native once loaded, demo answers until then).
  final InferenceEngine local;
  final CloudEngine cloud;

  /// The coding mode: the engine of the planner model, for the requests the planner answers (the
  /// coding agent's, while the mode is on). Null, or null for a request, means the model in use
  /// answers. The planner hands work to the developer model with the `delegate` tool, which the
  /// chat runs like any other tool.
  InferenceEngine? Function(GenerateRequest request)? planner;

  /// Whether [request] is answered by the device model, which only one chat at a time can use.
  bool usesDevice(GenerateRequest request) {
    final answering = planner?.call(request);
    if (answering != null) return identical(answering, local);
    return !isCloud;
  }

  AiProvider? _cloudProvider;

  bool get isCloud => _cloudProvider != null;

  /// The provider in use, or null for the device model.
  AiProvider? get cloudProvider => _cloudProvider;

  /// Switches to [provider] (cloud), or to the device model when it is null.
  set target(AiProvider? provider) => _cloudProvider = provider;

  InferenceEngine get active => _cloudProvider == null ? local : cloud;

  @override
  bool get isLoaded => active.isLoaded;

  @override
  Future<void> load(LoadParams params) => local.load(params);

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) {
    final answering = planner?.call(request);
    if (answering != null) return answering.generate(request);
    return active.generate(request);
  }

  @override
  void cancel() {
    // Whichever is answering stops; the other one has nothing running.
    cloud.cancel();
    local.cancel();
  }

  @override
  Future<void> unload() => local.unload();
}
