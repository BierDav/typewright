#!/usr/bin/env bash
# Builds the Rust bridges for the browser into webApp/src/wasm/{sync,typst}.
# Needs the wasm32-unknown-unknown target, wasm-bindgen-cli matching the crates' wasm-bindgen, and a
# clang with a WebAssembly backend for ring's C code (Homebrew's llvm on macOS; Apple's clang has none).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
target=wasm32-unknown-unknown
out="$root/webApp/src/wasm"

if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$target"; then
  rustup target add "$target"
fi
bindgen_version=$(grep -m1 -o 'wasm-bindgen = "=[0-9.]*"' "$root/irohBridge/Cargo.toml" | grep -o '[0-9.]*[0-9]')
if ! wasm-bindgen --version 2>/dev/null | grep -q "$bindgen_version"; then
  cargo install wasm-bindgen-cli --version "$bindgen_version" --locked
fi
# Linux distributions install LLVM versioned, e.g. /usr/lib/llvm-18.
for llvm in "${LLVM_PREFIX:-}" /opt/homebrew/opt/llvm /usr/local/opt/llvm $(ls -d /usr/lib/llvm-* 2>/dev/null | sort -V -r); do
  if [ -n "$llvm" ] && [ -x "$llvm/bin/clang" ]; then
    export CC_wasm32_unknown_unknown="$llvm/bin/clang" AR_wasm32_unknown_unknown="$llvm/bin/llvm-ar"
    break
  fi
done

# getrandom needs its JS backend picked; typst recurses deeply, so the stack gets 16 MB.
export RUSTFLAGS='--cfg getrandom_backend="wasm_js" -C link-arg=-zstack-size=16777216'

build() {
  local crate=$1 lib=$2 name=$3
  cargo rustc --release --lib --crate-type cdylib --manifest-path "$root/$crate/Cargo.toml" \
    --target "$target" --target-dir "$root/.build/cargo-wasm"
  mkdir -p "$out/$name"
  wasm-bindgen --target web --out-dir "$out/$name" --out-name "$name" \
    "$root/.build/cargo-wasm/$target/release/$lib.wasm"
  if command -v wasm-opt >/dev/null; then
    wasm-opt -O2 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-reference-types \
      "$out/$name/${name}_bg.wasm" -o "$out/$name/${name}_bg.wasm"
  fi
}

build irohBridge iroh_bridge sync
build typstBridge typst_bridge typst
