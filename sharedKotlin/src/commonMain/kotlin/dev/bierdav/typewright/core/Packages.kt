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

/** A package's name and version from its `typst.toml`. */
data class PackageManifest(val name: String, val version: String)

/** Local packages cloned from GitHub. */
object PackageRepos {
    /**
     * The clone URL for `owner/repo`, a github.com link (also to a tree or `.git`), or any other git URL as is;
     * null when it's none of these.
     */
    fun cloneURL(input: String): String? {
        val text = input.trim().removeSuffix("/")
        if (text.isEmpty()) return null
        val short = Regex("^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$").find(text)
        if (short != null) return "https://github.com/${short.groupValues[1]}/${short.groupValues[2].removeSuffix(".git")}.git"
        val github = Regex("^(?:https?://)?(?:www\\.)?github\\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)").find(text)
        if (github != null) return "https://github.com/${github.groupValues[1]}/${github.groupValues[2].removeSuffix(".git")}.git"
        if (text.startsWith("git@") || Regex("^[a-z][a-z0-9+.-]*://").containsMatchIn(text)) return text
        return null
    }

    /** The repository's name from its clone URL, e.g. for a namespace made of the whole repository. */
    fun repoName(url: String): String =
        url.removeSuffix("/").substringAfterLast('/').substringAfterLast(':').removeSuffix(".git")

    /** `name` and `version` of the `[package]` table; null when either is missing. */
    fun manifest(toml: String): PackageManifest? {
        var inPackage = false
        var name: String? = null
        var version: String? = null
        for (raw in toml.lineSequence()) {
            val line = raw.substringBefore('#').trim()
            if (line.startsWith("[")) {
                inPackage = line == "[package]"
                continue
            }
            if (!inPackage) continue
            val key = line.substringBefore('=').trim()
            val value = line.substringAfter('=', "").trim().removeSurrounding("\"").removeSurrounding("'")
            when (key) {
                "name" -> name = value
                "version" -> version = value
            }
        }
        val validName = name?.takeIf { Regex("^[A-Za-z0-9_-]+$").matches(it) } ?: return null
        val validVersion = version?.takeIf { Regex("^\\d+\\.\\d+\\.\\d+$").matches(it) } ?: return null
        return PackageManifest(validName, validVersion)
    }
}
