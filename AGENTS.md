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
  - `Sources/Shared` code compiled into both the app and the Quick Look extension (font search, Markdown rendering); only system frameworks and `TypstBridge`.
  - `QuickLook` the Finder Quick Look extension (`TypewrightQuickLook.appex`, data based): `.typ` compiled to PDF in process, Markdown as HTML. Its Info.plist and entitlements live in `Resources`.
  - `Sources/Typewright/Sync` device sync: passkey account (`SyncIdentity`), `SyncService` applying sync actions to folders, `LiveEditing` (the shown file shared live with other devices, with their cursors), `Invites` (`typewright://join/…` links), `.gitignore`-aware `FolderScanner` and FSEvents `FolderWatcher`, Devices settings.
- `sharedKotlin/` Kotlin Multiplatform logic layer (`dev.bierdav.typewright.core`), shared by the Mac app and the web app. Targets `macosArm64`/`macosX64` (static `TypewrightCore.framework`, built by `scripts/build-core.sh` as an Xcode build phase, needs a JDK) and `js` (ES module with TypeScript types). Only platform-free code lives here so far: diagnostics parsing, release picking, UTF-16 text positions and edits, file kinds, paths, space order, fuzzy matching, invite links, highlighting of code in raw blocks, and the solveng calculation language (`Solveng`: highlighting and completions for ```` ```solveng ```` code, and untagged code when a document sets `plain-code: true`). Swift keeps thin wrappers with the old APIs.
- `webApp/` SolidStart (client only) web app on GitHub Pages: CodeMirror editor, spaces in origin storage (`lib/storage.ts`), typst in a worker (`workers/typst.worker.ts`), sync through the iroh bridge (`lib/sync.ts`), passkey account (`lib/identity.ts`). Uses the Kotlin core's JS build and both Rust bridges built for wasm into `src/wasm/` (git-ignored).
- `typstBridge/` Rust static library linking typst in process; its `World` serves unsaved buffers from memory.
- `irohBridge/` Rust static library syncing spaces between a user's devices (and invited accounts) with iroh-docs, iroh-blobs and iroh-gossip, plus live editing of open files (`live.rs`, yrs CRDT over gossip); events reach Swift as JSON through one C callback.
- Both Rust bridges are built by `scripts/build-rust-bridge.sh <crate> <lib>` (needs `cargo`): the typst bridge in the Quick Look extension's build phase (the app depends on it, so it builds first), the iroh bridge in the app's. Their C API lives in `ffi.rs`, the wasm-bindgen API in `web.rs`.
- `scripts/` build phases, icon generation, release build, version calculation, cask generation.

## Commands

Run from the repository root.

- Build: `xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build build`
- Test: `xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build test`
- Kotlin tests (macOS and Node): `sharedKotlin/gradlew -p sharedKotlin allTests`
- Sync over the network (two devices in one process, real n0 relays): `TEST_RUNNER_TYPEWRIGHT_NETWORK_TESTS=1 xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build test -only-testing:TypewrightTests/SyncNetworkTests` and `cargo test --release --manifest-path irohBridge/Cargo.toml --target-dir .build/cargo -- --ignored`
- Kotlin JS bundle: `sharedKotlin/gradlew -p sharedKotlin jsBrowserProductionLibraryDistribution` (output in `sharedKotlin/build/dist/js/productionLibrary`)
- Web app: `scripts/build-web-wasm.sh` (needs Homebrew's `llvm`) and the Kotlin JS bundle first, then `bun install` and `bun run dev` / `bun run check` / `bun run build` in `webApp/`
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
- Sync, per space and opt-in: every key derives from one 32-byte account secret (a passkey's PRF output, or a recovery key), so devices of an account find each other through a pkarr record and open the same replicas without exchanging anything. One replica per space maps relative paths to blob hashes, written by one author derived from the space's namespace secret, so the newest write wins (lookups take the newest entry across authors, as older entries were written by the account's author); deletions are tombstone blobs, since empty entries can't be told from empty files.
- `SpaceSync` (Kotlin) keeps the last synced hash per path: a change on one side applies, changes on both sides of a small text file merge line by line (`TextMerge`), anything else becomes a `name (conflict).ext` copy. Binary kinds, contents that sniff as binary and files over the limit (Devices settings, 1 MB default) use LFS mode and are never diffed.
- Passkeys are the only sign-in. The relying party is `TYPEWRIGHT_PASSKEY_DOMAIN` (`bierdav.github.io`), which must serve `/.well-known/apple-app-site-association` listing `G5K3D2J5Y9.dev.bierdav.Typewright` under `webcredentials`. Only `scripts/build-app.sh` with `TYPEWRIGHT_SIGN_IDENTITY` and `TYPEWRIGHT_PROVISIONING_PROFILE` signs in the entitlement (the release workflow imports them from secrets and refuses to publish without them or the notary secrets); `SyncIdentity.passkeyDomain` checks the running app's entitlements, so ad-hoc and debug builds have no passkeys and no sync. The secret lives in the data protection keychain, which never prompts but needs that signature too.
- Space membership lives in the account replica as `member/<space>/<device>`: "Stop Syncing" removes only this device, a space without members drops off the account, and "Remove From All Devices" writes `removed/<space>`, which makes every device stop (files stay).
- Sharing with other accounts: "Copy Invite Link…" (spaces sidebar, Devices settings, command palette) builds `typewright://join/<base64url>` (`SpaceInvites` in Kotlin: namespace secret, space id, name, up to 3 endpoint ids to dial first) and marks the space `"shared": true` in the account replica. Joined spaces store `"secret"` in the joiner's account entry, so their other devices get it too. Every device syncing a shared space lists itself in a pkarr record keyed by that secret and syncs replica and live topic (`shared live v0`, from the secret) with everyone listed; iroh-docs also redials the last few peers it synced a replica with. Leaving takes only this device out of the record. Anyone with the link can edit; there's no revoking short of a new space.
- Live editing: the selected text file of a synced space joins a per-space gossip topic. Remote changes queue in Rust until Swift calls `tws_live_sync` with its current text, so edits never interleave with typing; when two sessions meet the older one wins and the other merges its edits in (`TextMerge`). Undo goes through the CRDT and takes back only this device's edits. Files with a live peer aren't rewritten by file sync (`SpaceSync.accepted`).
- Synced spaces autosave after 1 s instead of 30 s, flush before sync writes (`SyncService.willChangeFiles`) and reload after (`didChangeFiles`).
- Relative font folders (Settings › Fonts, default `./fonts`) are looked up in the previewed file's folder and every folder above it (`FontSearch`). The app writes the folder settings to `~/Library/Application Support/Typewright/fonts/paths.json`, since the sandboxed Quick Look extension can't read its defaults; the extension reads files through temporary read-only exceptions and keeps typst's package cache in the real home.
- `scripts/build-app.sh` signs the extension with its own entitlements before the app; `--deep` would drop its sandbox.
- The built-in typst version is pinned in `typstBridge/Cargo.toml` (`typst = "=x.y.z"`); bump all typst crates together.
- External compilers only see the disk: edits are saved on every keystroke and `typst watch` recompiles. The built-in compiler reads buffers and autosaves every 30 s.
- The typst CLI is downloaded to `~/Library/Application Support/Typewright/compilers/<version>/typst`.
- tinymist (the language server) is downloaded to `~/Library/Application Support/Typewright/tinymist/tinymist`; a Homebrew install wins. One process runs per open space and gets full-text `didChange`s.

- The web app derives the same account from the same passkey only on the relying party's domain, so it's hosted at `SpaceInvites.WEB_APP` (`bierdav.github.io/typewright`). One tab per browser runs the sync node (a Web Lock); other tabs show "Syncing in another tab".
- Web invite links are `<web app>/join#<payload>`; GitHub Pages serves `404.html` (the app) for `/join`.

## Releases

Run the `Release` workflow in GitHub Actions. Pick `alpha`, `rc` or `stable`, and tick `major` for breaking releases. `scripts/next-version.sh` computes the version from the last stable tag: a major bump if `major` is ticked, a minor bump if a `feat` commit landed since that tag, a patch bump otherwise. Pre-releases get `-alpha.N` / `-rc.N`. The workflow builds, creates the GitHub release and updates `Casks/typewright.rb` (stable) and `Casks/typewright@beta.rb` (every channel) in `BierDav/homebrew-tap`.

The `Web App` workflow deploys `webApp/` to GitHub Pages on every push to `main` that touches it, the Kotlin core or the bridges (Pages has to be set to "GitHub Actions" in the repository settings).
