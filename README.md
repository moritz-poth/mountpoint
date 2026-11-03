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
- **Warning about numbered folders** – per workspace or for a whole project (⋯ menu): an alert as soon as Avid creates a folder named only with a number (`1`, `2` …) in `Avid MediaFiles/MXF` – in a team every system can write into those.
- **Trash on network-style volumes** – macOS gives network drives no trash, so the Finder would delete immediately. Mountpoint moves what the Finder deletes into the trash of the drive the folder lives on instead – under its own name, like macOS does. The Finder still warns "will be deleted immediately" – the files are recoverable anyway. Other apps (e.g. Avid) delete as usual.
- **Own volume icon** in the Finder and **plain-language error messages** that say what went wrong and what to do.
- **Safe** – Mountpoint never deletes, moves or overwrites files. It never force-ejects: if Avid still has files open, the volume stays mounted.
- English and German, light and dark appearance, launch at login.

## Good to know

- **“This item will be deleted immediately”** – the Finder shows this warning for every network drive, and Mountpoint mounts workspaces as network drives so that Media Composer Enterprise creates `<computer name>.1` folders. **The warning is wrong here:** Mountpoint moves everything the Finder deletes into the Trash of the drive the folder lives on – under its own name, and you can drag it back from the Trash. (*Put Back* is not available.) The warning cannot be removed without losing the Avid collaboration: Finder and Avid both decide by whether a volume counts as local.
- **Deleting outside the Finder** (Terminal, Avid’s Media Tool) deletes permanently, as on any drive.
- **Changing settings or updating Mountpoint** applies to volumes the next time they are mounted – eject and mount them once.
- **Use at your own risk:** Mountpoint comes without any warranty; the author is not liable for data loss or other damage. Always keep a backup of your media.
- **Avid’s drive filter:** turn off *filter network drives* under Media Creation → Drive Filtering on every system, otherwise Avid hides the workspaces.

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

The menu bar icon (a drive with a folder) appears at the top right. It is filled while at least one workspace is mounted. On the very first launch a short notice explains the Finder’s delete warning and that you use Mountpoint at your own risk – it appears until you click **I understand**.

## Usage

- **Add workspace…** – pick the folder that contains `Avid MediaFiles` (folders that do are marked **AVID**). If it is missing, Mountpoint offers to create `Avid MediaFiles/MXF`. The picker remembers where you were last.
- **Mount / Eject** – per workspace or per project. Status dots: green = mounted, grey = not mounted, orange = partly mounted or a problem.
- **⋯ menus** – move a workspace to a project, show it in Finder, remove it; rename or delete a project, mount it at app launch. Removing a workspace or deleting a project never touches any files.
- **Settings (gear icon)** – launch at login, mount as network drive, appearance, language, protected volumes. Settings are saved right away; the panel always reopens on its main page. Changing the language restarts the app for a moment; mounted volumes stay mounted.

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
