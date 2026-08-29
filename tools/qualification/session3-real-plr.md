# Phase 1 final hardware qualification — Session 3 (real PLR, minimum destructive test)

Prepared by the Phase 1 overnight closure mission. **Not run tonight.** Only
attempt this after Session 1 and Session 2 have both passed. This is the
only session in the whole qualification that involves a genuine hard power
cut — designed to need exactly **one**, since the extensive offline test
suite (86+10+56 tests across the journal codec, extension state machine,
and candidate-promotion mechanism — see the Phase 1.9B and Mission A
reports) already strongly covers every failure-mode case that does not
require a real, physical, unplanned power loss to exercise.

## Minimum destructive sequence (one power cut)

| # | Step | Action | Expected result | Confirm before next step |
|---|---|---|---|---|
| 1 | Start a real, low-risk print | Start any short calibration print (a small single-wall test cube is enough) | Print begins normally, `PRINT_STATS.state = printing` | Yes |
| 2 | Wait for a durable checkpoint | Poll `NEBULAOS_PLR_STATUS` (or `printer.objects.query nebulaos_power_loss_recovery`) until `candidate_pending: false` and a generation is visible, well after the print has passed `min_z_for_start` (0.6mm) | Status reports recovery available, with a plausible `file_position` | Yes — note the exact generation/file_position reported |
| 3 | **Hard power cut** | Physically remove power (not a soft shutdown/reboot — the real event this feature exists for) | Printer goes fully dark | Yes |
| 4 | Power back on, wait for boot | Wait for Klipper `ready` | Klipper reaches `ready` with **no heat, no motion** issued automatically | Yes — confirm nozzle/bed are NOT heating and nothing is moving before proceeding |
| 5 | Confirm recovery is detected but not auto-applied | `NEBULAOS_PLR_STATUS` | Reports recovery available (same generation/file_position noted in step 2, or the last one that became durable before the cut) | Yes |
| 6 | Explicit resume | `NEBULAOS_PLR_RESUME` (no `ALLOW_UNSAFE`) | **Refused** with a clear `POSITION_UNSAFE`-style message (this is the correct, expected default) | Yes |
| 7 | One-time override | `NEBULAOS_PLR_RESUME ALLOW_UNSAFE=1` | State restoration gcode runs (G90/M82/G92/SET_VELOCITY_LIMIT/SET_PRESSURE_ADVANCE/M106 or M107/BED_MESH_.../M104/M140 as applicable) — **no G28, no G1/G0, no M24 is ever issued automatically** | Yes — visually confirm nothing moved and M24 was NOT sent |
| 8 | Manual resume decision | Owner visually inspects the print and physically verifies the nozzle's real position matches expectations, THEN manually issues `M24` only if genuinely safe to do so | Print resumes correctly if attempted, or is manually discarded if not | Yes — this is a human judgment call, not something this session automates |

## Targeted offline-equivalent checks (no physical power cut needed — already covered, re-verify their live-hardware analog only if time and confidence permit)

These do **not** each need a separate hard power cut — the offline suite
already proves the logic; use these only as a light live sanity pass:

| Check | Live action | Expected result |
|---|---|---|
| File changed → refuse | After a checkpoint exists, edit/replace the gcode file's content on disk, then `NEBULAOS_PLR_RESUME ALLOW_UNSAFE=1` | Refused — file identity (path/size/SHA256) mismatch |
| Corrupted sidecar → refuse | `echo garbage >> <sidecar path>` on the live device, then resume | Refused — sidecar unreadable |
| Bad generation → refuse | Hand-edit the sidecar JSON's `"generation"` field to a wrong value, then resume | Refused — stale sidecar generation |
| Clean finish → no recovery | Let a short print finish normally (`M84`/complete), then check `NEBULAOS_PLR_STATUS` | Reports no recovery available (tombstoned) |
| Cancel → no recovery | Start a print, `CANCEL_PRINT`, check `NEBULAOS_PLR_STATUS` | Reports no recovery available (tombstoned) |
| One-time `ALLOW_UNSAFE` | Already exercised in step 7 above | — |
| `ALLOW_UNSAFE` cannot bypass integrity failure | Combine "file changed" or "bad generation" above with `ALLOW_UNSAFE=1` | Still refused — confirms the override never reaches the integrity gates |

## Explicit non-goals for this session

- No dozens of repeated power cuts — one real hard cut, at a meaningfully
  advanced print position, is the target; everything else in this session
  is either a live sanity check of already-offline-tested logic, or purely
  observational (owner judgment on physical position at step 8).
- No automatic resume of actual printing (`M24`) is ever issued by any
  script or gcode command here — that decision belongs to the owner alone,
  every time, per the frozen architecture.
