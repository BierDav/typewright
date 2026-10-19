@file:JsExport

package dev.bierdav.typewright.core

import kotlin.js.JsExport

/** How a file syncs: small text files merge concurrent edits; everything else is replaced whole. */
enum class SyncMode { Merge, Lfs }

object SyncPolicy {
    /** Files above this many bytes switch to LFS mode. */
    const val DEFAULT_LFS_THRESHOLD: Double = 1_048_576.0

    /** `isText` is false for kinds like PDF, Office, images and fonts, and for contents that sniff as binary. */
    fun mode(isText: Boolean, size: Double, lfsThreshold: Double): SyncMode =
        if (isText && size <= lfsThreshold) SyncMode.Merge else SyncMode.Lfs

    /** Rejects paths that could leave the space or touch git's own data. */
    fun isSafe(path: String): Boolean {
        if (path.isEmpty() || path.startsWith("/") || path.contains('\\') || path.contains('\u0000')) return false
        return path.split('/').none { it.isEmpty() || it == "." || it == ".." || it == ".git" }
    }

    /** `dir/name (conflict).ext`, numbered while taken. */
    fun conflictPath(path: String, exists: (String) -> Boolean): String {
        val dir = path.substringBeforeLast('/', "")
        val file = path.substringAfterLast('/')
        val dot = file.lastIndexOf('.').takeIf { it > 0 }
        val stem = dot?.let { file.substring(0, it) } ?: file
        val ext = dot?.let { file.substring(it) } ?: ""
        var i = 1
        while (true) {
            val name = "$stem (conflict${if (i == 1) "" else " $i"})$ext"
            val candidate = if (dir.isEmpty()) name else "$dir/$name"
            if (!exists(candidate)) return candidate
            i++
        }
    }
}

/** A file on this device, hashed like blobs are (BLAKE3 hex). */
data class LocalFile(val path: String, val hash: String, val size: Double, val isText: Boolean)

/** The newest replica entry of a path; deletions keep their path with `deleted`. */
data class RemoteEntry(val path: String, val hash: String, val size: Double, val deleted: Boolean)

sealed class SyncAction {
    abstract val path: String

    /** Import the local file into the replica. */
    data class Publish(override val path: String) : SyncAction()

    /** Mark the path deleted in the replica. */
    data class Unpublish(override val path: String) : SyncAction()

    /** Replace the local file with the blob; report back with `wrote`. */
    data class Write(override val path: String, val hash: String, val size: Double) : SyncAction()

    /** Move the local file to the Trash. */
    data class Trash(override val path: String) : SyncAction()

    /** Merge the local text with the blob `remoteHash`, both edits of `baseHash`; report back with `merged`. */
    data class Merge(override val path: String, val baseHash: String, val remoteHash: String) : SyncAction()

    /** Save the blob as `copyPath` next to the local file, which stays and wins; no report needed. */
    data class ConflictCopy(override val path: String, val copyPath: String, val hash: String, val size: Double) : SyncAction()
}

/**
 * Decides how one space's folder and its replica converge. It remembers the hash each path last had
 * on both sides (the base): a side that differs from it changed, and two changed sides conflict.
 */
class SpaceSync(var lfsThreshold: Double = SyncPolicy.DEFAULT_LFS_THRESHOLD) {
    private val base = mutableMapOf<String, String>()
    private val publishing = mutableMapOf<String, String>()
    private val writing = mutableMapOf<String, String>()

    /** Restores the bases saved with `save`. */
    fun load(state: String) {
        base.clear()
        for (line in state.lines()) {
            val tab = line.indexOf('\t')
            if (tab > 0) base[line.substring(tab + 1)] = line.substring(0, tab)
        }
    }

    fun save(): String = base.entries.sortedBy { it.key }.joinToString("\n") { "${it.value}\t${it.key}" }

    val syncedPaths: List<String> get() = base.keys.sorted()

