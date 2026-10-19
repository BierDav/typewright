package dev.bierdav.typewright.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ReleasesTest {
    @Test
    fun picksNewestPatchPerMinor() {
        val asset = "typst-aarch64-apple-darwin.tar.xz"
        fun r(tag: String, pre: Boolean = false) = GitHubRelease(tag, pre, listOf(ReleaseAsset(asset, "https://x/$tag")))
        val picked = Releases.pick(
            listOf(r("v0.15.0-rc.1", pre = true), r("v0.15.1"), r("v0.15.0"), r("v0.14.2"), r("v0.14.10"), r("v0.10.0")),
            asset,
        )
        assertEquals(listOf("0.15.1", "0.14.10"), picked.map { it.version })
        assertEquals("https://x/v0.15.1", picked[0].assetUrl)
    }

    @Test
    fun comparesNumerically() {
        assertTrue(Versions.isNewer("0.14.10", "0.14.2"))
        assertTrue(Versions.isNewer("1.0.0", "0.99.99"))
        assertFalse(Versions.isNewer("0.13.1", "0.13.1"))
        assertTrue(Versions.isNewer("0.13.1-rc.2", "0.13.1-rc.1"))
        assertTrue(Versions.isNewer("0.13.1.1", "0.13.1"))
    }
}
