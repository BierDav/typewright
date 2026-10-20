#!/usr/bin/env bash
# Prints the Homebrew cask. Usage: cask.sh <name> <version> <sha256> [conflict]
set -euo pipefail
name=$1 version=$2 sha=$3 conflict=${4:-}
cat <<RUBY
cask "$name" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/BierDav/typewright/releases/download/v#{version}/Typewright-#{version}.zip"
  name "Typewright"
  desc "Native Typst editor with live preview"
  homepage "https://github.com/BierDav/typewright"

  depends_on macos: :tahoe
$( [ -n "$conflict" ] && echo "  conflicts_with cask: \"$conflict\"" )

  app "Typewright.app"

  zap trash: [
    "~/Library/Application Support/Typewright",
    "~/Library/Preferences/dev.bierdav.Typewright.plist",
  ]
end
RUBY
