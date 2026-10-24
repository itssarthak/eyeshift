#!/bin/sh
# Builds Eyeshift.app and installs it to ~/Applications.
# Signs with the "Eyeshift Local Signing" certificate if you've run scripts/make-signing-cert.sh, so macOS keeps
# the Accessibility permission across rebuilds. Otherwise ad-hoc signs, and you re-tick Accessibility after each build.
# scripts/release.sh sets APP to build a universal, ad-hoc signed copy elsewhere instead.
set -e
cd "$(dirname "$0")"
if [ -n "$APP" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/Eyeshift
  ID=-
else
  swift build -c release
  BIN=.build/release/Eyeshift
  APP="$HOME/Applications/Eyeshift.app"
  pkill -x Eyeshift 2>/dev/null || true
  ID=-
  security find-certificate -c "Eyeshift Local Signing" >/dev/null 2>&1 && ID="Eyeshift Local Signing"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign "$ID" "$APP"
echo "$APP"
