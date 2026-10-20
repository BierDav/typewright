@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** Token kinds of [CodeHighlight.tokens]; the Swift side mirrors these values. */
object CodeTokenKind {
    const val KEYWORD = 0
    const val STRING = 1
    const val COMMENT = 2
    const val NUMBER = 3
    const val FUNCTION = 4
    const val TYPE = 5
    const val VARIABLE = 6
    const val ANNOTATION = 7
    const val OPERATOR = 8
    const val UNIT = 9
}

/** Highlighting for code embedded in Typst raw blocks and Markdown fences. */
object CodeHighlight {
    private val aliases = mapOf(
        "sql" to "sql",
        "bash" to "bash", "sh" to "bash", "shell" to "bash", "zsh" to "bash", "console" to "bash",
        "javascript" to "javascript", "js" to "javascript", "jsx" to "javascript", "mjs" to "javascript",
        "cjs" to "javascript",
        "typescript" to "typescript", "ts" to "typescript", "tsx" to "typescript",
        "kotlin" to "kotlin", "kt" to "kotlin", "kts" to "kotlin",
        "java" to "java",
        "python" to "python", "py" to "python", "python3" to "python",
        "csharp" to "csharp", "cs" to "csharp", "c#" to "csharp",
        "markdown" to "markdown", "md" to "markdown",
        "typst" to "typst", "typ" to "typst", "typc" to "typc",
        "mermaid" to "mermaid", "mmd" to "mermaid",
        // Highlighted by solveng's own editor support (solveng-ide, in the typst bridge).
        "solveng" to "solveng",
    )

    /** Canonical languages, for completing fence tags. */
    fun tags(): Array<String> = aliases.values.distinct().toTypedArray()

    /** The canonical language for a fence tag (`py` → `python`), or null for unsupported ones. */
    fun language(tag: String): String? = aliases[tag.trim().lowercase()]

    /**
     * Splits a Typst raw block (```` ```lang body``` ````) into its language tag and body.
     * Returns UTF-16 `[tagStart, tagEnd, bodyStart, bodyEnd]`, or an empty array without a tag.
     */
    fun rawBlock(raw: String): IntArray {
        var ticks = 0
        while (ticks < raw.length && raw[ticks] == '`') ticks++
        if (ticks < 3) return IntArray(0)
        var tagEnd = ticks
        while (tagEnd < raw.length && raw[tagEnd] != '`' && !raw[tagEnd].isWhitespace()) tagEnd++
        if (tagEnd == ticks) return IntArray(0)
        var bodyEnd = raw.length
        var closing = 0
        while (closing < ticks && bodyEnd > tagEnd && raw[bodyEnd - 1] == '`') {
            bodyEnd--
            closing++
        }
        return intArrayOf(ticks, tagEnd, tagEnd, bodyEnd)
    }

    /**
     * Tokens of `code` in a canonical `language`, as flat UTF-16 `(start, length, kind)` triples with
     * kinds from [CodeTokenKind]. Empty for languages without a tokenizer (Markdown, Typst, unknown).
     */
    fun tokens(language: String, code: String): IntArray {
        val lang = languages[language] ?: return IntArray(0)
        return Scanner(lang, code).run { scan(0, code.length, 0); result() }
    }
}

private class Lang(
    keywords: String,
    types: String = "",
    val lineComments: List<String> = emptyList(),
    val blockComment: Pair<String, String>? = null,
    val quotes: String = "\"'",
    /** Quote chars that may span lines; the others end at a newline. */
    val multiline: String = "",
    /** Quote chars that also open triple-quoted strings. */
    val triple: String = "",
    val rawTriple: Boolean = false,
    /** Quote chars without backslash escapes. */
    val rawQuotes: String = "",
    /** String prefixes like Python's `rb` or C#'s `$@`; ones with a raw char turn escapes off. */
    prefixes: String = "",
    val rawPrefixChars: String = "",
    /** Quote chars whose strings interpolate `${…}`. */
    val interpolated: String = "",
    /** `$name` interpolates too, not just `${…}`. */
    val dollarNames: Boolean = false,
    /** `${…}` holds code (Kotlin, JavaScript) rather than a variable expansion (shells). */
    val braceCode: Boolean = true,
    /** `$x` outside strings is a variable. */
    val variables: Boolean = false,
    val annotations: Boolean = false,
    val capitalTypes: Boolean = false,
    val caseInsensitive: Boolean = false,
    /** Shell style: the first word of a command is a function and `#` only comments at a word start. */
    val commands: Boolean = false,
    commandAfter: String = "",
    /** Extra identifier chars, also allowed first. */
    val identChars: String = "_",
    /** Extra chars allowed inside identifiers only, like the dash in `apt-get`. */
    val identInner: String = "",
    /** Runs of these chars, two or more long, are operators (Mermaid arrows). */
    val operatorChars: String = "",
) {
    val keywords = words(keywords)
    val types = words(types)
    val prefixes = words(prefixes).sortedByDescending { it.length }
    val commandAfter = words(commandAfter)

    private fun words(s: String) = s.split(' ', '\n').filter { it.isNotEmpty() }
        .map { if (caseInsensitive) it.lowercase() else it }.toSet()
}

