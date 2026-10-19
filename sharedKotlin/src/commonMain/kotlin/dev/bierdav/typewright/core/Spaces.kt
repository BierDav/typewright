@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/**
 * The user's spaces in their chosen order, as stored paths. Storage and file system checks stay with
 * the platform; `visible` is the stored list resolved to existing space folders.
 */
object SpaceOrder {
    /** Appends a new space; known ones keep their place. */
    fun add(stored: List<String>, path: String): List<String> =
        if (path in stored) stored else stored + path

    /** Moves a visible space to `index`; missing folders keep their entries for when they return. */
    fun move(stored: List<String>, visible: List<String>, path: String, index: Int): List<String> {
        val order = visible.toMutableList()
        val from = order.indexOf(path)
        if (from < 0) return stored
        val item = order.removeAt(from)
        order.add(index.coerceIn(0, order.size), item)
        return order + stored.filter { it !in order }
    }

    /** Swaps a renamed space in place, keeping its position. */
    fun replace(stored: List<String>, old: String, new: String): List<String> =
        stored.map { if (it == old) new else it }

    /** Drops every entry whose space, per `rootOf`, is `root`. */
    fun remove(stored: List<String>, root: String, rootOf: (String) -> String): List<String> =
        stored.filter { rootOf(it) != root }
}

object FuzzyMatch {
    /** Lower is better: prefix, word start, substring, then scattered letters; null if no match. */
    fun score(query: String, text: String): Int? {
        if (text.startsWith(query)) return 0
        if (text.contains(" $query") || text.contains("/$query")) return 1
        if (text.contains(query)) return 2
        var from = 0
        for (c in query) {
            val i = text.indexOf(c, from)
            if (i < 0) return null
            from = i + 1
        }
        return 4
    }
}
