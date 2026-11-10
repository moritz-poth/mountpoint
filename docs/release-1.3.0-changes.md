# Mountpoint 1.3.0 – changes since 1.2.2 and the guarantees they must keep

This document describes the changes in this repository since tag `v1.2.2` and states what the code must guarantee. It
is the target of a pre-release review: every statement in the *Guarantees* sections must be true in the source code.
Source: `Sources/Mountpoint/`, build: `scripts/build-app.sh`, tests: `Tests/MountpointTests/`.

Out of scope for this review (not part of the app): `worker/` (the Cloudflare endpoint that receives problem reports;
hourly limit per IP and app), `scripts/soak-test.py` (overnight test tool).

## Terms

- **Media Composer** – Avid's video editing program. It stores media in `<volume>/Avid MediaFiles/MXF/<n>` folders
  ("MXF folders"), each with two database files (`msmMMOB.mdb`, `msmFMID.pmr`); it gets slow when one MXF folder holds
  too many files.
- **Mountpoint** – the menu bar app that mounts workspaces (folders) as volumes at `/Volumes/<folder name>`. Workspaces
  mount as network drives by default, because Media Composer Enterprise then creates "<computer name>.1" folders
  instead of "1" (shared media); the macFUSE `local` flag would make them local drives.
- **Store** – the app's state object (settings, workspace list); `Store.isShared` is true for the shared store of a
  real app process – Mountpoint's and the settings app's – and false in tests; `passive` marks the settings app's.
- **Helper** – `helper/mirror.c`, the macFUSE process that serves one mounted workspace (one per mount).
- **Consent panel** – asks on the first launch of each new version whether to run the self-test (`Consent.swift`).
- **CLAUDE.md** – the project's working-rules file; **`shortcut:`** – an in-code marker naming a known limit and when
  to remove it.
- **Settings app** – since 1.2.0 the settings run as a second process, `Mountpoint.app/Contents/Helpers/Mountpoint
  Settings.app`: the same binary, switched by the flag `settingsMode`. Its `Store` is **passive**: it reads and writes
  settings but never mounts, never runs the guard and never syncs or purges the Finder sidebar (only a self-test started
  there adds and removes one test entry, `Sidebar.probe`). Both processes share one
  UserDefaults domain; a change in the settings app posts a **"settings" notice** (DistributedNotificationCenter), and
  Mountpoint applies it in `Store.reloadSettings()` (without logging it again). Details: `docs/release-1.2.0-changes.md`
  §3–§4.
- **Guard** (`VolumeGuard`) – watches folders and shows alerts; `VolumeGuard.shared` is Mountpoint's real guard. The
  **self-test** (Settings → Support → "Run self-test…") creates its own guard instances on a temporary disk image.
