# PRTouch Runtime Removal Plan

Phase 1.8B Workstream D: dependency analysis and removal sequence for the
Creality PRTouch custom MCU protocol from NebulaOS.

## STATUS: REMOVAL COMPLETE (source level) — 2026-08-28

All PRTouch production modules and their dedicated test files have been
deleted from this repository. `prtouch_test_support.py` was kept (contrary
to this document's original Step 6 below) because it turned out to be
shared, generic offline test infrastructure for several non-PRTouch test
files (`test_z_offset_probe_safety.py`, `test_z_compensate_offset_safety.py`,
`test_z_compensate_reentrancy_guard.py`, `test_z_compensate_xy_reference.py`,
`test_z_offset_probe_coexistence.py`) that this plan's original dependency
table did not account for — see "Corrections to the original analysis"
below.

**This was a source-level removal, not a hardware-qualified one.** This
plan's original Step 1 ("Qualify nozzle_clear.py on hardware... Set
HARDWARE_BEHAVIOR_BLOCKED=False") was NOT followed as gate-before-removal.
Instead, per the Phase 1.8B integration-candidate decision record
(`_project/missions/phase1.8b-pre-build-review.md` and its follow-up in the
NebulaOS workspace), `HARDWARE_BEHAVIOR_BLOCKED` was flipped to `False` as a
source-activation-only step, and PRTouch was removed on the strength of that
plus full offline test coverage — real physical wipe-pad hardware
qualification of `nozzle_clear.py` has still NOT happened as of this
removal. This is a known, accepted, and explicitly documented risk (see
`extras/nozzle_clear.py`'s own module docstring), not an oversight.

### Corrections to the original analysis

The dependency table below ("PRTouch modules") undercounted
`prtouch_test_support.py`'s reach: it is not only used by
`test_prtouch_*.py`, but is also imported as generic offline
Klipper-fake infrastructure by five test files with no PRTouch subject
matter of their own. Those five files each also happened to instantiate a
real `prtouch_v2.PRTouchV2` object in their own local `_build()` helpers —
purely incidental leftover from when `z_compensate.py` used to look up
`prtouch_v2` at `klippy:connect`, which it no longer does since the prior
commit on this branch. All five were fixed (import and instantiation
removed) before PRTouch's production modules were deleted, and
`prtouch_test_support.py`'s own last functional dependency on real PRTouch
code (`from . import prtouch_mcu`, used only for three async-response format
constants) was replaced with the equivalent literal strings inlined
directly, verified against `prtouch_mcu.py`'s exact values before deletion.

### Files deleted (production)
`prtouch_v2.py`, `prtouch_probe.py`, `prtouch_mcu.py`, `prtouch_nozzle.py`,
`prtouch_calibration.py`, `prtouch_units.py`, `prtouch_safety_guard.py`
(this last one had zero production callers even before this removal, only
its own dedicated test — confirmed again at removal time).

### Files deleted (dedicated tests)
`test_prtouch_calibration.py`, `test_prtouch_config.py`,
`test_prtouch_orchestration.py`, `test_prtouch_probe_safety_hardening.py`,
`test_prtouch_protocol.py`, `test_prtouch_raw_op_guard.py`,
`test_prtouch_safety_guard.py`, `test_prtouch_serial_response.py`,
`test_prtouch_units.py`.

### Files kept
`prtouch_test_support.py` — decoupled from real PRTouch code (see above),
still used by the five shared test files named above.

### Not addressed by this removal (separate scope)
- `NebulaOS-firmware/scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg`
  and the commented-out `[prtouch_v2]` include in that repo's printer.cfg —
  a different repository, out of scope for this change.
- `NebulaOS-firmware/klippy_extras/` still mirrors the (now-deleted) PRTouch
  files as of this removal — that mirror is documented as a "reviewable
  mirror, NOT the real build input" (`manifests/dependencies.conf` in that
  repo) and needs its own follow-up PR in that repo to stay in sync.

## Original analysis (historical, kept for reference below)

## Current state

PRTouch is **inactive for probing** (BLTouch is the global Klipper probe;
nebulaos_z_offset_probe handles Z-offset calibration). PRTouch is retained
on disk solely because CRTENSE_NOZZLE_CLEAR in z_compensate.py calls
prtouch_nozzle.clear_nozzle(), which uses PrtouchProbe.touch_probe() for
two wipe-pad Z probes.

`[prtouch_v2]` is **commented out** in printer.cfg. If uncommented, Klipper
would load it, register its custom MCU commands (start_step_prtouch,
start_pres_prtouch, etc.), and consume HX711 pins PA4/PC6 — conflicting
with nebulaos_z_offset_probe's own HX711 usage.

## PRTouch modules (NebulaOS-klipper-extensions/extras/)

| Module | Role | Depends on | Depended on by |
|--------|------|-----------|----------------|
| prtouch_v2.py | Runtime entry point, Klipper load_config | prtouch_mcu, prtouch_probe, prtouch_nozzle | z_compensate.py (lookup_object, optional) |
| prtouch_probe.py | Probe engine, touch_probe() | prtouch_calibration, prtouch_units | prtouch_v2, prtouch_nozzle.clear_nozzle() |
| prtouch_mcu.py | MCU command protocol | prtouch_units | prtouch_probe |
| prtouch_nozzle.py | Nozzle wipe, ClearNozzleConfig, NozzleHeaters | (none — uses probe arg) | z_compensate.py (import + clear_nozzle call) |
| prtouch_calibration.py | Pure math (compute_trigger_z, filters) | (none) | prtouch_probe |
| prtouch_units.py | Unit conversion (steps, ticks) | (none) | prtouch_mcu, prtouch_probe |
| prtouch_safety_guard.py | Movement guard for dev sessions | (none) | prtouch_v2 (optional) |
| prtouch_test_support.py | Fake/mock infrastructure | prtouch_mcu | All test_prtouch_*.py files |

## Test modules

| Module | Tests |
|--------|-------|
| test_prtouch_calibration.py | compute_trigger_z math |
| test_prtouch_config.py | Config parsing, command registration |
| test_prtouch_orchestration.py | Probe orchestration |
| test_prtouch_probe_safety_hardening.py | Safety hardening |
| test_prtouch_protocol.py | MCU protocol format |
| test_prtouch_raw_op_guard.py | Raw operation guard |
| test_prtouch_safety_guard.py | Movement guard |
| test_prtouch_serial_response.py | Serial response handling |
| test_prtouch_units.py | Unit conversion |

## z_compensate.py dependencies on PRTouch

### Import statements (lines 42-44)
```python
from . import prtouch_mcu
from . import prtouch_nozzle
from . import prtouch_probe
```

### Runtime lookups
- Line 192: `self.prtouch = self.printer.lookup_object('prtouch_v2', None)` — optional, None default
- Line 88: `self.clear_nozzle_config = prtouch_nozzle.ClearNozzleConfig(config)` — config read at init
- Line 348-358: `cmd_nozzle_clear()` — checks `self.prtouch`, uses `self.prtouch.probe` and `self.prtouch.heaters`
- Line 306-327: `_probe_overrides()` — temporarily patches prtouch_probe attributes

### Exception types
- Line 356: catches `prtouch_probe.PrtouchProbeSafetyError`
- Line 357: catches `prtouch_mcu.PrtouchProtocolError`

## nebulaos-extensions.json manifest entries to remove

Lines 47-54 (runtime):
```json
{"path": "extras/prtouch_v2.py", "role": "runtime"},
{"path": "extras/prtouch_probe.py", "role": "runtime"},
{"path": "extras/prtouch_mcu.py", "role": "runtime"},
{"path": "extras/prtouch_nozzle.py", "role": "runtime"},
{"path": "extras/prtouch_calibration.py", "role": "runtime"},
{"path": "extras/prtouch_units.py", "role": "runtime"},
{"path": "extras/prtouch_safety_guard.py", "role": "runtime"},
{"path": "extras/prtouch_test_support.py", "role": "runtime"}
```

Lines 72-79 (test):
```json
{"path": "extras/test_prtouch_calibration.py", "role": "test"},
{"path": "extras/test_prtouch_config.py", "role": "test"},
{"path": "extras/test_prtouch_orchestration.py", "role": "test"},
{"path": "extras/test_prtouch_probe_safety_hardening.py", "role": "test"},
{"path": "extras/test_prtouch_protocol.py", "role": "test"},
{"path": "extras/test_prtouch_raw_op_guard.py", "role": "test"},
{"path": "extras/test_prtouch_safety_guard.py", "role": "test"},
{"path": "extras/test_prtouch_serial_response.py", "role": "test"},
{"path": "extras/test_prtouch_units.py", "role": "test"}
```

## What blocks removal

**CRTENSE_NOZZLE_CLEAR must be rewritten first (Workstream C).** The native
replacement module (nozzle_clear.py) exists but is marked
HARDWARE_BEHAVIOR_BLOCKED=True. Until it is hardware-qualified, the PRTouch
code path is the only working nozzle wipe implementation.

Nothing else in the codebase depends on PRTouch at runtime. Z_OFFSET_CALIBRATION
already uses nebulaos_z_offset_probe exclusively (Phase 1.8A).

## Removal sequence (when Workstream C is hardware-qualified)

### Step 1: Qualify nozzle_clear.py on hardware
- Set HARDWARE_BEHAVIOR_BLOCKED=False
- Run CRTENSE_NOZZLE_CLEAR on a real wipe pad
- Verify contact detection, Z accuracy, wipe quality
- Compare against PRTouch path behavior

### Step 2: Switch z_compensate.py to the native path
- Uncomment the `from . import nozzle_clear` import
- Uncomment `self.native_clear_nozzle_config = nozzle_clear.NozzleClearConfig(config)`
- Uncomment the native nozzle-clear block in cmd_nozzle_clear()
- Remove the PRTouch code path (the `if self.prtouch is None:` block and everything below it)
- Remove `_probe_overrides()` context manager

### Step 3: Remove PRTouch imports from z_compensate.py
- Delete `from . import prtouch_mcu`
- Delete `from . import prtouch_nozzle`
- Delete `from . import prtouch_probe`
- Delete `self.prtouch = self.printer.lookup_object('prtouch_v2', None)`
- Delete the PrtouchProbeSafetyError/PrtouchProtocolError exception handling

### Step 4: Remove prtouch.cfg from the firmware overlay
- Delete `NebulaOS-firmware/scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg`
- The commented-out include in printer.cfg can be removed

### Step 5: Remove PRTouch from the extensions manifest
- Remove all 8 runtime entries from nebulaos-extensions.json
- Remove all 9 test entries from nebulaos-extensions.json
- Add nozzle_clear.py + test_nozzle_clear_native.py to the manifest

### Step 6: Delete PRTouch source files
- prtouch_v2.py, prtouch_probe.py, prtouch_mcu.py
- prtouch_nozzle.py, prtouch_calibration.py, prtouch_units.py
- prtouch_safety_guard.py, prtouch_test_support.py

### Step 7: Delete PRTouch test files
- All 9 test_prtouch_*.py files

### Step 8: Update CURRENT_STATE.md
```
CUSTOM_PRTOUCH_MCU_COMMANDS=0
PRTOUCH_RUNTIME_DEPENDENCY=0
```

### Step 9: Update recovery-safety-tests.sh
- Remove prtouch_*.py entries from ACCEPTED_FILES list
- Add nozzle_clear.py to the list

## What can be removed immediately

**Nothing.** All PRTouch modules must be retained until the native nozzle
clear path is hardware-qualified. Removing any module now would break the
(currently commented-out but intact) PRTouch code path that is the only
known-working nozzle wipe implementation.

## Risk assessment

The removal itself is mechanically straightforward once the native path is
qualified. The primary risk is in the hardware qualification step: the native
probe uses a different contact detection algorithm (upstream Klipper's
LCBestFit vs PRTouch's custom hold-count trigger), which may behave
differently on the wipe pad surface compared to the flat bed surface where
it was qualified for Z-offset calibration.
