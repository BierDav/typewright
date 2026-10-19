# Typewright

Native macOS Typst editor (SwiftUI + AppKit, macOS 26+, Liquid Glass). Edist is the design reference.

## Rules

- No markdown files besides `README.md` and `AGENTS.md`. Do not write docs or memory files.
- Keep code comments short (one line, explain why, not what).
- Match surrounding code style. Prefer native Apple controls and look over custom designs.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:` …); release versions depend on it.

## Layout

- `Typewright.xcodeproj` uses folder-synchronized groups: files added under `Sources/Typewright` or `Tests/TypewrightTests` are picked up automatically, no pbxproj edits.
- `Sources/Typewright/App` app entry, window management (`Opener`, `MainWindowController`), spaces sidebar and selector.
- `Sources/Typewright/Workspace` space model (files, autosave, compile scheduling) and space UI. A space is a folder.
- `Sources/Typewright/Compiler` built-in compiler (`BuiltinCompiler`), external typst download/selection (`CompilerManager`), `typst watch` driver, diagnostics parsing, font sources (`FontLibrary`).
- `TypstBridge/` Rust static library linking typst in process; its `World` serves unsaved buffers from memory. Built by `scripts/build-typst-bridge.sh` as an Xcode build phase (needs `cargo`).
- `Sources/Typewright/Editor` NSTextView based editor, highlighting, line numbers.
- `Sources/Typewright/Preview` PDF (PDFKit), HTML and SVG previews (shown as the inspector pane).
- `scripts/` icon generation, release build, version calculation, cask generation.

## Commands

- Build: `xcodebuild -project Typewright.xcodeproj -scheme Typewright -derivedDataPath .build build`
- Test: `xcodebuild -project Typewright.xcodeproj -scheme Typewright -derivedDataPath .build test`
- Release bundle: `scripts/build-app.sh <version>`
- Icon: `swift scripts/make-icon.swift`

## Gotchas

- Windows are AppKit-managed (`MainWindowController` + `NSHostingController`); one window switches between spaces, or shows none. Don't reintroduce SwiftUI `WindowGroup`.
- Settings use `NSTabViewController` (toolbar style); the SwiftUI `Settings` scene rebuilds its toolbar on tab switches.
- Never create objects with side effects in a view `init` or `@State` default; SwiftUI re-inits views constantly.
- `NSViewRepresentable`s inside split views must implement `sizeThatFits`, or changing fitting sizes crash AppKit's constraint pass.
- The built-in typst version is pinned in `TypstBridge/Cargo.toml` (`typst = "=x.y.z"`); bump all typst crates together.
- External compilers only see the disk: edits are saved on every keystroke and `typst watch` recompiles. The built-in compiler reads buffers and autosaves every 30 s.
- The typst CLI is downloaded to `~/Library/Application Support/Typewright/compilers/<version>/typst`.

## Releases

Run the `Release` workflow in GitHub Actions. Pick `alpha`, `rc` or `stable`, and tick `major` for breaking releases. `scripts/next-version.sh` computes the version from the last stable tag: a major bump if `major` is ticked, a minor bump if a `feat` commit landed since that tag, a patch bump otherwise. Pre-releases get `-alpha.N` / `-rc.N`. The workflow builds, creates the GitHub release and updates `Casks/typewright.rb` (stable) and `Casks/typewright@beta.rb` (every channel) in `BierDav/homebrew-tap`.
