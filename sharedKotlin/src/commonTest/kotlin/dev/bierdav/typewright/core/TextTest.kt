package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class TextTest {
    private val text = "#let a = 1\n😀 \"hi\" \"x\\\"y\"\nlast"

    @Test
    fun convertsPositionsInUtf16() {
        assertEquals(TextPosition(1, 3), TextPositions.position(14, text))
        assertEquals(14, TextPositions.offset(1, 3, text))
        assertEquals(text.length, TextPositions.offset(9, 0, text))
        assertEquals(TextPosition(2, 4), TextPositions.position(1000, text))
        assertEquals(TextRange(11, 3), TextPositions.range(TextPosition(1, 0), TextPosition(1, 3), text))
    }

    @Test
    fun readsLines() {
        assertEquals("#let a = 1", TextPositions.lineText(0, text))
        assertEquals("last", TextPositions.lineText(2, text))
    }

    @Test
    fun findsStringLiterals() {
        val hi = text.indexOf("hi")
        assertEquals(TextRange(hi, 2), TextPositions.stringLiteralRange(hi + 1, text))
        val escaped = text.indexOf("x\\")
        assertEquals(TextRange(escaped, 4), TextPositions.stringLiteralRange(escaped + 3, text))
        assertNull(TextPositions.stringLiteralRange(2, text))
    }

    @Test
    fun appliesEditsBackToFront() {
        val edits = listOf(TextEdit(TextRange(0, 4), "#set"), TextEdit(TextRange(9, 1), "2"), TextEdit(TextRange(90, 1), "!"))
        assertEquals("#set a = 2", TextEdits.apply(edits, "#let a = 1"))
    }

    @Test
    fun differenceIsOneMinimalEdit() {
        assertEquals(TextEdit(TextRange(4, 0), "X"), TextEdits.difference("abcdef", "abcdXef"))
        assertEquals(TextEdit(TextRange(1, 2), ""), TextEdits.difference("abca", "aa"))
        assertEquals(TextEdit(TextRange(4, 0), ""), TextEdits.difference("same", "same"))
        // Repeated letters: the edit lands after the common start.
        assertEquals(TextEdit(TextRange(2, 0), "a"), TextEdits.difference("aa", "aaa"))
        for ((old, new) in listOf("x\uD83D\uDE00y" to "x\uD83D\uDE01y", "ab" to "", "" to "ab")) {
            assertEquals(new, TextEdits.apply(listOf(TextEdits.difference(old, new)), old))
        }
        // Emoji differing only in the low half are replaced whole.
        assertEquals(TextEdit(TextRange(1, 2), "\uD83D\uDE01"), TextEdits.difference("x\uD83D\uDE00y", "x\uD83D\uDE01y"))
    }
}
