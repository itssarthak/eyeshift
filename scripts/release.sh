#!/bin/sh
# Usage: scripts/release.sh 0.2.0
# Builds a universal Eyeshift.app, publishes it as a GitHub release and bumps the Homebrew cask.
set -eu
V=${1:?version, e.g. 0.2.0}
cd "$(dirname "$0")/.."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Info.plist
rm -rf dist && mkdir dist
APP="$PWD/dist/Eyeshift.app" ./build.sh >/dev/null
ZIP="dist/Eyeshift-$V.zip"
ditto -c -k --keepParent dist/Eyeshift.app "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
git commit -qam "Release $V

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>" || true
git tag "v$V" && git push -q && git push -q --tags
gh release create "v$V" "$ZIP" --title "Eyeshift $V" --generate-notes

TAP=$(mktemp -d)
gh repo clone chaibreak/homebrew-tap "$TAP" -- -q
sed "s/@VERSION@/$V/; s/@SHA256@/$SHA/" scripts/eyeshift.rb > "$TAP/Casks/eyeshift.rb"
git -C "$TAP" add Casks/eyeshift.rb
git -C "$TAP" commit -qam "eyeshift $V" && git -C "$TAP" push -q
echo "Released $V ($SHA)"
