<p align="center"><img src="assets/icon.png" width="128" alt="Mountpoint icon"></p>

# Mountpoint

A small macOS menu bar app that mounts any folder as its own volume – from a local disk, an archive drive or a NAS.

Built for Avid Media Composer: Avid only finds media in an `Avid MediaFiles` folder at the **root** of a volume. With Mountpoint, a folder like `/Volumes/Archive/2024/Documentary/AI_Media` becomes the volume `AI_Media`, with `Avid MediaFiles` right at its top.

*Deutsch: Die App gibt es auch auf Deutsch – Einstellungen (Zahnrad) → Sprache.*

> **Beta.** Mountpoint 1.0 is a beta. Please report problems in [Issues](../../issues).

## Features

- **Workspaces** – folders that are mounted as volumes. The volume name is the folder name.
- **Projects** – group workspaces, mount or eject a whole project with one click, and mount projects automatically when the app starts.
- **NAS without Finder** – Mountpoint remembers the network share of a workspace and connects it itself when needed (credentials from the Keychain). The folder picker can also connect to a share directly (`smb://nas/Archive`).
- **Create folders** – create new workspace folders, with `Avid MediaFiles/MXF` inside, directly from the folder picker.
- **Avid collaboration** – by default workspaces are mounted as *network drives*. Media Composer Enterprise then creates a `<computer name>.1` media folder instead of `1`, like on shared storage, so several systems (e.g. synced with Syncthing) never write into the same folder. Turn off *filter network drives* in Avid's Media Creation settings. Can be switched off in the settings.
- **Protected volumes** – get an alert as soon as Avid creates `Avid MediaFiles` on a volume where it should never write (e.g. LucidLink). Alerts can be snoozed per volume (5 min … rest of the day).
- **Safe** – Mountpoint never deletes, moves or overwrites files. It never force-ejects: if Avid still has files open, the volume stays mounted.
- English and German, light and dark appearance, launch at login.

## Requirements

- macOS 13 Ventura or later, Apple Silicon or Intel
- [macFUSE](https://macfuse.github.io) – often already installed by other tools (e.g. Mimiq)

## Install

1. Download `Mountpoint-<version>.zip` from [Releases](../../releases) and unzip it.
2. Move `Mountpoint.app` to your **Applications** folder.
3. Open it once as described below.

### First launch: “Apple could not verify …”

Mountpoint is open source and is not signed with a paid Apple Developer certificate. macOS therefore blocks the first launch. You only need to allow it **once**:

1. Double-click `Mountpoint.app`. macOS shows a warning – click **Done** (or **OK**).
2. Open **System Settings → Privacy & Security**.
3. Scroll down to *“Mountpoint” was blocked …* and click **Open Anyway**.
4. Confirm with your password and click **Open Anyway** again.

Alternatively, in Terminal:

```
xattr -dr com.apple.quarantine /Applications/Mountpoint.app
```

The menu bar icon (a drive with a folder) appears at the top right. It is filled while at least one workspace is mounted.

## Usage

- **Add workspace…** – pick the folder that contains `Avid MediaFiles` (folders that do are marked **AVID**). If it is missing, Mountpoint offers to create `Avid MediaFiles/MXF`. The picker remembers where you were last.
- **Mount / Eject** – per workspace or per project. Status dots: green = mounted, grey = not mounted, orange = partly mounted or a problem.
- **⋯ menus** – move a workspace to a project, show it in Finder, remove it; rename or delete a project, mount it at app launch. Removing a workspace or deleting a project never touches any files.
- **Settings (gear icon)** – launch at login, appearance, language, protected volumes. Changing the language restarts the app for a moment; mounted volumes stay mounted.

### Protected volumes

Mountpoint does not scan your drives. macOS notifies it when something changes at the top level of a protected volume, so it uses no CPU while nothing happens; a single check per minute acts as a safety net. Mountpoint cannot *prevent* the write – it tells you within seconds so you can stop the import or render. It never deletes the folder.

## Build

Requires the Xcode Command Line Tools and macFUSE.

```
scripts/build-app.sh            # → dist/Mountpoint.app (universal) and dist/Mountpoint-<version>.zip
swift test                      # unit tests
MOUNTPOINT_IT=1 swift test      # also real mounts (after build-app.sh)
```

Layout: `Sources/Mountpoint` (SwiftUI menu bar app), `helper/mirror.c` (pass-through file system for macFUSE), `Resources/<code>.lproj` (translations), `assets` (icon and design drafts).

## Translate

The UI is written in English (the default). To add a language:

1. Create `Resources/<code>.lproj/Localizable.strings` (copy `Resources/de.lproj/…`)
2. Add the language to `languages` in `Sources/Mountpoint/Model.swift`
3. Add the code to `CFBundleLocalizations` in `scripts/build-app.sh`

## License

Copyright © 2026 Moritz Poth. Mountpoint is free software under the GNU General Public License v3.0 or later – see [LICENSE](LICENSE). It comes with no warranty. Font: [JetBrains Mono](https://www.jetbrains.com/lp/mono/) (SIL Open Font License, `Resources/fonts/OFL.txt`). macFUSE is a separate product with its own license and is not included.

Sister project of MediaFiles Ferry.

*Avid and Media Composer are trademarks of Avid Technology, Inc. LucidLink is a trademark of LucidLink Corp. This project is not affiliated with either.*
