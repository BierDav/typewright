@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** Kinds of [SolvengItem]. */
object SolvengItemKind {
    const val VARIABLE = 0
    const val FUNCTION = 1
    const val UNIT = 2
    const val CONSTANT = 3
}

class SolvengItem(
    val label: String,
    val kind: Int,
    /** What it is: `= 30 mA`, `milliampere`, `f(x) = x^2 + 1`. */
    val detail: String,
    /** Text inserted for the item; `$0` marks where the caret goes. */
    val insert: String,
)

/** Completions at a caret: [items] replace the UTF-16 range `from..<offset`. */
class SolvengCompletions(val from: Int, val items: Array<SolvengItem>)

/**
 * The calculation language of the solveng package (`@preview/solveng`): ```` ```solveng ```` code in a
 * `solve-block`, and code without a language when the document turns on `plain-code: true`.
 */
object Solveng {
    /** Language tag of solveng code. */
    const val TAG = "solveng"

    private val functions = listOf("sqrt", "exp", "ln", "log", "sin", "cos", "tan", "asin", "acos", "atan", "abs")
    private val constants = mapOf("pi" to "π ≈ 3,14159", "e" to "Euler's number ≈ 2,71828")

    /** Units that take prefixes, with their names. */
    private val prefixable = linkedMapOf(
        "m" to "metre", "g" to "gram", "s" to "second", "A" to "ampere", "K" to "kelvin", "mol" to "mole",
        "cd" to "candela", "V" to "volt", "Ω" to "ohm", "W" to "watt", "J" to "joule", "C" to "coulomb",
        "F" to "farad", "H" to "henry", "S" to "siemens", "Hz" to "hertz", "N" to "newton", "Pa" to "pascal",
        "T" to "tesla", "Wb" to "weber", "Ah" to "ampere hour", "Wh" to "watt hour", "As" to "ampere second",
        "Ws" to "watt second", "eV" to "electronvolt", "l" to "litre", "L" to "litre", "rad" to "radian",
    )
    private val plainUnits = linkedMapOf(
        "min" to "minute", "h" to "hour", "%" to "percent", "‰" to "per mille", "°" to "degree",
        "deg" to "degree", "°C" to "degree Celsius (a difference)", "degC" to "degree Celsius (a difference)",
    )
    /** Typeable spellings solveng reads as the unit after them. */
    private val spellings = mapOf("Ohm" to "Ω", "ohm" to "Ω", "Omega" to "Ω", "Ω" to "Ω")
    private val prefixes = linkedMapOf(
        "m" to "milli", "k" to "kilo", "u" to "micro", "M" to "mega", "n" to "nano", "G" to "giga", "p" to "pico",
        "c" to "centi", "d" to "deci", "T" to "tera", "f" to "femto", "a" to "atto", "µ" to "micro", "μ" to "micro",
    )
    /** Prefixed units offered in completions; the rest still highlight. */
    private val commonPrefixes = listOf("m", "k", "u", "M", "n", "G", "p")

    private fun unitName(name: String): String? {
        plainUnits[name]?.let { return it }
        prefixable[spellings[name] ?: name]?.let { return it }
        if (name.length < 2) return null
        for ((p, pn) in prefixes) {
            if (!name.startsWith(p)) continue
            val rest = name.substring(p.length)
            prefixable[spellings[rest] ?: rest]?.let { return pn + it }
        }
        return null
    }

    /** Whether `name` is a built-in unit, or a prefix and one (`kOhm`, `mAh`). */
    fun isUnit(name: String): Boolean = unitName(name) != null

    // ---------- the document ----------

    /** A raw element of the document: its UTF-16 body range and language tag (empty without one). */
    private class Raw(val start: Int, val end: Int, val bodyStart: Int, val bodyEnd: Int, val tag: String)

