plugins {
    kotlin("multiplatform") version "2.4.21"
}

kotlin {
    // Both, since release builds of the app are universal.
    listOf(macosArm64(), macosX64()).forEach {
        it.binaries.framework {
            baseName = "TypewrightCore"
            isStatic = true
        }
    }

    // Consumed by the SolidJS web app as an ES module with TypeScript types.
    js {
        outputModuleName = "typewright-core"
        // Tests run on Node; the browser runner needs Chrome.
        browser { testTask { enabled = false } }
        nodejs()
        useEsModules()
        binaries.library()
        generateTypeScriptDefinitions()
    }

    compilerOptions {
        optIn.add("kotlin.js.ExperimentalJsExport")
        freeCompilerArgs.add("-Xexpect-actual-classes")
    }

    sourceSets {
        commonTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
