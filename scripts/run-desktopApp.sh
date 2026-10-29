#!/usr/bin/env bash
# Runs the Tauri desktop host against vite, with the library on the native filesystem.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="$root/.build/cargo"
port=5392

"$root/scripts/build-webApp-wasm.sh"
cd "$root/webApp"
bun install
bun run --bun dev --port "$port" --strictPort "$@" &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
until curl -s "http://localhost:$port/" >/dev/null; do
  kill -0 "$server" 2>/dev/null || exit 1
  sleep 0.3
done
cd "$root/desktopApp"
bun install
if [ "$(uname)" = Darwin ]; then
  profile=${TYPEWRIGHT_DESKTOP_PROVISIONING_PROFILE:-"$root/.build/Build/Products/Debug/Typewright.app/Contents/embedded.provisionprofile"}
  if [ -f "$profile" ]; then
    cargo build --manifest-path Cargo.toml
    app="$root/.build/Typewright Desktop Dev.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$root/.build/cargo/debug/typewright-desktop" "$app/Contents/MacOS/Typewright"
    cp "$profile" "$app/Contents/embedded.provisionprofile"
    security cms -D -i "$profile" > "$root/.build/desktop-dev-profile.plist"
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$root/.build/desktop-dev-profile.plist")
    team=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$root/.build/desktop-dev-profile.plist")
    bundle_identifier=${identifier#*.}
    identity=$(python3 "$root/scripts/desktopApp-signing-identity.py" "$root/.build/desktop-dev-profile.plist" "${TYPEWRIGHT_SIGN_IDENTITY:-}")
    cp native/Passkeys.entitlements "$root/.build/desktop-dev-entitlements.plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $identifier" -c "Add :com.apple.developer.team-identifier string $team" "$root/.build/desktop-dev-entitlements.plist"
    /usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' -c "Add :keychain-access-groups:0 string $identifier" "$root/.build/desktop-dev-entitlements.plist"
    mkdir -p "$app/Contents/Resources"
    cp build/icon.icns "$app/Contents/Resources/icon.icns"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_identifier</string>
<key>CFBundleExecutable</key><string>Typewright</string>
<key>CFBundleName</key><string>Typewright</string>
<key>CFBundleDisplayName</key><string>Typewright</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    codesign --force --sign "$identity" --entitlements "$root/.build/desktop-dev-entitlements.plist" "$app"
    "$app/Contents/MacOS/Typewright"
    exit
  fi
  echo "Native dev passkeys need TYPEWRIGHT_DESKTOP_PROVISIONING_PROFILE or a provisioned macApp Debug build." >&2
fi
bun run --bun start
