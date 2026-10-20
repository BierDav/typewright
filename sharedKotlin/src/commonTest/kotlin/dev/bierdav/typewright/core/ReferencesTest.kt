package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals

class ReferencesTest {
    private val files = setOf("main.typ", "chapters/intro.typ", "img/logo.png", "img", "chapters", "refs.bib")
    private fun exists(path: String) = path in files

    private fun summary(refs: List<PathReference>) = refs.map { "${it.line}:${it.oldPath}->${it.newPath}:${it.certain}:${it.inComment}" }

    @Test
    fun rewritesReferencesToTheMovedFile() {
        val text = """
            #import "chapters/intro.typ": *
            #include "/chapters/intro.typ"
            // see "chapters/intro.typ"
            #my-chapter("./chapters/intro.typ")
            #image("img/logo.png")
        """.trimIndent()
        val refs = PathReferences.moved(text, "main.typ", "chapters/intro.typ", "parts/intro.typ", ::exists)
        assertEquals(
            listOf(
                "0:chapters/intro.typ->parts/intro.typ:true:false",
                "1:/chapters/intro.typ->/parts/intro.typ:true:false",
                "2:chapters/intro.typ->parts/intro.typ:false:true",
                "3:./chapters/intro.typ->./parts/intro.typ:false:false",
            ),
            summary(refs),
        )
        val edits = refs.map { TextEdit(it.range, it.newPath) }
        assertEquals("#import \"parts/intro.typ\": *", TextEdits.apply(edits, text).lines().first())
    }

    @Test
    fun followsTheMovingFilesOwnReferences() {
        val text = "#image(\"../img/logo.png\")\n#bibliography(\"/refs.bib\")\n#import \"@preview/cetz:0.3.1\""
        val refs = PathReferences.moved(text, "chapters/intro.typ", "chapters/intro.typ", "intro.typ", ::exists)
        assertEquals(listOf("0:../img/logo.png->img/logo.png:true:false"), summary(refs))
    }

    @Test
    fun foldersMoveWithTheirContents() {
        val text = "#image(\"logo.png\")\n#import \"../main.typ\""
        // A file inside the moved folder keeps references inside it, but one to the outside changes depth.
        val refs = PathReferences.moved(text, "img/a.typ", "img", "assets/img", ::exists)
        assertEquals(listOf("1:../main.typ->../../main.typ:true:false"), summary(refs))
        val outside = PathReferences.moved("#image(\"img/logo.png\")", "main.typ", "img", "assets/img", ::exists)
        assertEquals(listOf("0:img/logo.png->assets/img/logo.png:true:false"), summary(outside))
    }

    @Test
    fun skipsMissingPathsRawAndUrls() {
        val text = "#link(\"https://x.y/img/logo.png\")\n#image(\"img/missing.png\")\n```\n#image(\"img/logo.png\")\n```\nhttps://example.com \"img/logo.png\""
        val refs = PathReferences.moved(text, "main.typ", "img/logo.png", "logo.png", ::exists)
        assertEquals(
            listOf("3:img/logo.png->logo.png:false:true", "5:img/logo.png->logo.png:false:false"),
            summary(refs),
        )
    }

    @Test
    fun relativePaths() {
        assertEquals("../b/c.typ", PathReferences.relativePath("a", "b/c.typ"))
        assertEquals("c.typ", PathReferences.relativePath("", "c.typ"))
        assertEquals("../..", PathReferences.relativePath("a/b", ""))
        assertEquals("x/y.png", PathReferences.relocate("img/y.png", "img", "x"))
    }
}
