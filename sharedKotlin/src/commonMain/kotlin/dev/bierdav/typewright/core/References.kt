@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** A path literal in a Typst file that a move breaks, and what it should say afterwards. */
data class PathReference(
    /** The literal's contents, without the quotes. */
    val range: TextRange,
    val line: Int,
    val oldPath: String,
    val newPath: String,
    /** The path argument of `import`, `include`, `image`, `read` and the like; anything else may only look like a path. */
    val certain: Boolean,
    /** Inside a comment or raw text, so most likely not a live reference. */
    val inComment: Boolean,
)

object PathReferences {
    private val pathCalls = setOf("image", "read", "json", "csv", "yaml", "toml", "xml", "cbor", "bibliography", "plugin")
    private val pathKeywords = setOf("import", "include")

    /**
     * Literals in `text`, the Typst file at `file`, that point at `from` or into it, rewritten for its move to `to`.
     * The file itself may move along. Paths are relative to the space root; `exists` checks one before the move,
     * so only literals that point at something count.
     */
    fun moved(text: String, file: String, from: String, to: String, exists: (String) -> Boolean): List<PathReference> {
        val dir = parent(file)
        val newDir = parent(relocate(file, from, to))
        val result = mutableListOf<PathReference>()
        var line = 0
        var scanned = 0
        for (literal in literals(text)) {
            val value = text.substring(literal.start, literal.end)
            // Packages, URLs and escaped strings aren't plain file paths.
            if (value.isBlank() || value.startsWith("@") || value.contains("://") || value.contains('\\')) continue
            val absolute = value.startsWith("/")
            val target = resolve(value, dir) ?: continue
            if (target.isEmpty() || !exists(target)) continue
            val newTarget = relocate(target, from, to)
            // Moved together with its file, or not affected at all.
            if (resolve(value, newDir) == newTarget) continue
            var replacement = if (absolute) "/$newTarget" else relativePath(newDir, newTarget)
            if (value.startsWith("./") && !replacement.startsWith("../")) replacement = "./$replacement"
            if (value.endsWith("/") && !replacement.endsWith("/")) replacement += "/"
            for (i in scanned until literal.start) if (text[i] == '\n') line++
            scanned = literal.start
            result += PathReference(
                TextRange(literal.start, literal.end - literal.start), line, value, replacement,
                certain = literal.certain, inComment = literal.inComment,
            )
        }
        return result
    }

    /** Where `path` ends up when `from` moves to `to`. */
    fun relocate(path: String, from: String, to: String): String = when {
        path == from -> to
        path.startsWith("$from/") -> to + path.substring(from.length)
        else -> path
    }

    /** The path from the folder `dir` to `target`, both relative to the root. */
    fun relativePath(dir: String, target: String): String {
        val a = dir.split('/').filter { it.isNotEmpty() }
        val b = target.split('/').filter { it.isNotEmpty() }
        var common = 0
        while (common < a.size && common < b.size && a[common] == b[common]) common++
        return (List(a.size - common) { ".." } + b.drop(common)).joinToString("/")
    }

    /** A literal as typst reads it: from the root with a leading slash, else from the file's folder. null above the root. */
    private fun resolve(value: String, dir: String): String? {
        val path = if (value.startsWith("/")) value.drop(1) else if (dir.isEmpty()) value else "$dir/$value"
        val parts = mutableListOf<String>()
        for (part in path.split('/')) {
            when (part) {
                "", "." -> {}
                ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.size - 1)
                else -> parts += part
            }
        }
        return parts.joinToString("/")
    }

    private fun parent(path: String) = path.substringBeforeLast('/', "")

    private class Literal(val start: Int, val end: Int, val certain: Boolean, val inComment: Boolean)

    /** String literals with what surrounds them; a light scan of comments, raw text and strings, not a full parse. */
    private fun literals(text: String): List<Literal> {
        val result = mutableListOf<Literal>()
        var i = 0
        var blockDepth = 0
        var lineComment = false
        var rawFence = 0
        fun run(at: Int): Int {
            var n = 0
            while (at + n < text.length && text[at + n] == '`') n++
            return n
        }
        while (i < text.length) {
            val c = text[i]
            if (c == '\n') lineComment = false
            val quiet = rawFence > 0 || blockDepth > 0 || lineComment
            when {
                rawFence > 0 && c == '`' -> {
                    val n = run(i)
                    if (n >= rawFence) rawFence = 0
                    i += n
                    continue
                }
                blockDepth > 0 && text.startsWith("*/", i) -> { blockDepth--; i += 2; continue }
                rawFence == 0 && !lineComment && text.startsWith("/*", i) -> { blockDepth++; i += 2; continue }
                !quiet && text.startsWith("//", i) && (i == 0 || text[i - 1] != ':') -> { lineComment = true; i += 2; continue }
                !quiet && c == '\\' -> { i += 2; continue }
                !quiet && c == '`' -> {
                    val n = run(i)
                    // Two backticks are an empty raw.
                    if (n != 2) rawFence = n
                    i += n
                    continue
                }
                c == '"' -> {
                    val end = stringEnd(text, i)
                    if (end > 0) {
                        result += Literal(i + 1, end, !quiet && isPathArgument(text, i), quiet)
                        i = end + 1
                        continue
                    }
                }
            }
            i++
        }
        return result
    }

    /** The closing quote of the string opening at `start`, or -1 if it doesn't close on its line. */
    private fun stringEnd(text: String, start: Int): Int {
        var i = start + 1
        while (i < text.length) {
            when (text[i]) {
                '\\' -> i++
                '"' -> return i
                '\n' -> return -1
            }
            i++
        }
        return -1
    }

    /** Whether the string opening at `quote` follows `import`, `include` or opens a call like `image(`. */
    private fun isPathArgument(text: String, quote: Int): Boolean {
        var i = quote - 1
        while (i >= 0 && (text[i] == ' ' || text[i] == '\t')) i--
        val call = i >= 0 && text[i] == '('
        if (call) {
            i--
            while (i >= 0 && (text[i] == ' ' || text[i] == '\t')) i--
        }
        val end = i + 1
        while (i >= 0 && (text[i].isLetterOrDigit() || text[i] == '-' || text[i] == '_')) i--
        // A field access like `image.decode(` is another function.
        if (i >= 0 && text[i] == '.') return false
        val word = text.substring(i + 1, end)
        return if (call) word in pathCalls else word in pathKeywords
    }
}
