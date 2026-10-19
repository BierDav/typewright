@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

data class ReleaseAsset(val name: String, val url: String)

/** The parts of a GitHub release that matter for picking compilers. */
data class GitHubRelease(val tag: String, val prerelease: Boolean, val assets: List<ReleaseAsset>)

data class TypstRelease(val version: String, val assetUrl: String)

object Releases {
    /** Newest patch of each minor version since 0.11 that ships `assetName`, newest first. */
    fun pick(all: List<GitHubRelease>, assetName: String): List<TypstRelease> {
        val byMinor = mutableMapOf<String, TypstRelease>()
        for (release in all) {
            if (release.prerelease) continue
            val version = release.tag.trim('v')
            val parts = version.split(".").mapNotNull { it.toIntOrNull() }
            if (parts.size != 3 || (parts[0] == 0 && parts[1] < 11)) continue
            val asset = release.assets.firstOrNull { it.name == assetName } ?: continue
            val key = "${parts[0]}.${parts[1]}"
            val existing = byMinor[key]
            if (existing != null && Versions.isNewer(existing.version, version)) continue
            byMinor[key] = TypstRelease(version, asset.url)
        }
        return byMinor.values.sortedWith { a, b -> Versions.compare(b.version, a.version) }
    }
}

object Versions {
    /** True if `a` is newer than `b`. */
    fun isNewer(a: String, b: String): Boolean = compare(a, b) > 0

    /** Orders digit runs by value and everything else by character, like Finder sorts names. */
    fun compare(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            if (a[i].isDigit() && b[j].isDigit()) {
                val si = i
                val sj = j
                while (i < a.length && a[i].isDigit()) i++
                while (j < b.length && b[j].isDigit()) j++
                val x = a.substring(si, i).trimStart('0')
                val y = b.substring(sj, j).trimStart('0')
                if (x.length != y.length) return x.length.compareTo(y.length)
                val c = x.compareTo(y)
                if (c != 0) return c.coerceIn(-1, 1)
            } else {
                if (a[i] != b[j]) return a[i].compareTo(b[j]).coerceIn(-1, 1)
                i++
                j++
            }
        }
        return (a.length - i).compareTo(b.length - j).coerceIn(-1, 1)
    }
}
