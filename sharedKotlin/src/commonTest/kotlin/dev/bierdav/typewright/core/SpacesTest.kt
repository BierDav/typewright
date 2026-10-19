package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class SpacesTest {
    @Test
    fun keepsOrderAndHiddenEntries() {
        val stored = listOf("/a", "/gone", "/b", "/c")
        val visible = listOf("/a", "/b", "/c")
        assertEquals(stored, SpaceOrder.add(stored, "/b"))
        assertEquals(stored + "/d", SpaceOrder.add(stored, "/d"))
        assertEquals(listOf("/b", "/c", "/a", "/gone"), SpaceOrder.move(stored, visible, "/a", 9))
        assertEquals(listOf("/c", "/a", "/b", "/gone"), SpaceOrder.move(stored, visible, "/c", -1))
        assertEquals(stored, SpaceOrder.move(stored, visible, "/x", 0))
        assertEquals(listOf("/a", "/gone", "/z", "/c"), SpaceOrder.replace(stored, "/b", "/z"))
        assertEquals(listOf("/gone", "/b", "/c"), SpaceOrder.remove(listOf("/a/main.typ", "/gone", "/b", "/a", "/c"), "/a") {
            if (it.endsWith(".typ")) it.substringBeforeLast('/') else it
        })
    }

    @Test
    fun scoresMatches() {
        assertEquals(0, FuzzyMatch.score("ma", "main.typ"))
        assertEquals(1, FuzzyMatch.score("ty", "new typ"))
        assertEquals(2, FuzzyMatch.score("in", "main.typ"))
        assertEquals(4, FuzzyMatch.score("mt", "main.typ"))
        assertNull(FuzzyMatch.score("zz", "main.typ"))
    }

    @Test
    fun namesAndPaths() {
        val taken = setOf("untitled.typ", "untitled-2.typ", "Folder")
        assertEquals("untitled-3.typ", Paths.uniqueName("untitled", "typ") { it in taken })
        assertEquals("Folder 2", Paths.uniqueName("Folder", null) { it in taken })
        assertEquals("sub/a.typ", Paths.relative("/space/sub/a.typ", "/space"))
        assertNull(Paths.relative("/spaces/a.typ", "/space"))
        assertEquals("main", Paths.gitBranch("ref: refs/heads/main\n"))
        assertEquals("abcdef1", Paths.gitBranch("abcdef1234567\n"))
        assertEquals(FileKind.Typst, FileKinds.forExtension("TYP"))
        assertNull(FileKinds.forExtension("weird"))
    }
}
