#!/usr/bin/env bash
# Builds the desktop app's installers for this platform into desktopApp/dist.
# Usage: scripts/build-desktopApp.sh <version> [--skip-web]
# --skip-web packages a web build already in desktopApp/web (CI builds it once for all platforms).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
version=${1:?usage: build-desktopApp.sh <version> [--skip-web]}
# Set inside apps hosted on Electron; it would make electron-builder's Electron act as Node.
unset ELECTRON_RUN_AS_NODE

if [ "${2:-}" != "--skip-web" ]; then
  "$root/scripts/build-webApp-wasm.sh"
  cd "$root/webApp"
  bun install --frozen-lockfile
  # The app serves itself from app://typewright/, so the build sits at the root.
  TYPEWRIGHT_WEB_BASE=/ bun run build
  rm -rf "$root/desktopApp/web"
  cp -R "$root/webApp/.output/public" "$root/desktopApp/web"
fi

cd "$root/desktopApp"
bun install --frozen-lockfile
bun -e 'const f = Bun.file("package.json"); const p = await f.json(); p.version = process.argv[1]; await Bun.write(f, JSON.stringify(p, null, 2) + "\n");' "$version"
# Without a Developer ID, macOS builds stay ad-hoc signed instead of failing.
if [ "$(uname)" = Darwin ] && [ -z "${CSC_LINK:-}" ]; then export CSC_IDENTITY_AUTO_DISCOVERY=false; fi
# --bun keeps electron-builder on Bun instead of looking for Node.
bunx --bun electron-builder --publish never
