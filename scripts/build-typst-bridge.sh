#!/usr/bin/env bash
# Builds the in-process typst bridge as a static library for Xcode's ARCHS.
# Runs as a build phase; outputs libtypst_bridge.a into BUILT_PRODUCTS_DIR.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
out=${BUILT_PRODUCTS_DIR:-$root/.build/typst-bridge}
archs=${ARCHS:-$(uname -m)}
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-26.0}
# Xcode's environment points cargo's linker at the wrong SDK otherwise.
unset SDKROOT

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
  cargo build --release --manifest-path "$root/TypstBridge/Cargo.toml" \
    --target "$target" --target-dir "$root/.build/cargo"
  libs+=("$root/.build/cargo/$target/release/libtypst_bridge.a")
done

mkdir -p "$out"
lipo -create "${libs[@]}" -output "$out/libtypst_bridge.a.tmp"
# Only touch the output when it changed, so Xcode doesn't relink every build.
if cmp -s "$out/libtypst_bridge.a.tmp" "$out/libtypst_bridge.a"; then
  rm "$out/libtypst_bridge.a.tmp"
else
  mv "$out/libtypst_bridge.a.tmp" "$out/libtypst_bridge.a"
fi
