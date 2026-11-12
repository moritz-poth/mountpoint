# 1.4.0 – Full Disk Access only for the sidebar cleanup

Security scan 2026-11-11 (report `CLAUDE-SECURITY-20261111-134821/`, not committed): F1, F2 and F4 have one root –
the mirror helper inherits Mountpoint's privacy permissions (TCC), and since 1.3.4 Mountpoint asks for Full Disk Access.
Any program of the same user could then reach Mail, Messages or the TCC database through Mountpoint
(symlink swap in the source folder, a crafted `library.json`, or a swapped libfuse).

Full Disk Access is only needed for one thing: `Sidebar.purge` reads and rewrites the Finder's FavoriteVolumes list.

## Change

1. **`Mountpoint Cleanup.app`** in `Contents/Helpers`, copied at start to `~/Library/Application Support/Mountpoint/`
   (`Sidebar.installCleanup`, only when its executable differs) – macOS charges an app inside `Mountpoint.app` to
   Mountpoint's own grant (tccd log: `subject=…mountpoint` for the nested helper, 2026-11-12); the copy outside has its
   own. Changing the copy changes its signature, so the grant stops applying. It is the same binary with its own bundle id (`…mountpoint.cleanup`),
   background only, like the settings app. `cleanupMode` (Model.swift): `Sidebar.runCleanup` (inspect → record →
   purge), then exit. Nothing else runs – no Store, no mounts, no UI.
2. Mountpoint starts it once per launch through LaunchServices (`NSWorkspace.openApplication`), never with `Process`:
   only then macOS treats it as its own app with its own privacy permissions. Names to clean come as arguments
   (`--names …`); a forged name can at most remove more of Mountpoint's own stale entries (`isStale` still applies).
   Mountpoint waits for it (max 30 s) before observing the list – the daemon restart drops observers.
3. Backups are written without following a symlink at the backup folder or file (`writeNoFollow`): the helper has
   Full Disk Access and `~/Library/Application Support/Mountpoint` is writable by every program of the user.
4. Asking for access (`SidebarAccess`): waits for the cleanup result; asks to switch on “Mountpoint Cleanup” – its
   first denied read lists it switched off (checked with a probe app, 2026-11-12). Ad-hoc signature: every update
   switches the existing entry off (checked 2026-11-12), so the notice comes once per version. Mountpoint's own grant from 1.3.4 is removed at start
   (`tccutil reset SystemPolicyAllFiles` for its own id, no admin rights needed); Mountpoint never reads the list itself,
   so it never shows up there. Settings → General “Allow…” does the same.
5. Error text for unreadable workspace folders no longer suggests Full Disk Access for Mountpoint.

## Not in this step

- F1 helper rewrite (no symlink following in `mirror.c`): draft in the report folder, needs the macOS 13/14 xattr fix.
- F4: embed libfuse in the bundle.
- Folder grants (Documents, Desktop, removable and network volumes) are still Mountpoint's and the helper's.

## Test

Dev terminals have Full Disk Access and hide every TCC problem: test the built app started with `open`,
ideally in a second user account. Check: the cleanup appears in the Full Disk Access list, the log shows
`sidebar: deleted …` with only the helper allowed, Mountpoint without Full Disk Access mounts as before,
the upgrade notice appears once when Mountpoint still has access. Then prerelease; friend on macOS 26.
