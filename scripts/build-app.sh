#!/bin/bash
# Builds "dist/Mountpoint.app" (menu bar app + mirror helper) as a universal binary (Apple Silicon + Intel)
# , "dist/Mountpoint-<version>.zip" (updater) and "dist/Mountpoint-<version>.dmg" (download). Usage: scripts/build-app.sh
# Requires macFUSE (provides libfuse in /usr/local).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.3.4          # CFBundleShortVersionString (numbers only)
RELEASE=1.3.4          # tag and zip name
BUILD=31
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
# shown as just "Mountpoint" in the menu bar, Dock and ⌘-Tab (owner): users only know the menu bar app, a second name
# confuses. The Dock shows the localized display name only while the unlocalized one equals the file name.
for l in en de fr es; do
  mkdir -p "$SET/Contents/Resources/$l.lproj"
  printf '"CFBundleDisplayName" = "Mountpoint";\n"CFBundleName" = "Mountpoint";\n' > "$SET/Contents/Resources/$l.lproj/InfoPlist.strings"
done
cat > "$SET/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mountpoint</string>
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
# sidebar cleanup app: the same binary, background only; the only part that gets Full Disk Access (cleanupMode,
# docs/plan-1.4.0-full-disk-access.md). Mountpoint copies it to Application Support and starts the copy through
# LaunchServices – inside the bundle macOS would charge it to Mountpoint's own permissions.
CLEAN="$APP/Contents/Helpers/Mountpoint Cleanup.app"
mkdir -p "$CLEAN/Contents/MacOS" "$CLEAN/Contents/Resources"
cp .build/universal/Mountpoint "$CLEAN/Contents/MacOS/Mountpoint Cleanup"
cp "$APP/Contents/Resources/AppIcon.icns" "$CLEAN/Contents/Resources/"   # shown in the Full Disk Access list
cat > "$CLEAN/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Mountpoint Cleanup</string>
  <key>CFBundleExecutable</key><string>Mountpoint Cleanup</string>
  <key>CFBundleIdentifier</key><string>io.github.moritz-poth.mountpoint.cleanup</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>MountpointRelease</key><string>$RELEASE</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Moritz Poth. GPL-3.0-or-later.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
# ad-hoc signed (no Apple Developer account): macOS needs "Open Anyway" once, see README
# hardened runtime: blocks DYLD_* code injection into the app that holds Full Disk Access.
# Signed inside-out so --deep cannot strip mirror's entitlement.
MIRROR_ENT="$(mktemp -t mirror-ent).plist"
cat > "$MIRROR_ENT" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- mirror links macFUSE's libfuse, signed by another team -->
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
ENT
codesign --force --sign - --options runtime --entitlements "$MIRROR_ENT" "$APP/Contents/MacOS/mirror"
rm -f "$MIRROR_ENT"
codesign --force --sign - --options runtime "$SET"
codesign --force --sign - --options runtime "$CLEAN"
codesign --force --sign - --options runtime "$APP"
# what installed updaters check: the whole bundle incl. the nested settings app verifies, versions match
codesign --verify --deep --strict "$APP"
NESTED_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$SET/Contents/Info.plist")
NESTED_REL=$(/usr/libexec/PlistBuddy -c "Print :MountpointRelease" "$SET/Contents/Info.plist")
if [ "$NESTED_ID" != "io.github.moritz-poth.mountpoint.settings" ] || [ "$NESTED_REL" != "$RELEASE" ]; then
  echo "settings app bundle is wrong: $NESTED_ID $NESTED_REL" >&2; exit 1
fi
CLEAN_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$CLEAN/Contents/Info.plist")
CLEAN_REL=$(/usr/libexec/PlistBuddy -c "Print :MountpointRelease" "$CLEAN/Contents/Info.plist")
if [ "$CLEAN_ID" != "io.github.moritz-poth.mountpoint.cleanup" ] || [ "$CLEAN_REL" != "$RELEASE" ]; then
  echo "cleanup app bundle is wrong: $CLEAN_ID $CLEAN_REL" >&2; exit 1
fi
# the bundle is recreated at the same path: without this, Finder keeps showing a cached (blank or old) app icon
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
# old zip and signature go first: a run that fails later never leaves a new zip next to an old .sig
rm -f "dist/Mountpoint-$RELEASE.zip" "dist/Mountpoint-$RELEASE.zip.sig"
ditto -c -k --keepParent "$APP" "dist/Mountpoint-$RELEASE.zip"
# download image: the classic window with the app next to an Applications link (the updater keeps using the zip)
DMG="dist/Mountpoint-$RELEASE.dmg"
STAGE=.build/dmg; RW=.build/Mountpoint-rw.dmg
rm -rf "$STAGE" "$RW" "$DMG"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Mountpoint.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
swift scripts/make-dmg-background.swift .build/dmg-bg.png 1
swift scripts/make-dmg-background.swift .build/dmg-bg@2x.png 2
tiffutil -cathidpicheck .build/dmg-bg.png .build/dmg-bg@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null
# never eject someone else's volume, and Finder's disk "Mountpoint" below must be ours: no other volume of that name
if ls /Volumes | grep -Eq '^Mountpoint( [0-9]+)?$'; then echo "a volume \"Mountpoint\" is mounted – eject it first" >&2; exit 1; fi
hdiutil create -quiet -volname Mountpoint -srcfolder "$STAGE" -fs HFS+ -format UDRW "$RW"
hdiutil attach -quiet -noautoopen -mountpoint "/Volumes/Mountpoint" "$RW"
# window layout is stored by Finder in .DS_Store (needs Finder automation for the terminal once)
osascript <<'OSA' || echo "warning: DMG window layout not set (Finder automation denied?)" >&2
tell application "Finder"
  repeat 20 times -- Finder sees a fresh image only after a moment
    if exists disk "Mountpoint" then exit repeat
    delay 0.5
  end repeat
  tell disk "Mountpoint"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set background picture of opts to file ".background:background.tiff"
    set position of item "Mountpoint.app" of container window to {140, 160}
    set position of item "Applications" of container window to {400, 160}
    set bounds of container window to {200, 120, 740, 460}
    update without registering applications
    delay 2
    close
    -- Finder writes the window size to .DS_Store only reliably after a second open/close
    open
    delay 1
    close
  end tell
end tell
OSA
sync
# Finder or Spotlight may still hold the volume for a moment
hdiutil detach "/Volumes/Mountpoint" -quiet || { sleep 2; hdiutil detach "/Volumes/Mountpoint" -quiet -force; }
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -rf "$STAGE" "$RW"
# update signature: installed apps only accept zips signed with the key in this Mac's Keychain
if PUB=$(swift scripts/update-key.swift public 2>/dev/null) && grep -q "\"$PUB\"" Sources/Mountpoint/Updater.swift \
   && swift scripts/update-key.swift sign "dist/Mountpoint-$RELEASE.zip"; then
  echo "Done: $APP, $DMG, dist/Mountpoint-$RELEASE.zip (+ .sig – upload all three)"
else
  echo "Done: $APP, dist/Mountpoint-$RELEASE.zip – NOT SIGNED (no update key, or it differs from Updater.publicKey): not releasable" >&2
fi
