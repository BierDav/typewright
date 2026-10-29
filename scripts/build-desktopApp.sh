#!/usr/bin/env bash
# Builds Tauri installers for this platform into desktopApp/dist.
# Usage: scripts/build-desktopApp.sh <version> [--skip-web]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="$root/.build/cargo"
version=${1:?usage: build-desktopApp.sh <version> [--skip-web]}

if [ "${2:-}" != "--skip-web" ]; then
  "$root/scripts/build-webApp-wasm.sh"
  cd "$root/webApp"
  bun install --frozen-lockfile
  TYPEWRIGHT_WEB_BASE=/ bun run --bun build
  rm -rf "$root/desktopApp/web"
  cp -R "$root/webApp/.output/public" "$root/desktopApp/web"
fi

cd "$root/desktopApp"
bun install --frozen-lockfile
work=$(mktemp -d)
config="$work/tauri.override.json"
trap 'rm -rf "$work"' EXIT
bun -e 'const c = { version: process.argv[1] }; if (process.env.APPLE_SIGNING_IDENTITY) c.bundle = { macOS: { signingIdentity: process.env.APPLE_SIGNING_IDENTITY } }; await Bun.write(process.argv[2], JSON.stringify(c));' "$version" "$config"
# A signed desktop profile enables native passkeys; unsigned builds keep browser sign-in.
if [ "$(uname)" = Darwin ] && [ -n "${TYPEWRIGHT_DESKTOP_PROVISIONING_PROFILE:-}" ]; then
  security cms -D -i "$TYPEWRIGHT_DESKTOP_PROVISIONING_PROFILE" > "$work/profile.plist"
  app_identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$work/profile.plist")
  team=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$work/profile.plist")
  if [ "$app_identifier" != "$team.dev.bierdav.Typewright.Desktop" ]; then
    echo "The provisioning profile must be for dev.bierdav.Typewright.Desktop." >&2
    exit 1
  fi
  cp native/Passkeys.entitlements "$work/Passkeys.entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_identifier" -c "Add :com.apple.developer.team-identifier string $team" "$work/Passkeys.entitlements"
  bun -e 'const f = Bun.file(process.argv[1]); const c = await f.json(); c.bundle ??= {}; c.bundle.macOS = { ...c.bundle.macOS, entitlements: process.argv[2], files: { "embedded.provisionprofile": process.env.TYPEWRIGHT_DESKTOP_PROVISIONING_PROFILE } }; await Bun.write(process.argv[1], JSON.stringify(c));' "$config" "$work/Passkeys.entitlements"
fi
bun run --bun dist --config "$config"
mkdir -p dist
case "$(uname)" in
  Darwin) platform=mac; arch=$(uname -m) ;;
  Linux) platform=linux; arch=$(uname -m) ;;
  *) platform=win; arch=${PROCESSOR_ARCHITECTURE:-x86_64} ;;
esac
case "$arch" in arm64|aarch64|ARM64) arch=arm64 ;; *) arch=x64 ;; esac
for extension in dmg exe AppImage deb rpm; do
  while IFS= read -r -d '' file; do
    cp "$file" "dist/Typewright-$version-$platform-$arch.$extension"
  done < <(find "$CARGO_TARGET_DIR/release/bundle" -type f -name "*.$extension" -print0)
done
