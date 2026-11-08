import 'engine.dart';

/// GGUF runs on llama.cpp; LiteRT-LM files run on LiteRT-LM (CPU, GPU or NPU).
enum ModelFormat { gguf, litertLm }

enum ThinkingSupport { switchable, alwaysOn, none }

/// A downloadable model.
///
/// The hybrid Qwen3 releases are listed on purpose: they switch reasoning on and off per
/// turn. The later "-2507" releases split into Instruct and Thinking models and cannot.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.hfRepo,
    required this.fileName,
    required this.fileBytes,
    required this.layers,
    required this.kvHeads,
    required this.headDim,
    required this.thinking,
    this.format = ModelFormat.gguf,
    // Set for NPU builds, which only run on the SoC they were compiled for (e.g. "mt6993").
    this.npuSoc,
  });

  final String id;
  final String displayName;
  final String hfRepo;
  final String fileName;
  final int fileBytes;
  final int layers;
  final int kvHeads;
  final int headDim;
  final ThinkingSupport thinking;
  final ModelFormat format;
  final String? npuSoc;

  /// "Qwen3.5-0.8B" -> 0.8
  double? get paramsB => paramsFromName(displayName.split(' ').first);

  static double? paramsFromName(String name) {
    final m = RegExp(r'(\d+(?:\.\d+)?)B$').firstMatch(name);
    return m == null ? null : double.tryParse(m.group(1)!);
  }
}

abstract final class ModelCatalog {
  static const _gb = 1000000000;

  // Sizes are the byte counts published on Hugging Face (verified again by SHA-256 on download).
  // Qwen3.5 is hybrid: only every 4th layer (6 of 24) keeps a KV cache, 2 KV heads x 256 dims.
  static const basic = ModelSpec(
    id: 'qwen3.5-0.8b-q8',
    displayName: 'Qwen3.5-0.8B',
    hfRepo: 'ggml-org/Qwen3.5-0.8B-GGUF',
    fileName: 'Qwen3.5-0.8B-Q8_0.gguf',
    fileBytes: 833592096,
    layers: 6,
    kvHeads: 2,
    headDim: 256,
    thinking: ThinkingSupport.switchable,
  );

  // The hybrid Qwen3 releases switch reasoning per turn. The 1.7B repo ships Q8_0 only.
  static const qwen3 = [
    ModelSpec(
      id: 'qwen3-0.6b-q8', displayName: 'Qwen3-0.6B', hfRepo: 'Qwen/Qwen3-0.6B-GGUF',
      fileName: 'Qwen3-0.6B-Q8_0.gguf', fileBytes: 639446688, layers: 28, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable,
    ),
    ModelSpec(
      id: 'qwen3-1.7b-q8', displayName: 'Qwen3-1.7B', hfRepo: 'Qwen/Qwen3-1.7B-GGUF',
      fileName: 'Qwen3-1.7B-Q8_0.gguf', fileBytes: 1800000000, layers: 28, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable,
    ),
    ModelSpec(
      id: 'qwen3-4b-q4km', displayName: 'Qwen3-4B', hfRepo: 'Qwen/Qwen3-4B-GGUF',
      fileName: 'Qwen3-4B-Q4_K_M.gguf', fileBytes: 2500000000, layers: 36, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable,
    ),
    ModelSpec(
      id: 'qwen3-8b-q4km', displayName: 'Qwen3-8B', hfRepo: 'Qwen/Qwen3-8B-GGUF',
      fileName: 'Qwen3-8B-Q4_K_M.gguf', fileBytes: 5 * _gb, layers: 36, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable,
    ),
    ModelSpec(
      id: 'qwen3-14b-q4km', displayName: 'Qwen3-14B', hfRepo: 'Qwen/Qwen3-14B-GGUF',
      fileName: 'Qwen3-14B-Q4_K_M.gguf', fileBytes: 9 * _gb, layers: 40, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable,
    ),
  ];

  // LiteRT-LM builds from litert-community. The MediaTek file is an NPU build for Dimensity (mt6993) only.
  static const liteRt = [
    ModelSpec(
      id: 'litert-qwen3-0.6b', displayName: 'Qwen3-0.6B LiteRT', hfRepo: 'litert-community/Qwen3-0.6B',
      fileName: 'Qwen3-0.6B.litertlm', fileBytes: 614236160, layers: 28, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable, format: ModelFormat.litertLm,
    ),
    ModelSpec(
      id: 'litert-qwen3-0.6b-mt6993', displayName: 'Qwen3-0.6B LiteRT NPU', hfRepo: 'litert-community/Qwen3-0.6B',
      fileName: 'Qwen3-0.6B.mediatek.mt6993.litertlm', fileBytes: 1202913280, layers: 28, kvHeads: 8,
      headDim: 128, thinking: ThinkingSupport.switchable, format: ModelFormat.litertLm, npuSoc: 'mt6993',
    ),
    ModelSpec(
      id: 'litert-qwen3-1.7b-int4', displayName: 'Qwen3-1.7B LiteRT', hfRepo: 'litert-community/Qwen3-1.7B',
      fileName: 'Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm', fileBytes: 977184032, layers: 28, kvHeads: 8,
      headDim: 128, thinking: ThinkingSupport.switchable, format: ModelFormat.litertLm,
    ),
    ModelSpec(
      id: 'litert-qwen3-4b-int4', displayName: 'Qwen3-4B LiteRT', hfRepo: 'litert-community/Qwen3-4B',
      fileName: 'qwen3_4b_mixed_int4.litertlm', fileBytes: 2659057664, layers: 36, kvHeads: 8, headDim: 128,
      thinking: ThinkingSupport.switchable, format: ModelFormat.litertLm,
    ),
  ];

  static const all = [basic, ...qwen3, ...liteRt];

  static ModelSpec? byFileName(String name) {
    for (final m in all) {
      if (m.fileName == name) return m;
    }
    return null;
  }
}

abstract final class MemoryEstimator {
  /// KV cache size: 2 (K and V) x layers x kv heads x head dim x bytes per element x tokens.
  static int kvCacheBytes(ModelSpec model, int contextTokens, KvCacheType type) =>
      (2.0 * model.layers * model.kvHeads * model.headDim * type.bytesPerElement * contextTokens).toInt();

  /// Weights are mmapped, so the whole file counts; compute buffers are left out of this estimate.
  static int totalBytes(ModelSpec model, int contextTokens, KvCacheType type) =>
      model.fileBytes + kvCacheBytes(model, contextTokens, type);

  /// Whether the model should be greyed out (spec §24/§60) unless Force Execution is on.
  static bool fits(ModelSpec model, int contextTokens, KvCacheType type, int deviceRamBytes) =>
      totalBytes(model, contextTokens, type) <= deviceRamBytes;
}