private const val jsKeywords = """
break case catch class const continue debugger default delete do else export extends finally for function if
import in instanceof let new return super switch this throw try typeof var void while with yield async await of
static from as true false null undefined NaN Infinity"""

private val languages = mapOf(
    "sql" to Lang(
        keywords = """
select from where and or not null is in as on join inner left right outer full cross natural using group by
order having limit offset union all distinct insert into values update set delete create table view index drop
alter add column primary key foreign references constraint unique default check if exists case when then else
end begin commit rollback transaction with recursive returning asc desc like ilike between true false cascade
database schema grant revoke trigger procedure function return returns declare replace temporary temp over
partition window rows range unbounded preceding following current row filter except intersect lateral fetch
first next only top collate escape do nothing conflict""",
        types = """
int integer smallint bigint tinyint serial bigserial decimal numeric real float double precision char varchar
text boolean bool date time timestamp timestamptz interval uuid json jsonb blob bytea money""",
        lineComments = listOf("--"), blockComment = "/*" to "*/", quotes = "'\"`", multiline = "'\"`",
        rawQuotes = "'\"`", caseInsensitive = true,
    ),
    "bash" to Lang(
        keywords = """
if then else elif fi for while until do done case esac in function select return exit break continue local
export readonly declare typeset unset source alias shift trap eval exec time""",
        lineComments = listOf("#"), quotes = "'\"`", multiline = "'\"`", rawQuotes = "'", interpolated = "\"",
        dollarNames = true, braceCode = false, variables = true, commands = true,
        commandAfter = "if then else elif while until do time exec", identInner = "-.",
    ),
    "javascript" to Lang(
        keywords = jsKeywords, lineComments = listOf("//"), blockComment = "/*" to "*/", quotes = "'\"`",
        multiline = "`", interpolated = "`", annotations = true, capitalTypes = true, identChars = "_$",
    ),
    "typescript" to Lang(
        keywords = "$jsKeywords interface type enum implements namespace declare abstract readonly private " +
            "public protected keyof infer is satisfies module",
        types = "string number boolean any unknown never void object symbol bigint",
        lineComments = listOf("//"), blockComment = "/*" to "*/", quotes = "'\"`", multiline = "`",
        interpolated = "`", annotations = true, capitalTypes = true, identChars = "_$",
    ),
    "kotlin" to Lang(
        keywords = """
package import class interface object fun val var if else when for while do return break continue throw try
catch finally in is as typealias this super null true false constructor init companion data sealed enum
abstract open override private protected public internal inline suspend operator infix lateinit const vararg
reified crossinline noinline by where out annotation inner expect actual external tailrec""",
        lineComments = listOf("//"), blockComment = "/*" to "*/", multiline = "", triple = "\"", rawTriple = true,
        interpolated = "\"", dollarNames = true, annotations = true, capitalTypes = true,
    ),
    "java" to Lang(
        keywords = """
abstract assert break case catch class const continue default do else enum extends final finally for goto if
implements import instanceof interface native new package private protected public return static strictfp super
switch synchronized this throw throws transient try volatile while true false null record sealed permits yield
var""",
        types = "boolean byte char short int long float double void",
        lineComments = listOf("//"), blockComment = "/*" to "*/", triple = "\"", annotations = true,
        capitalTypes = true, identChars = "_$",
    ),
    "python" to Lang(
        keywords = """
False None True and as assert async await break class continue def del elif else except finally for from
global if import in is lambda nonlocal not or pass raise return try while with yield match case""",
        types = "int float str bool bytes list dict set tuple object type complex frozenset bytearray",
        lineComments = listOf("#"), triple = "\"'", prefixes = "r u b f rb br fr rf", rawPrefixChars = "rR",
        annotations = true, capitalTypes = true,
    ),
    "csharp" to Lang(
        keywords = """
abstract as base break case catch checked class const continue default delegate do else enum event explicit
extern false finally fixed for foreach goto if implicit in interface internal is lock namespace new null operator
out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch
this throw true try typeof unchecked unsafe using virtual volatile while async await get set init record yield
where when nameof global partial required with var""",
        types = "bool byte sbyte char decimal double float int uint long ulong short ushort object string void dynamic nint nuint",
        lineComments = listOf("//"), blockComment = "/*" to "*/", triple = "\"", rawTriple = true,
        prefixes = "@ $ $@ @$", rawPrefixChars = "@", capitalTypes = true,
    ),
    "mermaid" to Lang(
        keywords = """
graph flowchart subgraph end direction TB TD BT RL LR sequenceDiagram classDiagram stateDiagram stateDiagram-v2
erDiagram gantt pie journey gitGraph mindmap timeline quadrantChart requirementDiagram participant actor as note
over of left right loop alt else opt par and critical break rect activate deactivate autonumber class classDef
style linkStyle click callback state title section dateFormat axisFormat excludes todayMarker commit branch
checkout merge accTitle accDescr""",
        lineComments = listOf("%%"), quotes = "\"", rawQuotes = "\"", identInner = "-", operatorChars = "-=.<>",
    ),
)

