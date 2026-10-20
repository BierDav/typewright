#!/usr/bin/env bash
# Builds a universal Typewright.app and zips it into dist/.
# Signed with Developer ID and the passkey entitlement when TYPEWRIGHT_SIGN_IDENTITY and
# TYPEWRIGHT_PROVISIONING_PROFILE (a .provisionprofile path) are set, ad-hoc otherwise (no passkeys, no sync).
# Notarized when TYPEWRIGHT_NOTARY_APPLE_ID, TYPEWRIGHT_NOTARY_PASSWORD and TYPEWRIGHT_NOTARY_TEAM are set too.
# Usage: build-app.sh <version> [build-number]
set -euo pipefail
version=$1
build=${2:-1}
root=$(cd "$(dirname "$0")/.." && pwd)
dd="$root/.build/release"

xcodebuild -project "$root/macApp/Typewright.xcodeproj" -scheme Typewright -configuration Release \
  -derivedDataPath "$dd" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- build

mkdir -p "$root/dist"
app="$dd/Build/Products/Release/Typewright.app"
zip="$root/dist/Typewright-$version.zip"
rm -f "$zip"

if [ -n "${TYPEWRIGHT_SIGN_IDENTITY:-}" ] && [ -n "${TYPEWRIGHT_PROVISIONING_PROFILE:-}" ]; then
  team=$(security cms -D -i "$TYPEWRIGHT_PROVISIONING_PROFILE" | plutil -extract TeamIdentifier.0 raw -)
  bundle=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
  domain=$(plutil -extract TypewrightPasskeyDomain raw "$app/Contents/Info.plist")
  entitlements=$(mktemp -t typewright).plist
  sed "s/\$(TYPEWRIGHT_PASSKEY_DOMAIN)/$domain/" "$root/macApp/Resources/Passkeys.entitlements" > "$entitlements"
  # Restricted entitlements only count with the profile's app and team identifiers alongside.
  plutil -insert com.apple.application-identifier -string "$team.$bundle" "$entitlements"
  plutil -insert com.apple.developer.team-identifier -string "$team" "$entitlements"
  cp "$TYPEWRIGHT_PROVISIONING_PROFILE" "$app/Contents/embedded.provisionprofile"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$TYPEWRIGHT_SIGN_IDENTITY" "$app"
  if [ -n "${TYPEWRIGHT_NOTARY_APPLE_ID:-}" ]; then
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --apple-id "$TYPEWRIGHT_NOTARY_APPLE_ID" --password "$TYPEWRIGHT_NOTARY_PASSWORD" \
      --team-id "$TYPEWRIGHT_NOTARY_TEAM" --wait >&2
    xcrun stapler staple "$app" >&2
    rm -f "$zip"
    spctl --assess --type execute --verbose "$app" >&2
  fi
  # Passkeys silently fail without the entitlement and its profile, so check both made it in.
  codesign --verify --strict --verbose=2 "$app" >&2
  codesign -d --entitlements - "$app" 2>/dev/null | grep -q "webcredentials:$domain" \
    || { echo "error: associated-domains entitlement missing" >&2; exit 1; }
else
  echo "warning: ad-hoc signing; passkeys and sync won't work in this build" >&2
  codesign --force --deep --sign - --options runtime "$app"
fi

ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
