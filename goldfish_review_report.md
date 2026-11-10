# Goldfish Annotated Review Report

**Target:** `docs/release-1.3.0-changes.md` (full file) · **Round 1 of 5** · Reviewers: `codebase_details`, `design_critic`, `implementation_readiness`, `zoom_out`, `comprehension` (all five completed)

Round 1 is **not clean**: 4 distinct Blockers, 12 distinct Majors after deduplication. Several reviewers found the same issues independently (marked ×n). The 1.2.0 report is in git history (commit 889b54d).

## Prioritized Findings & AI Suggestions

### [Issue 1] [`codebase_details`, `implementation_readiness`] – Blocker (code bug)
*   **Affected Scope:** G2.4 (lines 64–65), goal line 14, M2; `Guard.swift` `applySizes`.
*   **Discrepancy:** `over` leaves out `n == sizeLimit`, so the acknowledgement of an early-warned folder is dropped at exactly the limit. A folder that MediaFiles Check filled to exactly 5000 shows "soon full" again as soon as one file is removed. In 1.2.x, exactly 5000 kept the acknowledgement.
*   ***AI Suggestion:*** PROPOSE FIX (code)
*   ***Justification:*** Verified in the code. A folder at exactly the limit is "full on purpose" (rebalanced).
*   ***Proposed Edit:*** At exactly `sizeLimit`, no alert, but the folder counts as early-acknowledged (`"~"+folder` stays/gets valid). Shrinking to 4999 does not warn; dropping below 90 % resets. Test: 91 → OK → 100 → 99 → no alert; 100 (fresh) → 99 → no alert; 89 → 91 → early warning. Rewrite G2.4/M2 accordingly. A remainder folder between 90 % and the limit after a rebalance still gets the early warning (intended: that is what the early warning is for).

### [Issue 2] [`codebase_details`, `design_critic`, `implementation_readiness`] – Blocker
*   **Affected Scope:** G3.6 (line 101); `Sidebar.removeAll()` (`queue.sync` from main at quit).
*   **Discrepancy:** At quit, the main thread waits for the sidebar queue (a running purge, or `apply` resolving a hanging NAS entry), so "never on the main thread" is false at quit.
*   ***AI Suggestion:*** PROPOSE FIX (code + doc)
*   ***Justification:*** The quit-time sync is from 1.0.1 (it must remove entries before the process ends); the launch purge adds to the queue in front of it.
*   ***Proposed Edit:*** `removeAll` waits at most 5 s (`queue.async` + semaphore with timeout), then quits anyway (entries are cleaned at the next launch by the purge). G3.6 states the quit exception and the bound.

### [Issue 3] [`codebase_details`, `design_critic`, `implementation_readiness`] – Blocker
*   **Affected Scope:** G4.1 (line 119); `build-app.sh` order.
*   **Discrepancy:** The old `.sig` is removed only after the DMG step. If the DMG step fails, `dist/` has a new zip next to an old `.sig`.
*   ***AI Suggestion:*** PROPOSE FIX (script)
*   ***Proposed Edit:*** Remove the old `.sig` together with the old zip, before anything is built. A failed run then leaves no signature (the updater ignores releases without one).

### [Issue 4] [`design_critic`, `comprehension`] – Blocker
*   **Affected Scope:** whole document – no *Alternatives considered*.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** Add the section. (a) Re-use or unhide the hidden entry instead of inserting a new one: the API has no unhide; inserting the same URL again created a new entry (tested 2026-11-10). (b) Hide only: rejected by the owner (the list keeps growing, every ghost returns with "External disks"). (c) The macFUSE `local` flag: makes Finder list the volume itself, but breaks the network-drive rule that Media Composer needs (CLAUDE.md). (d) Purge only with the sidebar setting on: see Issue 8. DMG: `create-dmg`/`dmgbuild` would be a new dependency for about 30 lines of shell.

