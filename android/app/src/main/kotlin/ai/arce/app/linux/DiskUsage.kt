package ai.arce.app.linux

import java.io.File
import java.nio.file.Files

/**
 * How much room a folder takes, counted the way the disk does: every file and folder takes whole 4 KiB
 * blocks, so a million empty files are not "free". Symbolic links are counted as links and never
 * followed (a link to `/` must not make the workspace look as big as the device). No Android classes.
 *
 * Delete with [delete] / [clear], never with Kotlin's `File.deleteRecursively()`: that one follows a
 * symbolic link to a folder and deletes what is behind it (it once wiped a whole file system that way).
 */
object DiskUsage {
    private const val BLOCK = 4096L

    /** The size of [root], or more than [stopAfter] as soon as it is known to be over it (the walk ends there). */
    fun sizeOf(root: File, stopAfter: Long = Long.MAX_VALUE): Long {
        if (!root.exists()) return 0
        var total = 0L
        val pending = ArrayDeque<File>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            val dir = pending.removeLast()
            total += BLOCK
            val children = dir.listFiles() ?: continue
            for (child in children) {
                val path = child.toPath()
                if (Files.isSymbolicLink(path)) {
                    total += BLOCK
                } else if (child.isDirectory) {
                    pending.add(child)
                } else {
                    total += blocks(child.length())
                }
                if (total > stopAfter) return total
            }
        }
        return total
    }

    private fun blocks(length: Long): Long = if (length <= 0) BLOCK else (length + BLOCK - 1) / BLOCK * BLOCK

    /** Deletes everything inside [dir] (not [dir]), without following links. */
    fun clear(dir: File) {
        val children = dir.listFiles() ?: return
        for (child in children) delete(child)
    }

    /** Deletes [file] and what is inside it; a symbolic link is removed as a link, whatever it points at. */
    fun delete(file: File) {
        if (!Files.isSymbolicLink(file.toPath()) && file.isDirectory) {
            file.setWritable(true, true)
            file.setExecutable(true, true)
            file.listFiles()?.forEach { delete(it) }
        }
        file.delete()
    }
}
