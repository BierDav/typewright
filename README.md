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

## Build from source

Install Rust (`cargo`), then open `macApp/Typewright.xcodeproj` in Xcode and run the `Typewright` scheme.

For the web app, also install [Bun](https://bun.sh) and Homebrew's `llvm`, then:

```sh
scripts/build-web-wasm.sh
cd webApp && bun install && bun run dev
```

## License

[Apache License 2.0](LICENSE)
