package ai.arce.app.engine

import android.content.Context
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.ResponseCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Session
import com.google.ai.edge.litertlm.SessionConfig
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext

/**
 * LiteRT-LM backend for `.litertlm` models: CPU, GPU, or the NPU for SoC-specific builds.
 *
 * It uses a raw Session instead of a Conversation, so the prompt built by ChatMlPromptBuilder
 * is passed through unchanged and chat, tools and Thinking behave as with llama.cpp.
 * LiteRT-LM has no GBNF support: tool-call JSON is not grammar-constrained here and relies on
 * ToolCallParser's validation and the retry policy.
 */
class LiteRtEngine(private val context: Context) : InferenceEngine {
    private val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "litert") }.asCoroutineDispatcher()

    @Volatile private var engine: Engine? = null
    @Volatile private var session: Session? = null

    /** Which accelerator the current model runs on, for the status line and diagnostics. */
    @Volatile var backendName: String? = null
        private set

    override val isLoaded: Boolean get() = engine != null

    override suspend fun load(params: LoadParams) = withContext(dispatcher) {
        release()
        val candidates = buildList {
            // NPU builds carry their SoC vendor in the file name (e.g. Qwen3-0.6B.mediatek.mt6993.litertlm)
            if (params.path.contains(".mediatek.") || params.path.contains(".qualcomm.")) {
                add(Backend.NPU(nativeLibraryDir = context.applicationInfo.nativeLibraryDir))
            }
            if (params.gpuLayers > 0) add(Backend.GPU())
            add(Backend.CPU(threadCount = params.threads))
        }
        var lastError: Throwable? = null
        for (backend in candidates) {
            try {
                val e = Engine(EngineConfig(modelPath = params.path, backend = backend, maxNumTokens = params.contextLength, cacheDir = context.cacheDir.absolutePath))
                e.initialize()
                engine = e
                backendName = backend.javaClass.simpleName
                return@withContext
            } catch (t: Throwable) {
                // An unsupported accelerator falls back to the next one (NPU -> GPU -> CPU).
                lastError = t
            }
        }
        throw EngineException("LiteRT-LM could not load the model: ${lastError?.message}")
    }

    override fun generate(request: GenerateRequest): Flow<GenerationEvent> = callbackFlow {
        val e = engine ?: throw EngineException("no model loaded")
        val s = e.createSession(
            SessionConfig(samplerConfig = SamplerConfig(request.sampling.topK, request.sampling.topP.toDouble(), request.sampling.temperature.toDouble())),
        )
        session = s
        val finished = AtomicBoolean(false)
        var pieces = 0
        fun finish(reason: FinishReason) {
            if (finished.compareAndSet(false, true)) {
                trySend(GenerationEvent.Finished(reason))
                close()
            }
        }
        s.generateContentStream(listOf(InputData.Text(request.prompt)), object : ResponseCallback {
            override fun onNext(response: String) {
                if (finished.get()) return
                trySend(GenerationEvent.Piece(response))
                // LiteRT-LM has no per-call token limit on a Session; count streamed pieces instead.
                if (++pieces >= request.maxTokens) {
                    s.cancelProcess()
                    finish(FinishReason.LENGTH)
                }
            }
            override fun onDone() = finish(FinishReason.EOG)
            override fun onError(throwable: Throwable) {
                if (throwable is java.util.concurrent.CancellationException) finish(FinishReason.CANCELLED)
                else if (finished.compareAndSet(false, true)) close(EngineException(throwable.message ?: "LiteRT-LM error"))
            }
        })
        awaitClose {
            if (!finished.get()) s.cancelProcess()
            session = null
            runCatching { s.close() }
        }
    }.flowOn(dispatcher)

    override fun cancel() {
        session?.cancelProcess()
    }

    override suspend fun unload() = withContext(dispatcher) { release() }

    private fun release() {
        session?.let { runCatching { it.close() } }
        session = null
        engine?.let { runCatching { it.close() } }
        engine = null
        backendName = null
    }
}
