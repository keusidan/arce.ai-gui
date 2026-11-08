package ai.arce.app.bridge

import ai.arce.app.linux.LinuxEnv
import ai.arce.app.linux.ProotProbe
import ai.arce.app.service.GenerationService
import ai.arce.app.update.ApkInstaller
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Device facts, APK installation and the Linux environment, for the Dart side (`ai.arce.app/system`). */
class SystemBridge(private val context: Context, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val installer = ApkInstaller(context)

    /** proot runs as a child process, so the app's own folders are all it needs (see [LinuxEnv]). */
    private val linux by lazy {
        LinuxEnv(
            prootLibraryDir = File(context.applicationInfo.nativeLibraryDir),
            baseDir = context.filesDir,
            tmpDir = context.cacheDir,
        )
    }

    init {
        MethodChannel(messenger, "ai.arce.app/system").setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "memory" -> {
                    val manager = context.getSystemService(ActivityManager::class.java)
                    val info = ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
                    result.success(mapOf("total" to info.totalMem, "available" to info.availMem, "low" to info.lowMemory))
                }
                "freeStorage" -> {
                    val dir = File(call.argument<String>("path")!!)
                    // the model directory may not exist yet; ask about the closest folder that does
                    var existing: File? = dir
                    while (existing != null && !existing.exists()) existing = existing.parentFile
                    result.success(StatFs((existing ?: context.filesDir).absolutePath).availableBytes)
                }
                "soc" -> result.success("${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}")
                // The installed APK, which a delta update patches. A build installed from split APKs has no
                // single file that equals a release, so there is none to patch.
                "baseApk" -> {
                    val info = context.applicationInfo
                    result.success(if (info.splitSourceDirs.isNullOrEmpty()) info.sourceDir else null)
                }
                "canInstall" -> result.success(installer.canInstall())
                "requestInstall" -> {
                    context.startActivity(installer.permissionIntent())
                    result.success(null)
                }
                "install" -> {
                    installer.install(File(call.argument<String>("path")!!))
                    result.success(null)
                }
                "startForeground" -> {
                    val intent = Intent(context, GenerationService::class.java)
                        .setAction(GenerationService.ACTION_START)
                        .putExtra(GenerationService.EXTRA_KIND, call.argument<String>("kind"))
                    GenerationService.starting()
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(intent)
                        } else {
                            context.startService(intent)
                        }
                    } catch (e: Throwable) {
                        GenerationService.startFailed()
                        throw e
                    }
                    result.success(null)
                }
                // runs a child process for up to a few seconds: off the main thread
                "prootCheck" -> Thread {
                    val answer = try { ProotProbe.run(context) } catch (e: Throwable) { mapOf("error" to (e.message ?: e.javaClass.simpleName)) }
                    Handler(Looper.getMainLooper()).post { result.success(answer) }
                }.start()
                "stopForeground" -> {
                    // not while a start is still on its way: see GenerationService.mayStopNow
                    if (GenerationService.mayStopNow()) context.stopService(Intent(context, GenerationService::class.java))
                    result.success(null)
                }
                // The Linux environment. Every one of these reads or writes the file system and runs
                // child processes (proot, tar), so each runs on its own thread and answers on the main one.
                "linuxStatus" -> {
                    val limit = call.argument<Number>("workspaceLimitBytes")?.toLong() ?: 0L
                    offMain(result) { linux.status(limit) }
                }
                "linuxInstall" -> {
                    val archive = File(call.argument<String>("path")!!)
                    val sha256 = call.argument<String>("sha256")
                    val dns = call.argument<List<String>>("dns").orEmpty()
                    val maxBytes = call.argument<Number>("maxBytes")?.toLong() ?: 0L
                    offMain(result) {
                        // a zero limit would refuse every entry: 0 means "no limit" here, and the
                        // download already asked the device for the room
                        linux.install(archive, sha256, dns, maxBytes, null)
                    }
                }
                "linuxRemove" -> offMain(result) { linux.remove(); null }
                "workspaceClear" -> offMain(result) { linux.clearWorkspace(); null }
                "linuxRun" -> {
                    val params = LinuxEnv.RunParams(
                        command = call.argument<String>("command")!!,
                        cwd = call.argument<String>("cwd") ?: "/workspace",
                        timeoutSeconds = (call.argument<Number>("timeoutSeconds")?.toInt() ?: 120).coerceIn(1, 3600),
                        maxOutputChars = (call.argument<Number>("maxOutputChars")?.toInt() ?: 20000).coerceIn(500, 1000000),
                        workspaceLimitBytes = call.argument<Number>("workspaceLimitBytes")?.toLong() ?: 0L,
                        noSeccomp = call.argument<Boolean>("noSeccomp") == true,
                        secrets = call.argument<Map<String, String>>("secrets").orEmpty(),
                    )
                    offMain(result) { linux.run(params) }
                }
                // Sessions: a program that is talked to (a pseudo terminal under proot). Starting is quick, but
                // a read waits for output, so every one of these runs off the main thread.
                "linuxSessionStart" -> {
                    val params = LinuxEnv.SessionParams(
                        command = call.argument<String>("command")!!,
                        cwd = call.argument<String>("cwd") ?: "/workspace",
                        cols = call.argument<Number>("cols")?.toInt() ?: 120,
                        rows = call.argument<Number>("rows")?.toInt() ?: 40,
                        maxSessions = (call.argument<Number>("maxSessions")?.toInt() ?: 3).coerceIn(1, 20),
                        idleSeconds = (call.argument<Number>("idleSeconds")?.toInt() ?: 900).coerceIn(0, 86_400),
                        bufferKb = (call.argument<Number>("bufferKb")?.toInt() ?: 256).coerceIn(16, 8192),
                        workspaceLimitBytes = call.argument<Number>("workspaceLimitBytes")?.toLong() ?: 0L,
                        secrets = call.argument<Map<String, String>>("secrets").orEmpty(),
                        noSeccomp = call.argument<Boolean>("noSeccomp") == true,
                    )
                    offMain(result) { linux.startSession(params) }
                }
                "linuxSessionRead" -> {
                    val id = call.argument<String>("id")!!
                    val from = call.argument<Number>("from")?.toLong() ?: 0L
                    val waitMs = call.argument<Number>("waitMs")?.toLong() ?: 0L
                    val settleMs = call.argument<Number>("settleMs")?.toLong() ?: 300L
                    offMain(result) { linux.readSession(id, from, waitMs, settleMs) }
                }
                "linuxSessionWrite" -> {
                    val id = call.argument<String>("id")!!
                    val bytes = call.argument<ByteArray>("data")!!
                    offMain(result) { linux.writeSession(id, bytes); null }
                }
                "linuxSessionStop" -> {
                    val id = call.argument<String>("id")!!
                    offMain(result) { linux.stopSession(id); null }
                }
                "linuxSessionList" -> offMain(result) { linux.listSessions() }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("system_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    /** Runs [block] on its own thread and hands [result] its value (or an error) on the main thread. */
    private fun offMain(result: MethodChannel.Result, block: () -> Any?) {
        Thread {
            val handler = Handler(Looper.getMainLooper())
            try {
                val answer = block()
                handler.post { result.success(answer) }
            } catch (e: Throwable) {
                handler.post { result.error("linux_error", e.message ?: e.javaClass.simpleName, null) }
            }
        }.start()
    }
}
