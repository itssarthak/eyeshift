#!/bin/sh
# Builds Eyeshift.app and installs it to ~/Applications.
# Ad-hoc signed: macOS forgets the Accessibility grant on every rebuild, so re-tick it in
# System Settings → Privacy & Security → Accessibility after building.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Eyeshift.app"
pkill -x Eyeshift 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Eyeshift "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "$APP"
