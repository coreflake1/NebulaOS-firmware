# Pristine mainline Klipper invariant

Restated explicitly for the Phase 2 calibration-framework mission's Axis
Twist slice, though the invariant itself predates this mission (Phase 1
no-fork migration, 2026-08-17 - see `PROJECT_CONTEXT.md`).

The pinned upstream Klipper checkout
(`KLIPPER_PIN=58bd67db3ce1be1951c3e4a6d1156a79903d4edc`,
`manifests/dependencies.conf`) must remain completely pristine, official,
unmodified `Klipper3d/klipper`. NebulaOS extends Klipper only through:

- new files in `NebulaOS-klipper-extensions/extras/`, symlinked into the
  Klipper checkout's `klippy/extras/` at compose time
  (`etc/nebulaos-klipper-compose.sh`);
- NebulaOS configuration (`.cfg` files);
- NebulaOS macros/build composition.

Never through: edits to an upstream Klipper file, a Klipper fork, a patch
series, replacing an upstream module, a NebulaOS file that shadows an
upstream `klippy/extras/*.py` filename, or runtime/global monkeypatching
of an upstream class.

Concretely relevant to Axis Twist: `klippy/extras/axis_twist_compensation.py`,
`probe.py`, and `manual_probe.py` are never modified, never replaced, and
never given a same-named NebulaOS counterpart. `extras/nebulaos_calibration.py`
(`NebulaOS-klipper-extensions`) integrates with the real, unmodified
`axis_twist_compensation.AxisTwistCompensation`/`Calibrater` objects
entirely through their own already-public instance attributes and methods
(`clear_compensations()`, `calibrater.results`/`current_axis`/`gcmd`,
`calibrater._finalize_calibration()`) - see that file's own header comment
for the full reasoning and citations.

## Enforcement

Three layers, all real and automated (not merely documented intent):

1. **Build-time, mechanism-level** (`NebulaOS-firmware/scripts/build/etc/
   nebulaos-klipper-compose.sh`): `compose_build()`'s Pass 1 refuses to
   compose at all if upstream ships a regular file at any path a NebulaOS
   module also manages (a real filename collision); `compose_verify_pristine()`
   asserts `git status --porcelain` is empty on BOTH the Klipper and
   extensions checkouts after every composition, catching any
   modification, not only a collision. Exercised against synthetic
   fixtures in `tests/klipper-composition-tests.sh` (see its own
   "collision guard" section).

2. **Static, real-data, offline** (`tests/klipper-extras-collision-tests.py`,
   new in this mission): the mechanism-level tests above prove the GUARD
   works correctly in general, using synthetic fixtures - they do not, by
   themselves, prove today's actual manifest is collision-free against
   today's actual pinned Klipper file list. This script does exactly that,
   in milliseconds, no build container needed: reads the manifest's real
   declared module basenames, reads the real pinned checkout's real
   `klippy/extras/*.py` filenames, and asserts zero overlap - plus an
   explicit, named check that `axis_twist_compensation.py`/`probe.py`/
   `manual_probe.py` are genuinely absent from
   `NebulaOS-klipper-extensions/extras/`, and that the pinned checkout is
   git-pristine.

3. **Test-level parity, not production code**: `NebulaOS-klipper-extensions/
   extras/test_nebulaos_axis_twist.py`'s `RealUpstreamParityTest` imports
   the real pinned `axis_twist_compensation.py` directly (a test-only
   dependency, never shipped as a runtime module, via a synthetic package
   registration that avoids any `extras`-name collision with this repo's
   own package - see that test file's own `setUpClass` comment) and runs
   this project's own coordinator against the real, unmodified upstream
   objects end to end - the strongest available proof, short of real
   hardware, that the integration is correct without ever touching
   upstream's own source.