    /** Raw elements in Typst markup, by their backticks; good enough for an editor, not a parser. */
    private fun raws(text: String): List<Raw> {
        val out = mutableListOf<Raw>()
        var i = 0
        while (i < text.length) {
            val c = text[i]
            if (c == '\\') {
                i += 2
                continue
            }
            if (c != '`') {
                i++
                continue
            }
            var ticks = 0
            while (i + ticks < text.length && text[i + ticks] == '`') ticks++
            if (ticks == 2) {
                i += 2
                continue
            }
            val fence = "`".repeat(ticks)
            var close = text.indexOf(fence, i + ticks)
            // A longer run doesn't close a shorter fence.
            while (close >= 0 && close + ticks < text.length && text[close + ticks] == '`') {
                var j = close
                while (j < text.length && text[j] == '`') j++
                close = text.indexOf(fence, j)
            }
            val end = if (close < 0) text.length else close + ticks
            val bodyEnd = if (close < 0) text.length else close
            var bodyStart = i + ticks
            var tag = ""
            if (ticks >= 3) {
                var t = bodyStart
                while (t < bodyEnd && (text[t].isLetterOrDigit() || text[t] in "_-+#.")) t++
                tag = text.substring(bodyStart, t)
                bodyStart = t
            }
            out.add(Raw(i, end, bodyStart, bodyEnd, tag))
            i = end
        }
        return out
    }

    /** Whether the document makes `solve-block` read code without a language too (`plain-code: true`). */
    fun plainCode(document: String): Boolean = Regex("""plain-code\s*:\s*true\b""").containsMatchIn(document)

    private fun isSolveng(raw: Raw, plain: Boolean) = raw.tag == TAG || (raw.tag.isEmpty() && plain)

    /**
     * The UTF-16 `[bodyStart, bodyEnd]` of a raw element (```` `x` ````, ```` ```solveng x``` ````)
     * that holds solveng code, or an empty array; `plain` counts code without a language.
     */
    fun body(raw: String, plain: Boolean): IntArray {
        val r = raws(raw).firstOrNull() ?: return IntArray(0)
        if (r.start != 0 || !isSolveng(r, plain)) return IntArray(0)
        return intArrayOf(r.bodyStart, r.bodyEnd)
    }

    private class Definition(val name: String, val detail: String, val function: Boolean)

    private val nameAtStart = Regex("""^\s*([\p{L}][\p{L}\p{N}_]*)\s*(\([^()=]*\))?\s*(<=|>=|=|<|>|≤|≥)(.*)$""")

    /** `I = 30 mA` or `f(x) = x^2` → a definition; anything else (`Q0/2 = I t`, `= x`) → null. */
    private fun definition(line: String): Definition? {
        val m = nameAtStart.find(line) ?: return null
        val (name, params, relation, rest) = m.destructured
        if (relation == "=" && rest.startsWith("=")) return null
        val value = rest.substringBefore("->").trim()
        val unit = rest.substringAfter("->", "").trim()
        val detail = "$relation $value" + if (unit.isNotEmpty()) " → $unit" else ""
        return if (params.isNotEmpty()) Definition("$name$params", detail, true) else Definition(name, detail, false)
    }

    private fun codeLines(body: String) =
        body.split('\n').map { it.substringBefore("//") }.flatMap { it.split(';') }.filter { it.isNotBlank() }

    /** Names defined in the document: math equations, solveng code, and `def` / `solve` strings. */
    private fun definitions(text: String, plain: Boolean): List<Definition> {
        val found = mutableListOf<Definition>()
        val raws = raws(text)
        for (raw in raws) if (isSolveng(raw, plain)) codeLines(text.substring(raw.bodyStart, raw.bodyEnd)).mapNotNullTo(found, ::definition)
        // Outside raw: math and calls.
        val outside = StringBuilder(text)
        for (raw in raws) for (k in raw.start until raw.end) outside[k] = ' '
        val markup = outside.toString()
        val mathName = Regex("""^\s*[\p{L}][\p{L}\p{N}]*(_[\p{L}\p{N}]+)?\s*$""")
        Regex("""\$([^$]*)\$""").findAll(markup).forEach { m ->
            val body = m.groupValues[1]
            // Math writes Q_0 and quotes units: Q_0 = 3450 "mAh".
            if (!mathName.matches(body.substringBefore("="))) return@forEach
            definition(body.replace("\"", "").replace(Regex("""\s+"""), " "))?.let(found::add)
        }
        Regex("""\b(?:def|solve)\(""").findAll(markup).forEach { m ->
            var i = m.range.last + 1
            var depth = 1
            while (i < markup.length && depth > 0) {
                when (markup[i]) {
                    '(' -> depth++
                    ')' -> depth--
                    '"' -> {
                        val end = markup.indexOf('"', i + 1).let { if (it < 0) markup.length else it }
                        if (depth == 1) definition(markup.substring(i + 1, end))?.let(found::add)
                        i = end
                    }
                }
                i++
            }
        }
        return found
    }

