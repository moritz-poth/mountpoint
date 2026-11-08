# Mountpoint 1.2.0 – changes since 1.1.4 and the guarantees they must keep

This document describes the uncommitted changes in this repository (relative to commit `e5c56e5`, release 1.1.4) and states
what the code must guarantee. It is the target of a pre-release review: every statement in the *Guarantees* sections
must be true in the source code. Source: `Sources/Mountpoint/`, build: `scripts/build-app.sh`, tests: `Tests/MountpointTests/`.

## 1. Why the settings became their own app

Mountpoint is a menu bar app (activation policy `.accessory`, `LSUIElement`). In 1.1.1–1.1.3 the settings window turned
Mountpoint into a regular app while it was open, to get a Dock icon and a ⌘-Tab entry. macOS then listed Mountpoint last in
⌘-Tab, and every workaround (deactivate, hide/unhide, handing activation to the Dock with delays) was slow or unreliable.
1.1.4 removed the Dock icon again. 1.2.0 runs the settings as a separate, regular app instead.

### Alternatives considered

- **Keep the settings in Mountpoint without Dock icon (1.1.4):** reliable, but no ⌘-Tab entry for the settings, which
  the app's owner asked for while testing 1.1.x.
- **XPC / NSXPC service:** a typed, authenticated channel, but needs a launchd-registered service or a connection
  broker; too heavy for a menu bar app without a Developer ID. Rejected.
- **Settings app as a pure UI client, Mountpoint the only writer:** every edit becomes a request; the settings app could
  not work while Mountpoint is not running and needs replies for every field. Rejected in favour of field ownership (§4).
- **Protected volumes in a file of their own:** would avoid merging `library.json`, but needs a second file with its own
  lock, a migration of the guards in existing `library.json` files (and a rollback story for 1.1.4, which reads them
  there), and the same merge question for Mountpoint's in-process fallback window. Rejected; enforced field ownership in
  one file is less code.
- **LaunchAgent / SMAppService helper:** solves background work, not the window/⌘-Tab problem. Rejected.
- **Chosen:** same binary in a second bundle, shared defaults domain and `library.json`, field ownership with a
  read-merge-write under a file lock, `DistributedNotificationCenter` for change notices and the few jobs only
  Mountpoint may do.
- **Watching `library.json` (DispatchSource/kqueue) or KVO on the shared defaults instead of notifications:** would make
  change notices independent of IPC delivery, but atomic writes replace the file (the watch must be re-armed), KVO on a
  suite domain across processes is not reliable, and the jobs for Mountpoint (launch at login, show update) still need a
  message channel. Rejected for 1.2.0.

### Goals

- Settings as a regular app (Dock icon, ⌘-Tab, menu bar) that opens fast, while Mountpoint stays a menu bar app.
- No loss of workspaces, projects or protected volumes through the second process, in any order of edits or failures.
- Every error a user can cause or see in the settings app is shown with what to do.

### Non-goals

- Running two copies of Mountpoint (for example a development build next to the installed one) side by side.
- Editing workspaces or projects in the settings app.

## 2. Packaging

- `scripts/build-app.sh` builds `Mountpoint.app/Contents/Helpers/Mountpoint Settings.app`: the same universal binary,
  copied as `Contents/MacOS/Mountpoint Settings`, bundle id `io.github.moritz-poth.mountpoint.settings`, no `LSUIElement`
  (regular app with Dock icon, ⌘-Tab and menu bar), same icon, fonts and `*.lproj`, localized display name via
  `InfoPlist.strings` (en/de/fr/es), same `CFBundleVersion`, `CFBundleShortVersionString` and `MountpointRelease`.
- Version 1.2.0, build 24. The whole `Mountpoint.app` is ad-hoc signed with `codesign --deep`; the build script itself
  runs `codesign --verify --deep --strict` and checks the nested bundle id and release, and fails otherwise.

### Guarantees

- G2.1 The nested app is signed and the outer app passes `codesign --verify --deep --strict` (checked by the build
  script and by `UpdaterTests.unpackAcceptsOnlyTheExpectedIntactApp`, which also rejects a tampered nested file).
