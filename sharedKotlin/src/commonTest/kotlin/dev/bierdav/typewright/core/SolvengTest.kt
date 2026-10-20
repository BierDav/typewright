package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SolvengTest {
    private val k = CodeTokenKind

    private fun tokens(code: String): List<String> {
        val t = Solveng.tokens(code)
        return (t.indices step 3).map { "${code.substring(t[it], t[it] + t[it + 1])}:${t[it + 2]}" }
    }

    /** Completions at the `|` in `doc`. */
    private fun complete(doc: String): SolvengCompletions? = Solveng.complete(doc.replace("|", ""), doc.indexOf('|'))

    private fun labels(doc: String) = complete(doc)!!.items.map { it.label }

    @Test
    fun highlightsValuesUnitsAndVariables() {
        assertEquals(
            listOf("t:${k.VARIABLE}", "=:${k.OPERATOR}", "Q0:${k.VARIABLE}", "2:${k.NUMBER}", "I:${k.VARIABLE}",
                "->:${k.OPERATOR}", "h:${k.UNIT}", "// half:${k.COMMENT}"),
            tokens("t = Q0 / (2 I) -> h // half"),
        )
        assertEquals(
            listOf("g:${k.VARIABLE}", "=:${k.OPERATOR}", "9.81:${k.NUMBER}", "m:${k.UNIT}", "s:${k.UNIT}", "2:${k.UNIT}",
                ";:${k.OPERATOR}", "x:${k.VARIABLE}", "=:${k.OPERATOR}", "3:${k.NUMBER}", "kOhm:${k.UNIT}"),
            tokens("g = 9.81 m/s^2; x = 3 kOhm"),
        )
    }

    @Test
    fun highlightsBracketsFunctionsAndInlining() {
        assertEquals(
            listOf("P:${k.VARIABLE}", "=:${k.OPERATOR}", "5:${k.NUMBER}", "V:${k.UNIT}", "I:${k.VARIABLE}",
                "sqrt:${k.FUNCTION}", "@R:${k.ANNOTATION}", "2:${k.NUMBER}", "pi:${k.KEYWORD}", "f:${k.VARIABLE}"),
            tokens("P = [5 V] I sqrt(@R) 2 pi f"),
        )
        // A letter after a number is a unit only if solveng knows it.
        assertEquals(listOf("y:${k.VARIABLE}", "=:${k.OPERATOR}", "2:${k.NUMBER}", "R:${k.VARIABLE}"), tokens("y = 2 R"))
    }

    @Test
    fun knowsUnitsWithPrefixesAndSpellings() {
        assertTrue(Solveng.isUnit("mAh"))
        assertTrue(Solveng.isUnit("kOhm"))
        assertTrue(Solveng.isUnit("uA"))
        assertTrue(Solveng.isUnit("degC"))
        assertFalse(Solveng.isUnit("R"))
        assertFalse(Solveng.isUnit("Q0"))
        assertEquals("solveng", CodeHighlight.language("solveng"))
    }

    @Test
    fun findsBodiesOfSolvengCode() {
        assertContentEquals(intArrayOf(10, 16), Solveng.body("```solveng x = 1```", plain = false))
        assertEquals(0, Solveng.body("```py x = 1```", plain = true).size)
        assertEquals(0, Solveng.body("`x = 1`", plain = false).size)
        assertContentEquals(intArrayOf(1, 6), Solveng.body("`x = 1`", plain = true))
        assertContentEquals(intArrayOf(3, 10), Solveng.body("```\nx = 1\n```", plain = true))
        assertTrue(Solveng.plainCode("#show: solve-block.with(plain-code: true)"))
        assertFalse(Solveng.plainCode("#show: solve-block"))
    }

    @Test
    fun completesDefinitionsFromTheWholeDocument() {
        val doc = """
            #def("R = 7.2 kOhm", "f(x) = x^2 + 1")
            The load draws ${'$'}I = 30 "mA"${'$'} and ${'$'}Q_0/2 = I t${'$'}.
            ```solveng
            P = [5 V] I
            U = |
            ```
        """.trimIndent()
        val c = complete(doc)
        assertNotNull(c)
        val byLabel = c.items.associateBy { it.label }
        assertEquals("= 30 mA", byLabel.getValue("I").detail)
        assertEquals("= 7.2 kOhm", byLabel.getValue("R").detail)
        assertEquals("f(\$0)", byLabel.getValue("f(x)").insert)
        assertEquals(SolvengItemKind.FUNCTION, byLabel.getValue("sqrt").kind)
        assertTrue("P" in byLabel)
        // Equations that aren't definitions define nothing by name.
        assertFalse(c.items.any { it.label == "Q_0" })
    }

    @Test
    fun completesUnitsWhereAValueIsWritten() {
        val units = labels("```solveng\nI = 30 m|\n```")
        assertTrue("mA" in units && "kOhm" in units && "h" in units)
        assertTrue("A" in labels("```solveng\nP = [5 |] I\n```"))
        assertTrue("mW" in labels("```solveng\nP = U I -> |\n```"))
        assertTrue("s" in labels("```solveng\ng = 9.81 m/|\n```"))
        assertTrue("bar" in labels("#solve-config(units: (bar: \"100 kPa\"))\n```solveng\np = 3 |\n```"))
        assertFalse("mA" in labels("```solveng\nU = 2 I |\n```"))
        // The word being typed is replaced.
        assertEquals("```solveng\nI = 30 ".length, complete("```solveng\nI = 30 mA|\n```")!!.from)
    }

    @Test
    fun onlyInSolvengCode() {
        assertNull(complete("```py\nx = |\n```"))
        assertNull(complete("text `x = |`"))
        assertNotNull(complete("#show: solve-block.with(plain-code: true)\ntext `x = |`"))
        assertNotNull(complete("inline ```solveng = |```"))
        assertEquals(0, complete("```solveng\nx = 1 // a |\n```")!!.items.size)
    }
}
