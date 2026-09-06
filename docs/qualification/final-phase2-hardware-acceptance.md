# Final Phase 2 hardware acceptance procedure (RC3)

Generated 2026-09-06 during the final pre-hardware source closure mission
(printer powered off all night — nothing below has been run on real
hardware). Read `FINAL-PREHW-RC-MANIFEST.txt` (workspace root) first for
this exact build's hashes and source SHAs.

This build carries everything RC2 had (Mainsail hyphenated IDs/migration/
Expert default, Klipper composition pristine-check fix) plus tonight's
closure: mechanical proof every historical Phase 1/Phase 2 change survives
in source, the stale `load_cell_probe.cfg` removed, and
`Z_OFFSET_CALIBRATION`'s real GuppyScreen dependency documented and tested.
Nothing ADXL345 or MCU-stock-handoff-related changed in source tonight —
both were mechanically reconciled against their known-good checkpoints and
found unchanged, so the morning tests for those two items are unchanged
from RC2's own procedure, repeated here for a self-contained checklist.

## A. FLASH / IDENTITY

1. Verify local artifact hashes against `FINAL-PREHW-RC-MANIFEST.txt`.
2. Flash exact `xImage`/`rootfs.squashfs`.
3. Raw partition readback SHA256 match.
4. Boot RC3.
5. Verify exact source identity: `printer/info`'s firmware version and
   `git rev-parse HEAD` for both `/opt/klipper` and the extensions
   checkout, against the manifest.
6. `git -C /opt/klipper status --porcelain` /
   `git -C /opt/nebulaos-klipper-extensions status --porcelain` both
   empty; boot log has no `compose_ensure()` pristine `WARNING:` line;
   `printer/info`'s `software_version` reads `58bd67d`, no `-dirty`.

## B. MAINSAIL

7. Existing-install only: confirm all six underscore group IDs migrated
   to hyphenated form, old keys gone.
8. Confirm `macros.mode` reads `expert` (fresh or genuinely-untouched
   existing install).
9. **Open the dashboard in a browser and look** — confirm all six Expert
   groups (Calibration, Input Shaper, Extruder, Camera, Maintenance,
   Recovery) actually render as panels. This has never been directly
   confirmed on any prior build; Mainsail's own source shows it should
   auto-synthesize these panels from `macros.mode=expert` with no separate
   layout write, so this step is the real test of that claim.
10. Confirm group contents/order match
    `scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros`'s
    `DEFAULT_GROUPS`.
11. Confirm no stale legacy panel (nothing named
    `macrogroup_nebulaos_<anything with an underscore>`).
12. Switch to Simple, reboot, confirm Simple remains selected.

## C. MAINSAIL SENSORS / HARDWARE

13. Compare actual visible Mainsail hardware/sensors against
    `docs/NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md` (32 objects — one fewer
    than RC2's 33, since `load_cell_probe.cfg` is gone).
14. Confirm no duplicate temperature/fan/sensor/MCU object.
15. Confirm all expected live values update.
16. Confirm `/etc/nebulaos/klipper/load_cell_probe.cfg` is genuinely
    absent from the booted device (`ls` or Moonraker's file API against
    the image-owned config path) — should already be caught by
    `06-verify.sh`'s build-time check, this is the live-device echo of it.

## D. MACRO COUNT

17. On a genuinely fresh/reset `printer_data/config`: confirm the macro
    count is 49 (47 `[gcode_macro]` + 2 `[delayed_gcode]`) per
    `docs/NEBULAOS_RUNTIME_MACRO_PROVENANCE.md`. On the same long-lived
    test unit used throughout Phase 2, this comparison is not meaningful
    until that device's config is reset.

## E. ADXL / INPUT SHAPER (source unchanged tonight — see docs/adxl-known-good-reconciliation.md)

18. Run `ACCELEROMETER_QUERY`. **Capture the FULL `klippy.log`** for this
    query (not a tail) plus the exact console response — the single
    missing artifact from every prior RC1/RC2 test of this.
19. If it fails again identically: re-run 2-3 times immediately (rules out
    a one-off startup race with no code change).
20. If it fails consistently: physically re-seat/inspect the ADXL345
    module's SPI wiring, then retest once.
21. If passing: run the guided `NEBULAOS_INPUT_SHAPER_CALIBRATE` workflow
    and compare the fit against the previously qualified region (X: mzv
    near 56.8Hz, Y: mzv near 35.6Hz, within the locked 80Hz/50 envelope).
22. Do not pre-classify this as a source regression — mechanical
    reconciliation tonight proved config/kernel/init-script identical to
    the last confirmed-working hardware state (2026-09-03).

## F. MCU STOCK ROUND TRIP (source unchanged tonight — see docs/mcu-lifecycle-reconciliation.md)

23. Record native MCU identity.
24. Switch to Stock via the existing flow (unchanged tonight - no code to
    re-test differently).
25. Hard power cycle.
26. Capture Stock's `S13mcu_update` logs.
27. **Time the Creality bootloader's handshake window** (scope/logic
    analyzer, or a tightly-timestamped serial capture) — this is the
    central open question from tonight's reconciliation, not just
    pass/fail.
28. If tooling allows: as a control, deliberately strand the MCU via the
    guard-style code (never the bare `creality_flash.py` CLI — see the
    candidate-002 report's own operational learning), hard power cycle,
    and confirm `S13mcu_update` DOES catch it — directly testing the
    "healthy application closes the window too fast" hypothesis.
29. Switch back to NebulaOS, hard power cycle, prove S50 detects and
    restores correctly, native Klipper connects.

## G. REMAINING CORE INTEGRATION

30. Full Auto Calibration (`NEBULAOS_AUTO_CALIBRATE`) end to end.
31. Restart/persistence/journal verification.
32. Real PLR interrupted-print recovery.
33. Filament LOAD/UNLOAD/`M600`/PURGE/RESUME.
34. Camera LOW/MED/HIGH — never actually attempted on any prior build.
35. Small real `START_PRINT` -> print -> `END_PRINT`.
36. Final service/log sanity sweep.

E-Steps physical 100mm measurement remains deferred by product decision.
GuppyScreen functional testing remains deferred to the final UI phase —
its recalibration wizard's dependency on `Z_OFFSET_CALIBRATION` (confirmed
tonight, not tested live) is worth a quick manual check if time allows,
but is not required for Phase 2 core qualification.

## If everything above passes

This is the point this mission's brief describes as ready for: qualifying
the Phase 2 core baseline. That step — creating/moving the qualified
baseline or tag — is deliberately NOT done by this or any prior overnight
mission; it is the next session's own explicit action once every item
above is confirmed PASS.
