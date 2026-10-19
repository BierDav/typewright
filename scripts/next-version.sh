#!/usr/bin/env bash
# Prints the next version. Usage: next-version.sh <alpha|rc|stable> <major:true|false>
set -euo pipefail
channel=$1
major=${2:-false}

last=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -vE -- '-' | head -1 || true)
last=${last:-v0.0.0}
IFS=. read -r x y z <<<"${last#v}"

range="HEAD"
[ "$last" != "v0.0.0" ] && range="$last..HEAD"
if [ "$major" = "true" ]; then
  x=$((x + 1)); y=0; z=0
# grep -q would stop reading early; with pipefail the cut-off git log then fails the test.
elif git log --format=%s "$range" | grep -E '^feat(\(.+\))?!?:' >/dev/null; then
  y=$((y + 1)); z=0
else
  z=$((z + 1))
fi
base="$x.$y.$z"

if [ "$channel" = "stable" ]; then
  echo "$base"
else
  n=$(git tag --list "v$base-$channel.*" | wc -l | tr -d ' ')
  echo "$base-$channel.$((n + 1))"
fi
