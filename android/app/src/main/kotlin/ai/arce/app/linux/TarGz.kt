package ai.arce.app.linux

import java.io.BufferedInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.Paths
import java.util.zip.GZIPInputStream

/**
 * Unpacks a `.tar.gz` (the root file system of the Linux environment) into a folder, and refuses what
 * could write outside of it: a name with `..`, a path that goes through a symbolic link, and more
 * bytes than the limit. Read: ustar, GNU long names (`L` / `K`) and pax headers (`x` / `g`), which is
 * what GNU tar and the Ubuntu images use. No Android classes, so it runs on a plain JVM.
 *
 * Symbolic links are created as they are, absolute targets too: they are meant to be followed from
 * inside the root file system (proot), never from outside, and no later entry may go through one.
 * Devices and pipes are skipped (the root file system gets `/dev` from the device through proot).
 */
object TarGz {
    class Result(val files: Int, val dirs: Int, val links: Int, val bytes: Long, val skipped: List<String>)

    private const val BLOCK = 512

    fun extract(archive: File, dest: File, maxBytes: Long, onProgress: ((Long) -> Unit)? = null): Result {
        dest.mkdirs()
        val root = dest.canonicalFile
        var files = 0
        var dirs = 0
        var links = 0
        var written = 0L
        val skipped = mutableListOf<String>()
        var pendingName: String? = null
        var pendingLink: String? = null
        var pax: Map<String, String> = emptyMap()

        GZIPInputStream(BufferedInputStream(FileInputStream(archive), 1 shl 16)).use { input ->
            val header = ByteArray(BLOCK)
            while (true) {
                if (!readBlock(input, header)) break
                if (header.all { it == 0.toByte() }) break
                checkChecksum(header)
                val type = header[156].toInt().toChar()
                var size = parseNumber(header, 124, 12)
                var name = pendingName ?: pax["path"] ?: entryName(header)
                var linkName = pendingLink ?: pax["linkpath"] ?: field(header, 157, 100)
                pax["size"]?.toLongOrNull()?.let { size = it }
                val mode = parseNumber(header, 100, 8).toInt()

                when (type) {
                    'L' -> { pendingName = readText(input, size); continue }
                    'K' -> { pendingLink = readText(input, size); continue }
                    'x' -> { pax = parsePax(readText(input, size)); continue }
                    'g' -> { skipData(input, size); continue }
                }
                pendingName = null
                pendingLink = null
                pax = emptyMap()

                val relative = cleanName(name)
                if (relative == null) {
                    skipData(input, size)
                    continue
                }
                val target = File(root, relative)
                if (!isInside(root, target) || passesThroughLink(root, target)) {
                    throw IOException("unsafe entry in the archive: $name")
                }
                when (type) {
                    '5' -> {
                        target.mkdirs()
                        applyMode(target, mode, directory = true)
                        dirs++
                    }
                    '0', '\u0000', '7' -> {
                        if (written + size > maxBytes) throw IOException("the archive holds more than $maxBytes bytes")
                        target.parentFile?.mkdirs()
                        if (target.exists() || Files.isSymbolicLink(target.toPath())) target.delete()
                        copyData(input, target, size)
                        applyMode(target, mode, directory = false)
                        written += size
                        files++
                        onProgress?.invoke(written)
                    }
                    '2' -> {
                        skipData(input, size)
                        target.parentFile?.mkdirs()
                        if (target.exists() || Files.isSymbolicLink(target.toPath())) target.delete()
                        Files.createSymbolicLink(target.toPath(), Paths.get(linkName))
                        links++
                    }
                    '1' -> {
                        skipData(input, size)
                        val source = cleanName(linkName)?.let { File(root, it) }
                        if (source == null || !isInside(root, source) || passesThroughLink(root, source) || !source.isFile) {
                            throw IOException("unsafe hard link in the archive: $name -> $linkName")
                        }
                        target.parentFile?.mkdirs()
                        if (target.exists()) target.delete()
                        try {
                            Files.createLink(target.toPath(), source.toPath())
                        } catch (e: IOException) {
                            source.copyTo(target, overwrite = true)
                        } catch (e: UnsupportedOperationException) {
                            source.copyTo(target, overwrite = true)
                        }
                        links++
                    }
                    else -> {
                        skipData(input, size)
                        skipped += "$name (type $type)"
                    }
                }
            }
        }
        return Result(files, dirs, links, written, skipped)
    }

    /** `./etc/x` -> `etc/x`; null for the root itself; throws for `..` or an empty name. */
    internal fun cleanName(raw: String): String? {
        var name = raw.trimEnd('\u0000')
        while (name.startsWith("./")) name = name.substring(2)
        name = name.trimStart('/').trimEnd('/')
        if (name.isEmpty() || name == ".") return null
        if (name.split('/').any { it == ".." }) throw IOException("unsafe name in the archive: $raw")
        if (name.contains('\u0000')) throw IOException("unsafe name in the archive: $raw")
        return name
    }

