package ai.arce.app.linux

import android.content.Context
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Starts the proot that CI built and packaged as a native library (`libproot.so`, with its loader
 * `libproot_loader.so`), to show on a real device whether it runs at all. An executable can be started
 * only from a file on disk, so the libraries are extracted at install time (`useLegacyPackaging`) and
 * live in `nativeLibraryDir`; Android 10+ refuses to execute files from the app's own data folder.
 *
 * It runs nothing but `proot --version` and `proot -r / /system/bin/echo ok` (system root, system
 * binary): it needs no root file system, and shows whether ptrace and seccomp are allowed.
 */
object ProotProbe {
    private const val TIMEOUT_SECONDS = 10L
    private const val OUTPUT_LIMIT = 4000

    fun run(context: Context): Map<String, Any?> {
        val dir = File(context.applicationInfo.nativeLibraryDir)
        val proot = File(dir, "libproot.so")
        val loader = File(dir, "libproot_loader.so")
        val result = mutableMapOf<String, Any?>(
            "dir" to dir.path,
            "files" to (dir.list()?.sorted() ?: emptyList<String>()),
            "present" to (proot.isFile && loader.isFile),
        )
        if (result["present"] != true) return result
        val tmp = File(context.cacheDir, "proot-tmp").apply { mkdirs() }
        val env = mapOf("PROOT_LOADER" to loader.path, "PROOT_TMP_DIR" to tmp.path)
        val steps = mutableListOf<Map<String, Any?>>()
        steps += step("--version", listOf(proot.path, "--version"), env)
        steps += step("-r / echo", listOf(proot.path, "-r", "/", "/system/bin/echo", "ok"), env)
        // some devices refuse the seccomp filter proot uses to speed up; proot can do without it
        if (steps.last()["exit"] != 0) {
            steps += step("-r / echo (no seccomp)", listOf(proot.path, "-r", "/", "/system/bin/echo", "ok"), env + ("PROOT_NO_SECCOMP" to "1"))
        }
        result["steps"] = steps
        return result
    }

    private fun step(name: String, command: List<String>, env: Map<String, String>): Map<String, Any?> {
        return try {
            val builder = ProcessBuilder(command).redirectErrorStream(true)
            builder.environment().putAll(env)
            val process = builder.start()
            if (!process.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS)) {
                process.destroyForcibly()
                return mapOf("name" to name, "exit" to -1, "output" to "no answer in $TIMEOUT_SECONDS s")
            }
            val output = process.inputStream.readBytes().decodeToString().take(OUTPUT_LIMIT)
            mapOf("name" to name, "exit" to process.exitValue(), "output" to output)
        } catch (e: Throwable) {
            mapOf("name" to name, "exit" to -1, "output" to "${e.javaClass.simpleName}: ${e.message}")
        }
    }
}
