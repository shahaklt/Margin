#!/bin/zsh
# Builds Margin.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=build/Margin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Margin" "$APP/Contents/MacOS/Margin"
cp Support/Info.plist "$APP/Contents/Info.plist"
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

# Icon
TMP=$(mktemp -d)
swift Support/MakeIcon.swift "$TMP"
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  cp "$TMP/$s.png" "$SET/icon_${s}x${s}.png"
  cp "$TMP/$((s*2)).png" "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

codesign --force --deep --sign - --entitlements Support/Margin.entitlements "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Margin.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Margin.app"
