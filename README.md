<p align="center">
  <img src="macApp/Resources/logo.png" width="128" alt="Typewright logo">
</p>

<h1 align="center">Typewright</h1>

<p align="center">A native, open source <a href="https://typst.app">Typst</a> editor for macOS with a live preview.</p>

## Install

```sh
brew install --cask bierdav/tap/typewright
```

Update with `brew upgrade --cask typewright`.

Want alpha and release-candidate builds? Install `bierdav/tap/typewright@beta` instead.

Typewright needs macOS 26 or newer. On first launch it downloads the official Typst compiler. You can switch between Typst versions in Settings.

## Web app

[bierdav.github.io/typewright](https://bierdav.github.io/typewright/) runs Typewright in the browser. Spaces stay in the browser's storage and sync with your Mac through the same passkey.

## Command line

The Mac app also runs headlessly with `Typewright.app/Contents/MacOS/Typewright --cli`. Opening the app creates a wrapper at `.jj/typewright/bin/typewright` in the library root:

```sh
./.jj/typewright/bin/typewright info "Space/document.typ" --json
./.jj/typewright/bin/typewright check "Space/document.typ" --json
./.jj/typewright/bin/typewright compile "Space/document.typ" /tmp/document.pdf
./.jj/typewright/bin/typewright compile "Space/document.typ" /tmp/document.html --dark
```

The CLI uses the bundled compiler, package cache and configured font folders, and reads saved files from disk. It infers the space root; use `--root DIR` for another root. `--format html` also checks HTML without writing output. `--dark` forces dark browser appearance, including adaptive CSS, independently of the system theme; fixed document colors remain unchanged. HTML exports embed preview images and custom fonts. Run `--help` for options and exit codes.

## Build from source

Install Rust (`cargo`), then open `macApp/Typewright.xcodeproj` in Xcode and run the `Typewright` scheme.

For the web app, also install [Bun](https://bun.sh) and Homebrew's `llvm`, then:

```sh
scripts/build-webApp-wasm.sh
cd webApp && bun install && bun run dev
```

## License

[Apache License 2.0](LICENSE)
