#!/bin/bash
# Builds "dist/Mountpoint.app" (menu bar app + mirror helper) as a universal binary (Apple Silicon + Intel)
# and "dist/Mountpoint-<version>.zip". Usage: scripts/build-app.sh
# Requires macFUSE (provides libfuse in /usr/local).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.1.3          # CFBundleShortVersionString (numbers only)
RELEASE=1.1.3          # tag and zip name
BUILD=22
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
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"   # GPL text ships with the app

# every size drawn on Apple's grid (small sizes with less margin), not scaled down from 1024
ICONSET=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
# volume icon Finder shows for mounted workspaces (macFUSE volicon)
VOLSET=$(mktemp -d)/VolumeIcon.iconset
swift scripts/make-volume-icon.swift "$VOLSET" >/dev/null
iconutil -c icns "$VOLSET" -o "$APP/Contents/Resources/VolumeIcon.icns"

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
  <key>MountpointRelease</key><string>$RELEASE</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Moritz Poth. GPL-3.0-or-later.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>fr</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# ad-hoc signed (no Apple Developer account): macOS needs "Open Anyway" once, see README
codesign --force --deep --sign - "$APP"
# the bundle is recreated at the same path: without this, Finder keeps showing a cached (blank or old) app icon
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
rm -f "dist/Mountpoint-$RELEASE.zip"
ditto -c -k --keepParent "$APP" "dist/Mountpoint-$RELEASE.zip"
# update signature: installed apps only accept zips signed with the key in this Mac's Keychain
rm -f "dist/Mountpoint-$RELEASE.zip.sig"
if PUB=$(swift scripts/update-key.swift public 2>/dev/null) && grep -q "\"$PUB\"" Sources/Mountpoint/Updater.swift \
   && swift scripts/update-key.swift sign "dist/Mountpoint-$RELEASE.zip"; then
  echo "Done: $APP, dist/Mountpoint-$RELEASE.zip (+ .sig – upload both)"
else
  echo "Done: $APP, dist/Mountpoint-$RELEASE.zip – NOT SIGNED (no update key, or it differs from Updater.publicKey): not releasable" >&2
fi
