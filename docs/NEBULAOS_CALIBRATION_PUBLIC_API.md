# NebulaOS canonical calibration API (Phase 2 calibration-framework mission)

Backed by `NebulaOS-klipper-extensions`' `extras/nebulaos_calibration.py`
(the coordinator, `[nebulaos_calibration]`) and `extras/z_compensate.py`
(legacy/compatibility surface, `[z_compensate]`). Works from Mainsail or a
plain Klipper console - no touchscreen required. No GuppyScreen source has
been modified; a future GuppyScreen phase is expected to migrate to this
same backend.

## Implemented so far (this mission's first slice)

| Command | Notes |
|---|---|
| `NEBULAOS_Z_OFFSET_CALIBRATE [METHOD=LOAD_CELL\|MANUAL] [X=.. Y=..]` | `METHOD=LOAD_CELL` (default): a fresh automatic BLTouch probe paired with a validated HX711 nozzle-contact reading at the same point (`extras/nebulaos_probe_pair.py`), applied live to the registered probe's own `z_offset` and staged via `configfile.set()`. `METHOD=MANUAL`: starts stock `PROBE_CALIBRATE` (continue with `TESTZ`/`ACCEPT`/`ABORT`) - no duplicate paper-test logic. |
| `NEBULAOS_PID_CALIBRATE_BED [TARGET=..]` | Thin wrapper over stock `PID_CALIBRATE HEATER=heater_bed`, default target 65C. |
| `NEBULAOS_PID_CALIBRATE_HOTEND [TARGET=..]` | Thin wrapper over stock `PID_CALIBRATE HEATER=extruder`, default target 230C. |
| `NEBULAOS_BED_MESH_CALIBRATE [PROFILE=..]` | Stock `BED_MESH_CALIBRATE` + `BED_MESH_PROFILE SAVE`, default profile name `nebulaos_calibration`. |
| `NEBULAOS_CALIBRATION_STATUS` | Reports the coordinator's current Z-offset calibration state; also available via `printer.objects.query`/`subscribe` on `nebulaos_calibration` (`get_status()`). |
| `NEBULAOS_NOZZLE_CLEAN` | Canonical name for the existing native load-cell nozzle-wipe sequence (registered by `[z_compensate]`, same handler as `CRTENSE_NOZZLE_CLEAR`). |

## Compatibility aliases (unchanged, kept because GuppyScreen already calls them)

| Alias | Canonical equivalent |
|---|---|
| `CRTENSE_NOZZLE_CLEAR` | `NEBULAOS_NOZZLE_CLEAN` (same handler, not a separate implementation) |
| `Z_OFFSET_CALIBRATION` | Predates `NEBULAOS_Z_OFFSET_CALIBRATE METHOD=LOAD_CELL`; NOT yet rewired to delegate to it - still its own, separately-tested implementation. See "Not yet implemented" below. |

## Not yet implemented (see the Phase 2 mission status report for the full list)

- `NEBULAOS_AUTO_CALIBRATE` and its preflight/sequencing/transaction/journal
  machinery.
- `NEBULAOS_AXIS_TWIST_CALIBRATE` (`[axis_twist_compensation]` activation +
  METHOD=LOAD_CELL/MANUAL).
- `NEBULAOS_Z_OFFSET_AND_MESH`.
- `NEBULAOS_INPUT_SHAPER_CALIBRATE` (guided workflow).
- `NEBULAOS_E_STEPS_CALIBRATE` (guided workflow) and its GuppyScreen
  compatibility macros (`CALIBRATE_ESTEPS` etc.).
- `NEBULAOS_CALIBRATION_CONTINUE` / `NEBULAOS_CALIBRATION_CANCEL`.
- Rewiring `Z_OFFSET_CALIBRATION`/`PID_CALIBRATE_BED`/`PID_CALIBRATE_HOTEND`
  to become thin aliases of the new canonical commands (they currently
  remain their own, pre-existing, separately-tested implementations).
- Legacy/belt-pluck command removal.
