# Goldfish Annotated Review Report

**Target:** `docs/release-1.2.0-changes.md` (full file, lines 1–282) · **Round 5 of 5 (cap reached)** · Reviewers: `codebase_details`, `design_critic`, `implementation_readiness` (all three completed)

Round 5 is **not clean**: no Blocker, 3 Majors (1 code edge case, 2 manual-check steps). `design_critic` found no Blocker/Major. Not converged (rounds 4 and 5 not clean) → cap decision by the user. Nothing from this round is applied yet.

## Open findings

### [Issue 1] [`codebase_details`] – Major (code)
*   **Scope:** lines 105–106, G4.1, G4.5; Store.swift:85-93, 481, 491, 669-674.
*   **Description:** Mountpoint starts with an unreadable file that it cannot set aside → empty list in memory. If the file becomes readable again while Mountpoint runs (user fixes permissions), the next reload/save writes Mountpoint's empty project/workspace list over it. Needs two faults; loss is total.
*   ***AI Suggestion:*** PROPOSE FIX – Mountpoint treats its memory as authoritative only after it has loaded a readable file; until then, a successful read adopts projects/workspaces from disk. Test for it.

### [Issue 2] [`implementation_readiness`] – Major (manual check)
*   **Scope:** lines 277–280 (M2).
*   **Description:** M2(b) cannot run after M2(a): the Mac already runs the beta, nothing newer is offered.
*   ***AI Suggestion:*** PROPOSE FIX – run (b) first on the 1.2.0 Mac; expected: panel message, no "installing update" in the log.

### [Issue 3] [`implementation_readiness`] – Major (manual check)
*   **Scope:** line 271 (M5 launch at login), line 221 (§8).
*   **Description:** Quitting Mountpoint quits the settings app; the doc never says how to start the settings app alone.
*   ***AI Suggestion:*** PROPOSE FIX – `open ".../Helpers/Mountpoint Settings.app"`, check with `pgrep`; add: guard edit without Mountpoint is applied at its next start.

### Nits (PROPOSE FIX unless noted)
*   Settings app: a reload that finds the file missing should post `library` (Mountpoint repairs at once) – one line; G4.2 wording then holds (`design_critic`, `codebase_details`).
*   "fewer" → "different from" (doc + CLAUDE.md) (all three).
*   A login or self-test notice can replace the read-only notice; after it is cleared the banner is empty while still read-only → show `readOnlyText` again (`design_critic`).
*   Window closed during a self-test → panel pops up minutes later when the test ends → do not reopen the panel after a deferred close (`design_critic`).
*   Light/Dark and launch at login are not logged; G4.2 "logged once" → add `logSetting` (`implementation_readiness`).
*   Doc: line 81 qualifier; "at launch" test refers to the settings app; M5 prerelease vs. order; M5 "do not click OK / fresh folder"; M4 add "quit Mountpoint during a settings-app self-test"; M3 fallback codesign commands; §1 "which the user asked for" without reference; no Goals heading; file-watching alternative.

## Resolution (user: "Übernehmen und weiter")

Accepted at cap after 5 rounds. All PROPOSE FIX items of round 5 applied (code: `knowsList`, settings app posts on missing file, read-only notice returns, `noReopen`, dark/launch-at-login logged; doc: goals, file-watching alternative, wording, M2/M3/M4/M5 steps). 74 tests green incl. stress and integration; build and `MOUNTPOINT_RELEASE=1` updater test green.