    /** Compares a full scan of the folder (without ignored files) against the bases. */
    fun scan(files: List<LocalFile>, ignore: IgnoreRules): List<SyncAction> {
        val actions = mutableListOf<SyncAction>()
        val present = HashSet<String>()
        for (file in files) {
            present += file.path
            if (!SyncPolicy.isSafe(file.path)) continue
            if (base[file.path] == file.hash || publishing[file.path] == file.hash || writing[file.path] == file.hash) continue
            publishing[file.path] = file.hash
            actions += SyncAction.Publish(file.path)
        }
        for (path in base.keys.toList()) {
            if (path in present || path in writing) continue
            // Newly ignored files stop syncing without being deleted elsewhere.
            if (ignore.isIgnored(path, false)) {
                base.remove(path)
            } else if (publishing[path] != DELETED) {
                publishing[path] = DELETED
                actions += SyncAction.Unpublish(path)
            }
        }
        return actions
    }

    /**
     * A replica change, from another device or found at startup; `local` is the file's current state.
     * `exists` tells which paths are taken on disk, for naming conflict copies.
     */
    fun remote(entry: RemoteEntry, local: LocalFile?, ignore: IgnoreRules, exists: (String) -> Boolean): List<SyncAction> {
        val path = entry.path
        if (!SyncPolicy.isSafe(path) || ignore.isIgnored(path, false)) return emptyList()
        val synced = base[path]
        val mine = local?.hash
        if (entry.deleted) {
            return when {
                mine == null -> { base.remove(path); emptyList() }
                mine == synced -> { base.remove(path); listOf(SyncAction.Trash(path)) }
                // Edited here since: the edit outlives the deletion.
                else -> { base.remove(path); listOf(SyncAction.Publish(path)) }
            }
        }
        if (mine == entry.hash) {
            base[path] = entry.hash
            return emptyList()
        }
        if (mine == null || mine == synced) {
            writing[path] = entry.hash
            return listOf(SyncAction.Write(path, entry.hash, entry.size))
        }
        // Only this device changed it; the next scan publishes that.
        if (entry.hash == synced) return emptyList()
        val mode = SyncPolicy.mode(local.isText, maxOf(local.size, entry.size), lfsThreshold)
        if (mode == SyncMode.Merge && synced != null) return listOf(SyncAction.Merge(path, synced, entry.hash))
        return conflictCopy(path, entry.hash, entry.size) { exists(it) || ignore.isIgnored(it, false) }
    }

    /** A merge that left conflicts falls back to a conflict copy. */
    fun mergeFailed(path: String, remoteHash: String, size: Double, exists: (String) -> Boolean): List<SyncAction> =
        conflictCopy(path, remoteHash, size, exists)

    /** The merged text is on disk; it builds on the remote version, and the next scan publishes it. */
    fun merged(path: String, remoteHash: String) {
        base[path] = remoteHash
    }

    /** A `Write` finished; `ok` false leaves the path as it was. */
    fun wrote(path: String, hash: String, ok: Boolean) {
        if (writing[path] == hash) writing.remove(path)
        if (ok) base[path] = hash
    }

    /** The replica accepted a `Publish` or `Unpublish`. */
    fun published(path: String, hash: String, deleted: Boolean) {
        val pending = publishing[path]
        if (pending == hash || (deleted && pending == DELETED)) publishing.remove(path)
        if (deleted) base.remove(path) else base[path] = hash
    }

    private fun conflictCopy(path: String, hash: String, size: Double, exists: (String) -> Boolean): List<SyncAction> {
        // The local file stays and is published over the remote version, which lives on as the copy.
        base[path] = hash
        // The copy is a new file to the next scan, which publishes it.
        val copy = SyncPolicy.conflictPath(path) { exists(it) || base.containsKey(it) }
        return listOf(SyncAction.ConflictCopy(path, copy, hash, size))
    }

    private companion object {
        const val DELETED = "-"
    }
}
