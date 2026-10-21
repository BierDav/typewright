#!/usr/bin/env bash
# Builds the Rust core (sharedCore) for Xcode's ARCHS and compiles its UniFFI Swift bindings into the
# TypewrightCore module. Runs as a build phase; outputs into BUILT_PRODUCTS_DIR: libtypewright_core.a (Rust),
# libTypewrightCore.a with TypewrightCore.swiftmodule (Swift) and the TypewrightCoreFFI module they share.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
out=${BUILT_PRODUCTS_DIR:-$root/.build/core}
archs=${ARCHS:-$(uname -m)}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
[ "${CONFIGURATION:-Debug}" = Release ] && optimize=-O || optimize=-Onone

BUILT_PRODUCTS_DIR=$out ARCHS=$archs "$root/scripts/build-rust-bridge.sh" sharedCore typewright_core
export SDKROOT=$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)

tmp="$root/.build/core-tmp"
rm -rf "$tmp" && mkdir -p "$tmp/TypewrightCore.swiftmodule"
# The generator reads uniffi.toml through cargo metadata of the current folder.
(cd "$root/sharedCore" && cargo run --release --quiet --features bindgen --bin uniffi-bindgen \
  --target-dir "$root/.build/cargo" -- generate --library "$out/libtypewright_core.a" --language swift --out-dir "$tmp/bindings")
mkdir -p "$tmp/TypewrightCoreFFI"
cp "$tmp/bindings/TypewrightCoreFFI.h" "$tmp/TypewrightCoreFFI/"
cat > "$tmp/TypewrightCoreFFI/module.modulemap" <<'EOF'
module TypewrightCoreFFI {
    header "TypewrightCoreFFI.h"
    link "typewright_core"
    export *
}
EOF

objects=()
for arch in $archs; do
  xcrun swiftc -parse-as-library -wmo -g $optimize -swift-version 5 \
    -module-name TypewrightCore -module-link-name TypewrightCore \
    -target "$arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" -sdk "$SDKROOT" -I "$tmp/TypewrightCoreFFI" \
    -emit-module -emit-module-path "$tmp/TypewrightCore.swiftmodule/$arch-apple-macos.swiftmodule" \
    -emit-object -o "$tmp/TypewrightCore-$arch.o" "$tmp/bindings/TypewrightCore.swift"
  objects+=("$tmp/TypewrightCore-$arch.o")
done
lipo -create "${objects[@]}" -output "$tmp/TypewrightCore.o"
libtool -static -no_warning_for_no_symbols -o "$tmp/libTypewrightCore.a" "$tmp/TypewrightCore.o"

# Only touch what changed, so Xcode doesn't recompile and relink every build.
mkdir -p "$out/TypewrightCore.swiftmodule" "$out/TypewrightCoreFFI"
rsync -a --checksum --delete "$tmp/TypewrightCore.swiftmodule/" "$out/TypewrightCore.swiftmodule/"
rsync -a --checksum --delete "$tmp/TypewrightCoreFFI/" "$out/TypewrightCoreFFI/"
rsync -a --checksum "$tmp/libTypewrightCore.a" "$out/libTypewrightCore.a"
