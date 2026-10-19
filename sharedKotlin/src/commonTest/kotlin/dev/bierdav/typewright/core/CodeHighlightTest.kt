package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CodeHighlightTest {
    /** Tokens as `text:kind` pairs, easier to read than offsets. */
    private fun tokens(language: String, code: String): List<String> {
        val t = CodeHighlight.tokens(language, code)
        return (t.indices step 3).map { "${code.substring(t[it], t[it] + t[it + 1])}:${t[it + 2]}" }
    }

    private val k = CodeTokenKind

    @Test
    fun resolvesAliases() {
        assertEquals("python", CodeHighlight.language("py"))
        assertEquals("bash", CodeHighlight.language("ZSH"))
        assertEquals("csharp", CodeHighlight.language("c#"))
        assertEquals("typc", CodeHighlight.language("typc"))
        assertEquals("mermaid", CodeHighlight.language("mmd"))
        assertNull(CodeHighlight.language("cobol"))
        assertEquals(0, CodeHighlight.tokens("markdown", "# hi").size)
    }

    @Test
    fun splitsRawBlocks() {
        assertContentEquals(intArrayOf(3, 6, 6, 16), CodeHighlight.rawBlock("```sql\nSELECT 1\n```"))
        assertContentEquals(intArrayOf(4, 6, 6, 10), CodeHighlight.rawBlock("````js x()````"))
        assertEquals(0, CodeHighlight.rawBlock("`x`").size)
        assertEquals(0, CodeHighlight.rawBlock("```\ncode\n```").size)
    }

    @Test
    fun highlightsSqlCaseInsensitively() {
        assertEquals(
            listOf("SELECT:${k.KEYWORD}", "count:${k.FUNCTION}", "From:${k.KEYWORD}", "Where:${k.KEYWORD}",
                "'it''s':${k.STRING}", "-- done:${k.COMMENT}", "VARCHAR:${k.TYPE}", "255:${k.NUMBER}"),
            tokens("sql", "SELECT count(*) From t Where a = 'it''s' -- done\nVARCHAR(255)"),
        )
    }

    @Test
    fun highlightsShellCommandsAndVariables() {
        assertEquals(
            listOf("FOO:${k.VARIABLE}", "BAR:${k.VARIABLE}", "apt-get:${k.FUNCTION}", "if:${k.KEYWORD}",
                "test:${k.FUNCTION}", "\"a :${k.STRING}", "\$HOME:${k.VARIABLE}", "\":${k.STRING}",
                "then:${k.KEYWORD}", "echo:${k.FUNCTION}", "'\$x':${k.STRING}", "\${y}:${k.VARIABLE}",
                "# c:${k.COMMENT}", "fi:${k.KEYWORD}"),
            tokens("bash", "FOO=1 BAR=x apt-get install x#y\nif test \"a \$HOME\"; then echo '\$x' \${y} # c\nfi"),
        )
    }

    @Test
    fun highlightsTemplateLiterals() {
        assertEquals(
            listOf("const:${k.KEYWORD}", "`a :${k.STRING}", "\${:${k.KEYWORD}", "f:${k.FUNCTION}",
                "2:${k.NUMBER}", "}:${k.KEYWORD}", " b`:${k.STRING}", "// x:${k.COMMENT}"),
            tokens("javascript", "const s = `a \${f(2)} b` // x"),
        )
        assertEquals(listOf("let:${k.KEYWORD}", "string:${k.TYPE}", "Foo:${k.TYPE}"), tokens("typescript", "let a: string = new_ as Foo").filterNot { it.startsWith("as:") })
    }

    @Test
    fun highlightsKotlinStrings() {
        assertEquals(
            listOf("@Test:${k.ANNOTATION}", "fun:${k.KEYWORD}", "f:${k.FUNCTION}", "\"\"\"raw \\n :${k.STRING}",
                "\$x:${k.VARIABLE}", "\"\"\"\":${k.STRING}", "/* c */:${k.COMMENT}", "List:${k.TYPE}"),
            tokens("kotlin", "@Test fun f() = \"\"\"raw \\n \$x\"\"\"\" /* c */ List"),
        )
    }

    @Test
    fun highlightsPythonPrefixesAndTripleQuotes() {
        assertEquals(
            listOf("@cache:${k.ANNOTATION}", "def:${k.KEYWORD}", "f:${k.FUNCTION}", "rb'\\x':${k.STRING}",
                "\"\"\"doc\n\"\"\":${k.STRING}", "# end:${k.COMMENT}", "None:${k.KEYWORD}"),
            tokens("python", "@cache\ndef f(): rb'\\x' \"\"\"doc\n\"\"\" # end\nNone"),
        )
    }

    @Test
    fun highlightsJavaAndCSharp() {
        assertEquals(
            listOf("public:${k.KEYWORD}", "int:${k.TYPE}", "'c':${k.STRING}", "0x1F:${k.NUMBER}", "1.5e-3:${k.NUMBER}"),
            tokens("java", "public int x = 'c' + 0x1F + 1.5e-3;"),
        )
        assertEquals(
            listOf("var:${k.KEYWORD}", "@\"C:\\\":${k.STRING}", "\$\"{x}\":${k.STRING}", "\"\"\"a\"b\"\"\":${k.STRING}"),
            tokens("csharp", "var p = @\"C:\\\" + \$\"{x}\" + \"\"\"a\"b\"\"\";"),
        )
    }

    @Test
    fun highlightsMermaid() {
        assertEquals(
            listOf("flowchart:${k.KEYWORD}", "LR:${k.KEYWORD}", "-->:${k.OPERATOR}", "\"go\":${k.STRING}",
                "%% note:${k.COMMENT}", "stateDiagram-v2:${k.KEYWORD}"),
            tokens("mermaid", "flowchart LR\nA-->B[\"go\"] %% note\nstateDiagram-v2"),
        )
    }

    @Test
    fun stopsUnterminatedConstructsAtTheEnd() {
        assertTrue(tokens("javascript", "`a \${b").isNotEmpty())
        assertEquals(listOf("/* x:${k.COMMENT}"), tokens("java", "/* x"))
        assertEquals(listOf("\"a:${k.STRING}", "b:${k.FUNCTION}"), tokens("python", "\"a\nb()"))
    }
}
