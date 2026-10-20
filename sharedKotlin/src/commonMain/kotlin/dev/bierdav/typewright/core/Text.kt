@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** A UTF-16 range, the unit of NSString, JavaScript strings and LSP. */
data class TextRange(val location: Int, val length: Int) {
    val end: Int get() = location + length
}

/** A zero-based LSP position. */
data class TextPosition(val line: Int, val character: Int)

/** A replacement of a UTF-16 range, from formatting or renaming. */
data class TextEdit(val range: TextRange, val newText: String)

object TextEdits {
    /** Applies edits that don't overlap; later ones first so earlier ranges stay valid. */
    fun apply(edits: List<TextEdit>, text: String): String {
        val result = StringBuilder(text)
        for (edit in edits.sortedByDescending { it.range.location }) {
            if (edit.range.location < 0 || edit.range.end > result.length) continue
            result.setRange(edit.range.location, edit.range.end, edit.newText)
        }
        return result.toString()
    }

    /** The one edit that turns `old` into `new`: everything between their common start and end, never splitting a surrogate pair. */
    fun difference(old: String, new: String): TextEdit {
        var start = 0
        while (start < old.length && start < new.length && old[start] == new[start]) start++
        if (start > 0 && old[start - 1].isHighSurrogate()) start--
        var end = 0
        while (end < old.length - start && end < new.length - start && old[old.length - 1 - end] == new[new.length - 1 - end]) end++
        if (end > 0 && old[old.length - end].isLowSurrogate()) end--
        return TextEdit(TextRange(start, old.length - end - start), new.substring(start, new.length - end))
    }
}

object TextPositions {
    fun position(offset: Int, text: String): TextPosition {
        val end = offset.coerceIn(0, text.length)
        var line = 0
        var lineStart = 0
        for (i in 0 until end) {
            if (text[i] == '\n') {
                line++
                lineStart = i + 1
            }
        }
        return TextPosition(line, end - lineStart)
    }

    fun offset(line: Int, character: Int, text: String): Int {
        var current = 0
        var index = 0
        while (current < line && index < text.length) {
            if (text[index] == '\n') current++
            index++
        }
        return minOf(index + character, text.length)
    }

    fun range(start: TextPosition, end: TextPosition, text: String): TextRange {
        val a = offset(start.line, start.character, text)
        val b = offset(end.line, end.character, text)
        return TextRange(a, maxOf(b - a, 0))
    }

    /** The line's text without its line break. */
    fun lineText(line: Int, text: String): String {
        val start = offset(line, 0, text)
        val end = lineEnd(start, text)
        return text.substring(start, end)
    }

    /** Range of the contents of the string literal around `offset` on its line. */
    fun stringLiteralRange(offset: Int, text: String): TextRange? {
        val clamped = offset.coerceIn(0, text.length)
        var index = lineStart(clamped, text)
        val end = lineEnd(clamped, text)
        var start = -1
        while (index < end) {
            when (text[index]) {
                // Skips the escaped character.
                '\\' -> { index += 2; continue }
                '"' -> if (start >= 0) {
                    if (offset in start..index) return TextRange(start, index - start)
                    start = -1
                } else {
                    start = index + 1
                }
            }
            index++
        }
        return null
    }

    private fun lineStart(offset: Int, text: String): Int {
        var i = offset
        while (i > 0 && !isBreak(text[i - 1])) i--
        return i
    }

    private fun lineEnd(offset: Int, text: String): Int {
        var i = offset
        while (i < text.length && !isBreak(text[i])) i++
        return i
    }

    private fun isBreak(c: Char) = c == '\n' || c == '\r' || c == ' ' || c == ' '
}
