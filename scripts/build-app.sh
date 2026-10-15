#!/bin/bash
# Builds DemoRec.app and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DemoRecApp

APP=dist/DemoRec.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DemoRecApp "$APP/Contents/MacOS/DemoRec"
cp Sources/DemoRecApp/Info.plist "$APP/Contents/Info.plist"

ICON=.build/AppIcon.icns
if [ ! -f "$ICON" ] || [ scripts/make-icon.swift -nt "$ICON" ]; then
  rm -rf .build/AppIcon.iconset
  swift scripts/make-icon.swift .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

# A real signing identity keeps macOS privacy permissions across rebuilds; ad-hoc (-) re-prompts each time.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/DemoRec.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/DemoRec.app"
