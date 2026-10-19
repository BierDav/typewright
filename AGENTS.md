# Typewright

Native macOS Typst editor (SwiftUI + AppKit, macOS 26+, Liquid Glass). Edist is the design reference.

## Rules

- No markdown files besides `README.md` and `AGENTS.md`. Do not write docs or memory files.
- Keep code comments short (one line, explain why, not what).
- Match surrounding code style. Prefer native Apple controls and look over custom designs.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:` …); release versions depend on it.

## Layout

Every module lives in its own top-level folder; `scripts/` is shared.

- `macApp/` the SwiftUI/AppKit app: `Typewright.xcodeproj`, `Sources/Typewright`, `Tests/TypewrightTests`, `Resources`. The project uses folder-synchronized groups: files added under `Sources/Typewright` or `Tests/TypewrightTests` are picked up automatically, no pbxproj edits.
  - `Sources/Typewright/App` app entry, window management (`Opener`, `MainWindowController`), spaces sidebar and selector.
  - `Sources/Typewright/Workspace` space model (files, autosave, compile scheduling) and space UI. A space is a folder.
  - `Sources/Typewright/Compiler` built-in compiler (`BuiltinCompiler`), external typst download/selection (`CompilerManager`), `typst watch` driver, diagnostics parsing, font sources (`FontLibrary`).
  - `Sources/Typewright/Editor` NSTextView based editor, highlighting, line numbers, tinymist language server client (`LanguageClient`, completions, go to definition) and color literal swatches with the color wheel.
  - `Sources/Typewright/Preview` PDF (PDFKit), HTML and SVG previews (shown as the inspector pane).
  - `Sources/Typewright/Sync` device sync: passkey account (`SyncIdentity`), `SyncService` applying sync actions to folders, `.gitignore`-aware `FolderScanner` and FSEvents `FolderWatcher`, Devices settings.
- `sharedKotlin/` Kotlin Multiplatform logic layer (`dev.bierdav.typewright.core`), shared by the Mac app and the future SolidJS web app. Targets `macosArm64`/`macosX64` (static `TypewrightCore.framework`, built by `scripts/build-core.sh` as an Xcode build phase, needs a JDK) and `js` (ES module with TypeScript types). Only platform-free code lives here so far: diagnostics parsing, release picking, UTF-16 text positions and edits, file kinds, paths, space order, fuzzy matching. Swift keeps thin wrappers with the old APIs.
- `typstBridge/` Rust static library linking typst in process; its `World` serves unsaved buffers from memory.
- `irohBridge/` Rust static library syncing spaces between a user's devices with iroh-docs, iroh-blobs and iroh-gossip; events reach Swift as JSON through one C callback.
- Both Rust bridges are built by `scripts/build-rust-bridge.sh <crate> <lib>` in one Xcode build phase (needs `cargo`).
- `scripts/` build phases, icon generation, release build, version calculation, cask generation.

## Commands

Run from the repository root.

- Build: `xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build build`
- Test: `xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build test`
- Kotlin tests (macOS and Node): `sharedKotlin/gradlew -p sharedKotlin allTests`
- Sync over the network (two devices in one process, real n0 relays): `TEST_RUNNER_TYPEWRIGHT_NETWORK_TESTS=1 xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build test -only-testing:TypewrightTests/SyncNetworkTests` and `cargo test --release --manifest-path irohBridge/Cargo.toml --target-dir .build/cargo -- --ignored`
- Kotlin JS bundle: `sharedKotlin/gradlew -p sharedKotlin jsBrowserProductionLibraryDistribution` (output in `sharedKotlin/build/dist/js/productionLibrary`)
- Release bundle: `scripts/build-app.sh <version>`
- Icon: `swift scripts/make-icon.swift`

## Gotchas

- Windows are AppKit-managed (`MainWindowController` + `NSHostingController`); one window switches between spaces, or shows none. Don't reintroduce SwiftUI `WindowGroup`.
- Settings use `NSTabViewController` (toolbar style); the SwiftUI `Settings` scene rebuilds its toolbar on tab switches.
- Never create objects with side effects in a view `init` or `@State` default; SwiftUI re-inits views constantly.
- `NSViewRepresentable`s inside split views must implement `sizeThatFits`, or changing fitting sizes crash AppKit's constraint pass.
- New logic goes into `sharedKotlin/` when it doesn't need the platform; mark files `@file:JsExport` so the web app sees it. Kotlin `Int` is `Int32` in Swift, `(String) -> Boolean` closures return `KotlinBoolean`, and objects are reached through `.shared`.
- Kotlin type names can clash with the app's (`Diagnostic`, `FileKind`, `TextEdit`); unqualified names resolve to the Swift ones, so qualify Kotlin ones as `TypewrightCore.X`.
- `macosX64` is deprecated in Kotlin and still needed for the universal release build.
- Sync, per space and opt-in: every key derives from one 32-byte account secret (a passkey's PRF output, or a recovery key), so devices of an account find each other through a pkarr record and open the same replicas without exchanging anything. One replica per space maps relative paths to blob hashes, written by one shared author, so the newest write wins; deletions are tombstone blobs, since empty entries can't be told from empty files.
- `SpaceSync` (Kotlin) keeps the last synced hash per path: a change on one side applies, changes on both sides of a small text file merge line by line (`TextMerge`), anything else becomes a `name (conflict).ext` copy. Binary kinds, contents that sniff as binary and files over the limit (Devices settings, 1 MB default) use LFS mode and are never diffed.
- Passkeys need `TYPEWRIGHT_PASSKEY_DOMAIN` set, `macApp/Resources/Passkeys.entitlements` as `CODE_SIGN_ENTITLEMENTS` with a provisioning profile, and that domain serving `apple-app-site-association` with `webcredentials`. Ad-hoc builds can't carry the entitlement and fall back to recovery keys.
- Synced spaces autosave after 1 s instead of 30 s, flush before sync writes (`SyncService.willChangeFiles`) and reload after (`didChangeFiles`).
- The built-in typst version is pinned in `typstBridge/Cargo.toml` (`typst = "=x.y.z"`); bump all typst crates together.
- External compilers only see the disk: edits are saved on every keystroke and `typst watch` recompiles. The built-in compiler reads buffers and autosaves every 30 s.
- The typst CLI is downloaded to `~/Library/Application Support/Typewright/compilers/<version>/typst`.
- tinymist (the language server) is downloaded to `~/Library/Application Support/Typewright/tinymist/tinymist`; a Homebrew install wins. One process runs per open space and gets full-text `didChange`s.

## Releases

Run the `Release` workflow in GitHub Actions. Pick `alpha`, `rc` or `stable`, and tick `major` for breaking releases. `scripts/next-version.sh` computes the version from the last stable tag: a major bump if `major` is ticked, a minor bump if a `feat` commit landed since that tag, a patch bump otherwise. Pre-releases get `-alpha.N` / `-rc.N`. The workflow builds, creates the GitHub release and updates `Casks/typewright.rb` (stable) and `Casks/typewright@beta.rb` (every channel) in `BierDav/homebrew-tap`.
