package ai.arce.app.bridge

import ai.arce.app.engine.EngineException
import ai.arce.app.engine.FinishReason
import ai.arce.app.engine.GenerateRequest
import ai.arce.app.engine.GenerationEvent
import ai.arce.app.engine.KvCacheType
import ai.arce.app.engine.LiteRtEngine
import ai.arce.app.engine.LlamaCppEngine
import ai.arce.app.engine.LoadParams
import ai.arce.app.engine.RoutingEngine
import ai.arce.app.engine.SamplingParams
import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Exposes the on-device engines to Flutter.
 *
 * Calls come in on `ai.arce.app/engine`; generated text goes back on the event channel as
 * `{id, type: piece|done|error, ...}` maps, one stream for all generations, told apart by id.
 */
class EngineBridge(context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val llama = LlamaCppEngine()
    private val engine = RoutingEngine(llama, LiteRtEngine(context))
    private var sink: EventChannel.EventSink? = null

    init {
        MethodChannel(messenger, "ai.arce.app/engine").setMethodCallHandler(this)
        EventChannel(messenger, "ai.arce.app/engine/events").setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "devices" -> scope.launch {
                // the native library may be missing on an unsupported ABI; no devices then
                result.success(runCatching { llama.devices() }.getOrDefault(emptyList<String>()))
            }
            "load" -> scope.launch {
                try {
                    engine.load(
                        LoadParams(
                            path = call.argument<String>("path")!!,
                            contextLength = call.argument<Int>("contextLength") ?: 4096,
                            threads = call.argument<Int>("threads") ?: 4,
                            batchSize = call.argument<Int>("batchSize") ?: 0,
                            gpuLayers = call.argument<Int>("gpuLayers") ?: 0,
                            kvCache = KvCacheType.entries.firstOrNull { it.code == call.argument<Int>("kvType") }
                                ?: KvCacheType.F16,
                        ),
                    )
                    result.success(mapOf("backend" to engine.activeName))
                } catch (e: Throwable) {
                    result.error("load_failed", e.message ?: e.javaClass.simpleName, null)
                }
            }
            "generate" -> {
                val id = call.argument<Int>("id")!!
                val request = GenerateRequest(
                    prompt = call.argument<String>("prompt")!!,
                    toolCallSchema = call.argument<String>("toolSchema"),
                    thinking = call.argument<Boolean>("thinking") ?: false,
                    maxTokens = call.argument<Int>("maxTokens") ?: 2048,
                    sampling = SamplingParams(
                        temperature = (call.argument<Double>("temperature") ?: 0.7).toFloat(),
                        topP = (call.argument<Double>("topP") ?: 0.8).toFloat(),
                        topK = call.argument<Int>("topK") ?: 20,
                        minP = (call.argument<Double>("minP") ?: 0.0).toFloat(),
                        dryMultiplier = (call.argument<Double>("dry") ?: 0.0).toFloat(),
                    ),
                    strictJsonSchema = call.argument<String>("strictSchema"),
                )
                result.success(null)
                scope.launch { runGeneration(id, request) }
            }
            "saveState" -> scope.launch {
                // the file is only a cache: a failure is "nothing saved", never an error for the chat
                val bytes = runCatching {
                    engine.saveState(call.argument<String>("path")!!, call.argument<Int>("minTokens") ?: 0)
                }.getOrDefault(0L)
                result.success(bytes)
            }
            "loadState" -> scope.launch {
                val tokens = runCatching { engine.loadState(call.argument<String>("path")!!) }.getOrDefault(0L)
                result.success(tokens)
            }
            "cancel" -> {
                engine.cancel()
                result.success(null)
            }
            "unload" -> scope.launch {
                runCatching { engine.unload() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private suspend fun runGeneration(id: Int, request: GenerateRequest) {
        try {
            engine.generate(request).collect { event ->
                when (event) {
                    is GenerationEvent.Piece -> emit(mapOf("id" to id, "type" to "piece", "text" to event.text))
                    is GenerationEvent.Finished -> emit(mapOf("id" to id, "type" to "done", "reason" to reasonName(event.reason)))
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            val message = if (e is EngineException) e.message else e.message ?: e.javaClass.simpleName
            emit(mapOf("id" to id, "type" to "error", "message" to message))
        }
    }

    private fun emit(event: Map<String, Any?>) {
        sink?.success(event)
    }

    private fun reasonName(reason: FinishReason) = when (reason) {
        FinishReason.EOG -> "eog"
        FinishReason.LENGTH -> "length"
        FinishReason.CANCELLED -> "cancelled"
        FinishReason.ERROR -> "error"
    }

    fun close() {
        engine.cancel()
        scope.cancel()
    }
}