    /** Units the document adds with `solve-config(units: (bar: "100 kPa", …))`. */
    private fun customUnits(text: String): Map<String, String> {
        val out = linkedMapOf<String, String>()
        Regex("""units\s*:\s*\(""").findAll(text).forEach { m ->
            val start = m.range.last + 1
            val end = text.indexOf(')', start).let { if (it < 0) text.length else it }
            Regex("""([\p{L}][\p{L}\p{N}_]*|"[^"]+")\s*:\s*("[^"]*"|none)""").findAll(text.substring(start, end)).forEach {
                val (name, value) = it.destructured
                if (value != "none") out[name.trim('"')] = "= " + value.trim('"')
            }
        }
        return out
    }

    // ---------- completion ----------

    /** Before the word being typed: a value's unit (`30 m|`, `[5 |`, `-> |`, `kg m/|`). */
    private fun unitContext(line: String, custom: Set<String>): Boolean {
        if (Regex("""->\s*[^=;]*$""").containsMatchIn(line)) return true
        val open = line.lastIndexOf('[')
        if (open > line.lastIndexOf(']')) return true
        // A number, then units: 9.81 m/s^, 3 kg m; not 2 I, where I is a variable.
        val value = Regex("""(?:^|[^\p{L}\p{N}_])\d[\d.,]*(?:[eE][-+]?\d+)?\s*((?:[\p{L}°%‰µΩ]+(?:\^-?\d+|[²³])?\s*[/*·]?\s*)*)$""")
            .find(line) ?: return false
        return Regex("""[\p{L}°%‰µΩ]+""").findAll(value.groupValues[1]).all { isUnit(it.value) || it.value in custom }
    }

    /**
     * Completions when `offset` is in solveng code, else null (and the Typst language server answers).
     * Offers defined variables and functions, solveng's functions and constants, and units where a value's
     * unit is written.
     */
    fun complete(document: String, offset: Int): SolvengCompletions? {
        val plain = plainCode(document)
        val at = offset.coerceIn(0, document.length)
        val raw = raws(document).firstOrNull { it.bodyStart <= at && at <= it.bodyEnd && isSolveng(it, plain) } ?: return null
        var from = at
        while (from > raw.bodyStart && (document[from - 1].isLetterOrDigit() || document[from - 1] in "_°%‰µΩ")) from--
        val lineStart = maxOf(raw.bodyStart, document.lastIndexOf('\n', from - 1) + 1)
        val line = document.substring(lineStart, from)
        // Comments complete nothing.
        if (line.contains("//")) return SolvengCompletions(from, emptyArray())
        val items = mutableListOf<SolvengItem>()
        val units = customUnits(document)
        if (unitContext(line, units.keys)) {
            for ((u, d) in units) items.add(SolvengItem(u, SolvengItemKind.UNIT, d, u))
            for ((u, name) in prefixable) {
                items.add(SolvengItem(u, SolvengItemKind.UNIT, name, if (u == "Ω") "Ohm" else u))
                for (p in commonPrefixes) {
                    if (u == "g" && p != "k" && p != "m") continue
                    val label = p + if (u == "Ω") "Ohm" else u
                    items.add(SolvengItem(label, SolvengItemKind.UNIT, prefixes.getValue(p) + name, label))
                }
            }
            for ((u, name) in plainUnits) items.add(SolvengItem(u, SolvengItemKind.UNIT, name, u))
            return SolvengCompletions(from, items.distinctBy { it.label }.toTypedArray())
        }
        val seen = mutableSetOf<String>()
        for (d in definitions(document, plain).asReversed()) {
            val name = d.name.substringBefore('(')
            if (!seen.add(name)) continue
            if (d.function) {
                val params = d.name.substringAfter('(').substringBefore(')')
                items.add(SolvengItem(d.name, SolvengItemKind.FUNCTION, d.detail, "$name(${if (params.isBlank()) "" else "$0"})"))
            } else {
                items.add(SolvengItem(name, SolvengItemKind.VARIABLE, d.detail, name))
            }
        }
        for (f in functions) if (seen.add(f)) items.add(SolvengItem(f, SolvengItemKind.FUNCTION, "built-in", "$f($0)"))
        for ((c, d) in constants) if (seen.add(c)) items.add(SolvengItem(c, SolvengItemKind.CONSTANT, d, c))
        return SolvengCompletions(from, items.toTypedArray())
    }