### [Issue 5] [`zoom_out`, `design_critic`, `implementation_readiness`, `codebase_details`] – Major
*   **Affected Scope:** line 33, G1.4; `ThinScrollerHook`.
*   **Discrepancy:** Not an "overlay" scroller (legacy style, `isCompatibleWithOverlayScrollers = false`). The hook takes the first scroll view in the first ancestor that contains one, not the "nearest enclosing" one.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Justification:*** It is used in two places only, each the single scroll view in its sheet (self-test list, report text). Verified visually on 2026-11-10.
*   ***Proposed Edit:*** Line 33 says "thin always-legacy scroller". G1.4 states the real rule (the first `NSScrollView` found from the hook's ancestors, so only use it where the view holds one scroll view; both call sites do). M1 adds a check of both sheets.

### [Issue 6] [`design_critic`, `implementation_readiness`, `codebase_details`, `zoom_out`, `comprehension`] – Major
*   **Affected Scope:** G3.3–G3.5, G3.8, §6 tests; `Sidebar.purge` is private and hard-wired to the real file.
*   ***AI Suggestion:*** PROPOSE FIX (code + test)
*   ***Proposed Edit:*** `purge` takes the list URL, backup URL and a restart closure (with defaults). Test with a temporary sfl3 fixture:
    *   a missing or undecodable file → nothing written, no restart;
    *   nothing stale → no write, no restart;
    *   a stale item → backup equals the old bytes, the list lacks only that item, `properties` and the other items decode equal, restart called once.
    G3.8 is reworded as "decodes to equal values" (it is a re-encode, not byte-identical).

### [Issue 7] [`design_critic`, `zoom_out`, `implementation_readiness`, `codebase_details`, `comprehension`] – Major
*   **Affected Scope:** lines 84–86, G3.4 – one-slot backup, no restore steps.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** State that the backup holds the list before the latest purge (each purge removes only Mountpoint's own entries), and give the restore steps: copy the backup to the sfl3 path, then `killall sharedfilelistd`.

### [Issue 8] [`design_critic`, `implementation_readiness`, `codebase_details`] – Major
*   **Affected Scope:** §3 – the purge also runs when the sidebar setting is off.
*   ***AI Suggestion:*** PROPOSE FIX (doc: deliberate)
*   ***Justification:*** The entries are Mountpoint's own leftovers from earlier versions and self-tests. A user who switched the sidebar off (possibly because of the ghosts) still has them, and the purge never touches others' entries.
*   ***Proposed Edit:*** Document it as deliberate. **Owner decision wanted** (alternative: purge only with the setting on).

### [Issue 9] [`design_critic`, `implementation_readiness`, `comprehension`] – Major
*   **Affected Scope:** line 72, §5 – tested only on macOS 15, while the app supports 13+.
*   ***AI Suggestion:*** PROPOSE FIX (code + doc)
*   ***Proposed Edit:*** Log "sidebar: list file not found, not cleaned" when the file is missing. Add a risk entry: on systems where the file has another name, the purge does nothing and hiding stays (as in 1.2.2).

### [Issue 10] [`codebase_details`] – Major
*   **Affected Scope:** G4.3; `set statusbar visible … false`.
*   **Discrepancy:** The status bar is a global Finder preference. `defaults read com.apple.finder ShowStatusBar` is now `0` on this Mac, probably set by our build runs (the path bar had the same problem and was fixed).
*   ***AI Suggestion:*** PROPOSE FIX (script) + **owner question**
*   ***Proposed Edit:*** Drop the status-bar line from the AppleScript (the toolbar setting is per window and is kept). **Was the Finder status bar on before today? If so, I switch it back on (`ShowStatusBar` = 1).**

### [Issue 11] [`zoom_out`, `design_critic`, `implementation_readiness`, `codebase_details`] – Major
*   **Affected Scope:** G4.4; fixed `/Volumes/Mountpoint` mount point, blind `detach || true`, Finder `disk "Mountpoint"` by name.
*   ***AI Suggestion:*** PROPOSE FIX (script)
*   ***Proposed Edit:*** If anything is mounted at `/Volumes/Mountpoint`, stop with "eject the volume Mountpoint first" (never eject a foreign volume). The final detach retries with `-force`. With the path free, Finder's `disk "Mountpoint"` is ours.

### [Issue 12] [`codebase_details`, `implementation_readiness`] – Major
*   **Affected Scope:** G1.3.
*   **Discrepancy:** `LocalizationTests` compares de/fr/es only with each other.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** Say that the new keys were checked by hand in all three files (the reviewer confirmed this) and that the test guards consistency only.

### [Issue 13] [`implementation_readiness`, `zoom_out`, `codebase_details`] – Major
*   **Affected Scope:** version and release steps (lines 3–6, M5).
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** Release steps: `VERSION=1.3.0`, `RELEASE=1.3.0`, `BUILD=27` in `build-app.sh` → build → tests → upload dmg + zip + `.sig`.

### [Issue 14] [`implementation_readiness`] – Major
*   **Affected Scope:** manual checks M2/M3 incomplete.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** M2: switch on the folder warning, wait about a minute per step, invalid input ("abc", 99, 50001) is red and reverted, a change in the settings app reaches the running app. M3: on the first launch N counts all old leftovers; on later launches 1 per ejected workspace. M1: first lines do not jump when switching panes, and the scrollers in both sheets.

### [Issue 15] [`design_critic`, `codebase_details`] – Major
*   **Affected Scope:** §5 race "milliseconds".
*   ***AI Suggestion:*** PROPOSE FIX (doc + one line of code)
*   ***Justification:*** Tested 2026-11-10: the daemon did not write its old state back on `killall` (the cleaned list stayed).
*   ***Proposed Edit:*** Describe the real window (read → write, plus a `stat` per candidate; launch at login is the busiest moment) and the observed SIGTERM behaviour. Log a failed `killall` (exit status) instead of claiming success.

### [Issue 16] [`comprehension`] – Major (grouped)
*   **Affected Scope:** lines 14, 21, 54–59, 66–68, 82, 88.
*   **Discrepancy:** Undefined terms: settings app / passive store / "settings" notice, self-test guards, owned names, `probeName`, the 1.2.0 document reference, MediaFiles Check and rebalancing. Also "follows the same limit" reads as if Mountpoint reads Check's setting. The `isStale` arrow notation is ambiguous.
*   ***AI Suggestion:*** PROPOSE FIX (doc)
*   ***Proposed Edit:*** Short "Terms" section with link `docs/release-1.2.0-changes.md`. The goal becomes "the user can set the same limit as in MediaFiles Check (set by hand, not read from Check)". `isStale` as a list of conditions that must all hold. The two name sets (hide vs. purge) listed separately.

### Nits
*   Open alert keeps the old text when the limit changes; acknowledged folders can re-alert after a limit change (`design_critic`, `codebase_details`) – PROPOSE FIX (doc): state it; changing the limit is rare.
*   Observer loop: hidden entries are not in the snapshot, so no loop (`design_critic`) – PROPOSE FIX (doc): one line, observed 2026-11-10.
*   `SidebarTests` depends on `/Volumes` (`design_critic`) – CONTEST: "Macintosh HD" keeps its `/Volumes/…` path in the bookmark (checked 2026-11-10); the new fixture test (Issue 6) uses the same entry.
*   Window bounds include the title bar, so the bottom of the picture is cut off (`codebase_details`) – DECLINE: the bottom of the picture is empty.
*   `<release>` vs `<version>`, "four languages", the DMG detail level, the font risk, "77 tests" command, updater asset wording, `earlyLimit` hook, `sizeLimit` key in three places, `.atomic` drops xattrs – PROPOSE FIX (doc wording) where cheap; DECLINE the `sizeLimit` key constant (three reads, one meaning).
*   Layout failure lets a DMG without layout be uploaded (`comprehension`) – PROPOSE FIX: M4 checks the window layout.

## Resolution round 1 (user: "auto accept"; status bar was on → restored; purge also with the setting off)

Status: resolved. All PROPOSE FIX items applied:
*   **Code:**
    *   exactly-full folder counts as early-acknowledged (`Guard.applySizes`, test extended);
    *   `removeAll` waits at most 5 s;
    *   `purge` is testable and logs a missing file and a failed restart (`SidebarTests.purgeOnFixture`).
*   **Script:**
    *   old `.sig` is deleted with the zip;
    *   the build stops if `/Volumes/Mountpoint` is in use;
    *   the status-bar line is removed;
    *   the final detach retries with `-force`.
*   **Doc:** Terms, Alternatives, all wording and checks.

78 tests green, full build green, Finder `ShowStatusBar`/`ShowPathbar` = 1. DECLINE/CONTEST items not applied.

---

# Round 2 of 5

Reviewers: all five completed. **Not clean:** 3 Blockers (all claim accuracy: test coverage, G4.1 wording, alert behaviour on a limit change), plus Majors. One real code defect was found and is **already fixed ahead of the gate** (Issue R2-1; revert on request).

## Findings

### [R2-1] [`codebase_details`] – Major (code) – FIXED AHEAD
*   **Scope:** goal "exactly the limit causes no warning"; `Guard.entryCount`.
*   **Discrepancy:** Mountpoint counted every directory entry (`.DS_Store`, Avid's "Creating" folder). MediaFiles Check counts visible files including the two database files (`src/rebalance.rs` `per_folder` = limit − 2; Check CLAUDE.md "Rebalancing"). A folder Check filled to exactly 5000 plus a `.DS_Store` showed the full alert.
*   ***Applied:*** new `fileCount` (visible non-directory entries); used only when the quick count is above the early threshold (reads all names, so only near the limit). Tests: `countsEntriesBothWays` (`fileCount`), `exactLimitNeverWarns` (`.DS_Store` + `Creating` at exactly the limit → no alert).

### [R2-2] [`codebase_details`] – Major – **ESCALATE (owner decision)**
*   **Scope:** goal + G2.3. While Check fills a new folder (renames, about a minute on a NAS), a guard check can see it between 90 % and the limit and show an early warning that closes again when the folder reaches the limit.
*   **Options:**
    *   (a) Accept and document it. Rebalancing needs Media Composer closed, and the warning disappears by itself.
    *   (b) No size alerts while MediaFiles Check is running. One check of the running apps; it also silences real warnings while Check is merely open.
    *   (c) A new folder that started below 90 % warns only after two checks in a row with the same count. This delays warnings during capture too.
*   **Recommendation:** (a).

### [R2-3] [`codebase_details`, `design_critic`, `implementation_readiness`] – Blocker – PROPOSE FIX (test)
*   **Scope:** the test claim for G3.3–G3.5 and G3.8.
*   ***Proposed Edit:*** extend `purgeOnFixture`:
    *   a root without `items` → nothing written;
    *   the backup path in a missing folder → list unchanged, no restart;
    *   `restart` returning false → still returns the count;
    *   kept items compared as whole dictionaries (`NSDictionary` equality).

### [R2-4] [`codebase_details`, `design_critic`, `implementation_readiness`] – Blocker – PROPOSE FIX (doc)
*   **Scope:** G4.1. The old zip and `.sig` are deleted right before the zip is built, not "before anything is built". Reword.

### [R2-5] [`codebase_details`, `design_critic`] – Blocker – PROPOSE FIX (doc)
*   **Scope:** §2, "does not touch alerts on screen". Changing the limit triggers an immediate check, which closes alerts that no longer qualify. An alert that stays open keeps its text, and its OK acknowledges the kind it was shown as. Describe this.

### [R2-6] [`codebase_details`] – Major – PROPOSE FIX (doc, accepted)
*   **Scope:** G2.4. Acknowledgements are forgotten when a folder is missing for one check (NAS offline, volume ejected). This is deliberate since 1.2.0 ("drive gone → forget, so a new crossing warns"). Document it as accepted.

### [R2-7] [`design_critic`, `zoom_out`] – Major – PROPOSE FIX (code + doc)
*   **Scope:** single backup, overwritten by every purge (in practice by nearly every launch after a session with a mount).
*   ***Proposed Edit:*** keep two backups:
    *   `FavoriteVolumes-backup-first.sfl3`, written once: the list before Mountpoint ever purged;
    *   `FavoriteVolumes-backup.sfl3`, the latest.
    Document this together with the real frequency (nearly every launch after a session with a mount, because quitting only hides).

### [R2-8] [`design_critic`] – Major – PROPOSE FIX (code)
*   **Scope:** race window between reading and writing the list.
*   ***Proposed Edit:*** re-read the file right before writing and abort (log) if it changed since the first read.

### [R2-9] [`codebase_details`, `design_critic`] – Major – PROPOSE FIX (doc + code comment)
*   **Scope:** LucidLink / name match.
*   **Checked 2026-11-10 in the pre-cleanup copy of the list:**
    *   LucidLink 3's project entries have no `Name` and no `DateLastSeen` either, but sit at `/Volumes/<filespace>/<project>`, so `isStale` (direct child of `/Volumes` only) never matches them;
    *   a directly mounted LucidLink volume (`LUD_M_Lucidlink`) carried `Name` + `DateLastSeen`.
*   ***Proposed Edit:*** state this in §5 and put a `shortcut:` comment on `isStale`.

### [R2-10] [`zoom_out`] – Major – PROPOSE FIX (doc)
*   **Scope:** the project rule "never delete, move or overwrite files" (CLAUDE.md).
*   ***Proposed Edit:*** state the exception: the rule protects user and media data; the owner explicitly asked for the cleanup (2026-11-10). Scope: only Mountpoint's own list entries, with backups.

### [R2-11] [`design_critic`, `comprehension`] – Major – PROPOSE FIX (doc)
*   **Scope:** Alternatives.
*   ***Proposed Edit:***
    *   "Rejected by the owner" → "decided by the project owner in the development chat, 2026-11-10 (no issue)", plus the technical reason;
    *   add `sfltool` (only `clear`/`resetlist` of whole lists, no single item; checked) and `launchctl kickstart -k` (same effect as `killall`);
    *   explain the network-drive behaviour (Media Composer Enterprise creates "<computer>.1" folders on network drives).

### [R2-12] [`implementation_readiness`, `codebase_details`, `design_critic`] – Major – PROPOSE FIX (doc)
*   **Scope:** manual checks.
*   ***Proposed Edit:***
    *   M2: G2.5 is checked by behaviour (lower the limit below a folder's count with Mountpoint running → alert within a minute); the settings app's log line is tagged `[settings]`.
    *   M3: needs "Show in Finder sidebar" on and a workspace without "Mount at app launch"; count the leftovers before the first launch (scratch script or `plutil`); on a clean list no log line is expected.
    *   M4/M5 order: publish as a prerelease, switch on "Get test versions" in 1.2.2, run M4/M5, then mark as latest.
    *   Release steps: `swift test` before the build; check that the build prints "upload all three" and not "NOT SIGNED".

### [R2-13] [`codebase_details`] – Major – PROPOSE FIX (doc)
*   **Scope:** G3.6. The self-test sidebar probe also waits for the queue (`queue.sync`, since 1.1). In 1.2 the self-test runs in the settings app, where no purge runs; only the in-process fallback shares the queue. Add this as a second exception.

### [R2-14] [`comprehension`] – Major (grouped) – PROPOSE FIX (doc)
*   **Scope:** define the following:
    *   who adds sidebar entries (Mountpoint, on mount, setting "Show in Finder sidebar", default on);
    *   `sync` (called on every refresh) and `removeAll` (quit hides all owned entries);
    *   MXF folder (`<volume>/Avid MediaFiles/MXF/<n>`, which volumes are scanned, at least once a minute);
    *   Media Composer, `Store`, `settingsMode`, `.sig` (Ed25519 signature checked by the updater), `BUILD` (bundle build number).

### Nits (PROPOSE FIX unless noted)
*   `killall` exits with 1 when the daemon is not running: change the log text to a neutral one, including the exit code.
*   One name set: `apply` reuses `purgeNames` (∪ owned names, minus wanted).
*   G1.4: "replaces the Support pane's content", not "sheet"; `shortcut:` comment on `thinScroller`. The self-test is in the "Support" pane.
*   The updater wording matches `Updater.swift`. G2.6: self-test guards use the default 5000.
*   The settings hint keeps "5000" on purpose (the general recommendation): state it. §6: paths, README.
*   "Hide covers ejects within a session; purge removes them at the next launch" – one line.
*   "wanted" defined as "currently mounted by Mountpoint"; "(rare; accepted)" made concrete.
*   DECLINE:
    *   delay after launch at login (the purge itself is short);
    *   `osascript` hanging on the permission prompt (release Mac, interactive);
    *   a Finder disk named "Mountpoint" at another path;
    *   `bigKnown` migration (the format is unchanged since 1.2.0);
    *   local-mode workspaces (no change to them).

## Resolution round 2 (user: "auto accept", R2-2 = option a)

Status: resolved. Applied:
*   **Code:**
    *   `fileCount` near the limit (R2-1);
    *   two backups + change check before writing + neutral restart log;
    *   `apply` reuses `purgeNames`;
    *   `shortcut:` comments on `isStale` and `thinScroller`.
*   **Tests:** `purgeOnFixture` covers no `items`, unwritable backup, failed restart, first backup kept, whole-item equality.
*   **Doc:** Terms, exception to the project rule, alternatives (`sfltool`, `kickstart`, purge per eject, rebalance-time warning), §2 behaviour, G3.3–G3.6 and G4.1 wording, risks, release steps, M2–M5.

78 tests green.

---

# Round 3 of 5

Reviewers: all five completed. **Not clean:** 2 code Blockers (found by `codebase_details`, `implementation_readiness`, `design_critic` independently), 3 code Majors, 2 owner decisions, doc Majors.

## Code findings

### [R3-1] [`codebase_details`, `implementation_readiness`, `design_critic`] – Blocker – PROPOSE FIX
*   **Scope:** G2.3, goal; `Guard.checkSizes` cache.
*   **Failure:** the size cache keeps a quick count (with `.DS_Store`) taken under the old limit. A folder Check filled to exactly 3000 with Mountpoint still at 5000 is cached as 3001; setting 3000 then alerts "3001 files" for up to 10 minutes. This is the main "match Check's limit" flow.
*   ***Proposed Edit:*** clear the size cache when `sizeLimit`/`earlyLimit` change (on `sizeIO`). Test: count at limit 5000 with `.DS_Store`, set 20 without touching the folder → no alert.

### [R3-2] [`codebase_details`] – Blocker – PROPOSE FIX
*   **Scope:** G3.3, §5; `Sidebar.purge`.
*   **Failure:** `decodeObject` with the default failure policy raises an Objective-C exception on a valid archive with an unknown class (for example a future sfl3 format). Swift cannot catch it, so the app crashes on every launch, since the purge runs regardless of the setting.
*   ***Proposed Edit:*** `decodeTopLevelObject(forKey:)` (throws) + `decodingFailurePolicy = .setErrorAndReturn`. Test with a fixture archive that names an unknown class.

### [R3-3] [`codebase_details`] – Major – PROPOSE FIX
*   **Scope:** G3.6.
*   **Failure:** the consent panel's "Run self-test" runs in Mountpoint's own process, on the first launch of a new version – exactly when the big purge runs. `Sidebar.probe` uses `queue.sync` on the main thread and blocks Mountpoint while the purge and `apply` run (and on a hanging NAS).
*   ***Proposed Edit:*** make `probe` async (waits on the queue without blocking the main thread). G3.6 then has only the quit exception.

### [R3-4] [`zoom_out`, `comprehension`, `implementation_readiness`, `design_critic`] – Major – PROPOSE FIX
*   **Scope:** Goal 3, name sets.
*   **Failure:** paths owned under 1.0.1–1.2.2 whose workspace was removed are never purged (not in `purgeNames`), and are dropped from `sidebarOwned` by the first `apply`. They stay ghosts forever.
*   ***Proposed Edit:*** `purgeNames` also includes the names of `sidebarOwned` (the purge runs before `apply` on the same queue). One name set for both layers.

### [R3-5] [`implementation_readiness`] – Major – PROPOSE FIX
*   **Scope:** G3.3/G3.4.
*   **Failure:** the backups are written before the change check, so in the "changed meanwhile" branch the first backup can be a list that was never purged.
*   ***Proposed Edit:*** do the change check before writing the backups.

## Owner decisions (ESCALATE)

### [R3-6] [`design_critic`] – Major – **ESCALATE**
*   **Scope:** new risk from the DMG – the user starts Mountpoint directly from the mounted image instead of copying it to Applications. The same happens today with an app started from Downloads, which macOS runs from a read-only random path ("app translocation").
*   **Effects:** updates fail (the app cannot replace itself); the helper dies when the image is ejected; launch at login points to a path that disappears.
*   **Options:**
    *   (a) **Recommended:** at launch, if the app runs from a read-only volume or a translocated path, show a notice "Move Mountpoint to the Applications folder" (4 languages) and mount nothing until it is moved.
    *   (b) Only document it + M4.

### [R3-7] [`zoom_out`] – Major – **ESCALATE**
*   **Scope:** the purge and the daemon restart run on most launches (one ejected volume per session is enough).
*   **Options:**
    *   (a) every launch with at least one stale entry (current);
    *   (b) only from 10 stale entries – the restart becomes rare, the list grows by at most 10 hidden entries, and nothing becomes visible because hiding covers them.
*   **Recommendation:** (b).

## Doc findings – PROPOSE FIX
*   **Owner attribution (`comprehension`, `design_critic`):** drop "rejected by the owner" where a technical reason exists; keep the dated owner decisions in one "Decisions" list (the standard wants links, but there is no tracker; the doc is the record).
*   **§3 "what is new vs. 1.2.2"** (`comprehension`): hide-only and `sidebarOwned` exist since 1.0.1/1.2.2; new are the observer, `sidebarNames`, `probeName` hiding and the purge.
*   **M2 (`implementation_readiness`, `comprehension`):**
    *   exact path (a workspace source's `Avid MediaFiles/MXF/1`) and explicit order;
    *   G2.5 step with an open alert that closes at once when the limit is raised;
    *   "at once", not "within a minute";
    *   the R3-1 scenario as its own step.
*   **M3:** verify N as "backup item count − new item count" instead of counting by hand.
*   **Release steps:** M1–M3 before the prerelease; stress test (`MOUNTPOINT_STRESS=1 swift test --filter StressTests`) as in CLAUDE.md.
*   **G2.3 test claim:** recreate `.DS_Store` and `Creating` after `files(19)` in the test.
*   **Wording:**
    *   "strict decoding" → "shape-checked decoding";
    *   "minus wanted" (not "mounted");
    *   define "mirrors";
    *   the `.manual` marker;
    *   the settings hint "first warning at 90 %" → "above 90 %" (all four languages);
    *   "list file not found" → "list file not readable";
    *   the stale comment in `SettingsWindow.swift:6`.
*   **Alternatives:**
    *   a committed `.DS_Store` template for the DMG (rejected: drifts between macOS versions, harder to change);
    *   the scroller hook vs. a targeted lookup.
*   **§2:** state the one acknowledgement rule first.
*   **§5:**
    *   evidence width (one Mac, LucidLink checked; other mount tools such as Mountain Duck not checked);
    *   the limit set differently in Mountpoint and Check.
*   DECLINE:
    *   `build-app.sh` exit 1 on NOT SIGNED (forks without a key must still build; the release step checks the message);
    *   DMG `disk "Mountpoint"` at another path (low likelihood).

## Resolution round 3 (user: auto accept; R3-6 = a, R3-7 = a; R3-1: "files starting with a dot never count – it is only about media files")

Status: resolved. Applied:
*   **R3-1:** `fileCount` (visible files incl. the two database files, like Check) is now the only count; `entryCount` removed. The cache never mixes two counting methods, so a limit change cannot compare against a `.DS_Store`-inflated number.
*   **R3-2:** `decodeTopLevelObject` + `.setErrorAndReturn` + test `purgeSurvivesUnknownClass`.
    *   **Verified:** the original code did not crash either – `init(forReadingFrom:)` already defaults to `.setErrorAndReturn` (the test passes with the old code too).
    *   The finding was a false alarm. The explicit setting stays as documentation; the test now guards the behaviour.
*   **R3-3:** `Sidebar.probe` is async (the self-test awaits it).
*   **R3-4:** `purgeNames` includes owned names; `apply` copies owned names into `sidebarNames` before dropping paths; both layers use one set.
*   **R3-5:** the change check comes before the backups.
*   **R3-6 (a):** `runsFromTemporaryPlace` + dialog "Move Mountpoint to the Applications folder" (4 languages), exits before anything loads. Tested live: app started from the mounted DMG → dialog in German, no mount, Quit exits, log line written. Test `temporaryPlace`.
*   **R3-7 (a):** purge on every launch with a stale entry (decision D4).
*   **Doc:** Decisions list D1–D6 instead of "rejected by the owner", new alternatives (threshold, `.DS_Store` template, scroller lookup), §2 counting and one acknowledgement rule, §3 new vs. old and one name set, G3.3/G3.6/G4.6, §5 evidence width and differing limits, release steps with stress/IT tests and M1–M3, M2/M3/M4 rewritten.
*   **Settings hint:** "A first warning comes above 90 %" (all languages); stale comment in `SettingsWindow.swift` fixed.

80 tests green, build green.

---

# Round 4 of 5

Reviewers: all five completed. **Not clean:**
*   **2 Blockers:**
    *   F1 – the doc claims size checks run at once on folder changes (false);
    *   the standard's "no owner attribution without a link" rule.
*   **1 code Major:** F2.
*   **3 owner decisions.**
*   doc Majors.

The cap is the next round.

## Code – PROPOSE FIX
*   **[R4-1] [`codebase_details`] Major:** switching the folder warning off, or changing the limit, while a count runs. The running count still delivers `applySizes` and can open alerts after the switch-off; a limit change during a count triggers no recount. Fix: `applySizes` drops results when the warning is off, and a change during a count sets a rerun flag (like `scan()`'s `rescan`).
*   **[R4-2] [`zoom_out`] Nit:** `apply` calls `purgeNames(workspaceNames)` instead of rebuilding the set inline.

## Owner decisions – ESCALATE
*   **[R4-3] [`design_critic`] Major – macOS versions.**
    *   **Problem:** the purge is tested only on macOS 15 (the owner's Mac). Users are likely on macOS 26 already. A different daemon there could ignore or reset the rewritten file.
    *   **Options:**
        *   (a) purge only on macOS 15; on other versions hiding only, until someone tests M3 there;
        *   (b) all versions, and M3 on macOS 26 is required before release;
        *   (c) all versions, accepted risk.
    *   **Recommendation:** (a) – the safe default; one OS check.
*   **[R4-4] [`design_critic`] Major – `killall sharedfilelistd` and other lists.**
    *   **Problem:** the daemon also serves other lists (recent items, favourites). Changes it holds only in memory may be lost when it is killed.
    *   **Evidence:** 2026-11-10, one Mac, nothing lost visibly.
    *   **Options:**
        *   (a) accept and document;
        *   (b) no `killall`: write the file and let the daemon pick it up at the next login. This is untested – it may overwrite our change with its memory.
    *   **Recommendation:** (a).
*   **[R4-5] [`design_critic`, `comprehension`] Blocker (standard rule) – owner decisions without a link.**
    *   **Options:**
        *   (a) open a GitHub issue in the public repo recording D1–D6 and link it;
        *   (b) keep the Decisions list in the doc as the record and accept the deviation from the standard.
    *   **Recommendation:** (b) – there is no issue tracker in use, and a public issue would only mirror this list.

## Doc – PROPOSE FIX
*   **F1** (`codebase_details`, `design_critic`, `implementation_readiness`): size checks run at least once a minute, and at once only after a setting change or a mount/unmount. M2: wait up to a minute after each step.
*   **Scroller:** "legacy, non-fading scroller, shown when the content overflows". M1: with enough content.
*   **`fileCount`:** an `lstat` per entry where the file system reports no type (macFUSE, some SMB) – state the cost. Unreadable folders lose their acknowledgement like missing ones. Hidden (`nobrowse`) mounts are not scanned. The scan sentence becomes "scanned: … / not scanned: …".
*   **Acknowledgement cases:**
    *   an alert-acknowledged folder dropping from above the limit straight into the early band shows the early warning (intended);
    *   acknowledgements are judged against the current limit.
*   **Purge text:**
    *   the order of `.first` and the backup;
    *   "decoding failures (incl. unknown classes) are errors";
    *   "hiding triggers one more, empty `apply`".
*   **Hiding by name** can hide a Finder-owned entry of an ejected drive with a workspace's name (Finder hides those itself while the drive is away; the entry returns when the drive is mounted). State it as a risk.
*   **Exception scope:** "entries matching `isStale`, meant to be only Mountpoint's own (see Name match)".
*   **Restore:**
    *   only with Mountpoint quit;
    *   a wrongly deleted foreign entry would be deleted again at the next launch unless its volume is mounted – then report it;
    *   the user follows the steps with the maintainer's help.
*   **M3 / M4:**
    *   M3: preconditions (1.2.x used with mounts, no `FavoriteVolumes-backup*` files yet, run M3 before any other 1.3.0 launch); exact log text "deleted N old entries from the list (A → B)"; counting via the log's A → B.
    *   M4: "Open Anyway" first for the app inside the image, then the move dialog.
*   **G4.5:** `Updater.swift` is unchanged since v1.2.2 (`git diff v1.2.2` empty, checked 2026-11-10), so 1.2.2 uses the same asset rule – state it.
*   **CLAUDE.md:**
    *   one-line exception at the fixed rule;
    *   the sidebar bullet shortened to the rules plus a pointer to the doc.
*   **Glossary items:**
    *   helper;
    *   consent panel;
    *   the `shortcut:` convention;
    *   translation of the D1 quote;
    *   `VERSION` vs `RELEASE`;
    *   `isShared` in the settings app;
    *   the Alternatives section moved after §4 (it uses §3's terms).
*   **Risks:** the DMG carries no signature (same trust as the zip download: GitHub HTTPS + "Open Anyway").
*   **Smaller fixes:**
    *   G4.6 "changes nothing except one log line";
    *   G4.1: the DMG is built from a copy so the layout step never touches `dist/`;
    *   the file list split by folder;
    *   M2 step 4 explicit.
*   **DECLINE:**
    *   N dated backups / in-app restore (support case, two backups suffice);
    *   AppleScript by name vs. path (low likelihood);
    *   a problem statement section (the "Before:" lines and §3 facts state the problems).

## Resolution round 4 (owner decisions: macOS versions = c – all versions, risk accepted; killall = a – accepted; decisions record = b – the doc's list)

Status: resolved. Applied:
*   **Code:**
    *   **R4-1:** `applySizes` drops results when the warning is off, and a check requested during a count runs again afterwards. New test `switchedOffDuringCount` – it fails without the fix (verified).
    *   **R4-2:** `apply` uses `purgeNames`.
*   **Doc:**
    *   Decisions D7–D9;
    *   scan triggers (no check on folder change by itself);
    *   the scroller wording;
    *   `lstat` cost;
    *   the acknowledgement cases;
    *   purge order and byte comparison;
    *   hiding-by-name and DMG-trust risks;
    *   exception scope;
    *   restore with Mountpoint quit and re-deletion;
    *   G4.5 evidence (`git diff v1.2.2` of `Updater.swift` empty);
    *   G4.6 wording;
    *   terms (helper, consent panel, `shortcut:`, `isShared`);
    *   `VERSION` vs `RELEASE`;
    *   M1–M4 rewritten (M3 first, exact log text, Gatekeeper step).
*   **CLAUDE.md:** the exception stated at the fixed rule.

81 tests green.

---

# Round 5 of 5 (cap reached)

Reviewers: all five completed. **Not clean, not converged.** No code defect in the app was found that breaks a guarantee. The open items are claims in the doc that are wrong or stronger than the evidence, test claims, and two build-script/edge cases.

## Open findings

### Blocker
*   **[R5-1] [`codebase_details`, `design_critic`, `implementation_readiness`] §5 "Limit differs from Check's":** the doc claims the UI says "…like MediaFiles Check". It does not.
    *   **Fix:** either add a short note to the settings hint in 4 languages ("set the same value as in MediaFiles Check"), or state the risk as unmitigated.
    *   **Recommendation:** add the note – it is the only place where a user learns that both values must match.

### Major
*   **[R5-2] Ghosts of workspaces removed under 1.2.x** (before `sidebarNames` existed) match no name and are never hidden or purged.
    *   **Fix:** state it as a known limit in §3/§5 and in M3.
    *   On the owner's Mac these were cleaned by hand on 2026-11-10.
*   **[R5-3] The settings app's self-test probe writes the sidebar list from a second process,** not serialized with Mountpoint's purge/`killall`. The Terms entry "never touches the sidebar" is wrong.
    *   **Fix:** correct Terms and add it to §5 (rare: the self-test in the settings app at the moment of a launch purge; the worst case is a failed probe check or one lost probe entry).
*   **[R5-4] Lost concurrent change:** the window is not milliseconds. Changes the daemon holds only in memory are lost at `killall` – the same as D8. **Fix:** merge into the D8 bullet.
*   **[R5-5] Test claims too strong:**
    *   G2.4 cites tests that do not cover the drop into the early band, missing folders, judging against the current limit, or alert closing on a raise;
    *   the "first backup kept" test cannot fail.
    *   **Fix:** add the tests (all fit the existing harnesses), or mark these as "code reading".
*   **[R5-6] D6 (start from the image) has no alternatives.**
    *   Candidates: a "move and relaunch" button (LetsMove-style), or running without mounting/updates and showing a banner.
    *   **Fix:** add the alternatives with their reasons: moving needs file moves (CLAUDE.md rule), a running app without mounts confuses more than a clear quit.
*   **[R5-7] The counting rule "like MediaFiles Check" has no pinned source.** **Fix:** reference Check's `src/rebalance.rs` `per_folder` and CLAUDE.md "Rebalancing" (2026-11-09).
*   **[R5-8] Purge at quit instead of launch** is not listed as an alternative. **Fix:** add it, rejected because the quit path is capped at 5 s and the user may log out or shut down.
*   **[R5-9] G4.5 (`comprehension`):** "1.2.x" covers more versions than the evidence. Checked now: the asset rule is identical in 1.1.0, 1.2.0 and 1.2.1 (`git show`). Fix: say "since 1.1.0" and add `git diff --exit-code v1.2.2 -- Sources/Mountpoint/Updater.swift` to the release steps.
*   **[R5-10] Two copies of §2/§3 in CLAUDE.md** (`zoom_out`). **Fix:** shorten CLAUDE.md to the rules and point to the doc; fix its order (re-read before backups).

### Nits
*   **Build script:** the DMG layout addresses Finder's `disk "Mountpoint"` by name – another mounted volume named "Mountpoint" (for example a second DMG at "Mountpoint 1") could get the layout. Fix: stop when any volume named "Mountpoint" is mounted.
*   **M2:** other real MXF folders above 90 files also alert at limit 100 – precondition.
*   **M3:**
    *   answer "Not now" on the consent panel (the self-test adds one more stale entry);
    *   add a launch with nothing stale;
    *   check that a "Mount at app launch" workspace appears in the sidebar on a purge launch.
*   **G4.6:** "two log lines and the app's language preference".
*   **`lstat` branch** untested; an entry deleted between `readdir` and `lstat` counts briefly.
*   **`warnsOncePerCrossing`** writes `bigKnown` to the test defaults (`persist` default).
*   **Rest:** wording (threshold = level, scroller "hidden when nothing overflows", cache, `.manual`, "NOT SIGNED", "title, arrow"), forward references to M-checks, problem statements for §1/§4, the D-references in rejections, DMG checksum (DECLINE).

## Decision needed (cap)
*   **Options:**
    *   accept at cap and proceed;
    *   continue past the cap;
    *   return to drafting.
*   **Recommendation:** accept at cap after applying the PROPOSE FIX items above. They are doc corrections plus small tests, the UI note for R5-1 and the build-script name check, with no change to the app's behaviour. Then release.

## Resolution round 5 (user: "Abschließen" – accepted at cap)

Status: **accepted at cap after 5 rounds** (not converged; no open finding breaks a guarantee in code). Applied:
*   **R5-1:** the settings hint now says "Use the same limit as in MediaFiles Check" (it replaced the "no more than 5000" sentence, so the text still fits). Translated to de/fr/es with a non-breaking space before "%"; fr and de checked in screenshots.
*   **R5-2, R5-3, R5-4, R5-6, R5-7, R5-8:** doc (known limit for 1.2.x ghosts, the settings app's probe as a risk, `killall` window merged into D8, alternatives for D6 and purge-at-quit, counting source in Check).
*   **R5-5:** tests `acknowledgementCases` (drop into the early band, missing folder, current limit) and a second purge with a different list (first backup kept); `warnsOncePerCrossing` with `persist: false`.
*   **R5-9:** G4.5 = from 1.1.0 (asset rule checked with `git show`), plus a `git diff` check in the release steps.
*   **R5-10:** CLAUDE.md sidebar bullet shortened to the rules plus a pointer to the doc.
*   **Nits:**
    *   build script stops when any volume named "Mountpoint" is mounted;
    *   M2/M3/M4 preconditions and expectations;
    *   G4.6 wording.

82 tests green, full build green.
