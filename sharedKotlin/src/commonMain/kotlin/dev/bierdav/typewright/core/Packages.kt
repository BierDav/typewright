@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** Typst package specs like `@local/name:1.0.0` in import strings. */
object PackageSpecs {
    private fun isSpecChar(c: Char) = c.isLetterOrDigit() || c == '_' || c == '-' || c == '/' || c == ':' || c == '.'

    /** Where the spec being typed starts (its `@`) when `offset` is inside a `"@…` string, else -1. */
    fun specStart(text: String, offset: Int): Int {
        var i = offset.coerceIn(0, text.length)
        while (i > 0 && isSpecChar(text[i - 1])) i--
        if (i < 1 || text[i - 1] != '@') return -1
        return if (i >= 2 && text[i - 2] == '"') i - 1 else -1
    }

    /** Specs offered for `typed`: every version once a name is complete, else the newest version of each package. */
    fun candidates(typed: String, specs: List<String>): List<String> {
        val hasVersion = typed.contains(':')
        val seen = mutableSetOf<String>()
        return specs.filter { spec ->
            if (hasVersion) spec.startsWith(typed.substringBefore(':') + ":") else seen.add(spec.substringBefore(':'))
        }
    }
}