    // ---------- highlighting ----------

    /**
     * Tokens of solveng code as flat UTF-16 `(start, length, kind)` triples with kinds from [CodeTokenKind]:
     * numbers and their units, variables, functions, `@`-inlined formulas, relations and `->`, comments.
     */
    fun tokens(code: String): IntArray {
        val out = mutableListOf<Int>()
        fun emit(start: Int, end: Int, kind: Int) {
            if (end > start) out.addAll(listOf(start, end - start, kind))
        }
        val unitChars = "°%‰µΩ"
        fun isNameStart(c: Char) = c.isLetter()
        fun isNamePart(c: Char) = c.isLetterOrDigit() || c == '_'
        var i = 0
        // Where units are read: after a number, inside [ ], after ->.
        var unitMode = false
        var inBracket = false
        var afterArrow = false
        while (i < code.length) {
            val c = code[i]
            when {
                c == '\n' || c == ';' -> {
                    if (c == ';') emit(i, i + 1, CodeTokenKind.OPERATOR)
                    unitMode = false
                    inBracket = false
                    afterArrow = false
                    i++
                }
                code.startsWith("//", i) -> {
                    val end = code.indexOf('\n', i).let { if (it < 0) code.length else it }
                    emit(i, end, CodeTokenKind.COMMENT)
                    i = end
                }
                code.startsWith("->", i) -> {
                    emit(i, i + 2, CodeTokenKind.OPERATOR)
                    afterArrow = true
                    unitMode = true
                    i += 2
                }
                c == '[' -> {
                    inBracket = true
                    unitMode = true
                    i++
                }
                c == ']' -> {
                    inBracket = false
                    unitMode = false
                    i++
                }
                c in "=<>≤≥" -> {
                    val end = if (i + 1 < code.length && code[i + 1] == '=') i + 2 else i + 1
                    emit(i, end, CodeTokenKind.OPERATOR)
                    unitMode = false
                    i = end
                }
                c == '@' && i + 1 < code.length && isNameStart(code[i + 1]) -> {
                    var j = i + 1
                    while (j < code.length && isNamePart(code[j])) j++
                    emit(i, j, CodeTokenKind.ANNOTATION)
                    unitMode = false
                    i = j
                }
                c.isDigit() || (c == '.' && i + 1 < code.length && code[i + 1].isDigit()) -> {
                    var j = i
                    while (j < code.length) {
                        val d = code[j]
                        if (d.isDigit()) j++
                        else if ((d == '.' || d == ',') && j + 1 < code.length && code[j + 1].isDigit()) j++
                        else if ((d == 'e' || d == 'E') && j + 1 < code.length &&
                            (code[j + 1].isDigit() || (code[j + 1] in "+-" && j + 2 < code.length && code[j + 2].isDigit()))
                        ) j += 2
                        else break
                    }
                    // An exponent of a unit (m^2) keeps the unit going.
                    val exponent = i > 0 && code[i - 1] == '^'
                    emit(i, j, if (exponent && unitMode) CodeTokenKind.UNIT else CodeTokenKind.NUMBER)
                    if (!exponent) unitMode = true
                    i = j
                }
                isNameStart(c) || c in unitChars -> {
                    var j = i + 1
                    while (j < code.length && (isNamePart(code[j]) || code[j] in unitChars)) j++
                    val word = code.substring(i, j)
                    var k = j
                    while (k < code.length && code[k] == ' ') k++
                    val call = k < code.length && code[k] == '('
                    val kind = when {
                        call -> CodeTokenKind.FUNCTION
                        unitMode && (inBracket || afterArrow || isUnit(word)) -> CodeTokenKind.UNIT
                        word in constants -> CodeTokenKind.KEYWORD
                        else -> CodeTokenKind.VARIABLE
                    }
                    emit(i, j, kind)
                    if (kind != CodeTokenKind.UNIT) unitMode = inBracket || afterArrow
                    i = j
                }
                c == '/' || c == '^' || c == '*' || c == '·' || c == ' ' || c == '\t' || c in "²³⁻¹" -> {
                    if (c in "²³⁻¹" && unitMode) emit(i, i + 1, CodeTokenKind.UNIT)
                    i++
                }
                else -> {
                    // + - ( ) , end a value's unit.
                    if (!inBracket && !afterArrow) unitMode = false
                    i++
                }
            }
        }
        return out.toIntArray()
    }
}
