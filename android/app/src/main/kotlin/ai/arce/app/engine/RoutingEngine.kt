package ai.arce.app.engine

import kotlinx.coroutines.flow.Flow

/**
 * Picks the backend from the model file: `.litertlm` goes to LiteRT-LM (CPU/GPU/NPU),
 * everything else (GGUF) to llama.cpp. Only one model is loaded at a time.
 */
class RoutingEngine(val llama: LlamaCppEngine, val liteRt: LiteRtEngine) : InferenceEngine {
    @Volatile private var active: InferenceEngine? = null

    override val isLoaded: Boolean get() = active?.isLoaded == true

    /** "llama.cpp" or "LiteRT-LM (GPU)" for the status line. */
    val activeName: String?
        get() = when (active) {
            null -> null
            liteRt -> "LiteRT-LM" + (liteRt.backendName?.let { " ($it)" } ?: "")
            else -> "llama.cpp"
        }

    override suspend fun load(params: LoadParams) {
        val target = if (params.path.endsWith(".litertlm", ignoreCase = true)) liteRt else llama
        // Free the other backend first so two models never share RAM.
        (if (target === liteRt) llama else liteRt).takeIf { it.isLoaded }?.unload()
        active = null
        target.load(params)
        active = target
    }

    override fun generate(request: GenerateRequest): Flow<GenerationEvent> =
        (active ?: error("no model loaded")).generate(request)

    override fun cancel() {
        active?.cancel()
    }

    override suspend fun saveState(path: String, minTokens: Int): Long =
        active?.saveState(path, minTokens) ?: 0L

    override suspend fun loadState(path: String): Long = active?.loadState(path) ?: 0L

    override suspend fun unload() {
        active?.unload()
        active = null
    }
}
