#!/bin/sh
# Builds Eyeshift.app and installs it to ~/Applications.
# Signs with the "Eyeshift Local Signing" certificate if you've run scripts/make-signing-cert.sh, so macOS keeps
# the Accessibility permission across rebuilds. Otherwise ad-hoc signs, and you re-tick Accessibility after each build.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Eyeshift.app"
pkill -x Eyeshift 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Eyeshift "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
ID=-
security find-certificate -c "Eyeshift Local Signing" >/dev/null 2>&1 && ID="Eyeshift Local Signing"
codesign --force --sign "$ID" "$APP"
echo "$APP"
