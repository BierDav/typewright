#!/usr/bin/env bash
# Builds the Debug app and runs it in the foreground, so its logs show here and Ctrl-C quits it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/.build/Build/Products/Debug/Typewright.app"

xcodebuild -project "$root/macApp/Typewright.xcodeproj" -scheme Typewright -configuration Debug \
  -derivedDataPath "$root/.build" -quiet build

# One dev instance at a time; an installed release keeps running.
pkill -f "$app/Contents/MacOS/Typewright" && sleep 1 || true
exec "$app/Contents/MacOS/Typewright"
