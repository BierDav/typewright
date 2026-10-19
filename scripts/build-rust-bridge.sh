#!/usr/bin/env bash
# Builds a Rust bridge crate as a static library for Xcode's ARCHS.
# Usage: build-rust-bridge.sh <crate folder> <library name>, e.g. typstBridge typst_bridge.
# Runs as a build phase; outputs lib<name>.a into BUILT_PRODUCTS_DIR.
set -euo pipefail
crate=$1
lib=$2
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
out=${BUILT_PRODUCTS_DIR:-$root/.build/rust-bridges}
archs=${ARCHS:-$(uname -m)}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
# Xcode's SDKROOT can point cargo's linker at the wrong SDK; C dependencies still need the macOS one.
export SDKROOT=$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)

libs=()
for arch in $archs; do
  case $arch in
    arm64) target=aarch64-apple-darwin ;;
    x86_64) target=x86_64-apple-darwin ;;
    *) echo "unsupported arch $arch" >&2; exit 1 ;;
  esac
  if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$target"; then
    rustup target add "$target"
  fi
  cargo build --release --manifest-path "$root/$crate/Cargo.toml" \
    --target "$target" --target-dir "$root/.build/cargo"
  libs+=("$root/.build/cargo/$target/release/lib$lib.a")
done

mkdir -p "$out"
lipo -create "${libs[@]}" -output "$out/lib$lib.a.tmp"
# Only touch the output when it changed, so Xcode doesn't relink every build.
if cmp -s "$out/lib$lib.a.tmp" "$out/lib$lib.a"; then
  rm "$out/lib$lib.a.tmp"
else
  mv "$out/lib$lib.a.tmp" "$out/lib$lib.a"
fi
