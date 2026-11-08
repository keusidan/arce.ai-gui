package ai.arce.app.linux

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.util.concurrent.TimeUnit

/**
 * Runs one command as a child process with the limits a model's command needs: a time limit, a cap
 * on what is kept of the output (the start and the end; the middle is the part nobody reads), nothing
 * to read from the keyboard (the input is closed), and a watch that can end it (the workspace
 * growing past its limit). No Android classes: the command line is the caller's (proot, or a plain
 * shell in a test).
 */
class ShellRunner {
    class Request(
        val command: List<String>,
        val env: Map<String, String>,
        val timeoutMs: Long,
        val maxOutputBytes: Int,
        val workDir: File? = null,
        /** Asked every [watchEveryMs]; a text ends the command with that as the reason. */
        val watch: (() -> String?)? = null,
        val watchEveryMs: Long = 2000,
    )

    class Result(
        val exit: Int,
        val stdout: String,
        val stderr: String,
        val truncated: Boolean,
        /** `timeout`, the reason the watch gave, or null when it ended by itself. */
        val killedBy: String?,
        val elapsedMs: Long,
    )

    fun run(request: Request): Result {
        val started = System.nanoTime()
        val builder = ProcessBuilder(request.command)
        builder.environment().clear()
        builder.environment().putAll(request.env)
        request.workDir?.let { builder.directory(it) }
        val process = builder.start()
        process.outputStream.close()

        val half = (request.maxOutputBytes / 2).coerceAtLeast(1)
        val out = HeadTail(half, half)
        val err = HeadTail(half, half)
        val readers = listOf(
            Thread { out.drain(process.inputStream) }.apply { isDaemon = true; start() },
            Thread { err.drain(process.errorStream) }.apply { isDaemon = true; start() },
        )

        var killedBy: String? = null
        val deadline = started + request.timeoutMs * 1_000_000
        while (true) {
            val left = (deadline - System.nanoTime()) / 1_000_000
            if (left <= 0) { killedBy = "timeout"; break }
            val step = minOf(left, request.watchEveryMs)
            if (process.waitFor(step, TimeUnit.MILLISECONDS)) break
            val reason = request.watch?.invoke()
            if (reason != null) { killedBy = reason; break }
        }
        if (killedBy != null) {
            process.destroyForcibly()
            process.waitFor(5, TimeUnit.SECONDS)
        }
        // a child that outlives the shell may keep the pipes open: do not wait for ever
        readers.forEach { it.join(if (killedBy == null) 10_000 else 1_000) }
        val exit = if (process.isAlive) -1 else process.exitValue()
        return Result(
            exit = exit,
            stdout = out.text(),
            stderr = err.text(),
            truncated = out.dropped > 0 || err.dropped > 0,
            killedBy = killedBy,
            elapsedMs = (System.nanoTime() - started) / 1_000_000,
        )
    }

    /** Keeps the first [head] and the last [tail] bytes of a stream and counts the rest. */
    internal class HeadTail(private val head: Int, private val tail: Int) {
        private val first = ByteArrayOutputStream()
        private val ring = ByteArray(tail)
        private var ringLength = 0
        private var ringStart = 0
        @Volatile var dropped = 0L
            private set

        fun drain(input: InputStream) {
            val buffer = ByteArray(8192)
            try {
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    synchronized(this) { add(buffer, n) }
                }
            } catch (_: Exception) {
                // the stream closed under us (the process was killed)
            }
        }

        private fun add(bytes: ByteArray, n: Int) {
            var from = 0
            if (first.size() < head) {
                val take = minOf(head - first.size(), n)
                first.write(bytes, 0, take)
                from = take
            }
            for (i in from until n) {
                if (ringLength < ring.size) {
                    ring[(ringStart + ringLength) % ring.size] = bytes[i]
                    ringLength++
                } else {
                    ring[ringStart] = bytes[i]
                    ringStart = (ringStart + 1) % ring.size
                    dropped++
                }
            }
        }

        @Synchronized
        fun text(): String {
            val tailBytes = ByteArray(ringLength) { ring[(ringStart + it) % ring.size] }
            val middle = if (dropped > 0) "\n[… $dropped bytes omitted …]\n".toByteArray() else ByteArray(0)
            return String(first.toByteArray() + middle + tailBytes, Charsets.UTF_8)
        }
    }
}
