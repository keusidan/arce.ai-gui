import '../core/engine.dart';
import 'demo_engine.dart';
import 'native_engine.dart';

/// Uses the on-device model once one is loaded, and the demo answers until then.
class HybridEngine implements InferenceEngine, KvStatePersistence {
  HybridEngine(this.native, this.demo);

  final NativeEngine native;
  final DemoEngine demo;

  @override
  bool get isLoaded => native.isLoaded;

  @override
  Future<void> load(LoadParams params) => native.load(params);

  @override
  Stream<GenerationEvent> generate(GenerateRequest request) =>
      native.isLoaded ? native.generate(request) : demo.generate(request);

  @override
  void cancel() {
    native.cancel();
    demo.cancel();
  }

  @override
  Future<void> unload() => native.unload();

  @override
  Future<int> saveKvState(String path, {required int minTokens}) => native.saveKvState(path, minTokens: minTokens);

  @override
  Future<int> loadKvState(String path) => native.loadKvState(path);
}
