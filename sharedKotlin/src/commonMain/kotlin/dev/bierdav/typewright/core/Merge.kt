@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** A merged text; `conflicts` counts the regions both sides changed differently. */
data class MergeResult(val text: String, val conflicts: Int)

object TextMerge {
    /** Line-based three-way merge of two edits of `base`; conflicting regions get git-style markers. */
    fun merge3(base: String, local: String, remote: String): MergeResult {
        if (local == remote) return MergeResult(local, 0)
        if (local == base) return MergeResult(remote, 0)
        if (remote == base) return MergeResult(local, 0)
        val o = lines(base)
        val a = lines(local)
        val b = lines(remote)
        val matchA = matches(o, a)
        val matchB = matches(o, b)
        val out = StringBuilder()
        var conflicts = 0
        var io = 0
        var ia = 0
        var ib = 0
        while (true) {
            // Lines that are unchanged on both sides from here.
            var stable = 0
            while (io + stable < o.size && matchA[io + stable] == ia + stable && matchB[io + stable] == ib + stable) stable++
            if (stable > 0) {
                for (k in 0 until stable) out.append(o[io + k])
                io += stable
                ia += stable
                ib += stable
                continue
            }
            // The next base line both sides kept ends the changed region.
            var next = io
            while (next < o.size && (matchA[next] < 0 || matchB[next] < 0)) next++
            val endA = if (next < o.size) matchA[next] else a.size
            val endB = if (next < o.size) matchB[next] else b.size
            val chunkO = o.subList(io, next)
            val chunkA = a.subList(ia, endA)
            val chunkB = b.subList(ib, endB)
            when {
                chunkA == chunkO -> chunkB.forEach(out::append)
                chunkB == chunkO || chunkA == chunkB -> chunkA.forEach(out::append)
                else -> {
                    conflicts++
                    out.append("<<<<<<< local\n")
                    chunkA.forEach { out.append(it).append(if (it.endsWith("\n")) "" else "\n") }
                    out.append("=======\n")
                    chunkB.forEach { out.append(it).append(if (it.endsWith("\n")) "" else "\n") }
                    out.append(">>>>>>> remote\n")
                }
            }
            if (next >= o.size && endA >= a.size && endB >= b.size) break
            io = next
            ia = endA
            ib = endB
        }
        return MergeResult(out.toString(), conflicts)
    }

    /** Lines including their line breaks, so joining them gives the text back. */
    private fun lines(text: String): List<String> {
        val result = mutableListOf<String>()
        var start = 0
        while (start < text.length) {
            val end = text.indexOf('\n', start)
            if (end < 0) {
                result.add(text.substring(start))
                break
            }
            result.add(text.substring(start, end + 1))
            start = end + 1
        }
        return result
    }

    /** For each line of `a`, the index of the matching line in `b` along a shortest edit script, or -1. */
    private fun matches(a: List<String>, b: List<String>): IntArray {
        val ids = HashMap<String, Int>()
        val x = IntArray(a.size) { ids.getOrPut(a[it]) { ids.size } }
        val y = IntArray(b.size) { ids.getOrPut(b[it]) { ids.size } }
        val n = x.size
        val m = y.size
        val max = n + m
        val offset = max + 1
        val v = IntArray(2 * max + 3)
        val trace = mutableListOf<IntArray>()
        var found = false
        // Myers' greedy forward search, keeping each round for the backtrack.
        for (d in 0..max) {
            trace.add(v.copyOf())
            var k = -d
            while (k <= d) {
                var i = if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) v[offset + k + 1] else v[offset + k - 1] + 1
                var j = i - k
                while (i < n && j < m && x[i] == y[j]) { i++; j++ }
                v[offset + k] = i
                if (i >= n && j >= m) { found = true; break }
                k += 2
            }
            if (found) break
        }
        val result = IntArray(n) { -1 }
        var i = n
        var j = m
        for (d in trace.size - 1 downTo 0) {
            val prev = trace[d]
            val k = i - j
            val prevK = if (k == -d || (k != d && prev[offset + k - 1] < prev[offset + k + 1])) k + 1 else k - 1
            val prevI = if (d == 0) 0 else prev[offset + prevK]
            val prevJ = prevI - prevK
            while (i > prevI && j > prevJ) {
                i--; j--
                result[i] = j
            }
            if (d > 0) { i = prevI; j = prevJ }
        }
        return result
    }
}
