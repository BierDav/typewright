package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DiagnosticsTest {
    @Test
    fun parsesShortFormat() {
        val out = """
            main.typ:2:3: error: cannot access fields on type integer
            @preview/icons:0.1.0/index.typ:8:21: warning: no whitespace before raw text
            garbage line
        """.trimIndent()
        val d = Diagnostics.parse(out)
        assertEquals(2, d.size)
        assertEquals(Diagnostic("main.typ", 2, 3, Severity.Error, "cannot access fields on type integer"), d[0])
        assertFalse(d[0].isFromPackage)
        assertTrue(d[1].isFromPackage)
        assertEquals(Severity.Warning, d[1].severity)
    }

    @Test
    fun parsesWatchDuration() {
        assertEquals(0.01581, Diagnostics.compileDuration("[11:18:33] compiled successfully in 15.81 ms")!!, 1e-9)
        assertEquals(1.5, Diagnostics.compileDuration("[11:18:33] compiled with warnings in 1.5 s"))
        assertNull(Diagnostics.compileDuration("[11:18:35] compiled with errors"))
    }
}
