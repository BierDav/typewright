package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ArgumentsTest {
    @Test
    fun findsNamedArguments() {
        val text = "#solve($ t = \"@Q\" / I $, unit: \"min\", digits: f(1, 2))"
        assertEquals("unit", Arguments.namedArgument(text, text.indexOf("unit") + 2)?.name)
        assertEquals(TextRange(text.indexOf("unit"), 4), Arguments.namedArgument(text, text.indexOf("min"))?.range)
        assertEquals("digits", Arguments.namedArgument(text, text.indexOf("f("))?.name)
        assertNull(Arguments.namedArgument(text, text.indexOf("2)")), "an inner call's positional argument")
        assertNull(Arguments.namedArgument(text, text.indexOf("@Q")), "positional")
        assertNull(Arguments.namedArgument("#let unit: x", 6))
        assertNull(Arguments.namedArgument("Note: (unit: x)", 0))
    }

    @Test
    fun readsParameterTypes() {
        val signature = "solve(approx: auto | bool, config: dictionary, unit: auto | str, sci: array | (a, b)) -> content"
        assertEquals("auto | str", Arguments.parameterType(signature, "unit"))
        assertEquals("array | (a, b)", Arguments.parameterType(signature, "sci"))
        assertNull(Arguments.parameterType(signature, "fig"))
    }
}
