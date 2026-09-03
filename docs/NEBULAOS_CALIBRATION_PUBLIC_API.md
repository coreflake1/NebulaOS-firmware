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
| `PID_CALIBRATE_BED [BED_TEMP=..]` | SimpleAF-vendored (`simpleaf/useful_macros.cfg`), not NebulaOS code: stock `PID_CALIBRATE HEATER=heater_bed`, default `BED_TEMP=65`, refuses while printing. `NEBULAOS_PID_CALIBRATE_BED` (a separate, NebulaOS-authored, functionally-duplicate wrapper with no such guard) was removed 2026-09-04 in favor of this one - see `NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md`. |
| `PID_CALIBRATE_HOTEND [HOTEND_TEMP=..]` | SimpleAF-vendored, same file: stock `PID_CALIBRATE HEATER=extruder`, default `HOTEND_TEMP=230`, refuses while printing. `NEBULAOS_PID_CALIBRATE_HOTEND` removed 2026-09-04, same reason. |
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
- Rewiring `Z_OFFSET_CALIBRATION` to become a thin alias of the new
  canonical command (currently its own, pre-existing, separately-tested
  implementation). The former `NEBULAOS_PID_CALIBRATE_BED`/`_HOTEND` were
  removed entirely 2026-09-04, not rewired - see the table above.
- NOTE (2026-09-04): this whole document predates several since-completed
  slices (`NEBULAOS_AUTO_CALIBRATE`, `NEBULAOS_INPUT_SHAPER_CALIBRATE`,
  `NEBULAOS_ESTEPS_CALIBRATE`, and the removal of automatic Axis Twist -
  `NEBULAOS_AXIS_TWIST_CALIBRATE` does not exist, by final product
  decision, not as unfinished work) and needs a full refresh, not just
  this one line - flagged, not done here, to avoid an unrelated rewrite
  inside a narrowly-scoped macro-rename change.
- Legacy/belt-pluck command removal.
