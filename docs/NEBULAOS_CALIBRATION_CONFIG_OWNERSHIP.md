# Calibration config ownership (Phase 2 calibration-framework mission)

## The problem

Klipper's own `configfile.py` (`ConfigAutoSave._disallow_include_conflicts`)
refuses `SAVE_CONFIG` for any section/option that already has a literal value
anywhere in the regular (non-autosave) config text - in *any* included file,
regardless of which file the new autosave value is being written from - and
aborts the **entire** `SAVE_CONFIG` call if even one staged value conflicts,
not just that one field.

Before this mission, `[bltouch] z_offset`, `[extruder] rotation_distance`,
`control`, `pid_Kp/Ki/Kd`, and `[heater_bed] control`, `pid_kp/ki/kd` all had
literal factory-default values in the immutable, image-owned `machine.cfg`.
This made it architecturally impossible for any of the following to ever
persist a result via `SAVE_CONFIG`:

- stock `PID_CALIBRATE` / `NEBULAOS_PID_CALIBRATE_BED` / `_HOTEND`
- stock `PROBE_CALIBRATE` / `NEBULAOS_Z_OFFSET_CALIBRATE METHOD=MANUAL`
- `NEBULAOS_E_STEPS_CALIBRATE`

Moving the *value* from `machine.cfg` to `printer.cfg`'s own regular text
does **not** fix this - a literal value in `printer.cfg`'s own regular
section conflicts exactly the same way. The only way `SAVE_CONFIG` ever
succeeds for a given option is for that option to have **no** literal value
anywhere in the regular-parsed text at all.

## The fix

`machine.cfg` no longer defines any of these options. Static hardware
description and real safety bounds (`min_temp`/`max_temp`, pin assignments,
`nozzle_diameter`, etc.) stay there, unchanged.

The tracked `printer.cfg` seed
(`scripts/build/overlay/opt/printer_data/config/printer.cfg`) now ships with
a real, pre-baked Klipper `SAVE_CONFIG` autosave block - byte-for-byte the
same shape Klipper's own `cmd_SAVE_CONFIG` would produce, using the exact
`AUTOSAVE_HEADER` constant from the pinned `klippy/configfile.py`
(`58bd67db...`) - carrying this printer model's existing factory-default
values:

```
#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 0.000
#*#
#*# [extruder]
#*# control = pid
#*# pid_kp = 20.584
#*# pid_ki = 1.737
#*# pid_kd = 60.981
#*# rotation_distance = 7.530
#*#
#*# [heater_bed]
#*# control = pid
#*# pid_kp = 70.652
#*# pid_ki = 1.798
#*# pid_kd = 694.157
```

This is functionally identical, at boot, to a device that already ran
`SAVE_CONFIG` once at build time with zero calibration drift: a genuinely
fresh device gets a real, required value for every option Klipper's own
`bltouch.py`/`extruder.py`/`heaters.py` require, and a later real
calibration's `SAVE_CONFIG` simply rewrites this same block in place -
Klipper's own mechanism, not a NebulaOS-specific one.

**Verified directly against the real pinned `configfile.py`** (not merely
asserted): `tests/test_migrate_config_ownership.py`'s
`test_result_round_trips_through_real_klipper_with_no_conflicts` builds the
real `regular_fileconfig`/`autosave_fileconfig` objects via the actual
`ConfigFileReader`/`ConfigAutoSave` classes and asserts (a) none of the 8
target options are literal in the regular-parsed text, and (b) the autosave
block resolves to the correct factory values.

## Existing installations

A device provisioned by an older image still has a `printer.cfg` that
relies on the now-removed `machine.cfg` literals, and has none of these 4
sections in its own autosave block yet. `S04nebulaos-migrate`'s new
`migrate_config_ownership()` step (calling
`scripts/build/overlay/opt/nebulaos/tools/migrate_config_ownership.py`)
closes this gap once, idempotently, on the next boot after an update:

- Never touches a section that already has *any* of the target options in
  its existing autosave block (a real user calibration, however currently
  theoretically impossible, is never clobbered).
- Only adds the sections genuinely missing, seeded with the exact same
  factory-default constants the tracked `printer.cfg` seed uses - safe by
  construction, since `SAVE_CONFIG` for these fields was architecturally
  impossible before this mission, so no existing device's true persisted
  value for them could ever differ from the shipped factory default.
- Preserves any unrelated existing autosave content byte-for-byte (e.g. a
  device that has already run `LOAD_CELL_CALIBRATE`) - appends the missing
  sections onto the *same* block rather than creating a second one, which
  Klipper's own parser would not tolerate.
- Refuses and backs up, rather than guessing, on anything it cannot
  confidently parse by Klipper's own corruption rules - the tool's own
  `find_autosave_data()` is proven byte-exact against the real
  `configfile.py`'s `_find_autosave_data()` on shared fixtures
  (`test_migrate_config_ownership.py`).

See `tests/config-ownership-migration-tests.sh` for the init-script-level
wiring tests and `tests/test_migrate_config_ownership.py` for the migration
logic tests.

## What this does NOT change

- TMC `run_current` and every other static hardware value stay exactly
  where they were - only the four calibration-relevant sections above
  moved.
- No new persistence mechanism was introduced. This is entirely upstream
  Klipper's own `configfile.set()` + `SAVE_CONFIG`, unmodified.
- No Klipper core file was touched. `HOST_KLIPPER_CORE_PATCHES` remains 0.
