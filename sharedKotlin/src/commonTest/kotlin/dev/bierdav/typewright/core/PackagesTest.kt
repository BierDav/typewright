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

class PackageReposTest {
    @Test
    fun turnsGitHubNamesAndLinksIntoCloneURLs() {
        assertEquals("https://github.com/typst/templates.git", PackageRepos.cloneURL("typst/templates"))
        assertEquals("https://github.com/a/b.git", PackageRepos.cloneURL("https://github.com/a/b/tree/main/src"))
        assertEquals("https://github.com/a/b.git", PackageRepos.cloneURL("github.com/a/b.git"))
        assertEquals("git@gitlab.com:a/b.git", PackageRepos.cloneURL("git@gitlab.com:a/b.git"))
        assertEquals(null, PackageRepos.cloneURL("not a repo"))
        assertEquals("b", PackageRepos.repoName("git@gitlab.com:a/b.git"))
    }

    @Test
    fun readsNameAndVersionOfThePackageTable() {
        val toml = """
            [package]
            name = "my-pkg" # comment
            version = "0.2.1"
            entrypoint = "lib.typ"

            [tool.x]
            name = "other"
        """.trimIndent()
        assertEquals(PackageManifest("my-pkg", "0.2.1"), PackageRepos.manifest(toml))
        assertEquals(null, PackageRepos.manifest("[package]\nname = \"x\""))
    }
}
