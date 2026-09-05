# RC2 morning hardware acceptance procedure

Generated 2026-09-06 during the RC2 overnight closure mission (printer
powered off all night — nothing below has been run on real hardware yet).
Keep this short and executable; each step names exactly what to check and
against what.

Before starting: read `RC2-MANIFEST.txt` (workspace root) for the exact
artifact hashes and source SHAs this procedure verifies.

## FLASH / BOOT

1. Verify local RC2 artifact hashes against `RC2-MANIFEST.txt`
   (`sha256sum` both `xImage` and `rootfs.squashfs`).
2. Flash `xImage`/`rootfs.squashfs` to the spare slot.
3. Raw partition readback SHA256 — confirm it matches the manifest exactly
   (catches a truncated/corrupted transfer before first boot).
4. Boot RC2, flip the OTA marker only after Klipper/Moonraker are
   confirmed healthy (the existing automatic safety net).
5. Verify exact build/source identity: `printer/info`'s reported firmware
   version, and `git rev-parse HEAD` for both `/opt/klipper` and the
   extensions checkout, against `RC2-MANIFEST.txt`.

## KLIPPER PRISTINE-NESS (new tonight — see docs/klipper-dirty-investigation.txt)

6. `git -C /opt/klipper status --porcelain` and
   `git -C /opt/nebulaos-klipper-extensions status --porcelain` — expect
   both empty.
7. Check the boot log (`S05nebulaos-activate`'s output, e.g.
   `logread` / dmesg / the init log) for a
   `WARNING: ... is not pristine ...` line from `compose_ensure()` —
   expect absent.
8. `printer/info`'s `software_version` should read `58bd67d` with no
   `-dirty` suffix.
9. If either check 6 or 7 still shows dirty content: this run's fix
   (`core.fileMode=false`) has already ruled out the permission-bit
   hypothesis — capture the FULL `git status --porcelain` AND `git diff`
   output this time (never previously done in this project's history) and
   file it as a new, better-instrumented follow-up.

## MAINSAIL — macro groups (new tonight)

10. If this is an EXISTING install carrying the old underscore group IDs:
    confirm all six migrated to hyphenated IDs
    (`GET /server/database/item?namespace=mainsail&key=macros.macrogroups.nebulaos-calibration`
    etc. via Moonraker's API, or the Mainsail Macros settings page) and
    that the old underscore keys are gone.
11. Confirm `macros.mode` reads `expert` (fresh install: seeded
    automatically; existing install with no prior value: also seeded —
    see docs/klipper-dirty-investigation.txt's sibling commit message for
    why this counts as "genuinely untouched," not an override of a real
    user choice).
12. Confirm all six Expert groups (Calibration, Input Shaper, Extruder,
    Camera, Maintenance, Recovery) visibly render as dashboard panels —
    this was never actually confirmed in a browser on any prior build (see
    the RC1 evidence review); Mainsail is expected to auto-synthesize
    these panels from `macros.mode=expert` with no separate layout seeding
    (confirmed by reading the vendored dist source directly), so simply
    opening the dashboard is the first real test of this claim.
13. Confirm group contents/order match
    `scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros`'s
    `DEFAULT_GROUPS`.
14. Confirm no stale legacy panel remains (nothing named
    `macrogroup_nebulaos_<anything with an underscore>`).
15. Switch to Simple mode, reboot, confirm Simple remains selected (never
    forced back to Expert).

## MAINSAIL — hardware/sensor surface

16. Compare actual visible Mainsail hardware/sensors against
    `docs/NEBULAOS_MAINSAIL_SENSOR_INVENTORY.md` (33 objects catalogued;
    expect all `SHOULD_BE_VISIBLE=Yes` entries present, no duplicates).
17. Confirm no duplicate temperature/fan/sensor/MCU object.
18. Confirm all expected live values update (extruder/bed temps, both
    MCUs' identity, part/hotend/board fans).

## MACRO COUNT (new tonight)

19. On a genuinely fresh/reset `printer_data/config` (or a fresh virgin
    install): confirm the macro count is ~49 (47 `[gcode_macro]` + 2
    `[delayed_gcode]`), matching
    `docs/NEBULAOS_RUNTIME_MACRO_PROVENANCE.md` — NOT 83. If testing on the
    same long-lived physical unit used throughout Phase 2 (which still has
    accumulated stale SimpleAF/GuppyScreen-era macros in its persistent
    `printer_data/config`), this comparison is not meaningful until that
    device's config is reset — do not treat a stale count as a new defect.

## MCU STOCK HANDOFF (see docs/mcu-stock-handoff-investigation.txt)

20. Record native MCU identity.
21. Execute the existing switch-to-Stock flow (no NebulaOS code changes
    were made here tonight — see investigation doc for why).
22. Shutdown, hard power cycle.
23. Capture Stock S13 logs.
24. Run experiment 1 from `docs/mcu-stock-handoff-investigation.txt`: time
    the Creality bootloader's handshake window on this boot (scope/logic
    analyzer or a tightly-timestamped serial capture) — this is the
    central open question, not just pass/fail.
25. If time/tooling allows, run experiment 2 (the stranded-MCU control)
    from the same doc to directly confirm or refute this session's
    "healthy application closes the window too fast" hypothesis.
26. Switch back to NebulaOS, hard power cycle, prove S50 detects the
    correct state and native Klipper connects.

## ADXL345 (see docs/adxl345-investigation.txt)

27. Run `ACCELEROMETER_QUERY`. **Capture the FULL `klippy.log`** for this
    query (not a tail) and the exact console/gcode response text, and save
    both — this exact artifact was missing from every prior RC1 test and
    is the single biggest gap in last night's investigation.
28. If it fails again identically: immediately re-run it 2-3 more times in
    direct succession (rules out a one-off startup race without any code
    change).
29. If it fails consistently: physically re-seat/inspect the ADXL345
    module's SPI wiring, then re-test once.
30. Guided Input Shaper workflow integration
    (`NEBULAOS_INPUT_SHAPER_CALIBRATE`) — only proceed past step 27 if
    accelerometer data is flowing.

## REMAINING CORE QUALIFICATION

31. Full Auto Calibration (`NEBULAOS_AUTO_CALIBRATE`) end to end.
32. Restart/persistence/journal verification (one `SAVE_CONFIG`, one
    restart, confirm the journal/config actually persisted).
33. Real PLR interrupted-print recovery (a genuine mid-print power pull,
    then `NEBULAOS_RESUME_POWER_LOSS`).
34. Filament load/unload/`M600`/purge/resume.
35. Camera LOW/MED/HIGH quality presets — this was never actually attempted
    on RC1 (not merely skipped-and-noted; the hardware-acceptance evidence
    has no record of it at all).
36. Small real `START_PRINT` -> print -> `END_PRINT`.
37. Final service/log sanity sweep.

E-Steps physical 100 mm measurement remains deferred by product decision.
GuppyScreen functional testing remains deferred (binary shipped, no
config/backend dependency — unchanged tonight).
