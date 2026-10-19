#!/usr/bin/env bash
# Builds the Kotlin Multiplatform core as a static framework for Xcode's ARCHS.
# Runs as a build phase; outputs TypewrightCore.framework into BUILT_PRODUCTS_DIR.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
out=${BUILT_PRODUCTS_DIR:-$root/.build/core}
archs=${ARCHS:-$(uname -m)}
[ "${CONFIGURATION:-Debug}" = Release ] && kind=Release || kind=Debug
# Xcode's environment confuses Kotlin/Native's toolchain lookup otherwise.
unset SDKROOT

tasks=() targets=()
for arch in $archs; do
  case $arch in
    arm64) target=macosArm64 task=MacosArm64 ;;
    x86_64) target=macosX64 task=MacosX64 ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
  esac
  tasks+=(":link${kind}Framework$task")
  targets+=("$target")
done
"$root/sharedKotlin/gradlew" -p "$root/sharedKotlin" --console=plain --quiet "${tasks[@]}"

dir=$(echo "$kind" | tr '[:upper:]' '[:lower:]')Framework
first="$root/sharedKotlin/build/bin/${targets[0]}/$dir/TypewrightCore.framework"
tmp="$root/.build/core-tmp/TypewrightCore.framework"
rm -rf "$tmp" && mkdir -p "$(dirname "$tmp")" && cp -R "$first" "$tmp"
binary=$(cd "$tmp" && realpath TypewrightCore)
lipo -create $(for t in "${targets[@]}"; do echo "$root/sharedKotlin/build/bin/$t/$dir/TypewrightCore.framework/TypewrightCore"; done) \
  -output "$binary"

mkdir -p "$out/TypewrightCore.framework"
# Only touch what changed, so Xcode doesn't recompile and relink every build.
rsync -a --checksum --delete "$tmp/" "$out/TypewrightCore.framework/"
