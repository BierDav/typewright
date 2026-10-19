#!/usr/bin/env bash
# Builds a universal, ad-hoc signed Typewright.app and zips it into dist/.
# Usage: build-app.sh <version> [build-number]
set -euo pipefail
version=$1
build=${2:-1}
root=$(cd "$(dirname "$0")/.." && pwd)
dd="$root/.build/release"

xcodebuild -project "$root/Typewright.xcodeproj" -scheme Typewright -configuration Release \
  -derivedDataPath "$dd" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
  CODE_SIGN_IDENTITY=- build

mkdir -p "$root/dist"
app="$dd/Build/Products/Release/Typewright.app"
codesign --force --deep --sign - --options runtime "$app"
zip="$root/dist/Typewright-$version.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
shasum -a 256 "$zip" | cut -d' ' -f1