- G2.2 Updating from 1.1.x to 1.2.0 with the built-in updater works: tag `v1.2.0` = `MountpointRelease` 1.2.0, bundle
  id and signature of the outer app as before. The installed old updaters are not run by any automated test; this is the
  manual check M1 (§9).
- Rollback: the `library.json` schema is unchanged, so 1.1.4 reads a file written by 1.2.0. Signing still uses
  `codesign --deep`, which Apple deprecates for signing; it is to be replaced once there is a Developer ID.

## 3. One code base, two modes

- `Model.swift`: `mainBundleID`, `settingsMode` (true when the bundle id is `mainBundleID + ".settings"`), `defaults`
  (in settings mode `UserDefaults(suiteName: mainBundleID)`, otherwise `.standard`) and `mainBundleURL` (the outer
  `Mountpoint.app`, also from inside the settings app).
- `main.swift`: in settings mode `SettingsAppDelegate` runs with activation policy `.regular`; otherwise `AppDelegate`
  with `.accessory`.
- `SettingsApp.swift`: `SettingsAppDelegate` first registers the IPC listener, then loads the store, asks Mountpoint for
  the login-item state, builds the menu and shows `SettingsWindow` (pane from `--pane <n>`). It quits when the last window
  closes – unless a self-test is running (§7).

### Guarantees

- G3.1 Every read and write of shared settings in both processes goes through `defaults`. The language switch also writes
  the settings app's own `AppleLanguages` (its `UserDefaults.standard`) for system texts from its next launch; its menu
  follows at once through the `$language` subscription.
