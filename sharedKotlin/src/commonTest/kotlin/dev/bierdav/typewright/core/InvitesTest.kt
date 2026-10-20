package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class InvitesTest {
    private val secret = (0 until 32).joinToString("") { (it * 7 % 256).toString(16).padStart(2, '0') }
    private val device = "ab".repeat(32)

    @Test
    fun roundTrips() {
        val invite = SpaceInvite("1b4e28ba-2fa1-11d2-883f-0016d3cca427", "Thesis ✍️", secret, listOf(device, "cd".repeat(32)))
        val link = SpaceInvites.link(invite)!!
        assertTrue(link.startsWith("typewright://join/"))
        assertTrue(link.removePrefix("typewright://join/").none { it == '+' || it == '/' || it == '=' })
        assertEquals(invite, SpaceInvites.parse(link))
        assertEquals(invite, SpaceInvites.parse("  $link/ "))
    }

    @Test
    fun cleansNamesAndDropsBadHints() {
        val link = SpaceInvites.link(SpaceInvite("x", "../a/b:c", secret.uppercase(), listOf("nope", device, device, device, device)))!!
        val parsed = SpaceInvites.parse(link)!!
        assertEquals("-a-b-c", parsed.name.trimStart('.'))
        assertEquals(secret, parsed.secret)
        assertEquals(SpaceInvites.MAX_HINTS, parsed.hints.size)
        assertEquals("Shared Space", SpaceInvites.folderName(" .. "))
        val long = SpaceInvites.parse(SpaceInvites.link(SpaceInvite("x", "😀".repeat(100), secret, emptyList()))!!)!!
        assertEquals("😀".repeat(30), long.name)
    }

    @Test
    fun rejectsMalformedLinks() {
        assertNull(SpaceInvites.link(SpaceInvite("x", "a", "00", emptyList())))
        assertNull(SpaceInvites.link(SpaceInvite("a/b", "a", secret, emptyList())))
        assertNull(SpaceInvites.parse("https://join/abc"))
        assertNull(SpaceInvites.parse("typewright://join/"))
        assertNull(SpaceInvites.parse("typewright://join/!!!"))
        val link = SpaceInvites.link(SpaceInvite("x", "a", secret, listOf(device)))!!
        // Cut hints and a wrong version don't parse.
        assertNull(SpaceInvites.parse(link.dropLast(4)))
        assertNull(SpaceInvites.parse("typewright://join/B" + link.removePrefix("typewright://join/").drop(1)))
    }
}
