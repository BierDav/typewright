@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/**
 * `.gitignore` matching for a space. Rules of a folder's `.gitignore` apply below that folder; later
 * and deeper rules win, and `!` re-includes. Paths are relative to the space root with `/` separators.
 */
class IgnoreRules {
    private class Rule(val base: String, val regex: Regex, val negated: Boolean, val dirOnly: Boolean)

    private val rules = mutableListOf<Rule>()

    /** Adds the rules of the `.gitignore` in folder `dir` ("" for the root). Add parents before children. */
    fun add(dir: String, content: String) {
        val base = dir.trim('/')
        for (raw in content.lines()) {
            parse(base, raw)?.let(rules::add)
        }
    }

    /** Whether `path` or one of its folders is ignored. */
    fun isIgnored(path: String, isDir: Boolean): Boolean {
        val parts = path.trim('/').split('/')
        for (i in 1 until parts.size) {
            if (matches(parts.subList(0, i).joinToString("/"), true)) return true
        }
        return matches(parts.joinToString("/"), isDir)
    }

    /** Whether the item itself matches, assuming its folders aren't ignored. */
    fun matches(path: String, isDir: Boolean): Boolean {
        val name = path.substringAfterLast('/')
        if (name == ".git" || name == ".DS_Store") return true
        var ignored = false
        for (rule in rules) {
            if (rule.dirOnly && !isDir) continue
            val relative = if (rule.base.isEmpty()) path else Paths.relative(path, rule.base) ?: continue
            if (rule.regex.matches(relative)) ignored = !rule.negated
        }
        return ignored
    }

    private fun parse(base: String, raw: String): Rule? {
        var line = raw.trimEnd('\r')
        // Trailing spaces count only when escaped.
        while (line.endsWith(" ") && !line.endsWith("\\ ")) line = line.dropLast(1)
        if (line.isEmpty() || line.startsWith("#")) return null
        var negated = false
        if (line.startsWith("!")) {
            negated = true
            line = line.drop(1)
        } else if (line.startsWith("\\!") || line.startsWith("\\#")) {
            line = line.drop(1)
        }
        val dirOnly = line.endsWith("/")
        line = line.trimEnd('/')
        if (line.isEmpty()) return null
        // A slash anywhere but the end anchors the pattern to its folder; otherwise it matches at any depth.
        val anchored = line.contains('/')
        line = line.trimStart('/')
        val glob = globToRegex(line)
        val regex = Regex(if (anchored) glob else "(?:.*/)?$glob")
        return Rule(base, regex, negated, dirOnly)
    }

    private fun globToRegex(glob: String): String {
        val out = StringBuilder()
        var i = 0
        while (i < glob.length) {
            val c = glob[i]
            when {
                glob.startsWith("**/", i) -> { out.append("(?:.*/)?"); i += 3; continue }
                glob.startsWith("/**", i) && i + 3 == glob.length -> { out.append("/.*"); i += 3; continue }
                glob.startsWith("**", i) -> { out.append(".*"); i += 2; continue }
                c == '*' -> out.append("[^/]*")
                c == '?' -> out.append("[^/]")
                c == '[' -> {
                    val end = glob.indexOf(']', i + 2)
                    if (end < 0) {
                        out.append("\\[")
                    } else {
                        var set = glob.substring(i + 1, end)
                        if (set.startsWith("!")) set = "^" + set.drop(1)
                        out.append('[').append(set.replace("\\", "\\\\")).append(']')
                        i = end + 1
                        continue
                    }
                }
                c == '\\' && i + 1 < glob.length -> { out.append(Regex.escape(glob[i + 1].toString())); i += 2; continue }
                else -> out.append(Regex.escape(c.toString()))
            }
            i++
        }
        return out.toString()
    }
}