- **MediaFiles Check** – a sibling app by the same author (https://github.com/moritz-poth/mediafiles-check). Its
  **rebalancing** moves media files from over-full MXF folders into new folders and fills each folder up to exactly a
  user-set limit (default 5000), counting all visible files including the two database files.
- **Finder sidebar entries** – with the setting "Show in Finder sidebar" (`Store.sidebar`, default on) Mountpoint adds
  an entry for each volume it mounts to the Finder's "Locations" list (§3). `Sidebar.sync` is called on every refresh
  of the app's state; `Sidebar.removeAll` runs at quit and hides all entries Mountpoint added.
- **Owner** – the project's author and only maintainer. Decisions D1–D9 below were made in the development chat; this
  document is their record (no issue tracker is used – D9).

### Goals

- Settings window and self-test look like MediaFiles Check (owner, 2026-11-10).
- The user can set the same folder limit in Mountpoint as in MediaFiles Check (set by hand; Mountpoint does not read
  Check's settings), Mountpoint counts files the way Check does, and a folder Check filled to exactly that limit causes
  no warning.
- Ejected Mountpoint volumes no longer pile up in the Finder sidebar list and do not come back when the user ticks
  Finder Settings → Sidebar → "External disks".
- Downloads come as a disk image with the usual "drag to Applications" window.

### Non-goals

- No change to mounting, the helper (`helper/mirror.c`), IPC or field ownership (`docs/release-1.2.0-changes.md` §4).
- No Developer ID signing or notarization; the app stays ad-hoc signed ("Open Anyway" once).
- No change to the update channel: installed apps keep updating from the zip.

### Exception to a project rule

CLAUDE.md's first rule is "never delete, move or overwrite files". It protects the user's media and workspace data.
The sidebar purge (§3) overwrites a macOS list file; the owner asked for exactly this (D1). Scope of the exception:
list entries that match `isStale` (§3), a rule meant to match only entries Mountpoint itself created (see "Name match"
in §5), with two backups, never the user's files. CLAUDE.md states the exception at the rule.

### Alternatives considered

(Terms such as "ghost", "purge", "stale" and the scroller hook are explained in §1 and §3.)

- **Sidebar: re-use or unhide the hidden entry instead of inserting a new one.** LSSharedFileList has no call to make a
  hidden entry visible again, and inserting the same URL again created a second entry (tested 2026-11-10). Rejected.
- **Sidebar: `sfltool`.** It can only `clear`/`resetlist` a whole list, not remove one entry (checked 2026-11-10); a
  reset would also drop the Finder's own entries. Rejected.
- **Sidebar: `launchctl kickstart -k` instead of `killall`.** Same effect (the daemon restarts and reads the file),
  needs the service label. No gain. Rejected.
- **Sidebar: hide only (1.2.2 plus the observer).** The list grows by one entry per mount and every ghost returns
  whenever Finder shows all external disks; Mountpoint then hides them again, visibly. Rejected.
- **Sidebar: the macFUSE `local` mount flag** – Finder would list the volumes itself without any list entry, but they
  would no longer be network drives (see Terms). Rejected.
- **Sidebar: purge only while the sidebar setting is on.** The leftovers are Mountpoint's own, from earlier versions and
  self-tests; a user who switched the setting off (possibly because of the ghosts) still has them. Rejected.
- **Sidebar: purge at every eject instead of hiding.** The purge needs a daemon restart; once per launch is enough, and
  hiding covers ejects within a session. Rejected.
- **DMG: `create-dmg` or `dmgbuild`.** A new build dependency for about 30 lines of shell + AppleScript. Rejected.
- **Folder limit: read MediaFiles Check's setting.** Couples two apps through a private defaults domain that Check may
  change; the user sets the value once. Rejected.
- **No early warning while Check rebalances** (no size alerts while Check runs, or only after two equal counts):
  silences or delays real warnings during capture. Rejected; the transient warning is accepted (§2).
- **Sidebar: purge only from 10 stale entries** – the daemon restart would become rare, but the list grows again and
  the behaviour is harder to test. Rejected: purge on every launch with at least one stale entry.
- **Sidebar: purge at quit instead of at launch** – one restart per session while the user is done, but the quit path is
  capped at 5 s (G3.6) and logout/shutdown may cut it short, leaving the work half done. Rejected.
- **Started from the image: a "Move to Applications" button that moves the app and relaunches it** – moving files is
  against the project's first rule and needs admin rights for some setups. Rejected. **Running without mounts and
  updates, with a banner** – an app that looks normal but does nothing confuses more than a clear quit. Rejected.
- **DMG: a committed `.DS_Store` layout template** instead of Finder AppleScript – no automation permission, but the
  binary layout file drifts between macOS versions and cannot be edited by hand. Rejected.
- **Scroller: a targeted lookup** (the scroll view the modifier is attached to) – SwiftUI exposes no reference to it on
  macOS 13; with two call sites the ancestor search plus a `shortcut:` note is enough. Rejected.

### Decisions (owner, development chat, 2026-11-10; no issue tracker is used)

- D1 The list must really be cleaned, not only hidden ("Wie können wir diese Liste cleanen?" – "How can we clean up this list?" → automatic cleanup).
- D2 Clean up also when the sidebar setting is off.
- D3 Accept the transient early warning while MediaFiles Check fills a folder.
- D4 Purge on every launch that finds a stale entry (not from a threshold).
- D5 Count only visible files, like MediaFiles Check ("files starting with a dot never count").
- D6 Started from the disk image or a temporary place: ask to move to Applications and mount nothing.
- D7 Purge on every supported macOS version, although it was tested only on macOS 15 (risk accepted, §5).
- D8 Accept the `killall sharedfilelistd` risk for other lists the daemon serves (§5).
- D9 This Decisions list is the record of the owner's decisions; no public issue is opened for them.

## 1. Settings window polish

- Window title is always "Mountpoint" (not the pane name), also after a language change.
- App menu of the settings app: "Hide Settings" / "Quit Settings" (de "Einstellungen ausblenden/beenden", fr, es).
  The "Window" menu is gone; ⌘W stays as a hidden menu item in the app menu.
- The first line of every pane sits at the same height (`Pane.firstLine`, a top offset per pane).
- Self-test list and the problem-report text field get a thin legacy scroller like MediaFiles Check: shown whenever
  the content overflows (hidden only when nothing overflows), never fading like the system's overlay bar (view modifier `.thinScroller(dark:)`). Self-test
  status circles are 12 pt.

### Guarantees

- G1.1 ⌘W closes the settings window in English, German, French and Spanish; no visible "Window" menu exists
  (`SettingsApp.swift` `buildMainMenu`: hidden item, `allowsKeyEquivalentWhenHidden`).
- G1.2 The window title never shows a pane name (`SettingsWindow.swift`:
  `canPropagateSelectedChildViewControllerTitle = false`).
- G1.3 Every new user-visible string exists in de, fr and es, and no "Window" key is left. Checked by hand on
  2026-11-10; `LocalizationTests` only guarantees that de, fr and es have the same keys and placeholders.
- G1.4 `ThinScrollerHook` changes the first `NSScrollView` it finds from its ancestors (searching each ancestor's
  subtree). It is therefore only used where the surrounding view holds exactly one scroll view: the self-test list and
  the report text field, each of which replaces the Support pane's content. It sets legacy style, a vertical scroller
  and autohide. (`shortcut:` comment on `thinScroller`.)

## 2. Adjustable MXF folder limit

Before: fixed 5000 entries per MXF folder, early warning above 4500, alert also at exactly 5000, so Mountpoint warned
right after every MediaFiles Check rebalance.

Now: `Store.sizeLimit` (UserDefaults `sizeLimit`, range `Store.limitRange` = 100…50000, default 5000), edited in
Settings → Avid Media Composer (`SizeLimitRow`: number field + the existing on/off switch "Warn about MXF folders …"
= `watchSize`, default off). The hint below says "Use the same limit as in MediaFiles Check" and that the first
warning comes above 90 % (all four languages).

What is scanned (unchanged). Scanned: every MXF folder below `/Volumes` on visible mounted volumes; the system volume
(Media Composer's local media root `/Users/Shared/AvidMediaComposer`); every workspace's source folder. Not scanned:
Mountpoint's own workspace volumes (their sources are scanned instead) and hidden (`nobrowse`) mounts.
When: on every guard refresh – the 60 s timer, a mount or unmount, and at once after a setting change. Adding files to
an MXF folder triggers no check by itself; it is seen at the next refresh (within a minute). A folder is recounted only
when its modification time changed or after 10 minutes. A count already running when a setting changes is followed by
one more check; results of a count that finishes after the warning was switched off are dropped.

Counting (D5): like MediaFiles Check (source: Check's `src/rebalance.rs`, `per_folder` = limit − 2 media files, and
its CLAUDE.md "Rebalancing", 2026-11-09 – the limit includes the two database files), `fileCount` – visible files including the two database files, without hidden
files (`.DS_Store`, `._*`) and without subfolders (Avid's "Creating"; symlinks count as files). It reads the names
(readdir); where the file system reports no entry type (macFUSE, some SMB servers) it needs one `lstat` per entry,
which only runs when the folder changed. A folder that cannot be read drops out like a missing one. The guard keeps the last count per folder in memory (not on disk) and reuses it while the folder is
unchanged; it always holds a `fileCount` result, so a changed limit never compares against a differently counted
number. 1.2.2 counted all entries.

`VolumeGuard.applySizes`, with E = `sizeLimit * 9 / 10` (`VolumeGuard.earlyLimit` overrides E, used by tests). One rule:
an acknowledgement stays valid only while the folder stays above the level it was acknowledged at (early level = E,
alert level = `sizeLimit`, both taken from the current limit), and a folder at
exactly `sizeLimit` counts as acknowledged at the early level. Consequences:
- **alert** when a folder holds more than `sizeLimit` files;
- **early warning** when it holds more than E and fewer than `sizeLimit` files;
- **exactly `sizeLimit`**: no alert, and the folder counts as early-acknowledged ("full on purpose"), so removing a
  file afterwards does not show the early warning;
- "OK" on an early warning silences that folder until it holds E files or fewer; "OK" on an alert silences it until it
  holds `sizeLimit` files or fewer. An early-acknowledged folder that grows over `sizeLimit` alerts;
- a folder that is missing or unreadable in one check (volume ejected, NAS offline) loses its acknowledgement, so it can warn again
  when it comes back (deliberate since 1.2.0: a new crossing must warn);
- an alert-acknowledged folder that drops from above `sizeLimit` straight into the early band (without passing exactly
  `sizeLimit`) shows the early warning – a new, lower threshold was crossed;
- acknowledgements are always judged against the current limit;
- a remainder folder between E and `sizeLimit` (for example after rebalancing 9800 files into 5000 + 4800) gets the
  early warning – that is the warning's purpose;
- while Check fills a new folder, a check may see it between E and `sizeLimit`; the early warning then closes by itself
  when the folder reaches the limit (accepted, see Alternatives; Media Composer is closed during rebalancing).

Alert texts show the current limit. The settings app writes the value; Mountpoint picks it up via the "settings" notice
(`reloadSettings`), sets `VolumeGuard.shared.sizeLimit` and checks at once. That check closes every size alert whose
folder no longer qualifies (for example after raising the limit). An alert that stays open keeps its text, and its OK
acknowledges the kind it was shown as (an early warning OK after the limit was lowered below the folder's count is
followed by the alert at the next check).

### Guarantees

- G2.1 A stored value outside 100…50000 or missing reads as 5000 (`Store.validLimit`), in both processes and in
  `VolumeGuard.shared`'s initial value (code reading; M2 step 5 covers the field).
- G2.2 Invalid input in the field (empty, non-numeric, out of range) is never stored (red frame while typing); the
  field shows the stored value again when it loses focus, on Return, or when the pane disappears.
- G2.3 Exactly `sizeLimit` files never shows an alert or early warning, and one file less afterwards neither; hidden
  files and subfolders never count (`SizeTests.exactLimitNeverWarns`, `countsEntriesBothWays`). Limits: the transient warning
  during a fill and the lost acknowledgement after a missing check (above).
- G2.4 Acknowledgements behave as listed above: `exactLimitNeverWarns`, `warnsOncePerCrossing`,
  `warnsEarlyThenAgainAtLimit`, `acknowledgementCases` (drop into the early band, missing folder, current limit) and
  `switchedOffDuringCount`. Alerts closing on a limit raise: code reading + M2 step 2.
- G2.5 Changing the limit in the settings app reaches Mountpoint's running guard without a restart; the passive store
  never touches `VolumeGuard.shared`.
- G2.6 Only Mountpoint's real guard follows the setting; self-test guards use the default 5000 (code reading:
  `VolumeGuard.shared` takes the stored value in its initializer, `Store.sizeLimit` sets it only under
  `isShared, !passive`; other guards keep the default).

## 3. Finder sidebar: really removing old entries

Facts (tested on macOS 15, 2026-11-10): the sidebar's "Locations" list is LSSharedFileList `FavoriteVolumes`, stored in
`~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteVolumes.sfl3`
(NSKeyedArchiver, root dictionary with `items` and `properties`). `LSSharedFileListItemRemove` only sets an entry's
`visibility` to 1; hidden entries are not returned by `LSSharedFileListCopySnapshot`. Every mount by Mountpoint adds a
new entry; ticking "External disks" sets all entries visible, so every volume Mountpoint ever mounted showed up again
as an unresolvable "ghost". There is no API to delete an entry. Rewriting the file and restarting `sharedfilelistd`
(`killall`; launchd restarts it on demand) makes the daemon read the new file; it did not write its old state back
when killed.

New in 1.3.0: the observer, `sidebarNames`, hiding by name, the purge. Since 1.0.1/1.2.2: adding and removing the
entries Mountpoint owns (`sidebarOwned`), hiding at quit.

Name sets:
- `sidebarNames` (UserDefaults): every volume name Mountpoint ever added to the list; only grows.
- `sidebarOwned` (UserDefaults): volume paths of the entries Mountpoint added and has not removed yet. `apply` copies
  their names into `sidebarNames` before it drops a path, so names owned under 1.0.1–1.2.2 are kept too.
- `probeName` = `MPSelftest-Side`, the volume name the self-test uses for its sidebar check.
- `purgeNames` = `sidebarNames` ∪ names of `sidebarOwned` ∪ all workspace names ∪ `probeName` – the one name set both
  layers use.
- Known limit: ghosts of workspaces that were removed or renamed under 1.2.x, before `sidebarNames` existed, match no
  name and stay (hidden only by the Finder's own rules). On the owner's Mac they were cleaned by hand on 2026-11-10.

Two layers in `Sidebar.swift`:
1. **Hide (live, within a session):** `Sidebar.observe()` registers an `LSSharedFileListAddObserver`; changes are
   debounced 1 s and `apply` hides every unresolvable entry whose display name is in `purgeNames`, minus the names of
   the wanted volumes (mounted by Mountpoint, with the sidebar setting on). Hidden entries are not in the
   snapshot, so hiding triggers at most one more, empty `apply`. Hiding checks the name only: a Finder-owned entry of
   an ejected drive with a workspace's name is hidden too (§5).
2. **Delete (once per launch):** on the first `sync`, `purge` reads the sfl3 file and drops every item for which
   `isStale` is true. If at least one item is dropped, it re-reads the file and compares the bytes; if they changed
   meanwhile it stops. Then it writes the original bytes to
   `~/Library/Application Support/Mountpoint/FavoriteVolumes-backup.first.sfl3` (only if that file does not exist yet)
   and to `FavoriteVolumes-backup.sfl3`, writes the new file (atomically, only if the backups succeeded), runs
   `/usr/bin/killall sharedfilelistd` and logs the result. Decoding uses `decodeTopLevelObject` with
   `decodingFailurePolicy = .setErrorAndReturn`: decoding failures, including unknown classes, are errors. The
   observer is attached only after the purge. The purge runs whether the sidebar setting is on or off (Alternatives).
   Because quitting only hides, the next launch after a session with a mount purges again (one entry per ejected
   volume), so the purge and the daemon restart happen on most launches (D4).

`isStale(item)` is true only when **all** of these hold:
- the item has no `Name` key (the Finder's own entries have one);
- its `CustomItemProperties` dictionary has no `com.apple.LSSharedFileList.DateLastSeen` key (the Finder's own entries
  have one; Mountpoint's do not);
- it has a `Bookmark` whose path is `/Volumes/<name>`, directly under `/Volumes`;
- `<name>` is in `purgeNames`;
- nothing exists at that path now.

Restore (done by the user with the maintainer's help): quit Mountpoint, copy `FavoriteVolumes-backup.sfl3` (the list
before the latest purge, original bytes) or `FavoriteVolumes-backup.first.sfl3` (before Mountpoint's very first purge;
newer entries are then lost) to the sfl3 path, then `killall sharedfilelistd`. An entry that was deleted wrongly still
matches `isStale` and would be deleted again at the next launch unless its volume is mounted – report it, so the rule
can be narrowed.

### Guarantees

- G3.1 An entry made by the Finder itself (has `Name` or `DateLastSeen`) is never deleted.
- G3.2 An entry for a path that currently exists (mounted volume, the user's own drive with the same name) is never
  deleted.
- G3.3 If the file is missing, cannot be decoded (including unknown classes), has no `items` array, or changed between
  read and write, nothing is written (neither backups nor list), no process is killed and a log line says so; hiding
  (layer 1) still works.
- G3.4 The backups are written before the list file; if a backup write fails, the list file is not written (a `.first`
  backup written just before may then remain). The first backup is never overwritten (tested with a second, different
  list).
- G3.5 Nothing is written and `sharedfilelistd` is not restarted when no item is dropped; a failed restart is logged
  (`killall` also fails when the daemon is not running – then it reads the new file at its next start anyway).
- G3.6 Purge, apply and the self-test's sidebar probe run on the sidebar queue, never on the main thread (the probe
  is awaited, so the self-test offered on the consent panel at the first launch of a version does not block Mountpoint
  while the purge runs). Exception: at quit, `removeAll` waits for the queue at most 5 s and then quits anyway
  (leftovers are deleted by the next launch's purge).
- G3.7 Tests and the passive settings app never call `sync` (`Store.syncSidebar` checks `isShared, !passive`).
- G3.8 After a purge, `properties` and every kept item decode to values equal to the original's (a re-encode, not a
  byte-identical copy; file permissions and extended attributes of the list file are not preserved).
- Tests: G3.3 (missing, undecodable, no `items`; unknown class in `purgeSurvivesUnknownClass`), G3.4 (backup in a missing folder → list unchanged; first backup kept),
  G3.5 (nothing stale → no write; restart failing → the purge still reports the dropped entries) and G3.8 (whole kept item and `properties` equal)
  in `SidebarTests.purgeOnFixture`; G3.1/G3.2 in `SidebarTests.staleOnlyOwnEjectedEntries`. The "changed meanwhile"
  branch is not tested (needs a concurrent writer). Log lines are checked by code reading (`Log.write` writes nothing in
  tests).

## 4. Disk image download

`scripts/build-app.sh` additionally builds `dist/Mountpoint-<release>.dmg` (`<release>` = the script's `RELEASE`, the
same value as in `Mountpoint-<release>.zip`). Steps: staging folder with a copy of the app and a symlink
`Applications → /Applications`, background picture `.background/background.tiff` (drawn by
`scripts/make-dmg-background.swift`), read-write image mounted at `/Volumes/Mountpoint`, Finder AppleScript sets the
window layout (stored by Finder in the image's `.DS_Store`), detached, converted to a compressed read-only image.

The zip and its `.sig` (Ed25519 signature of the zip; installed apps install only a zip whose signature matches the key
built into them) are built as before; the updater (`Updater.swift`) takes the first asset named `Mountpoint-*.zip`,
uses it only if that zip's `.sig` exists (or an empty `Mountpoint-<v>.manual` asset tells older apps to show "install by hand", used only if the update key is
ever lost), and ignores
other assets. README: install from the DMG.

Started from the image (D6, see Alternatives): at launch Mountpoint checks `runsFromTemporaryPlace()` – the app is on a read-only volume
(the mounted DMG) or in an "App Translocation" path (macOS runs a downloaded app from a random read-only copy until it is
moved). Then it shows "Move Mountpoint to the Applications folder" with a Quit button and exits before loading anything:
no mount, no sidebar change, no updater. Without this the updater could not replace the app and ejecting the image
would kill the mount helpers.

### Guarantees

- G4.1 The DMG is built from a copy of the app, so the Finder layout step never touches the signed `dist/` app. The old zip and `.sig` are deleted right before the new zip is
  created, so a run that fails later never leaves a new zip next to an old signature.
- G4.2 A failing layout script (Finder automation denied) does not fail the build; the DMG is still produced and a
  warning is printed (manual check M4 checks the layout of the uploaded DMG).
- G4.3 The build changes no global Finder setting: the script only sets per-window properties of the image's own
  window (icon view, toolbar, icon size and positions, background, bounds). Path bar and status bar are global in
  Finder and are not touched (an earlier draft hid them and changed the developer's settings, fixed 2026-11-10).
- G4.4 The build never ejects a volume it did not mount, and its Finder layout can only reach its own image: if any
  volume named "Mountpoint" (or "Mountpoint 1" …) is mounted, it stops with a message.
  The final detach retries with `-force` after 2 s.
- G4.5 Installed apps from 1.1.0 on find and install the next release from the zip as before: `Updater.swift` is
  unchanged since v1.2.2 (`git diff v1.2.2` empty), and its asset rule is the same in 1.1.0, 1.2.0 and 1.2.1
  (`git show`, checked 2026-11-10). Release step 2 repeats the diff.
- G4.6 Started from the disk image or a translocated copy, Mountpoint mounts nothing and changes nothing except two
  log lines and the app's language preference (written by the startup code before the check); it asks to be moved and quits (`SidebarTests.temporaryPlace` for the translocation path; the read-only
  branch was tested live on 2026-11-10 by starting the app from a mounted build DMG; M4 for the dialog).

## 5. Risks and mitigations

- **Undocumented file format (sidebar, D7).** Apple may change the sfl3 format, file name or daemon behaviour; tested
  only on macOS 15 (supported: 13+; current macOS 26 untested). Where the file has another name, the purge logs
  "list file missing or not readable" and does nothing – hiding works as in 1.2.2. On a macOS with the same file but
  different behaviour, the daemon could undo the purge (no effect) or reject the rewritten file (the Finder's own
  entries could be lost; restore from the backup). Mitigation: shape-checked decoding, the change check (G3.3), two
  backups (G3.4), only entries matching `isStale` (G3.1, G3.2). Accepted by the owner.
- **`killall sharedfilelistd`** on most launches (D8). The list is re-read right before writing, so a change already on
  disk is never overwritten. But a change the daemon holds only in memory when it is killed – in this list or in the
  other lists it serves (recent items, favourites) – may be lost; the window is the daemon's own write delay, not
  milliseconds. Other apps' LSSharedFileList references reconnect on
  demand (launchd service). Observed on one Mac: Finder sidebar redraws, nothing visibly lost. Accepted.
- **Hiding by name.** Layer 1 can hide a Finder-owned entry of an ejected drive that has a workspace's name. The Finder
  hides such entries itself while the drive is away and shows them when it is mounted again. Accepted.
- **DMG trust.** The DMG carries no signature of its own (only the zip has `.sig`); first-install trust is the same as
  for the zip before: GitHub over HTTPS plus "Open Anyway".
- **Name match.** A foreign entry without `Name` and `DateLastSeen`, directly under `/Volumes`, named like one of
  `purgeNames`, would be deleted. Checked 2026-11-10 in the pre-cleanup list: LucidLink 3's project entries also lack
  both keys but sit at `/Volumes/<filespace>/<project>` (never matched); a directly mounted LucidLink volume carried
  both keys. Other mount tools (Mountain Duck, ExpanDrive, …) were not checked; the evidence is one Mac. Accepted
  (`shortcut:` comment on `Sidebar.isStale` names the upgrade: check the bookmark's origin).
- **Limit differs from Check's.** The "exactly the limit" protection only works when both apps use the same value;
  the hint below the setting says "Use the same limit as in MediaFiles Check".
- **Settings app writes the list too.** A self-test started in the settings app adds and removes one test entry from a
  second process, not serialized with Mountpoint's purge. If both happen at the same moment, the probe check can fail
  or its entry can survive until the next purge. Rare (self-test at the moment of a launch purge). Accepted.
- **Counting on type-less file systems.** Where `readdir` reports no entry type, an entry deleted between `readdir` and
  `lstat` counts as a file for one check. Accepted.
- **DMG layout depends on Finder automation** on the release Mac (once per terminal app); M4 catches a missing layout.

## 6. Files, tests and release steps

- Code, modified, in `Sources/Mountpoint/`: `SettingsWindow.swift`, `SettingsApp.swift`, `Views.swift`,
  `Support.swift`, `Store.swift`, `Guard.swift`, `Sidebar.swift`, `SelfTest.swift` (awaits the probe), `Model.swift`
  (`runsFromTemporaryPlace`), `main.swift` (the move dialog).
- Strings, modified: `Resources/{de,fr,es}.lproj/Localizable.strings` (repository root).
- Docs, modified: `README.md` (install from the DMG), `CLAUDE.md`; new: this file.
- Build: `scripts/build-app.sh` (modified), `scripts/make-dmg-background.swift` (new).
- Tests: `Tests/MountpointTests/SizeTests.swift` (modified: `countsEntriesBothWays`, `exactLimitNeverWarns`, new
  `switchedOffDuringCount`, `acknowledgementCases`),
  `Tests/MountpointTests/SidebarTests.swift` (new: `staleOnlyOwnEjectedEntries`, `purgeOnFixture`,
  `purgeSurvivesUnknownClass`, `temporaryPlace`), `Tests/MountpointTests/LocalizationTests.swift` (unchanged). Command: `swift test` (stress and integration tests are skipped without their environment
  variables).
- Release steps:
  1. Set `VERSION=1.3.0` (the bundle's version, numbers only), `RELEASE=1.3.0` (tag and file names; differs only for
     test versions such as 1.3.1-beta.1) and `BUILD=27` (the bundle build number, +1 per release) in
     `scripts/build-app.sh`.
  2. Check `git diff --exit-code v1.2.2 -- Sources/Mountpoint/Updater.swift` (G4.5). Run `swift test`, the stress test (`MOUNTPOINT_STRESS=1 swift test --filter StressTests`) and
     `MOUNTPOINT_IT=1 swift test`, then `scripts/build-app.sh`. The build must print "upload all three", not
     "NOT SIGNED" (= the update key in this Mac's Keychain is missing or differs; installed apps would ignore the
     release).
  3. Run M3 first (it needs the first launch of 1.3.0 on a Mac that used 1.2.x), then M1 and M2, with the built
     `dist/Mountpoint.app` copied to /Applications.
  4. Commit, then create the GitHub **prerelease** `v1.3.0` with `Mountpoint-1.3.0.dmg`, `Mountpoint-1.3.0.zip` and
     `Mountpoint-1.3.0.zip.sig`.
  5. Run M4 and M5.
  6. Mark the release as latest (owner approval).

### Manual checks before release

- M1 Settings app: ⌘W closes; menu texts in de/fr/es; title stays "Mountpoint" when switching panes and languages;
  the first line does not jump when switching panes; with enough content (a finished self-test, a long report text)
  the self-test list and the report text field show the thin scroller; the protected-volume list keeps its normal one.
- M2 Limit (manual checks are referenced as M1–M5 above). Precondition: no other MXF folder with more than 90 files
  on connected drives, the system volume or workspace sources (they would alert too at limit 100). Test folder: a workspace's source folder `<source>/Avid MediaFiles/MXF/1` (create it). Switch on "Warn
  about MXF folders…", type 100 and press Return. After each change of the folder wait up to a minute (the next guard
  check); after a setting change the check runs at once.
  1. 90 files → nothing; 91 → early warning, click OK; 100 → nothing; 99 → nothing; 101 → alert, leave it open.
  2. In the settings app set 120 → the open alert closes at once (G2.5); set 100 again → alert again at once.
  3. Delete files down to exactly 100, add a `.DS_Store` and a folder "Creating" → the open alert closes and nothing
     new appears within a minute (hidden files and subfolders do not count).
  4. Set the limit to 5000, wait a minute, then set 100 again → nothing (the folder still holds exactly 100 visible
     files plus `.DS_Store`).
  5. Typing "abc", 99 or 50001 shows a red frame; Return or clicking elsewhere reverts it.
  (The settings app's own log line is tagged `[settings]`; Mountpoint does not log the reload.)
- M3 Sidebar. Preconditions: this Mac used 1.2.x with mounts and ejects; no `FavoriteVolumes-backup*.sfl3` in
  `~/Library/Application Support/Mountpoint/` yet (move them aside if a development build created them); "Show in
  Finder sidebar" on; a workspace without "Mount at app launch" (so its volume is not mounted, and therefore stale, at
  the next launch). First launch of 1.3.0 → log "sidebar: deleted N old entries from the list (A → B)" with
  N = A − B > 0, and `FavoriteVolumes-backup.first.sfl3` exists. Answer "Not now" on the consent panel (a self-test
  would add one more stale entry). Also: ghosts of workspaces removed under 1.2.x stay (known limit, §3). Then mount the workspace, quit Mountpoint, start it
  again → "sidebar: deleted 1 old entries from the list (…)". Quit and start once more without mounting anything → no
  "deleted" line. On a launch that purged, a workspace with "Mount at app launch" still appears under Locations. Tick
  "External disks" in Finder → no ghost of a current workspace.
- M4 DMG (prerelease): download the DMG in a browser, open it: window with the title "MOUNTPOINT", a brush arrow, the app and Applications.
  Double-click the app inside the image → macOS blocks it; System Settings → Privacy & Security → "Open Anyway" → the
  app shows "Move Mountpoint to the Applications folder", Quit, nothing mounted. Drag to Applications, open it (allow
  "Open Anyway" again if asked) → app starts normally.
- M5 Update (prerelease): in 1.2.2 switch on "Get test versions" → the in-app updater offers and installs 1.3.0 from
  the zip.

### Results of the manual checks (2026-11-10, owner's Mac, macOS 15.5; released as 1.3.3)

- M1 Settings app – passed (owner). Follow-ups shipped in 1.3.1–1.3.2: the settings app is called "Mountpoint" in the
  menu bar, Dock and ⌘-Tab; its app menu has no "Settings…" item and says "Close Settings".
- M2 Limit – passed (owner).
- M3 Sidebar – **failed**: every launch of 1.3.0–1.3.3 logs "sidebar: list file missing or not readable, not cleaned".
  Cause: macOS privacy protection – `~/Library/Application Support/com.apple.sharedfilelist/` can only be read by apps
  with Full Disk Access (confirmed with a minimal ad-hoc signed app: "Operation not permitted"). The development tests
  ran from a terminal that has Full Disk Access. Effect: the purge never runs, nothing is touched (G3.3 holds), hiding
  (layer 1) works; the self-test check "Finder sidebar cleanup" fails for the same reason. Open decision.
- M4 DMG – passed: start from a translocated copy showed the move dialog (log 21:28:47).
- M5 Update – passed: 1.2.2 → 1.3.0 via the updater (log 21:20–21:21); later updates 1.3.0 → 1.3.1 → 1.3.2 → 1.3.3
  also worked, the last one in 4 s (download 3.5 s – the earlier 46–57 s were slow GitHub downloads).
- Self-test: 25 checks, 0 failed on 1.3.0 and 1.3.1.

### Follow-up in 1.3.4: Full Disk Access (owner decision 2026-11-10, option a)

- On the first `sync` Mountpoint runs `Sidebar.inspect` (read-only) and records the result in the shared defaults
  (`sidebarList` = "ok: …" or the reason, `sidebarAccess` = false when macOS denied reading). The purge runs only when the
  inspection passed – so it also never runs when no entry carries the Finder's markers.
- Settings → General: only when `sidebarAccess` is false, the sidebar hint says that ejected volumes come back unless
  Mountpoint has Full Disk Access, and a row "Remove old entries for good" with "Allow…" opens System Settings →
  Privacy & Security → Full Disk Access (the user adds Mountpoint with +; it takes effect at Mountpoint's next start).
- The self-test check "Finder sidebar cleanup" shows Mountpoint's recorded result (the settings app has its own,
  different permissions): skipped without Full Disk Access or before Mountpoint checked, failed for any other reason.
- Test: `SidebarTests.inspectList` (unreadable file → `noAccess`).
