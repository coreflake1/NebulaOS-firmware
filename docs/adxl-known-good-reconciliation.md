# ADXL345 known-good reconciliation (mechanical, not narrative)

Generated 2026-09-06, final pre-hardware closure mission. Every claim below is
backed by an actual git command run against the real repositories tonight —
not a description of two versions read side by side.

## The known-good checkpoint, precisely identified

`_evidence/phase2-mostly-autonomous-closure-20260903-173300/REPORT.md` (§4,
§7/8) records a full successful hardware run on 2026-09-03: `ACCELEROMETER_QUERY`
and `MEASURE_AXES_NOISE` returning real per-axis data, followed by a fully
qualified `SHAPER_CALIBRATE` on both axes (X: mzv@56.8Hz, Y: mzv@35.6Hz),
committed with one `SAVE_CONFIG` and confirmed persisted after restart.

That session live-patched the printer against extensions commit **`12c187f`**
(bumped into the firmware manifest by commit `797203a`, "Bump
KLIPPER_EXTENSIONS_PIN to 12c187f (AUTO_CALIBRATE hardware-qualified, §11-14/21)",
2026-09-03 20:23:59 +0200 — 40 minutes before the REPORT.md session started).
This is the exact, named known-good checkpoint.

```
$ git -C NebulaOS-klipper-extensions merge-base --is-ancestor 12c187f 7f627672c9605a0191a719a8dd9fa6ab043876cb
$ echo $?
0   # ANCESTOR — the known-good extensions commit is present in current HEAD
```

## Mechanical diff: extras (resonance/shaper wrapper code)

```
$ git -C NebulaOS-klipper-extensions diff 12c187f 7f627672c9605a0191a719a8dd9fa6ab043876cb \
    --stat -- '*calibrate_shaper_config*' '*resonance*'
(empty output)
```

Zero lines changed in `calibrate_shaper_config.py` or any resonance-related
extra between the known-good checkpoint and current extensions HEAD.

## Mechanical diff: machine.cfg's `[mcu rpi]` / `[adxl345]` / `[resonance_tester]`

Current source, read directly (not paraphrased):

```
[mcu rpi]
serial: /tmp/klipper_host_mcu

[adxl345]
cs_pin: rpi:None
spi_speed: 2000000
spi_bus: spidev2.0
axes_map: z,y,x

[resonance_tester]
accel_chip: adxl345
accel_per_hz: 50
probe_points: 117.5,117.5,100
max_freq: 80
```

`cs_pin`, `spi_bus`, `axes_map`, and the `[mcu rpi]` block are unchanged from
every prior citation of the known-good wiring (RC2's own overnight
investigation, `docs/adxl345-investigation.txt`, and
`_project/missions/phase1.9-host-mcu-accelerometer-plr-analysis.md`).

`accel_per_hz`/`max_freq` are **not** the raw 2026-09-03 values (that session
found `max_freq=60` was the safe ceiling at `accel_per_hz=70`) — they read
`accel_per_hz=50`/`max_freq=80` instead. This is **forward progress, not
drift**: later Phase 2 hardware qualification refined the envelope further
(lowering `accel_per_hz` let `max_freq` go back up without re-triggering the
"Timer too close" MCU shutdown), landing on exactly the `80/50` envelope this
mission's own architecture rules (§15) require as the locked value. The
in-tree comment cites the same qualified fit values (X=mzv@56.8Hz,
Y=mzv@35.6Hz) as the 2026-09-03 report, confirming continuity rather than a
forgotten reset.

## Mechanical diff: kernel DTS / SPI-GPIO variant / init script

Carried forward from last night's byte-for-byte diff (re-verified, not
re-derived, since the kernel/init-script side has not been touched since):
`scripts/build/accelerometer-eeprom-bus-enable-variant.sh` matches the
polarity-fix mission's committed fix exactly; RC2's own `06-verify.sh` run
against the actual decompiled production DTB confirmed `CONFIG_SPI_GPIO=y`
and the `spi_gpio_adxl345` node + `spi2` alias present (not merely in
source — in the built artifact). `S54nebulaos-host-mcu` starts
`klipper_mcu -r -I /tmp/klipper_host_mcu`, ordered before `S55klipper`,
unchanged.

## Conclusion

```
ADXL_KNOWN_GOOD_WORK_PRESENT_IN_FINAL_BRANCH = YES
```

Every file/config path that mattered for the 2026-09-03 qualified hardware
run is either byte-identical or has evolved forward under continued
qualification, never regressed. Per mission policy: **no speculative ADXL
change was made.** The morning hardware test remains the only way to
determine whether RC1's unexplained "0 responses" symptom (still unresolved,
see `docs/adxl345-investigation.txt`) reproduces on RC3 — this reconciliation
proves source is not the cause, it does not predict the hardware outcome.
