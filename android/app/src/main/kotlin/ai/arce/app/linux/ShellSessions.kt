package ai.arce.app.linux

import java.io.IOException

/**
 * Commands that run for a long time and are talked to: a program that asks questions, a read-eval
 * loop, a command-line agent. Each one is a child process (proot, and inside it `script`, which gives the
 * program a pseudo terminal), whose output is kept in a ring buffer and whose input is written to its
 * stdin. The Dart side reads the buffer from an offset, so nothing is read twice or lost between two
 * reads (unless the program wrote more than the buffer holds: then [Chunk.lost] says so).
 *
 * Android classes are not used here, so it runs on a plain JVM too.
 */
class ShellSessions {
    /** What a read returns: the bytes since the offset asked for, and where the next read starts. */
    class Chunk(
        val data: ByteArray,
        val next: Long,
        /** Output between the offset asked for and [data] was overwritten before it was read. */
        val lost: Boolean,
        val alive: Boolean,
        val exit: Int?,
        /** Why the session was stopped by the app (`idle`, `workspace`, `stopped`), or null. */
        val stoppedBy: String?,
    )

    class Session internal constructor(
        val id: String,
        val command: String,
        private val process: Process,
        private val capacity: Int,
        val idleMs: Long,
    ) {
        private val lock = Object()
        private val buffer = ByteArray(capacity)
        private var total = 0L

        @Volatile var lastUsed = System.currentTimeMillis()
        @Volatile var stoppedBy: String? = null
        val startedAt = System.currentTimeMillis()

        init {
            Thread {
                val chunk = ByteArray(8192)
                try {
                    while (true) {
                        val n = process.inputStream.read(chunk)
                        if (n < 0) break
                        append(chunk, n)
                    }
                } catch (_: IOException) {
                    // the process is gone
                }
                synchronized(lock) { lock.notifyAll() }
            }.apply { isDaemon = true; name = "shell-session-$id"; start() }
        }

        private fun append(data: ByteArray, n: Int) {
            synchronized(lock) {
                for (i in 0 until n) buffer[((total + i) % capacity).toInt()] = data[i]
                total += n
                lock.notifyAll()
            }
        }

        val alive: Boolean get() = process.isAlive

        fun exitCode(): Int? = if (process.isAlive) null else process.exitValue()

        /**
         * The output since [from], waiting up to [waitMs] for some to come (and, once it does, until the
         * program has been quiet for [settleMs]: output arrives in bursts, and a reply is usually several).
         */
        fun read(from: Long, waitMs: Long, settleMs: Long): Chunk {
            lastUsed = System.currentTimeMillis()
            synchronized(lock) {
                val deadline = System.currentTimeMillis() + waitMs.coerceAtLeast(0)
                var seen = total
                // wait for the first output
                while (total <= from && process.isAlive) {
                    val left = deadline - System.currentTimeMillis()
                    if (left <= 0) break
                    lock.wait(left)
                }
                // then for a quiet moment
                if (total > from) {
                    while (process.isAlive) {
                        seen = total
                        val left = deadline - System.currentTimeMillis()
                        if (left <= 0) break
                        lock.wait(minOf(settleMs.coerceAtLeast(1), left))
                        if (total == seen) break
                    }
                }
                val oldest = (total - capacity).coerceAtLeast(0)
                val start = from.coerceIn(oldest, total)
                val lost = from < oldest
                val size = (total - start).toInt()
                val out = ByteArray(size)
                for (i in 0 until size) out[i] = buffer[((start + i) % capacity).toInt()]
                return Chunk(out, total, lost, process.isAlive, exitCode(), stoppedBy)
            }
        }

        fun write(bytes: ByteArray) {
            lastUsed = System.currentTimeMillis()
            if (!process.isAlive) throw IOException("the session has ended")
            process.outputStream.write(bytes)
            process.outputStream.flush()
        }

        fun stop(reason: String) {
            if (stoppedBy == null) stoppedBy = reason
            process.destroy()
            Thread {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                }
                if (process.isAlive) process.destroyForcibly()
            }.apply { isDaemon = true; start() }
        }
    }

    private val sessions = LinkedHashMap<String, Session>()
    private var counter = 0
    private var reaper: Thread? = null

    /** Starts [command line] as a session; throws when [maxSessions] are already running. */
    @Synchronized
    fun start(
        commandLine: List<String>,
        env: Map<String, String>,
        label: String,
        bufferBytes: Int,
        idleMs: Long,
        maxSessions: Int,
    ): Session {
        sessions.values.removeAll { !it.alive && System.currentTimeMillis() - it.lastUsed > 60_000 }
        val running = sessions.values.count { it.alive }
        if (running >= maxSessions) throw IOException("$running sessions are running already (the most allowed): stop one first")
        val builder = ProcessBuilder(commandLine).redirectErrorStream(true)
        builder.environment().clear()
        builder.environment().putAll(env)
        val process = builder.start()
        val id = "s${++counter}"
        val session = Session(id, label, process, bufferBytes.coerceAtLeast(4096), idleMs)
        sessions[id] = session
        startReaper()
        return session
    }

    @Synchronized
    fun get(id: String): Session = sessions[id] ?: throw IOException("there is no session $id")

    @Synchronized
    fun all(): List<Session> = sessions.values.toList()

    /** Stops every running session (the workspace is full, the environment is removed). */
    @Synchronized
    fun stopAll(reason: String) {
        for (s in sessions.values) if (s.alive) s.stop(reason)
    }

    @Synchronized
    fun anyAlive(): Boolean = sessions.values.any { it.alive }

    private fun startReaper() {
        if (reaper?.isAlive == true) return
        reaper = Thread {
            while (true) {
                try {
                    Thread.sleep(5000)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                val now = System.currentTimeMillis()
                synchronized(this) {
                    for (s in sessions.values) {
                        if (s.alive && s.idleMs > 0 && now - s.lastUsed > s.idleMs) s.stop("idle")
                    }
                    if (sessions.values.none { it.alive }) {
                        reaper = null
                        return@Thread
                    }
                }
            }
        }.apply { isDaemon = true; name = "shell-session-reaper"; start() }
    }
}
