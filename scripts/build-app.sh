#!/usr/bin/env bash
# Builds a universal Typewright.app and zips it into dist/.
# Signed with Developer ID and the passkey entitlement when TYPEWRIGHT_SIGN_IDENTITY and
# TYPEWRIGHT_PROVISIONING_PROFILE (a .provisionprofile path) are set, ad-hoc otherwise (no passkeys, no sync).
# Notarized when TYPEWRIGHT_NOTARY_APPLE_ID, TYPEWRIGHT_NOTARY_PASSWORD and TYPEWRIGHT_NOTARY_TEAM are set too,
# or locally with a `notarytool store-credentials` profile named in TYPEWRIGHT_NOTARY_PROFILE.
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
# Extensions are signed on their own first: they need their sandbox entitlements, which --deep would drop.
appex="$app/Contents/PlugIns/TypewrightQuickLook.appex"
appex_entitlements="$root/macApp/Resources/QuickLook.entitlements"

if [ -n "${TYPEWRIGHT_SIGN_IDENTITY:-}" ] && [ -n "${TYPEWRIGHT_PROVISIONING_PROFILE:-}" ]; then
  team=$(security cms -D -i "$TYPEWRIGHT_PROVISIONING_PROFILE" | plutil -extract TeamIdentifier.0 raw -)
  bundle=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
  domain=$(plutil -extract TypewrightPasskeyDomain raw "$app/Contents/Info.plist")
  entitlements=$(mktemp -t typewright).plist
  sed "s/\$(TYPEWRIGHT_PASSKEY_DOMAIN)/$domain/" "$root/macApp/Resources/Passkeys.entitlements" > "$entitlements"
  # Restricted entitlements only count with the profile's app and team identifiers alongside.
  # PlistBuddy, since plutil reads the dots in these keys as a key path.
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $team.$bundle" \
    -c "Add :com.apple.developer.team-identifier string $team" "$entitlements"
  cp "$TYPEWRIGHT_PROVISIONING_PROFILE" "$app/Contents/embedded.provisionprofile"
  # A dedicated keychain (TYPEWRIGHT_SIGN_KEYCHAIN) avoids the login keychain's access prompts.
  codesign --force --options runtime --timestamp --entitlements "$appex_entitlements" \
    ${TYPEWRIGHT_SIGN_KEYCHAIN:+--keychain "$TYPEWRIGHT_SIGN_KEYCHAIN"} --sign "$TYPEWRIGHT_SIGN_IDENTITY" "$appex"
  codesign --force --options runtime --timestamp --entitlements "$entitlements" \
    ${TYPEWRIGHT_SIGN_KEYCHAIN:+--keychain "$TYPEWRIGHT_SIGN_KEYCHAIN"} --sign "$TYPEWRIGHT_SIGN_IDENTITY" "$app"
  if [ -n "${TYPEWRIGHT_NOTARY_APPLE_ID:-}" ] || [ -n "${TYPEWRIGHT_NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$app" "$zip"
    if [ -n "${TYPEWRIGHT_NOTARY_PROFILE:-}" ]; then
      xcrun notarytool submit "$zip" --keychain-profile "$TYPEWRIGHT_NOTARY_PROFILE" --wait >&2
    else
      xcrun notarytool submit "$zip" --apple-id "$TYPEWRIGHT_NOTARY_APPLE_ID" --password "$TYPEWRIGHT_NOTARY_PASSWORD" \
        --team-id "$TYPEWRIGHT_NOTARY_TEAM" --wait >&2
    fi
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
  codesign --force --sign - --options runtime --entitlements "$appex_entitlements" "$appex"
  codesign --force --sign - --options runtime "$app"
fi

ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
