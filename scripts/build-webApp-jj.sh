#!/usr/bin/env bash
# Builds jjBridge for the browser into webApp/src/wasm/jj/jj_bridge.wasm: a wasm32-wasip1 library exporting the
# twj_* functions of jjBridge/include/JJBridge.h, run by webApp/src/workers/jj.worker.ts on its own WASI host.
# wasip1 rather than unknown-unknown because jj-lib and gix need std::fs (see jjBridge/Cargo.toml's patches).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
target=wasm32-wasip1
out="$root/webApp/src/wasm/jj"

if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "$target"; then
  rustup target add "$target"
fi

# jj's tree merges recurse per folder level, so the stack gets 8 MB.
RUSTFLAGS='-C link-arg=-zstack-size=8388608' cargo rustc --release --lib --crate-type cdylib \
  --manifest-path "$root/jjBridge/Cargo.toml" --target "$target" --target-dir "$root/.build/cargo-wasi"
mkdir -p "$out"
cp "$root/.build/cargo-wasi/$target/release/jj_bridge.wasm" "$out/jj_bridge.wasm"
if command -v wasm-opt >/dev/null; then
  wasm-opt -O2 --enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext \
    "$out/jj_bridge.wasm" -o "$out/jj_bridge.wasm"
fi
