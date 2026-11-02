# Mountpoint – notes for working on the project

Mac-only menu bar app (own `NSStatusItem` + `NSPopover` with SwiftUI, `LSUIElement`), macOS 13+, universal (arm64 + x86_64). Sister project of MediaFiles Ferry, same typography and colors. GPL-3.0. Users are editors without a technical background.

## Fixed rules
- Never delete, move or overwrite files. Removing a workspace = remove the entry + eject.
- Never force-eject (`/sbin/umount` without `-f`); "busy" → tell the user to quit Media Composer.
- Volume name = folder name, mount point `/Volumes/<name>`. An existing, non-empty entry there blocks mounting.
- Eject via `/sbin/umount`, not `unmount(2)`: only then does macOS remove the mount point folder (`/Volumes` is owned by root).
- NAS: when adding, store `volumeURLForRemounting` + subpath; when mounting, connect the share via NetFS.
- Protected volumes (`Guard.swift`): never scan. kqueue on the volume root (`O_EVTONLY`, does not block eject) + mount notifications + 60 s safety net. Snooze is per volume and persisted; alert again after the snooze; "OK" = only again when the folder is created anew.
- Always decode `Library` with `decodeIfPresent`: old files without new fields must still load.

## UI
- No `MenuBarExtra` and no `NSAlert` in the panel: both close the panel. Questions are `Dialog` cards in the panel (Panel.swift), the folder picker is `FolderBrowser` in the panel (no `NSOpenPanel`). Anything open outside the panel (NAS password) keeps it open via `hold(true)`.
- Settings and folder picker replace the panel content (no separate windows: they slip behind the panel). The picker starts at `Store.lastFolder`.
- Dots: green = all mounted, grey = none, orange (`Theme.partial`) = partly / problem. Projects are collapsed by default.
- Colors only from `Theme` (Views.swift), font `Font.mono` (JetBrains Mono), title Helvetica Neue Light. Default: dark.
- UI strings are English in code, translations in `Resources/<code>.lproj/Localizable.strings` – update them with every new string. Language is selectable (default English, `languages` in Model.swift); switching restarts the app via `AppleLanguages`, volumes stay mounted.
- Visual check: temporarily render the panel with `ImageRenderer` to PNG, then remove the hook again.

## Icon
N01 (`assets/icon.svg` → `assets/icon.png` → AppIcon.icns in the build script). Menu bar: `menuBarIcon()` in main.swift draws the same motif as a template image; mounted = drive filled. Folder lines have flat ends.

## Build / test
`scripts/build-app.sh` (universal app + zip), `swift test`, `MOUNTPOINT_IT=1 swift test` (really mounts). Only Swift Testing is available (Command Line Tools, no XCTest). Release: bump `VERSION`/`RELEASE`/`BUILD` in the build script.
