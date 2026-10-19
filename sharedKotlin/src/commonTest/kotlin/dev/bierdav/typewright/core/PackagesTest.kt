package dev.bierdav.typewright.core

import kotlin.test.Test

import kotlin.test.assertEquals

class PackagesTest {
    @Test
    fun findsSpecsInImportStrings() {
        val text = "#import \"@local/my-pkg:0"
        assertEquals(9, PackageSpecs.specStart(text, text.length))
        assertEquals(9, PackageSpecs.specStart("#import \"@", 10))
        assertEquals(-1, PackageSpecs.specStart("#import \"local", 14))
        assertEquals(-1, PackageSpecs.specStart("see @intro", 10))
    }

    @Test
    fun offersNewestVersionsUntilOneIsTyped() {
        // Versions come newest first, as the package library lists them.
        val specs = listOf("@local/a:2.0.0", "@local/a:1.0.0", "@local/b:0.1.0")
        assertEquals(listOf("@local/a:2.0.0", "@local/b:0.1.0"), PackageSpecs.candidates("@lo", specs))
        assertEquals(listOf("@local/a:2.0.0", "@local/a:1.0.0"), PackageSpecs.candidates("@local/a:", specs))
    }
}
