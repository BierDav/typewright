package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class IgnoreTest {
    private val rules = IgnoreRules().apply {
        add("", "# build output\n*.pdf\n!keep.pdf\n/out/\nbuild/\ndocs/**/*.tmp\n\\#literal\n")
        add("sub", "notes.txt\n/local.typ\n")
    }

    @Test
    fun followsGitignore() {
        assertTrue(rules.isIgnored("main.pdf", false))
        assertTrue(rules.isIgnored("sub/deep/x.pdf", false))
        assertFalse(rules.isIgnored("keep.pdf", false))
        assertTrue(rules.isIgnored("out/a.typ", false))
        assertFalse(rules.isIgnored("sub/out/a.typ", false))
        assertTrue(rules.isIgnored("sub/build/a.typ", false))
        assertFalse(rules.isIgnored("build", false))
        assertTrue(rules.isIgnored("docs/a/b/c.tmp", false))
        assertTrue(rules.isIgnored("#literal", false))
        assertTrue(rules.isIgnored("sub/notes.txt", false))
        assertTrue(rules.isIgnored("sub/a/notes.txt", false))
        assertFalse(rules.isIgnored("notes.txt", false))
        assertTrue(rules.isIgnored("sub/local.typ", false))
        assertFalse(rules.isIgnored("sub/a/local.typ", false))
        assertTrue(rules.isIgnored(".git/HEAD", false))
        assertTrue(rules.isIgnored(".DS_Store", false))
    }
}

class MergeTest {
    @Test
    fun mergesSeparateEdits() {
        val base = "a\nb\nc\nd\ne\n"
        val local = "A\nb\nc\nd\ne\n"
        val remote = "a\nb\nc\nd\nE\nf\n"
        assertEquals(MergeResult("A\nb\nc\nd\nE\nf\n", 0), TextMerge.merge3(base, local, remote))
    }

    @Test
    fun mergesInsertionsAndDeletions() {
        val base = "one\ntwo\nthree\nfour\n"
        val local = "zero\none\ntwo\nthree\nfour\n"
        val remote = "one\nthree\nfour"
        assertEquals(MergeResult("zero\none\nthree\nfour", 0), TextMerge.merge3(base, local, remote))
    }

    @Test
    fun marksConflicts() {
        val result = TextMerge.merge3("x\ny\n", "x\nlocal\n", "x\nremote\n")
        assertEquals(1, result.conflicts)
        assertEquals("x\n<<<<<<< local\nlocal\n=======\nremote\n>>>>>>> remote\n", result.text)
    }
}

class SpaceSyncTest {
    private val none = IgnoreRules()
    private fun text(path: String, hash: String, size: Double = 10.0) = LocalFile(path, hash, size, true)
    private fun entry(path: String, hash: String, deleted: Boolean = false) = RemoteEntry(path, hash, 10.0, deleted)

    @Test
    fun publishesLocalChangesOnce() {
        val sync = SpaceSync()
        assertEquals(listOf<SyncAction>(SyncAction.Publish("a.typ")), sync.scan(listOf(text("a.typ", "h1")), none))
        assertEquals(emptyList(), sync.scan(listOf(text("a.typ", "h1")), none))
        sync.published("a.typ", "h1", false)
        assertEquals(emptyList(), sync.scan(listOf(text("a.typ", "h1")), none))
        assertEquals(listOf<SyncAction>(SyncAction.Unpublish("a.typ")), sync.scan(emptyList(), none))
        sync.published("a.typ", "del", true)
        assertEquals(emptyList(), sync.syncedPaths)
    }

    @Test
    fun appliesRemoteChanges() {
        val sync = SpaceSync()
        val write = sync.remote(entry("a.typ", "h1"), null, none) { false }
        assertEquals(listOf<SyncAction>(SyncAction.Write("a.typ", "h1", 10.0)), write)
        // Scans while the write is in flight don't publish the half-synced file.
        assertEquals(emptyList(), sync.scan(listOf(text("a.typ", "h1")), none))
        sync.wrote("a.typ", "h1", true)
        assertEquals(listOf<SyncAction>(SyncAction.Write("a.typ", "h2", 10.0)), sync.remote(entry("a.typ", "h2"), text("a.typ", "h1"), none) { false })
        sync.wrote("a.typ", "h2", true)
        assertEquals(listOf<SyncAction>(SyncAction.Trash("a.typ")), sync.remote(entry("a.typ", "x", deleted = true), text("a.typ", "h2"), none) { false })
    }

    @Test
    fun mergesTextAndCopiesBinaryConflicts() {
        val sync = SpaceSync()
        sync.load("b0\tmain.typ\nb0\tfig.png")
        assertEquals(
            listOf<SyncAction>(SyncAction.Merge("main.typ", "b0", "r1")),
            sync.remote(entry("main.typ", "r1"), text("main.typ", "l1"), none) { false },
        )
        val copy = sync.remote(entry("fig.png", "r1"), LocalFile("fig.png", "l1", 10.0, false), none) { it == "fig (conflict).png" }
        assertEquals(listOf<SyncAction>(SyncAction.ConflictCopy("fig.png", "fig (conflict 2).png", "r1", 10.0)), copy)
        // The local version wins afterwards.
        assertEquals(listOf<SyncAction>(SyncAction.Publish("fig.png")), sync.scan(listOf(LocalFile("fig.png", "l1", 10.0, false)), none).take(1))
    }

    @Test
    fun largeTextFilesUseLfs() {
        val sync = SpaceSync(lfsThreshold = 100.0)
        sync.load("b0\tbig.csv")
        val actions = sync.remote(RemoteEntry("big.csv", "r1", 500.0, false), LocalFile("big.csv", "l1", 500.0, true), none) { false }
        assertTrue(actions.single() is SyncAction.ConflictCopy)
        assertEquals(SyncMode.Lfs, SyncPolicy.mode(false, 5.0, 100.0))
        assertEquals(SyncMode.Merge, SyncPolicy.mode(true, 5.0, 100.0))
    }

    @Test
    fun keepsLocalEditsOverRemoteDeletionAndRejectsUnsafePaths() {
        val sync = SpaceSync()
        sync.load("b0\ta.typ")
        assertEquals(listOf<SyncAction>(SyncAction.Publish("a.typ")), sync.remote(entry("a.typ", "x", deleted = true), text("a.typ", "l1"), none) { false })
        assertEquals(emptyList(), sync.remote(entry("../evil", "h"), null, none) { false })
        assertEquals(emptyList(), sync.remote(entry(".git/config", "h"), null, none) { false })
        assertEquals(emptyList(), sync.remote(entry("out.pdf", "h"), null, IgnoreRules().apply { add("", "*.pdf") }) { false })
    }

    @Test
    fun savesBases() {
        val sync = SpaceSync()
        sync.load("h1\ta b/c.typ\nh2\tx.typ")
        val copy = SpaceSync().apply { load(sync.save()) }
        assertEquals(listOf("a b/c.typ", "x.typ"), copy.syncedPaths)
    }
}
