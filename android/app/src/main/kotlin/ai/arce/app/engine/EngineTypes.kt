package ai.arce.app.engine

import kotlinx.coroutines.flow.Flow

/** How the KV cache is stored: F16 (full), Q8_0 (about half the memory), Q4_0 (about a third). */
enum class KvCacheType(val code: Int) { F16(0), Q8_0(1), Q4_0(2) }

/** Why the native side stopped producing tokens. */
enum class FinishReason { EOG, LENGTH, CANCELLED, ERROR }

data class LoadParams(
    val path: String,
    val contextLength: Int = 4096,
    val threads: Int = 4,
    /** 0 = llama.cpp default. */
    val batchSize: Int = 0,
    val gpuLayers: Int = 0,
    val kvCache: KvCacheType = KvCacheType.F16,
)

data class SamplingParams(
    val temperature: Float,
    val topP: Float,
    val topK: Int,
    val minP: Float,
    /** 0 disables DRY; it discourages repeating earlier phrases. */
    val dryMultiplier: Float = 0.8f,
)

data class GenerateRequest(
    val prompt: String,
    /** JSON Schema of an allowed tool call; null means no grammar is applied. */
    val toolCallSchema: String?,
    val thinking: Boolean,
    val maxTokens: Int,
    val sampling: SamplingParams,
    /** JSON Schema the whole output must match (no lazy trigger); used for short classifications. */
    val strictJsonSchema: String? = null,
)

sealed interface GenerationEvent {
    data class Piece(val text: String) : GenerationEvent
    data class Finished(val reason: FinishReason) : GenerationEvent
}

class EngineException(message: String) : Exception(message)

/** Common surface of the inference backends (llama.cpp and LiteRT-LM). */
interface InferenceEngine {
    val isLoaded: Boolean
    suspend fun load(params: LoadParams)
    fun generate(request: GenerateRequest): Flow<GenerationEvent>
    /** Stops the running generation from any thread. */
    fun cancel()
    suspend fun unload()

    /** Saves the KV entries of the last prompt to [path]; the bytes written, or 0 when unsupported. */
    suspend fun saveState(path: String, minTokens: Int): Long = 0L

    /** Restores what [saveState] wrote; the tokens restored, or 0 when unsupported or refused. */
    suspend fun loadState(path: String): Long = 0L
}