/** A single pass over the code; `${…}` interpolations recurse a few levels at most. */
private class Scanner(val lang: Lang, val s: String) {
    private var out = IntArray(96)
    private var size = 0

    fun result(): IntArray = out.copyOf(size)

    private fun emit(start: Int, end: Int, kind: Int) {
        if (end <= start) return
        // Neighbours of one kind, like string parts around an escape, merge.
        if (size >= 3 && out[size - 1] == kind && out[size - 3] + out[size - 2] == start) {
            out[size - 2] = end - out[size - 3]
            return
        }
        if (size + 3 > out.size) out = out.copyOf(out.size * 2)
        out[size++] = start
        out[size++] = end - start
        out[size++] = kind
    }

    private fun identStart(c: Char) = c.isLetter() || c in lang.identChars
    private fun identPart(c: Char) = c.isLetterOrDigit() || c in lang.identChars

    fun scan(from: Int, to: Int, depth: Int) {
        var i = from
        var command = true
        while (i < to) {
            val c = s[i]
            if (c == '\n') {
                command = true
                i++
                continue
            }
            if (c.isWhitespace()) {
                i++
                continue
            }
            val line = lang.lineComments.firstOrNull { s.startsWith(it, i) }
            if (line != null && (!lang.commands || i == from || s[i - 1].isWhitespace() || s[i - 1] == ';')) {
                val end = s.indexOf('\n', i).let { if (it < 0 || it > to) to else it }
                emit(i, end, CodeTokenKind.COMMENT)
                i = end
                continue
            }
            val block = lang.blockComment
            if (block != null && s.startsWith(block.first, i)) {
                val close = s.indexOf(block.second, i + block.first.length)
                val end = if (close < 0 || close + block.second.length > to) to else close + block.second.length
                emit(i, end, CodeTokenKind.COMMENT)
                i = end
                continue
            }
            if (c in lang.quotes) {
                i = string(i, i, to, false, depth)
                command = false
                continue
            }
            val prefix = lang.prefixes.firstOrNull {
                s.startsWith(it, i, ignoreCase = true) && i + it.length < to && s[i + it.length] in lang.quotes
            }
            if (prefix != null) {
                i = string(i, i + prefix.length, to, prefix.any { it in lang.rawPrefixChars }, depth)
                command = false
                continue
            }
            if (lang.variables && c == '$') {
                i = variable(i, to, depth)
                command = false
                continue
            }
            if (lang.annotations && c == '@' && i + 1 < to && identStart(s[i + 1])) {
                var j = i + 2
                while (j < to && (identPart(s[j]) || (s[j] == '.' && j + 1 < to && identStart(s[j + 1])))) j++
                emit(i, j, CodeTokenKind.ANNOTATION)
                i = j
                continue
            }
            if (c.isDigit() || (c == '.' && i + 1 < to && s[i + 1].isDigit())) {
                val end = number(i, to)
                emit(i, end, CodeTokenKind.NUMBER)
                i = end
                continue
            }
            if (identStart(c)) {
                var j = i + 1
                while (j < to && (identPart(s[j]) || (s[j] in lang.identInner && j + 1 < to && identPart(s[j + 1])))) j++
                val word = s.substring(i, j)
                val key = if (lang.caseInsensitive) word.lowercase() else word
                val kind = when {
                    key in lang.keywords -> CodeTokenKind.KEYWORD
                    key in lang.types -> CodeTokenKind.TYPE
                    lang.commands && j < to && s[j] == '=' -> CodeTokenKind.VARIABLE
                    j < to && s[j] == '(' -> CodeTokenKind.FUNCTION
                    lang.commands && command -> CodeTokenKind.FUNCTION
                    lang.capitalTypes && c.isUpperCase() && word.any { it.isLowerCase() } -> CodeTokenKind.TYPE
                    else -> -1
                }
                if (kind >= 0) emit(i, j, kind)
                // `FOO=1 cmd` keeps looking for the command; keywords like `then` start a new one.
                command = kind == CodeTokenKind.VARIABLE || (kind == CodeTokenKind.KEYWORD && key in lang.commandAfter)
                i = j
                if (kind == CodeTokenKind.VARIABLE) {
                    // A plain assigned value isn't a command either.
                    i++
                    while (i < to && !s[i].isWhitespace() && s[i] !in ";|&\"'`$") i++
                }
                continue
            }
            if (c in lang.operatorChars) {
                var j = i + 1
                while (j < to && s[j] in lang.operatorChars) j++
                if (j - i >= 2) emit(i, j, CodeTokenKind.OPERATOR)
                i = j
                continue
            }
            if (c in "|;&(") command = true
            i++
        }
    }

