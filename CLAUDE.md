# Mountpoint – notes for working on the project

Mac-only menu bar app (own `NSStatusItem` + `NSPopover` with SwiftUI, `LSUIElement`), macOS 13+, universal (arm64 + x86_64). Sister project of MediaFiles Ferry, same typography and colors. GPL-3.0. Users are editors without a technical background.

## Fixed rules
- Never delete, move or overwrite files. Removing a workspace = remove the entry + eject.
- Never force-eject (`/sbin/umount` without `-f`); "busy" → tell the user to quit Media Composer.
- Default: mount as network drive (no macFUSE `local` flag → macOS reports non-local, DiskArbitration network=1). Media Composer Enterprise (tested 2026.8) then creates "<computer name>.1" instead of "1". Setting `Store.network`; `local` only when switched off.
- Volume name = folder name, mount point `/Volumes/<name>`. An existing, non-empty entry there blocks mounting.
- Eject via `/sbin/umount`, not `unmount(2)`: only then does macOS remove the mount point folder (`/Volumes` is owned by root).
- NAS: when adding, store `volumeURLForRemounting` + subpath; when mounting, connect the share via NetFS.
- Protected volumes (`Guard.swift`): never scan. kqueue on the volume root (`O_EVTONLY`, does not block eject) + mount notifications + 60 s safety net. Snooze is per volume and persisted; alert again after the snooze; "OK" = only again when the folder is created anew.
- Always decode `Library` with `decodeIfPresent`: old files without new fields must still load.
- An unreadable `library.json` is set aside (`library-unreadable-<time>.json`) with a notice – never continue silently with an empty list (the next save would overwrite it).
- Errors must say what happened and what to do, in plain words (EN + DE); technical output goes after "Details:". Per-workspace errors show in the row, app-wide ones in `Store.notice` (banner in the panel; menu bar icon gets a dot). No `NSAlert` while the panel is open; on quit, an alert lists volumes that stay mounted.
- Numbered-folder warning: `Workspace.warnNumbered` (optional for old files); project checkmark = all its workspaces on; new workspaces inherit it. Guard watches `<volume>/Avid MediaFiles/MXF` (kqueue + 60 s); folders present when watching starts are "known", only new ones alert; "OK" adds them to the known list (UserDefaults `numberedKnown`).
- Trash: network-style volumes have no trash. `helper/mirror.c` moves deletions by the Finder (`Finder.app` or its `DesktopServicesHelper`, found via the caller's pid) into the source volume's `.Trashes/<uid>` (`~/.Trash` on the system volume), keeping folder structure; if moving fails it returns an error instead of deleting. Other callers delete normally.
- Volume icon: `scripts/make-volume-icon.swift` → `VolumeIcon.icns`, passed to the helper as `volicon` (otherwise Finder shows macFUSE's "FUSE" drive).

## UI
- No `MenuBarExtra` and no `NSAlert` in the panel: both close the panel. Questions are `Dialog` cards in the panel (Panel.swift), the folder picker is `FolderBrowser` in the panel (no `NSOpenPanel`). Anything open outside the panel (NAS password) keeps it open via `hold(true)`.
- Settings and folder picker replace the panel content (no separate windows: they slip behind the panel). The picker starts at `Store.lastFolder`.
- Dots: green = all mounted, grey = none, orange (`Theme.partial`) = partly / problem. Projects are collapsed by default.
- Colors only from `Theme` (Views.swift), font `Font.mono` (JetBrains Mono), title Helvetica Neue Light. Default: dark.
- UI strings are English in code, translations in `Resources/<code>.lproj/Localizable.strings` – update them with every new string. Language is selectable (default English, `languages` in Model.swift); switching restarts the app via `AppleLanguages`, volumes stay mounted.
- Visual check: temporarily render the panel with `ImageRenderer` to PNG, then remove the hook again.

## Icon
N01, drawn by `scripts/make-icon.swift` → `assets/icon.png` (Apple grid: 824 px plate, shadow, gradient, light edge) → AppIcon.icns in the build script. Menu bar: `menuBarIcon()` in main.swift draws the same motif as a template image; mounted = drive filled. Folder lines have flat ends.

## Build / test
`scripts/build-app.sh` (universal app + zip), `swift test`, `MOUNTPOINT_IT=1 swift test` (really mounts). Only Swift Testing is available (Command Line Tools, no XCTest). Release: bump `VERSION`/`RELEASE`/`BUILD` in the build script.
