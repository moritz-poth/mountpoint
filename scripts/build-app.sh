#!/bin/bash
# Builds "dist/Mountpoint.app" (menu bar app + mirror helper) as a universal binary (Apple Silicon + Intel)
# and "dist/Mountpoint-<version>.zip". Usage: scripts/build-app.sh
# Requires macFUSE (provides libfuse in /usr/local).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.2.1          # CFBundleShortVersionString (numbers only)
RELEASE=1.2.1          # tag and zip name
BUILD=25
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
# settings app: the same binary in its own bundle (regular app: Dock icon, ⌘-Tab, menu bar), see SettingsApp.swift
SET="$APP/Contents/Helpers/Mountpoint Settings.app"
mkdir -p "$SET/Contents/MacOS" "$SET/Contents/Resources"
cp .build/universal/Mountpoint "$SET/Contents/MacOS/Mountpoint Settings"
cp -R Resources/fonts Resources/*.lproj "$SET/Contents/Resources/"
cp "$APP/Contents/Resources/AppIcon.icns" "$SET/Contents/Resources/"
cp LICENSE "$SET/Contents/Resources/LICENSE.txt"   # About in the settings app links to it
for l in en de fr es; do
  case $l in en) n="Mountpoint Settings";; de) n="Mountpoint-Einstellungen";; fr) n="Réglages Mountpoint";; es) n="Ajustes de Mountpoint";; esac
  mkdir -p "$SET/Contents/Resources/$l.lproj"
  printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$n" "$n" > "$SET/Contents/Resources/$l.lproj/InfoPlist.strings"
done
cat > "$SET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mountpoint Settings</string>
  <key>CFBundleDisplayName</key><string>Mountpoint Settings</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>Mountpoint Settings</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.mountpoint.settings</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>MountpointRelease</key><string>$RELEASE</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Moritz Poth. GPL-3.0-or-later.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>fr</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# ad-hoc signed (no Apple Developer account): macOS needs "Open Anyway" once, see README
codesign --force --deep --sign - "$APP"
# what installed updaters check: the whole bundle incl. the nested settings app verifies, versions match
codesign --verify --deep --strict "$APP"
NESTED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SET/Contents/Info.plist")
NESTED_REL=$(/usr/libexec/PlistBuddy -c "Print :MountpointRelease" "$SET/Contents/Info.plist")
if [ "$NESTED_ID" != "io.github.moritz-poth.mountpoint.settings" ] || [ "$NESTED_REL" != "$RELEASE" ]; then
  echo "settings app bundle is wrong: $NESTED_ID $NESTED_REL" >&2; exit 1
fi
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