- G3.2 In settings mode, `Store.shared` is passive (the self-test's own temporary stores are not): no refresh timer; `mount`, `unmount` and `refresh` return at once;
  never syncs Mountpoint's Finder sidebar entries or starts the volume guard; never sets `library.json` aside (§4, G4.5);
  never reads `SMAppService`. (The self-test, when run from the settings app, checks the sidebar with its own test volumes.)
- G3.3 The settings app never shows the welcome panel, the self-test consent panel, a status item, guard alerts, and never
  starts the updater timer.

## 4. Shared state and IPC

- Both processes read and write the same `library.json` (`~/Library/Application Support/Mountpoint/`) and the same
  defaults domain.
- **Field ownership, enforced in `Store.merged(onto:)`:** `projects`/`workspaces` belong to Mountpoint – it always
  writes and keeps them from memory, the settings app always takes them from the file and never writes an edited copy (only its last-loaded state, when the
  file is missing – see below).
  `guarded`/`guardOwn` are edited by the settings app (and by Mountpoint's in-process fallback window): each process takes
  from memory only those it changed since its last load or save, the rest from the file. `Store.save()` does this under a
  file lock (`library.json.lock`) after re-reading the file, so a stale or empty copy never overwrites the other side's
  data. Guard merging works per whole field: should the fallback window and the settings app both edit guards before
  either reloads, the later save wins for that field – a known limit.
- `IPC.swift`: `DistributedNotificationCenter`, name `io.github.moritz-poth.mountpoint.ipc`, user info `what`, `pid` and
  extras; `post` calls `CFPreferencesAppSynchronize` first; `listen` ignores the process's own messages.
- Messages: `library` (after every save by `Store.shared`, posted after the file lock is released; also once at
  Mountpoint's start), `settings` (the settings app, after a user change), `launchAtLogin` with `on` and a request `id`,
  and `launchAtLoginQuery` (jobs for Mountpoint), `launchAtLoginResult` with `on`, `error` and the request `id`
  (Mountpoint's reply; empty `id` for a query), `showUpdate` (open Mountpoint's panel with the update notice), `pane`
  (Mountpoint → running settings app).
- Mountpoint registers its IPC listener before `Store.shared` reads `library.json`, then reloads the settings once, so a
  change saved by an open settings app during Mountpoint's start is not missed.
- `Store.reloadLibrary()` re-reads `library.json` with the same merge as `save()`; `Store.reloadSettings()` synchronizes the defaults domain and assigns only values that differ; while it
  assigns, setting changes are neither announced nor logged.
- Reading `library.json` distinguishes *missing* (ENOENT) from *unreadable* (any other read error, or invalid JSON).
  - Unreadable, settings app: read-only. Guard edits are refused before anything changes in memory (an edit refused at
    save time is taken back), so the window only shows what is saved. Notice: "…cannot be saved right now. Mountpoint
    repairs the list while it runs – open Mountpoint if it is not running." It posts `library` so a running Mountpoint
    re-reads at once.
  - Unreadable, Mountpoint (at a save or reload): it holds the complete list, so under the lock it moves the file aside
    (`library-unreadable-<time>.json`) and writes its list; notice "…was set aside as … Mountpoint saved the list it had
    open." At launch it has no list: it moves the file aside and writes an empty list. If the move fails, it writes
    nothing and says so ("…could not be set aside either. Mountpoint does not change it."). Its in-memory list is then not
    authoritative (`knowsList = false`): the first readable version of the file (for example after the user fixed the
    permissions) supplies projects and workspaces, instead of being overwritten with the empty list.
  - Missing: both write their last known state (`loaded`). The settings app thus writes the projects/workspaces it last
    loaded (none if it started while the file was missing) – never edited ones. A settings-app reload that finds the
    file missing posts `library`; Mountpoint keeps its own list: a reload that finds the file missing, or with
    projects/workspaces different from Mountpoint's, makes Mountpoint save at once.
  - A successful reload ends read-only and removes its notice.
- `save()` logs when the lock file cannot be opened and then saves without the lock. The lock is held only for one
  read-merge-write on the main thread; a process stopped while holding it would block the other one's next save.
- Launch at login: only Mountpoint calls `SMAppService.mainApp`. It always answers with the real state, the error text,
  if any, and the request id; for requests from the settings app it does not touch its own panel notice. The settings
  app accepts an error and the switch state only from the answer to its pending request; without that answer within 3 s
  the switch returns to the state Mountpoint last confirmed and the window says "Mountpoint did not answer…". A later
  answer sets the switch and removes that notice. The switch never removes other notices (for example read-only).

### Guarantees

- G4.1 No data loss: a change saved by one process is never overwritten by a stale copy in the other, in any order of
  edits, also when one side has not processed the other's `library` message yet (test
  `editsWithoutReloadInBetweenAreNeverLost`).
- G4.2 No message loops and no echo: a successful reload never posts; a reload never posts `settings`; a reload that finds
  `library.json` missing, unreadable or with projects/workspaces different from Mountpoint's posts `library` only to
  request (settings app: missing or unreadable) or announce (Mountpoint, only after a successful write) a repair, so no
  path repeats. The same setting change is logged once, by the process that made it; launch at login is logged by
  Mountpoint, which performs it.
- G4.3 Every setting changed in the settings app (launch at login, light/dark, language, Finder sidebar, network drive,
  both warnings, test versions, protected volumes and their mode) takes effect in Mountpoint within about a second,
  including its side effects.
- G4.4 Launch at login registers Mountpoint itself, never the settings app.
- G4.5 An unreadable `library.json` (at launch or later, any reason other than "missing") is never overwritten: the
  settings app never writes or moves it and becomes read-only with its notice; only Mountpoint moves it aside, under the
  lock, and writes only after a successful move. Mountpoint never loses its in-memory workspace list because of a missing,
  empty or unreadable file.
- G4.6 Errors in the settings app (save failures, unreadable list, launch at login, Mountpoint cannot be opened from
  "Show in Mountpoint") appear as a banner in the settings window.

## 5. Opening and closing the settings

- `SettingsLauncher` (Mountpoint side) opens the settings app with `NSWorkspace.openApplication` (`activates = true`,
  `--pane` on first launch; IPC `pane` when it already runs) and tracks whether it runs via `NSWorkspace`
  launch/terminate notifications (`isOpen` → filled gear in the panel). If opening fails (for example Gatekeeper blocks
  the nested app), it logs the error and shows the settings in Mountpoint's own window instead. Development builds without
  the helper bundle always use that window.
- The panel closes when the settings app opens (normal popover behaviour) and opens again when the settings app
  terminates, but only if it was open when the settings were opened and the launch did not fail.
- ⌘, in the panel and the menu item "Settings…" open the settings app; "About Mountpoint" opens its About pane.
- When Mountpoint quits it asks a running settings app to quit too (the settings app finishes a running self-test first).
- An update is never installed while a self-test runs in either process (`SelfTest.runningAnywhere`, checked when the
  user clicks Install and again right before the swap); the panel says "A self-test is running. Install the update when
  it is done." Before the swap Mountpoint asks the settings app to quit, waits up to 5 s and then force-quits it.
- When Mountpoint quits during its own self-test (started after the consent question), it waits for the test to clean up
  (`.terminateLater`), then ejects and quits.
- "Show in Mountpoint" in the settings app opens Mountpoint with `--show-update` when it does not run (it then checks and
  shows its panel), otherwise posts `showUpdate`.

### Guarantees

- G5.1 Clicking the gear always brings the settings window to the front, also when the settings app already runs or its
  window is hidden; if the settings app cannot be opened, the settings still appear.
- G5.2 The panel reopens after closing the settings only when it was open before; it never pops up unasked – also not
  minutes later when a close waited for a self-test (the settings app posts `noReopen`).
  *Superseded in 1.2.1:* the panel no longer reopens when the settings close (user request); `willOpen`/`openChanged`/
  `openFailed` and the `noReopen` message were removed.
- G5.3 After an update no settings process of the old version keeps running; quitting Mountpoint also quits the
  settings app (after its self-test, if one runs). No update or quit of Mountpoint cuts a self-test short.

## 6. Settings window

- `SettingsWindow.swift`: `NSTabViewController` with toolbar tabs (General, Avid Media Composer, Protected volumes,
  Updates, Support, About), 800×450, title = pane, minimize/zoom dimmed, last pane restored (`settingsPane`). Panes never
  scroll; only the protected-volume list (max. 180 pt) and the self-test results scroll; its intro text uses the full width, other hint texts stop
  at 390 pt. In settings mode the window has the normal level and does not hide on deactivate.
- Updates pane in the settings app: one update check per click; if an update exists, "Mountpoint X is available" with
  "Show in Mountpoint", which opens Mountpoint's panel with the install button (also after the notice was dismissed with ×:
  `Updater.dismissed` is reset).

### Guarantees

- G6.1 All new texts have translations in de/fr/es. `LocalizationTests` checks that the three files have the same keys
  and placeholders; it does not detect a string missing from all three, so new strings are checked by hand.
- G6.2 Language changes update tab labels and the window title without a restart.

## 7. Self-test and consent (from 1.1.x, changed in 1.2.0)

- `SelfTest.helper` and `SelfTest.icon` resolve the helper and `VolumeIcon.icns` from `mainBundleURL`, so the self-test
  also works from the settings app. It runs on its own APFS disk image; test volumes are named `MPSelftest-…`.
- Only one self-test runs at a time across both processes (`flock` on `$TMPDIR/Mountpoint-Selftest.lock`); a second start
  shows "A self-test is already running".
- The self-test's guards keep acknowledgements and snoozes in memory only (`VolumeGuard(persist: false)`) and watch only
  the self-test's own volumes: the folder checks pass `sizeRoots: { [] }`, so they never count or alert on the user's
  real MXF folders.
- Closing the settings window or pressing ⌘Q during a self-test keeps the window open with the notice "The self-test is
  still running. The settings close by themselves when it is done."; when the test is done the window closes and the
  app quits. So the settings app never runs without its window. Because the close was deferred, it posts `noReopen`:
  Mountpoint's panel does not pop up when the test ends. (Since 1.2.1 the panel never reopens, so `noReopen` is gone.)
- The consent panel (`Consent.swift`) appears after the welcome panel on first launch and once per new version, stays
  visible while Mountpoint is in the background (`hidesOnDeactivate = false`), and auto-sends the report after consent.

### Guarantees

- G7.1 The self-test never mounts, ejects, modifies or deletes the user's workspaces, volumes or files. With the user's
  consent, the optional NAS check creates and removes its own `.mountpoint-selftest-…` folder on one share; the system
  info only counts the workspaces.
- G7.2 A self-test never interferes with Mountpoint's own mounts, sidebar entries, acknowledgements or snoozes, or with
  another self-test, and never leaves test volumes behind when the window is closed.
- G7.3 Logging works in both processes without interleaved or overwritten lines: one `O_APPEND` write per line, rotation
  under a file lock; lines from the settings app carry `[settings]`. Lines are written on a background queue, so a line
  written right before a forced exit can be lost.

## 8. Risks and mitigations

- **Version skew** (old settings process after an update): no update during a self-test; before the swap the settings
  app is asked to quit and force-quit after 5 s (G5.3). A self-test started in the fraction of a second between the
  swap-time check and the force-quit would be cut short – accepted.
- **Quit waits for a self-test:** a self-test takes a few minutes; quitting (also at logout) waits that long. Accepted:
  the alternative leaves test volumes and a disk image behind.
- **IPC is unauthenticated:** any local process of the same user can post the jobs. They are harmless (login-item toggle of
  Mountpoint itself, update check, opening a pane). A development build running beside the installed app reacts too –
  a non-goal.
- **Unsent problem report:** quitting or updating Mountpoint quits the settings app without asking; a problem report
  typed but not sent (or a send in flight) is lost – accepted, the self-test is protected, a report can be sent again.
- **Settings app without Mountpoint:** protected-volume edits are saved and applied at the next Mountpoint start; launch at
  login says that Mountpoint did not answer; "Show in Mountpoint" starts Mountpoint.
- **Gatekeeper on the nested, ad-hoc-signed app** after a browser download: fallback to the in-process window (G5.1);
  both paths verified by hand before the release (M3, M6).

## 9. Files and tests

- New: `Sources/Mountpoint/SettingsApp.swift`, `IPC.swift`, `Tests/MountpointTests/SettingsAppTests.swift`.
- Changed: `Store.swift`, `Model.swift`, `main.swift`, `SettingsWindow.swift`, `Panel.swift`, `SelfTest.swift`,
  `Support.swift`, `Consent.swift`, `Welcome.swift`, `Guard.swift`, `Log.swift`, `Sidebar.swift`, `Updater.swift`,
  `scripts/build-app.sh`, `Resources/*.lproj/Localizable.strings`, `Tests/MountpointTests/UpdaterTests.swift`,
  `CLAUDE.md`, `README.md`.
- Automated: `swift test` (74 tests, of which 17 stress and 6 integration tests only run with `MOUNTPOINT_STRESS=1` /
  `MOUNTPOINT_IT=1`; one live GitHub test returns early without `MOUNTPOINT_IT=1`). `SettingsAppTests`, all in one process with two `Store` instances: G3.2 (passive store never
  mounts), G4.1 (edits without reload in between; file deleted while Mountpoint runs and a new settings app writes – checked
  on disk right after Mountpoint's reload),
  G4.3 only as "every setting and the language reload from defaults" (not the IPC delivery or the side effects), G4.5
  (settings app: unreadable at launch, no read permission, read-only from launch then recovered; Mountpoint: corrupted
  after load and repaired, unreadable file that cannot be moved – also after it becomes readable again; Mountpoint's
  successful set-aside at launch is not tested separately), G7.2 (self-test lock, `runningAnywhere`, persistence of `bigKnown`
  only) and launch at login (timeout to the confirmed state, late answer, foreign answer, other notices kept, read-only
  notice returns after a login notice).
  `UpdaterTests` covers G2.1 for the build in `dist/` (fails when it is missing with `MOUNTPOINT_RELEASE=1`).
- Manual before the release, in this order, with expected results:
  - Before each check: quit Mountpoint and Mountpoint Settings; `pgrep -lf Mountpoint` shows neither.
  - M3 (G5.1, Gatekeeper): download the built zip through a browser (keeps the quarantine flag; check with
    `xattr -p com.apple.quarantine <zip>`), unzip, move `Mountpoint.app` to /Applications (no App Translocation), open
    it, confirm "Open Anyway" in System Settings → Privacy & Security for Mountpoint only → click the gear: no further
    system dialog, the settings app opens. If a dialog appears, the release is blocked: note the dialog text and the
    log (`~/Library/Logs/Mountpoint`), then in build-app.sh sign inside out –
    `codesign --force --sign - "$SET"` before `codesign --force --sign - "$APP"` (without `--deep`) – rebuild and repeat.
    If the dialog still appears, stop the release and keep 1.1.4.
  - M6 (G5.1 fallback): in a copy of the built app, `chmod -x "…/Helpers/Mountpoint Settings.app/Contents/MacOS/Mountpoint
    Settings"`, start that copy, open the panel → click the gear: the settings open in Mountpoint's own window, the gear
    is filled, the panel stays as it was while the window is open; after closing the window nothing pops up by itself.
    Quit the copy and delete it.
  - M4 (G5.2, §7): start the self-test in the settings app, close the window → it stays open with the notice and closes
    when the test is done; the panel does not pop up afterwards. Same with ⌘Q. Then start another self-test in the
    settings app and quit Mountpoint → the settings app stays until the test is done, then quits.
  - M5 (G4.3), both apps running, the panel open next to the settings window. Preconditions: a mounted SMB share
    (rows "1" and protected volume), a test folder `Avid MediaFiles/MXF/9` with more than 5000 files on a drive, a
    published prerelease newer than the installed version (row test versions; run that row after M2(b), with the M2 beta,
    before deleting it). For the warning rows do not click "OK" on an alert (that silences it) – use a fresh folder or
    delete and re-create `1` for each on/off step. Every result is
    produced by Mountpoint itself (no `[settings]` tag in the log, or visible in Mountpoint's panel or alerts):

    | Change in the settings app | Expected in Mountpoint within about a second |
    |---|---|
    | Light/Dark | panel colours switch |
    | Language | panel texts and menus switch |
    | Finder sidebar off/on | mounted workspaces leave/return under "Locations" |
    | Mount as network drive | next mount: volume shows as network volume (on) or local (off) in Finder's Get Info |
    | Warn about "1" on network drives | creating `Avid MediaFiles/MXF/1` on a mounted NAS raises an alert (on), none (off) |
    | Warn about folders over 5000 files | on: Mountpoint's alert for `MXF/9` within about a minute; off: none |
    | Get test versions | on: Mountpoint's panel offers the prerelease (after "Show in Mountpoint" or within its next check); off: not |
    | Add protected volume / switch its mode | creating `Avid MediaFiles` (or own folder in MXF) on it raises an alert |
    | Launch at login on/off | System Settings → Login Items lists/drops Mountpoint |
    | Launch at login without Mountpoint | quit Mountpoint, `open "/Applications/Mountpoint.app/Contents/Helpers/Mountpoint Settings.app"`, `pgrep -lf Mountpoint` shows only the settings app → toggle: after 3 s the switch returns with "Mountpoint did not answer…" |
    | Protected volume without Mountpoint | same setup, add a protected volume, quit the settings, open Mountpoint → the volume is protected (alert on `Avid MediaFiles`) |

  - M1 (G2.2): publish 1.2.0 on GitHub as a **prerelease** (zip + .sig). On a Mac with 1.1.4 and "Get test versions" on:
    Install in the panel → 1.2.0 starts, workspaces and settings unchanged; the gear opens the settings app and it shows
    the same settings as before (read through the shared domain, new in 1.2.0). Then mark the release as latest (only
    then do users without test versions get it).
  - M2 (G5.3): set `VERSION=1.2.1`, `RELEASE=1.2.1-beta.1`, `BUILD=25` in `scripts/build-app.sh`, build, publish as a
    prerelease `v1.2.1-beta.1`. On a Mac with 1.2.0 and "Get test versions" on, first (b): self-test running in the settings
    app → Install says "A self-test is running…", nothing is replaced, no "installing update" line in the log. Then (a):
    settings app open → Install → after the restart `pgrep -lf "Mountpoint Settings"` lists no process, or only one
    started after the update. Delete the prerelease and its tag right after, and reset
    build-app.sh to 1.2.0/24 (testers are then offered 1.2.0 again; anyone who installed the beta updates to the next
    real version).
