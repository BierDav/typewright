#!/usr/bin/env bash
# Moves the solveng editor dependency to the newest commit on its main branch. CI runs this so a
# solveng release reaches the app without a bump here; the committed lock keeps the last built one.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cargo update --manifest-path "$root/typstBridge/Cargo.toml" -p solveng-ide -p solveng-names
