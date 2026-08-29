# Phase 1 final hardware qualification — Session 2 (controlled motion)

Prepared by the Phase 1 overnight closure mission. **Not run tonight** — the
printer stayed off for the entire mission. Every step below requires the
owner's own explicit action; nothing here is a script that runs unattended.

Run this only after Session 1 passed and you have chosen to proceed. Have
the printer's screen/emergency stop within reach for every step.

Connect once: `ssh root@<printer-ip>` (custom, password per
`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`), then issue G-code either via
GuppyScreen's console, Mainsail/Fluidd, or `curl -s -X POST
http://<ip>:7125/printer/gcode/script --data-urlencode "script=<gcode>"`.

| # | Step | Command | Expected result | Owner must confirm before next step |
|---|---|---|---|---|
| 1 | TMC driver health | `TMC_STATUS` for stepper_x/y/z/extruder (or check each individually) | No `run_current`/`ots`/`otpw` warnings, no shutdown flags set | Yes — visually inspect output |
| 2 | Home X | `G28 X` | X carriage moves to the physical left endstop and stops cleanly | Yes — watch the motion, confirm no grinding/skipped steps |
| 3 | Home Y | `G28 Y` | Y bed/gantry moves to the physical endstop and stops cleanly | Yes — watch the motion |
| 4 | Home Z (BLTouch) | `G28 Z` | BLTouch deploys, probes down, retracts; toolhead ends at a safe Z | Yes — watch the probe deploy/retract and the approach speed |
| 5 | Full home | `G28` | All three axes home cleanly in sequence | Yes |
| 6 | Bed mesh (if used) | `BED_MESH_CALIBRATE` | Mesh completes without error, reasonable Z variance | Yes |
| 7 | Z offset / load-cell calibration | `Z_OFFSET_CALIBRATION` (or this project's own load-cell-based flow — see `feedback_load_cell_calibration_method.md`) | Converges to a sane, repeatable offset | Yes |
| 8 | Nozzle clear macro | `CRTENSE_NOZZLE_CLEAR` (or this project's current native equivalent) | Clears cleanly, no crash into the bed/frame | Yes |
| 9 | ADXL345 resonance / input shaper qualification | `MEASURE_AXES_NOISE`, then `SHAPER_CALIBRATE` | Produces a real shaper recommendation, no error | Yes |
| 10 | Any PLR physical-position primitive from Mission C | *(Mission C found no provable path — nothing to test here; see the Mission B/C report. If a future mission implements one, add its explicit test here before this session is reused.)* | N/A | N/A |

**Stop condition, any step**: if motion looks wrong, sounds wrong, or a
value is out of the expected range, stop immediately (emergency stop / power
off) and do not proceed — this is real physical hardware, not something to
push through "to see what happens."

**Safe to power off after this session**: yes, once every step above has
been explicitly confirmed by the owner (or the session was stopped early).
