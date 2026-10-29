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

## Windows, Linux and macOS

Every release also carries the desktop app, the web app in its own window: `Typewright-<version>-win-x64.exe` (and `arm64`), `.AppImage`, `.deb` and `.rpm` for Linux, and `.dmg` for Macs before macOS 26. Download them from [Releases](https://github.com/BierDav/typewright/releases). Spaces stay on the device; sign in with your account key (Settings › Devices) to sync, since passkeys only work on the website and in the Mac app.

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

Debug builds use Apple Development signing with team `G5K3D2J5Y9` and the data protection keychain, so rebuilding preserves account access without repeated keychain prompts. Sign in to the team in Xcode Settings > Accounts; `scripts/run-macApp.sh` registers the Mac and manages development provisioning automatically. An existing account may require one final keychain approval to migrate.

To build without a developer account, use `xcodebuild -project macApp/Typewright.xcodeproj -scheme Typewright -derivedDataPath .build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual TYPEWRIGHT_DEBUG_ENTITLEMENTS= build`. Ad-hoc builds use the legacy keychain and may prompt again after rebuilding.

For the web app, also install [Bun](https://bun.sh) and Homebrew's `llvm`, then:

```sh
scripts/build-webApp-wasm.sh
cd webApp && bun install && bun run dev
```

The cross-platform desktop app uses Tauri and stores spaces and history in the native filesystem. It runs with `scripts/run-desktopApp.sh`; `scripts/build-desktopApp.sh <version>` builds its installers for the current platform. Linux builds require WebKitGTK 4.1, Ayatana AppIndicator and librsvg development packages. macOS builds require Xcode. Existing desktop libraries are reused; sign in again and set preferences after migrating from Electron.

## License

[Apache License 2.0](LICENSE)
