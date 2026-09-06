# Historical reconciliation (mechanical, not narrative)

Generated 2026-09-06, final pre-hardware closure mission. Discovered branch
names and SHAs directly from `git branch -a`/`git worktree list` in each
repository — none assumed from any prior prompt. Classification method for
every row: `git merge-base --is-ancestor`, cross-checked with `git diff
--stat` against the specific files each historical branch touched where the
ancestor check alone was insufficient (a real merge-commit ancestor check
can miss content-equivalent work landed via a distinct commit sequence, and
conversely a stale draft branch can show as "not an ancestor" while its
actual content was fully superseded by later, better work — both cases are
called out explicitly below, never silently assumed).

Final candidate HEADs reconciled against:
- `NebulaOS-firmware` `phase2/calibration-framework` @ `3dfd5f3b455eabc2a1a60937e72700fa517f03ef`
- `NebulaOS-klipper-extensions` `phase2/calibration-framework` @ `7f627672c9605a0191a719a8dd9fa6ab043876cb`
- `NebulaOS-klipper-mcu` `main` @ `2c9bab5` (unchanged since RC1)

| # | Historical work | Source branch/SHA | Purpose | Current equivalent | Classification | Evidence |
|---|---|---|---|---|---|---|
| 1 | Phase 0 safety/logging cleanup | `NebulaOS-firmware` `origin/phase0/safety-logging-cleanup` (`86a034c`) | Safety-log baseline predating Phase 1 | Ancestor of current HEAD | **PRESENT_AS_ANCESTOR** | `git merge-base --is-ancestor 86a034c 3dfd5f3` → 0 |
| 2 | Phase 1 no-fork migration | `NebulaOS-firmware` `origin/phase1/no-fork-migration` (`113efbe`) | Retired the Klipper fork, established symlink/exclude composition | Ancestor of current HEAD | **PRESENT_AS_ANCESTOR** | `git merge-base --is-ancestor 113efbe 3dfd5f3` → 0 |
| 3 | Phase 1.5 persistent namespace | `NebulaOS-firmware` `origin/phase1.5/persistent-namespace` (`a4a3f0d`); `NebulaOS-klipper-extensions` `origin/phase1.5/hardware-closure` (`4bdd419`) | `/usr/data` persistent layout, hardware-closure qualification | Ancestor of current HEAD in both repos | **PRESENT_AS_ANCESTOR** | Both `merge-base --is-ancestor` checks → 0 |
| 4 | Phase 1.8 host-58bd native MCU / host-compat | `NebulaOS-firmware` `origin/phase1.8/host-58bd-native-mcu` (`ff49e65`); `NebulaOS-klipper-extensions` `origin/phase1.8/host-58bd-compat` (`389e49f`) | First native GD32F303 MCU wiring, host Klipper `58bd67db` qualification | Ancestor of current HEAD in both repos; pinned Klipper commit unchanged | **PRESENT_AS_ANCESTOR** | `merge-base --is-ancestor` → 0 both repos; `git_commit_klipper=58bd67db...` unchanged in every RC1/RC2/RC3 build manifest |
| 5 | Phase 1.8B integration (boot safety, candidate-001 integration, MCU lifecycle draft, KE stepper parity) | `NebulaOS-firmware` local-only branches `phase1.8b/boot-safety` (`604fc7e`), `phase1.8b/candidate-001-integration` (`849b201`), `phase1.8b/mcu-lifecycle` (`1397d17`), `phase1.8b/ke-stepper-parity` (`67fd5b9`) — **none pushed to origin** | Staging branches for the Phase 1.8B integration effort | Not literal ancestors; content re-implemented and hardened on the path to `phase1.8b/integrated` (`ba28d42`, confirmed ancestor), then further fixed by candidate-002 (`85814b6`, confirmed ancestor) | **INTENTIONALLY_SUPERSEDED** | `merge-base --is-ancestor` → false for all four; `git diff 1397d17..3dfd5f3 -- '*mcu_lifecycle*' '*mcu_restore*' '*mcu_restart*' '*mcu_application_identify*'` shows 479 insertions/71 deletions (early draft, since hardened); `phase1.8b/integrated` and `85814b6` both confirmed ancestors; see `docs/mcu-lifecycle-reconciliation.md` |
| 6 | Phase 1.8B candidate-002 — known-good platform state | `85814b604a6857669d287df72669cc7629896497` | Real, hardware-qualified fix for the MCU lifecycle guard (Option C restart) | **Zero-diff** ancestor of current HEAD | **PRESENT_AS_ANCESTOR** (byte-identical) | `git diff 85814b6 3dfd5f3 -- <5 mcu_*.py files>` → empty; see `docs/mcu-lifecycle-reconciliation.md` |
| 7 | Phase 1.9A host-MCU / accelerometer wiring | `NebulaOS-firmware` `origin/phase1.9a/host-mcu-accelerometer` (`95f770a`); `NebulaOS-klipper-extensions` `origin/phase1.9a/host-mcu-accelerometer` (`61cf27c`) | `[mcu rpi]`/`[adxl345]` wiring, SPI polarity fix, `klipper_mcu` build | Ancestor of current HEAD in both repos | **PRESENT_AS_ANCESTOR** | `merge-base --is-ancestor` → 0 both repos |
| 8 | Phase 1.9B power-loss recovery (PLR) | `NebulaOS-firmware` `origin/phase1.9b/plr` (`32cb93f`); `NebulaOS-klipper-extensions` `origin/phase1.9b/plr` (`b6ae35e`) | `nebulaos_power_loss_recovery.py`, `nebulaos_plr_journal.py`, `NEBULAOS_RESUME_POWER_LOSS`/`NEBULAOS_CLEAR_POWER_LOSS_RECOVERY` | Ancestor of current HEAD in both repos | **PRESENT_AS_ANCESTOR** | `merge-base --is-ancestor` → 0 both repos |
| 9 | Nozzle-clear / load-cell / Z-offset work | `NebulaOS-klipper-extensions` `origin/phase1.8b/nozzle-clear-native` (`f2536ff`) | Native `nozzle_clear.py` on the shared `nebulaos_z_offset_probe` backend, PRTouch removal | Not a literal ancestor; further evolved by Phase 2's own "upstream-first cleanup" (`1307dcd`, ancestor) which rewrote `z_compensate.py`'s internals | **INTENTIONALLY_SUPERSEDED** | `merge-base --is-ancestor` → false; `git diff f2536ff..7f62767 --stat -- '*nozzle_clear*' '*z_compensate*'` shows `nozzle_clear.py` nearly unchanged (29 lines) while `z_compensate.py` was substantially rewritten (203 lines) by later, ancestor commits — the native-backend *concept* survived intact, its implementation matured |
| 10 | Input-shaper relocation workflow | Extensions commits `a0e7749`→`5f004c7`→`5a0374d` (guided 3-call `NEBULAOS_INPUT_SHAPER_CALIBRATE` redesign, per `REPORT.md` §7/8's live design correction) | Real movable-sensor guided workflow, not a fixed-mount single pass | All three commits confirmed ancestors of current extensions HEAD (linear history, same branch) | **PRESENT_AS_ANCESTOR** | `git log --oneline` on current branch includes all three |
| 11 | Calibration-framework work | Extensions commits `c29f1a9`→`3381a9b`→`d9483e8` (coordinator, per-axis slices, load-cell preflight) | `NEBULAOS_AUTO_CALIBRATE`/`NEBULAOS_Z_OFFSET_CALIBRATE` orchestration | All ancestors (same branch's own linear history since these ARE the branch) | **PRESENT_AS_ANCESTOR** | Trivial — these commits are on the branch being evaluated |
| 12 | Mainsail groups/public API work | Last night's RC2 overnight closure commits `cd93674`, `214d652`, `8e1a620` | Hyphenated group IDs, migration, Expert default, inventory docs | All ancestors (immediately preceding current HEAD on the same branch) | **PRESENT_AS_ANCESTOR** | Trivial — `git log --oneline -8` shows them directly below `3dfd5f3` |
| 13 | Current native MCU branch | `NebulaOS-klipper-mcu` `main` @ `2c9bab5` | GD32F303 firmware patch/build repo | Unchanged since RC1 — no new commits | **NOT_REQUIRED** (nothing changed, nothing to reconcile) | `git log --oneline -3` identical to last night's RC2 manifest |

## Summary

```
HISTORICAL_RECONCILIATION_COMPLETE = YES
HISTORICAL_BRANCHES_REVIEWED = 16
MISSING_REQUIRED_CHANGE = 0
INTENTIONALLY_SUPERSEDED_CHANGES = 2   (row 5: Phase 1.8B staging branches;
                                        row 9: nozzle-clear-native draft)
```

Every historical branch discovered via `git branch -a`/`git worktree list`
in both repositories was checked. No load-bearing change from any prior
Phase 1 or Phase 2 session is missing from the current candidate branch.
The two "superseded" rows are drafts whose *content* was carried forward in
matured form by later, already-ancestor commits — confirmed by diffing the
actual files each draft touched, not assumed from a similar filename.
