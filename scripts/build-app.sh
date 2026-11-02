#!/bin/bash
# Builds "dist/Mountpoint.app" (menu bar app + mirror helper) as a universal binary (Apple Silicon + Intel)
# and "dist/Mountpoint-<version>.zip". Usage: scripts/build-app.sh
# Requires macFUSE (provides libfuse in /usr/local).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.0.0          # CFBundleShortVersionString (numbers only)
RELEASE=1.0.0-beta.1   # tag and zip name
BUILD=1
APP=dist/Mountpoint.app

swift build -c release --arch arm64
swift build -c release --arch x86_64
mkdir -p .build/helper .build/universal
lipo -create .build/arm64-apple-macosx/release/Mountpoint .build/x86_64-apple-macosx/release/Mountpoint \
  -output .build/universal/Mountpoint
cc -Wall -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 -D_FILE_OFFSET_BITS=64 -I/usr/local/include/fuse \
  helper/mirror.c -L/usr/local/lib -lfuse -o .build/helper/mirror

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/universal/Mountpoint .build/helper/mirror "$APP/Contents/MacOS/"
cp -R Resources/fonts Resources/*.lproj "$APP/Contents/Resources/"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mountpoint</string>
  <key>CFBundleExecutable</key><string>Mountpoint</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.mountpoint</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# ad-hoc signed (no Apple Developer account): macOS needs "Open Anyway" once, see README
codesign --force --deep --sign - "$APP"
rm -f "dist/Mountpoint-$RELEASE.zip"
ditto -c -k --keepParent "$APP" "dist/Mountpoint-$RELEASE.zip"
echo "Done: $APP, dist/Mountpoint-$RELEASE.zip"