    private fun isInside(root: File, file: File): Boolean {
        val path = file.absoluteFile.toPath().normalize()
        return path.startsWith(root.toPath())
    }

    /** Whether a folder on the way to [target] (below [root]) is a symbolic link. */
    private fun passesThroughLink(root: File, target: File): Boolean {
        var current = target.parentFile
        while (current != null && current != root) {
            if (Files.isSymbolicLink(current.toPath())) return true
            current = current.parentFile
        }
        return false
    }

    /** The user can read, write and enter what is unpacked (the app is the only user); the other bits do not exist for it. */
    private fun applyMode(file: File, mode: Int, directory: Boolean) {
        file.setReadable(true, true)
        file.setWritable(true, true)
        if (directory || (mode and 0b001_001_001) != 0) file.setExecutable(true, true)
    }

    private fun entryName(header: ByteArray): String {
        val name = field(header, 0, 100)
        val magic = field(header, 257, 6)
        if (magic.startsWith("ustar")) {
            val prefix = field(header, 345, 155)
            if (prefix.isNotEmpty()) return "$prefix/$name"
        }
        return name
    }

    private fun field(header: ByteArray, offset: Int, length: Int): String {
        var end = offset
        while (end < offset + length && header[end] != 0.toByte()) end++
        return String(header, offset, end - offset, Charsets.UTF_8)
    }

    private fun parseNumber(header: ByteArray, offset: Int, length: Int): Long {
        // base-256 for sizes over 8 GiB (a high bit in the first byte)
        if ((header[offset].toInt() and 0x80) != 0) {
            var value = (header[offset].toInt() and 0x7f).toLong()
            for (i in 1 until length) value = (value shl 8) or (header[offset + i].toLong() and 0xff)
            return value
        }
        val text = field(header, offset, length).trim()
        return if (text.isEmpty()) 0 else text.toLong(8)
    }

    private fun checkChecksum(header: ByteArray) {
        var sum = 0L
        for (i in 0 until BLOCK) sum += if (i in 148 until 156) 32 else (header[i].toLong() and 0xff)
        val stored = field(header, 148, 8).trim()
        if (stored.isEmpty() || stored.toLongOrNull(8) != sum) throw IOException("the archive is damaged (bad header)")
    }

    private fun parsePax(text: String): Map<String, String> {
        val out = mutableMapOf<String, String>()
        val bytes = text.toByteArray(Charsets.UTF_8)
        var at = 0
        while (at < bytes.size) {
            var space = at
            while (space < bytes.size && bytes[space] != ' '.code.toByte()) space++
            val length = String(bytes, at, space - at, Charsets.UTF_8).toIntOrNull() ?: break
            if (length <= 0 || at + length > bytes.size) break
            val record = String(bytes, space + 1, at + length - space - 2, Charsets.UTF_8)
            val eq = record.indexOf('=')
            if (eq > 0) out[record.substring(0, eq)] = record.substring(eq + 1)
            at += length
        }
        return out
    }

    private fun readBlock(input: InputStream, buffer: ByteArray): Boolean {
        var read = 0
        while (read < buffer.size) {
            val n = input.read(buffer, read, buffer.size - read)
            if (n < 0) {
                if (read == 0) return false
                throw EOFException("the archive ends in the middle of a header")
            }
            read += n
        }
        return true
    }

    private fun padding(size: Long): Long = (BLOCK - size % BLOCK) % BLOCK

    private fun skipData(input: InputStream, size: Long) {
        var left = size + padding(size)
        val buffer = ByteArray(1 shl 14)
        while (left > 0) {
            val n = input.read(buffer, 0, minOf(left, buffer.size.toLong()).toInt())
            if (n < 0) throw EOFException("the archive ends in the middle of an entry")
            left -= n
        }
    }

    private fun readText(input: InputStream, size: Long): String {
        if (size > 1 shl 20) throw IOException("a header record is too long")
        val bytes = ByteArray(size.toInt())
        var read = 0
        while (read < bytes.size) {
            val n = input.read(bytes, read, bytes.size - read)
            if (n < 0) throw EOFException("the archive ends in the middle of a header record")
            read += n
        }
        var pad = padding(size)
        while (pad > 0) { if (input.read() < 0) throw EOFException(); pad-- }
        return String(bytes, Charsets.UTF_8).trimEnd('\u0000', '\n')
    }

    private fun copyData(input: InputStream, target: File, size: Long) {
        target.outputStream().buffered(1 shl 16).use { out ->
            val buffer = ByteArray(1 shl 16)
            var left = size
            while (left > 0) {
                val n = input.read(buffer, 0, minOf(left, buffer.size.toLong()).toInt())
                if (n < 0) throw EOFException("the archive ends in the middle of a file")
                out.write(buffer, 0, n)
                left -= n
            }
        }
        var pad = padding(size)
        while (pad > 0) {
            if (input.read() < 0) throw EOFException("the archive ends in the middle of a file")
            pad--
        }
    }
}
