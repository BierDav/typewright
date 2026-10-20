@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** A named argument of a call, like `unit` in `solve(x, unit: "min")`, and where its name stands. */
data class NamedArgument(val name: String, val range: TextRange)

object Arguments {
    private const val LOOKBACK = 4000

    /** The named argument whose name or value `offset` is in; null for positional arguments and outside calls. */
    fun namedArgument(text: String, offset: Int): NamedArgument? {
        val at = offset.coerceIn(0, text.length)
        // On the name itself, like hovering `unit`.
        var start = at
        var end = at
        while (start > 0 && isName(text[start - 1])) start--
        while (end < text.length && isName(text[end])) end++
        if (start < end && isKey(text, start, end)) return NamedArgument(text.substring(start, end), TextRange(start, end - start))
        // In the value: back to the comma or parenthesis that starts this argument.
        var i = at - 1
        var depth = 0
        // Inside a string when the line so far has an odd number of quotes; the scan flips at each one.
        var quoted = false
        var j = at - 1
        while (j >= 0 && text[j] != '\n') {
            if (text[j] == '"' && (j == 0 || text[j - 1] != '\\')) quoted = !quoted
            j--
        }
        val limit = maxOf(0, at - LOOKBACK)
        while (i >= limit) {
            val c = text[i]
            if (c == '"' && (i == 0 || text[i - 1] != '\\')) quoted = !quoted
            if (!quoted) {
                when (c) {
                    ')', ']', '}' -> depth++
                    '(', '[', '{' -> if (depth == 0) return if (c == '(') keyAfter(text, i + 1) else null else depth--
                    ',' -> if (depth == 0) return keyAfter(text, i + 1)
                }
            }
            i--
        }
        return null
    }

    /** The type a signature like `solve(approx: auto | bool, unit: str)` gives the parameter `name`. */
    fun parameterType(signature: String, name: String): String? {
        var from = 0
        while (true) {
            val index = signature.indexOf("$name:", from)
            if (index < 0) return null
            from = index + 1
            if (index > 0 && isName(signature[index - 1])) continue
            var depth = 0
            var i = index + name.length + 1
            val start = i
            while (i < signature.length) {
                val c = signature[i]
                if (c == '(' || c == '[' || c == '{') depth++
                if (c == ')' || c == ']' || c == '}') { if (depth == 0) break; depth-- }
                if (c == ',' && depth == 0) break
                i++
            }
            return signature.substring(start, i).trim().ifEmpty { null }
        }
    }

    /** The argument's name if the argument starting at `from` is named. */
    private fun keyAfter(text: String, from: Int): NamedArgument? {
        var start = from
        while (start < text.length && text[start].isWhitespace()) start++
        var end = start
        while (end < text.length && isName(text[end])) end++
        if (start == end || !isKey(text, start, end)) return null
        return NamedArgument(text.substring(start, end), TextRange(start, end - start))
    }

    /** A name followed by a colon and preceded by the call's parenthesis or a comma. */
    private fun isKey(text: String, start: Int, end: Int): Boolean {
        if (!text[start].isLetter() && text[start] != '_') return false
        var after = end
        while (after < text.length && (text[after] == ' ' || text[after] == '\t')) after++
        if (after >= text.length || text[after] != ':') return false
        var before = start - 1
        while (before >= 0 && text[before].isWhitespace()) before--
        return before >= 0 && (text[before] == '(' || text[before] == ',')
    }

    private fun isName(c: Char) = c.isLetterOrDigit() || c == '_' || c == '-'
}