    private fun number(start: Int, to: Int): Int {
        var j = start
        val hex = s.startsWith("0x", start, ignoreCase = true)
        while (j < to) {
            val ch = s[j]
            if (ch.isLetterOrDigit() || ch == '_') j++
            else if (ch == '.' && j + 1 < to && s[j + 1].isDigit()) j++
            else if (!hex && (ch == '+' || ch == '-') && (s[j - 1] == 'e' || s[j - 1] == 'E')) j++
            else break
        }
        return j
    }

    /** A string from `start` (its prefix) whose quote is at `quote`; returns the end. */
    private fun string(start: Int, quote: Int, to: Int, raw: Boolean, depth: Int): Int {
        val q = s[quote]
        val triple = q in lang.triple && quote + 2 < to && s[quote + 1] == q && s[quote + 2] == q
        val closeLength = if (triple) 3 else 1
        val escapes = !raw && q !in lang.rawQuotes && !(triple && lang.rawTriple)
        val interpolates = q in lang.interpolated
        var i = quote + closeLength
        var part = start
        while (i < to) {
            val ch = s[i]
            if (escapes && ch == '\\') {
                i += 2
                continue
            }
            if (ch == q && (!triple || (i + 2 < to && s[i + 1] == q && s[i + 2] == q))) {
                i += closeLength
                // Kotlin's `""""` ends on the last quote.
                while (triple && i < to && s[i] == q) i++
                emit(part, i, CodeTokenKind.STRING)
                return i
            }
            if (ch == '\n' && !triple && q !in lang.multiline) break
            if (interpolates && ch == '$' && i + 1 < to &&
                (s[i + 1] == '{' || (lang.dollarNames && (identStart(s[i + 1]) || s[i + 1].isDigit())))
            ) {
                emit(part, i, CodeTokenKind.STRING)
                i = variable(i, to, depth)
                part = i
                continue
            }
            i++
        }
        val end = minOf(i, to)
        emit(part, end, CodeTokenKind.STRING)
        return end
    }

    /** `$name`, `${…}` or a shell special like `$?` at `start`; returns the end. */
    private fun variable(start: Int, to: Int, depth: Int): Int {
        if (start + 1 >= to) return start + 1
        val next = s[start + 1]
        if (next == '{') {
            var j = start + 2
            var open = 1
            while (j < to) {
                if (s[j] == '{') open++
                if (s[j] == '}' && --open == 0) break
                j++
            }
            val end = minOf(j + 1, to)
            if (lang.braceCode && depth < 4) {
                emit(start, start + 2, CodeTokenKind.KEYWORD)
                scan(start + 2, minOf(j, to), depth + 1)
                if (j < to) emit(j, j + 1, CodeTokenKind.KEYWORD)
            } else {
                emit(start, end, CodeTokenKind.VARIABLE)
            }
            return end
        }
        var j = start + 1
        if (identStart(next) || next.isDigit()) {
            while (j < to && (s[j].isLetterOrDigit() || s[j] == '_')) j++
        } else if (lang.commands && next in "@*#?$!-") {
            j++
        } else {
            return start + 1
        }
        emit(start, j, CodeTokenKind.VARIABLE)
        return j
    }
}
