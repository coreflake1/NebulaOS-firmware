# Phase 1 Tomorrow Runbook

Follow this top to bottom. No architectural decisions are required — every
step is a command/action with a stated expected result. If a step's actual
result doesn't match, stop at that step's STOP CONDITION and don't improvise
past it.

The exact candidate this runbook qualifies is frozen in
`docs/qualification/PHASE_1_FINAL_CANDIDATE.md` — check it out and flash
that exact commit, not whatever happens to be checked out later.

| # | STEP | COMMAND/ACTION | EXPECTED RESULT | PASS/FAIL | STOP CONDITION | SAFE TO POWER OFF? |
|---|---|---|---|---|---|---|
| 0 | Confirm the candidate | `git -C NebulaOS-firmware log -1 --oneline` on branch `phase1.9b/plr` | Matches the commit in `PHASE_1_FINAL_CANDIDATE.md` | | Commit doesn't match → stop, do not flash | N/A (not yet on device) |
| 1 | Flash the candidate | Follow the project's own existing flash procedure (A/B slot, never the booted slot — see `docs/A_B_SLOT_MODEL.md`) | Flash completes, MD5-verified | | Flash verification fails → stop, do not boot into it | Yes, before booting into the new slot |
| 2 | First boot | Power on into the new candidate slot | Klipper reaches `ready` within a reasonable time | | Does not reach `ready` → stop, check `klippy.log` before anything else | No — proceed to Session 1 |
| 3 | Session 1 (no motion) | `sh tools/qualification/session1-no-motion.sh <printer-ip>` | Script reports `SAFE TO POWER OFF: YES` | | Any FAIL in the script's own output → stop, do not proceed to Session 2 | Yes, if the script says so |
| 4 | Decision point | Review Session 1's evidence directory | Owner confirms comfortable proceeding | | Any doubt → stop here, this is a legitimate place to end the day | Yes |
| 5 | Session 2 (controlled motion) | Work through `tools/qualification/session2-controlled-motion.md`, confirming each row | Every row's expected result matches | | Any unexpected motion/sound/value → emergency stop immediately | Yes, once every row is confirmed or the session was stopped |
| 6 | Session 3 (real PLR) | Work through `tools/qualification/session3-real-plr.md` | Every row's expected result matches, including the one real hard power cut | | Recovery misbehaves, or any automatic motion/heat is observed before an explicit owner action → stop and report exactly what happened | Yes, once complete |
| 7 | Fill in the regression matrix | Update `tools/qualification/phase1-regression-matrix.md`'s "tomorrow regression needed" rows with actual pass/fail | Every row marked | | — | — |
| 8 | Promote (only if everything above passed) | Bump `QUALIFIED_BASELINE_TAG` in `manifests/dependencies.conf` to a new tag covering this candidate, in its own reviewed commit; create the tag; merge `phase1.9b/plr` to `main` in both repos | New tag exists, merge is clean | | Anything above failed → do NOT promote; file what failed instead | Yes |
| 9 | Declare done | Update this runbook's own final line (below) | `PHASE_1_PRINTER_COMPLETE=YES` | | — | — |

## Final line (fill in after step 8/9)

```
PHASE_1_PRINTER_COMPLETE=<YES/NO — fill in tomorrow>
```

## If something fails

- Do not modify the candidate source to "make a check pass" — if a real
  check fails, the candidate has a real problem. Fix it as a normal,
  reviewed change, produce a NEW candidate, and re-run from step 0.
- Do not skip Session 1 even if you're confident — it's ~15 minutes and
  catches the highest-value class of problem (EEPROM/host-MCU/GD32 issues)
  before any motion risk is taken on.
- If in doubt at any point, stop and power off. Nothing in this candidate
  requires an uninterrupted session — every stopping point above is marked
  "safe to power off".
