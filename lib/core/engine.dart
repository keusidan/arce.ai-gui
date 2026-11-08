import 'attachments.dart';
import 'generation.dart';
import 'protocol.dart';

/// How the KV cache is stored. The same cache costs F16 → Q8_0 → Q4_0 about 1 : ½ : ⅓ of the memory
/// (a block of 32 values takes 64, 34 and 18 bytes), at a growing cost in accuracy. llama.cpp
/// supports more types; these are the useful steps.
enum KvCacheType {
  f16(2.0, 0),
  q8_0(1.0625, 1),
  q4_0(0.5625, 2);

  const KvCacheType(this.bytesPerElement, this.nativeCode);
  final double bytesPerElement;

  /// What the native side is told (`kv_type` of `nativeLoad`).
  final int nativeCode;
}

/// An engine that can keep the work it did on a prompt in a file and read it back later, so a
/// conversation that is opened again does not have to be evaluated from the start.
abstract interface class KvStatePersistence {
  /// Writes the KV entries of the last prompt to [path]; returns the bytes written, or 0 when
  /// nothing was written (no model, too short, or a model that cannot do it).
  Future<int> saveKvState(String path, {required int minTokens});

  /// Reads a file written by [saveKvState]; returns the tokens restored, or 0 when it was refused.
  Future<int> loadKvState(String path);
}

class LoadParams {
  const LoadParams({
    required this.path,
    this.contextLength = 4096,
    this.threads = 4,
    // 0 = llama.cpp default.
    this.batchSize = 0,
    this.gpuLayers = 0,
    this.kvCache = KvCacheType.f16,
  });

  final String path;
  final int contextLength;
  final int threads;
  final int batchSize;
  final int gpuLayers;
  final KvCacheType kvCache;
}

class SamplingParams {
  const SamplingParams({
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.minP,
    // 0 disables DRY; it discourages repeating earlier phrases (spec §55).
    this.dryMultiplier = 0.8,
  });

  // Qwen3 model card recommendations for each mode
  static const qwen3Thinking = SamplingParams(temperature: 0.6, topP: 0.95, topK: 20, minP: 0);
  static const qwen3NonThinking = SamplingParams(temperature: 0.7, topP: 0.8, topK: 20, minP: 0);

  final double temperature;
  final double topP;
  final int topK;
  final double minP;
  final double dryMultiplier;
}

/// The sampling values the user set in the settings for the model that answers; null where the
/// user set nothing. [GenerateRequest.sampling] and `maxTokens` already contain the app's defaults,
/// so the engine needs this to tell "the user chose it" from "nobody chose it" (the maker's
/// recommendation applies to the second only).
class UserSampling {
  const UserSampling({this.temperature, this.topP, this.maxTokens, this.speedAccuracy = 0.5, this.useModelMax = false});

  final double? temperature;
  final double? topP;

  /// The reply length the user set, before "速度⇔精度" scaled it into [GenerateRequest.maxTokens].
  final int? maxTokens;

  /// With no [maxTokens] set, ask for the model's own largest reply when it is known (online models).
  final bool useModelMax;

  /// The 速度⇔精度 slider (0 fast … 1 accurate), which also sets how hard a reasoning model thinks.
  final double speedAccuracy;
}

class GenerateRequest {
  const GenerateRequest({
    required this.prompt,
    required this.toolCallSchema,
    required this.thinking,
    required this.maxTokens,
    required this.sampling,
    this.strictJsonSchema,
    this.tools = const [],
    this.images = const {},
    this.agentId,
    this.continuation = false,
    this.user = const UserSampling(),
    this.assistantReasoning = const [],
    this.abort,
    this.conversationKey,
  });

  final String prompt;

  /// Names the conversation this request is part of (the same for all of its requests); an online
  /// provider whose prompt-cache switch is on sends it as its cache hint. Null for the app's own
  /// short requests.
  final String? conversationKey;

  /// Completes when the user stops the reply. An online request that is waiting for the model's
  /// next word (a model that thinks sends nothing for a long time) is dropped at once, instead of
  /// when the next word arrives. Null for a request nobody stops.
  final Future<void>? abort;

  /// This request, with [abort] set.
  GenerateRequest withAbort(Future<void> abort) => GenerateRequest(
        prompt: prompt,
        toolCallSchema: toolCallSchema,
        thinking: thinking,
        maxTokens: maxTokens,
        sampling: sampling,
        strictJsonSchema: strictJsonSchema,
        tools: tools,
        images: images,
        agentId: agentId,
        continuation: continuation,
        user: user,
        assistantReasoning: assistantReasoning,
        abort: abort,
        conversationKey: conversationKey,
      );

  /// What the model thought before each earlier reply, oldest first, one entry per assistant turn
  /// of the prompt (empty when it did not think). The prompt text never carries it; only an
  /// engine whose provider takes it back reads it.
  final List<String> assistantReasoning;

  /// The agent this reply is for; null for the app's own short requests (choosing an agent).
  final String? agentId;

  /// The reply continues one that was cut off, so it must stay with the engine that began it.
  final bool continuation;

  /// What the user chose in the settings; see [UserSampling].
  final UserSampling user;

  /// The pictures the prompt marks (see `ImageMarker`), by id. Only an engine whose model can see
  /// reads them; the device engine ignores them.
  final Map<String, ImageData> images;

  /// JSON Schema of an allowed tool call; null means the agent has no tools and no grammar is applied.
  final String? toolCallSchema;
  final bool thinking;
  final int maxTokens;
  final SamplingParams sampling;

  /// JSON Schema the whole output must match (no lazy trigger); used for short classifications.
  final String? strictJsonSchema;

  /// The same tools [toolCallSchema] describes, in a form a cloud provider can take as function
  /// calling. The device engine ignores it: there the schema alone constrains the output.
  final List<ToolDefinition> tools;
}

sealed class GenerationEvent {
  const GenerationEvent();
}

class Piece extends GenerationEvent {
  const Piece(this.text);
  final String text;
}

/// What a provider reported about the request that just ended. [cachedTokens] is how much of the
/// prompt it read from its own cache (prompt caching), null when it says nothing about that.
class Usage extends GenerationEvent {
  const Usage({this.promptTokens, this.completionTokens, this.cachedTokens});
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;
}

class Finished extends GenerationEvent {
  const Finished(this.reason);
  final FinishReason reason;
}

class EngineException implements Exception {
  EngineException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Common surface of all inference backends, so chat, agents and Generation Tasks never
/// depend on a specific engine.
abstract interface class InferenceEngine {
  bool get isLoaded;
  Future<void> load(LoadParams params);
  Stream<GenerationEvent> generate(GenerateRequest request);

  /// Stops the running generation; the stream then ends with [FinishReason.cancelled].
  void cancel();
  Future<void> unload();
}
