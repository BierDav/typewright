#!/usr/bin/env bash
# Builds the Rust core and bridges for wasm, installs packages and runs the web app's dev server.
# Extra arguments go to vite, e.g. `scripts/run-webApp.sh --port 5391 --host`.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Cargo rebuilds only what changed, so this is quick after the first run.
"$root/scripts/build-webApp-wasm.sh"

cd "$root/webApp"
bun install
exec bun run dev "$@"
