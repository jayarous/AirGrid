# AirGrid — branch comparison before merging to main

**As of 2026-08-02, from the Windows box.** Written to answer one question:
what should the "final version" that goes to `main` actually be?

**Headline: `walkie-ux-polish` must not be merged into `main` as-is.** It
forked before the PR #1 security remediation and would revert it.

---

## 0. Outcome — COMPLETE. One trunk, everything merged.

**`origin/main` is `85f39f0` and contains every line of work.** The rest of
this document is the analysis that led there; §6 is the plan, and it was
carried out in full.

| Branch | Head | State |
|---|---|---|
| `origin/main` | `85f39f0` | the trunk — everything |
| `origin/walkie-ux-polish` | `85f39f0` | fast-forwarded to main, no longer divergent |
| `origin/integration/consolidate-walkie` | `03a2a0d` | fully merged into main; safe to delete |
| `origin/fix/stop-mesh-reentrancy` | `4b41b08` | merged (PR #2); safe to delete |
| `sticky-sheet` | `6c25e56` | still local-only. Prohibition intact, never pushed |

Verified on `main` at `85f39f0`:

```
flutter test      546 passed / 0 failed
flutter analyze   No issues found
dart format       clean (exit 0)
secrets-guard     passes
flutter build apk --debug   OK, 183 MB
  ABIs: arm64-v8a, armeabi-v7a, x86_64
```

`armeabi-v7a` is present, so the Linux `airgrid-arm64-only.gradle` release
hazard (original handover §3) did **not** follow the clone. That file is
absent on this box. A Play AAB from here will carry 32-bit support.

`walkie-ux-polish` was fast-forwarded rather than force-pushed — it was
already an ancestor of main, so no history was rewritten and no other machine
needs to reset. Pulling either branch now gets the same code.

**`AIRGRID-HANDOVER-2026-08-02-session2.md` is superseded** by this file. Its
§4/§8/§10 instruction to "check out `fix/stop-mesh-reentrancy`, not main" is
now actively wrong — `main` is correct.

Two things worth knowing about the result:

1. **`WalkieState` was adopted, not dropped.** `chat_state.dart` merged cleanly
   to main's value-object form while the walkie controller and screen still
   used flat fields, leaving the tree incoherent. The field sets turned out to
   be a 1:1 mapping, so 95 references were migrated. This is the largest
   mechanical part of the diff.
2. **A user-visible default changed.** `batteryOptimizationEnabled` is `true`
   on `main` and `false` on the walkie line — changed deliberately by
   `4af400c RiderModeReady`, since rider mode needs continuous background
   activity. The merge kept `false`. If that is wrong, it is a one-line
   revert in `chat_state.dart` plus the test note assertions.

### What to do next

1. **Re-trust the peers on both handsets before testing always-on** (original
   handover §7). The uninstall wiped trust; untrusted contacts reproduce the
   same false alarm.
2. **Re-verify the stopMesh fix on device**: a single stop should now log
   **one** `Transport stopped` and **one** `Foreground service stopped`, not
   three.
3. **The Note 8 Bluetooth finding is still the top open item** (original
   handover §5.1): 847 GATT failures against the Fold's zero, everything on
   Wi-Fi LAN. Test with Wi-Fi off on both devices — that either clears it or
   makes it the most serious issue in the project. Nothing in this session
   touched it.
4. Still unaddressed from the handover: cleartext display name in the BLE
   advertisement (§5.2) and missing log tags for file transfer and walkie
   audio (§5.3).
5. Still waiting on third parties: GitHub GC (ticket 4622171) and the Google
   upload-key reset.

---

## 1. The three live lines

| Branch | Head | Version | Has stopMesh fix |
|---|---|---|---|
| `main` | `ddaec06` | 1.0.3+4 | no — waits on PR #2 |
| `fix/stop-mesh-reentrancy` (PR #2) | `4b41b08` | 1.0.3+4 | yes |
| `walkie-ux-polish` | `8b5e355` (local) | 1.0.11+14 | yes — ported this session, **not pushed** |

`copilot/project-reach-and-impact-report` and
`remediation/p0-security-and-oversize-fix` are both already merged into
`main`. Nothing to do with either.

`sticky-sheet` is a local WIP checkpoint (`6c25e56`, worktree at
`.kilo/worktrees/sticky-sheet`). It carries the same unguarded `stopMesh`.
Left untouched — it is under a standing no-push prohibition.

## 2. Why walkie-ux-polish cannot go to main as-is

Merge base is `75cabfe` (*WalkieTalkie*). `walkie-ux-polish` is **15 ahead,
11 behind**. The 11 it is missing are the entire PR #1 remediation:

```
ddaec06 Merge PR #1: security remediation, oversize-send fix, test-suite repair
50b80f7 Migrate deprecated Radio API; make analyze exit clean
c0e2140 Split walkie state out of ChatState into a WalkieState value object
45cd967 Consolidate the eight private-send paths onto shared helpers
a89012d Show peer safety numbers; accept packets with no sender name (phase 1)
1a8705d Relay public walkie audio mesh-wide; pin relay-eligibility matrix
d809ba0 Add key fingerprints and trust-on-first-use key-change detection
9448dd3 Apply dart format across the project; make CI format check gate
e68ee8a Repair test suite: 40 failures -> 0
75cdcc0 Verify oversize fix; mock secure storage in new test
f3cb605 Remove signing material from tracking; fix oversize-file silent failure
```

Concretely, merging walkie → main would:

| Regression | Evidence |
|---|---|
| **Revert the oversize-file fix** | 0 `oversize`/`maxFileBytes` refs on walkie vs 4 on main (`constants.dart`, `mesh_service.dart`) |
| **Delete CI entirely** | `.github/workflows/` — 1 file on main, **0 on walkie**. This includes `secrets-guard`, which the handover calls "the backstop" |
| **Resurrect deleted junk** | `airgrid/fix_corruption.ps1`, `airgrid/fix_node_ids.ps1`, `logs/device_*.log` (1.9 MB) still present on walkie |
| **Lose key-fingerprint work** | 3 files reference `fingerprint` on main, 1 on walkie |
| **Undo the format gate** | `9448dd3` applied `dart format` repo-wide and gated CI on it; walkie never got it |

Neither branch tracks signing material (`.jks`/`.keystore`/`key.properties`)
— that part is clean on both.

Walkie also adds ~11 MB of `play-console-screenshots/*.png` that main lacks.
Not a regression, but worth a decision before it lands on trunk.

## 3. Reconciliation cost

Dry-run merge (`git merge-tree`, main → walkie): **17 conflicting files.**

```
.gitignore
airgrid/lib/data/storage/local_identity_store.dart
airgrid/lib/domain/models/airgrid_packet.dart
airgrid/lib/domain/services/mesh_service.dart
airgrid/lib/features/chat/chat_controller.dart
airgrid/lib/features/chat/chat_screen.dart
airgrid/lib/features/home/home_screen.dart
airgrid/lib/features/settings/{profile_edit,reports,settings,trusted_contacts}_screen.dart
airgrid/lib/features/walkie/walkie_screen.dart
airgrid/test/data/local_identity_store_test.dart
airgrid/test/domain/mesh_service_test.dart
airgrid/test/features/{play_services_widget,walkie_screen,walkie_state}_test.dart
```

`chat_controller.dart` alone differs by 159 insertions / 535 deletions
between the branches. This is a real reconciliation, not a fast-forward.

## 4. walkie-ux-polish is not green

Measured on this box, at `6fade3f` **before** any change this session:

```
flutter test      488 passed / 4 failed
flutter analyze   2 info issues (walkie_screen.dart 537, 1003)
dart format       chat_controller_startup_test.dart already non-compliant
```

Failing at HEAD:
- `walkie_state_test.dart` — incoming accept activates outgoing private walkie session
- `play_services_widget_test.dart` — Settings shows battery optimization controls and note changes
- `play_services_widget_test.dart` — Chat mesh status panel does not overflow on small screens
- `play_services_widget_test.dart` — Chat mesh status panel does not overflow on compact height layout

The handover's "523 passed, analyze exit 0" applies to the **main** line, not
this one. These four are pre-existing and unrelated to the stopMesh work.

## 5. The stopMesh port (local commit `8b5e355`, unpushed)

```
airgrid/lib/features/chat/chat_controller.dart          +15
airgrid/test/features/chat_controller_startup_test.dart +70
```

Same guard as `4b41b08`, reapplied by hand because the refactor blocks a
clean cherry-pick. Verified on this branch:

- Suite goes 488→490 passed, same 4 failures (stashed baseline run to confirm)
- Mutation check: guard disabled → `Expected: <1>, Actual: <3>`, matching the
  device multiplier
- Analyze unchanged; added code is format-clean
- `gradle.properties` deliberately **not** carried over — those flags came
  from Flutter's migrator on the Linux box, unrelated to this fix

## 6. Recommended order

1. **Merge PR #2 into `main`.** Small, reviewed, in isolation. `main` gets the
   fix and stays the clean trunk. (CI status unread — `gh` is not installed
   here; check PR #2 on GitHub first.)
2. **Merge `main` into `walkie-ux-polish`**, not the reverse. This pulls the
   11 remediation commits forward into the line the devices actually run and
   is where the 17 conflicts get resolved — once, on a feature branch, not on
   trunk.
3. **Fix the 4 pre-existing failures** on walkie so the branch is green.
4. **Then** open a PR from `walkie-ux-polish` → `main` as the release
   candidate, with CI restored and the junk files dropped.

Step 2 supersedes the stopMesh port: after the merge, `8b5e355` and `4b41b08`
are the same fix arriving from two directions. Git will reconcile them in
`chat_controller.dart` — expect that file to conflict and keep the guard once.

## 7. Open question for you

`walkie-ux-polish` deleted CI. Whether that was deliberate or just an artifact
of forking before `f3cb605` decides step 2's shape — if deliberate, restoring
`.github/workflows/ci.yml` needs to be an explicit call, since `secrets-guard`
not running is exactly the gap the key rotation cares about.
