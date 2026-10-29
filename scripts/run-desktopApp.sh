#!/usr/bin/env bash
# Runs the desktop app against the web app's dev server, so edits reload live.
# Extra arguments go to vite, as with run-webApp.sh.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.bun/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
port=5392
unset ELECTRON_RUN_AS_NODE

"$root/scripts/build-webApp-wasm.sh"
cd "$root/webApp"
bun install
bun run dev --port "$port" --strictPort "$@" &
server=$!
trap 'kill $server 2>/dev/null' EXIT
until curl -s "http://localhost:$port/" >/dev/null; do sleep 0.3; done

cd "$root/desktopApp"
bun install
TYPEWRIGHT_DESKTOP_URL="http://localhost:$port/" bunx --bun electron .
