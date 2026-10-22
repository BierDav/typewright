#!/usr/bin/env bash
# Builds jjBridge for the browser into webApp/src/wasm/jj/jj_bridge.wasm: a wasm32-wasip1 library exporting the
# twj_* functions of jjBridge/include/JJBridge.h, run by webApp/src/workers/jj.worker.ts on its own WASI host.
# wasip1 rather than unknown-unknown because jj-lib and gix need std::fs (see jjBridge/Cargo.toml's patches).
# Needs binaryen's wasm-opt.
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
wasm="$root/.build/cargo-wasi/$target/release/jj_bridge.wasm"
features=(--enable-bulk-memory --enable-nontrapping-float-to-int --enable-sign-ext)
wasm-opt -O2 "${features[@]}" "$wasm" -o "$out/jj_bridge.wasm"
# Browsers without JSPI get a build whose stack unwinds at the imports that wait on OPFS (lib/wasi.ts's ASYNC).
imports=$(sed -n '/export const ASYNC = new Set(\[/,/\]);/p' "$root/webApp/src/lib/wasi.ts" | grep -o '"[a-z_]*"' | tr -d '"' |
  sed 's/^/wasi_snapshot_preview1./' | paste -sd, -)
wasm-opt -O2 "${features[@]}" --asyncify --pass-arg="asyncify-imports@$imports" "$wasm" -o "$out/jj_bridge.asyncify.wasm"
