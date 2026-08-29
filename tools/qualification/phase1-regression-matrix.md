# Phase 1 Final Regression Matrix

One row per feature. "Tomorrow regression needed?" is NO only when Phase
1.9's own changes provably do not touch that feature's dependency path
(confirmed by the diffs in this mission and Phase 1.9A/1.9B, not assumed) —
those features keep their existing hardware-qualification evidence rather
than being re-tested for no reason.

| Feature | Source verified | Build verified | Prior hardware evidence | Tomorrow regression needed? | Exact tomorrow test | Pass criterion |
|---|---|---|---|---|---|---|
| Boot (custom slot) | Yes | Yes (candidate-post-build) | Phase 1.8B qualified | No — untouched | Power on, confirm boot | Reaches Klipper `ready` |
| Stock→native GD32 restoration | Yes | Yes | Phase 1.8B qualified (candidate-002) | No — MCU lifecycle guard untouched by Phase 1.9A/1.9B (confirmed via `host-mcu-tests.sh`'s own diff-against-main check) | Session 1, step 1 (GD32 identity) | Reports native/candidate identity, no restore attempted |
| Native GD32 no unnecessary reflash | Yes | Yes | Phase 1.8B qualified | No — same as above | Session 1, step 1 (guard's last decision) | Guard's last decision shows a clean pass-through, not a restore |
| Broken-Klipper-remains-NebulaOS (no auto stock fallback) | Yes | Yes | Phase 1.8B qualified | No — untouched | — | — |
| TMC X/Y/Z | Yes | Yes | Prior phases qualified | No — untouched by 1.9A/1.9B | Session 2, step 1 | No driver warnings |
| Motion (basic X/Y/Z) | Yes | Yes | Prior phases qualified | No — untouched | Session 2, steps 2-5 | Clean, accurate motion |
| G28 (homing) | Yes | Yes | Prior phases qualified | No — SimpleAF homing.cfg untouched this mission (read, not modified — see Mission B) | Session 2, steps 2-5 | Homes cleanly on all axes |
| BLTouch | Yes | Yes | Prior phases qualified | No — untouched | Session 2, step 4 | Deploys/probes/retracts cleanly |
| Bed mesh | Yes | Yes | Prior phases qualified | No — untouched | Session 2, step 6 | Completes without error |
| HX711 / Z offset calibration | Yes | Yes | Prior phases qualified (see `feedback_load_cell_calibration_method.md`) | No — untouched | Session 2, step 7 | Converges to a sane offset |
| CRTENSE_NOZZLE_CLEAR | Yes | Yes | Phase 1.8B qualified (native nozzle-clear) | No — untouched | Session 2, step 8 | Clears without crash |
| Heaters | Yes | Yes | Prior phases qualified | No — untouched (PLR only ever *sets* heater targets via standard M104/M140, using the same command path any macro would) | Session 3 (incidental, during resume) | Targets set correctly, no direct hardware check needed beyond that |
| Fans | Yes | Yes | Prior phases qualified | No — untouched | Session 3 (incidental) | M106/M107 restore correctly |
| Extrusion | Yes | Yes | Prior phases qualified | No — untouched | — | — |
| Host MCU (klipper_mcu) | Yes | Yes | Phase 1.9A hardware-qualified (`ACCELEROMETER_QUERY` proven) | **Yes — new since 1.9A/1.9B, re-verify still healthy** | Session 1, step 2 | Process running, socket present, `[mcu rpi]` reports `mcu_version` |
| ADXL345 | Yes | Yes | Phase 1.9A hardware-qualified (real motion data confirmed, SPI polarity fix verified) | **Yes — confirm still working after this session's kernel/DTS changes** | Session 1, step 6 (connectivity) + Session 2, step 9 (resonance) | Real motion data, no "Invalid adxl345 id" |
| Resonance / input shaping | Yes | Yes | Not yet hardware-qualified (Phase 1.9A stopped before this) | **Yes — first real test** | Session 2, step 9 | Produces a real shaper recommendation |
| at24 EEPROM | Yes | Yes (this mission) | **Not yet hardware-qualified — first real test tomorrow** | **Yes** | Session 1, steps 3-5 | Bound at 2-0050, exactly 2048 bytes, write/readback/restore exact, page 0 untouched |
| PLR checkpoint correctness (candidate/promotion) | Yes (Mission A, 10 new tests) | Yes | Not yet hardware-qualified | **Yes** | Session 3, steps 1-2 | Durable checkpoint appears only after real print progress |
| PLR integrity (EEPROM/sidecar/SHA) | Yes (86 existing + Mission A tests) | Yes | Not yet hardware-qualified | **Yes**, but only as a live sanity pass — offline coverage is already extensive | Session 3, targeted checks table | Each integrity failure mode refuses as expected |
| PLR position policy | Yes | Yes | Not yet hardware-qualified | **Yes** | Session 3, steps 6-7 | Refuses by default, one-time `ALLOW_UNSAFE=1` overrides only that gate |
| PLR real resume | Yes | Yes | Not yet hardware-qualified — the one genuinely destructive test | **Yes** | Session 3, full sequence | State restored correctly, no automatic motion/M24 |
| Completion invalidation | Yes (tested) | Yes | Not yet hardware-qualified | Optional live sanity pass | Session 3 targeted table | Tombstoned, no recovery reported |
| Cancellation invalidation | Yes (tested) | Yes | Not yet hardware-qualified | Optional live sanity pass | Session 3 targeted table | Tombstoned, no recovery reported |
| File-mismatch refusal | Yes (tested) | Yes | Not yet hardware-qualified | Optional live sanity pass | Session 3 targeted table | Refused, integrity failure |
| Repeated reboot/power-cycle | Yes | Yes | Phase 1.8B qualified (boot stability) | No — untouched by this mission beyond the PLR extension itself, which is inert until a print starts | — | — |
| Stock-switch tombstone behavior | Yes (10 tests, `plr-tombstone-tests.sh`) | Yes | **Not yet hardware-qualified** — genuinely new this mission | **Yes, but low priority** — only relevant if the owner actually exercises a stock↔custom switch during qualification, not required for Phase 1 closure itself | Manually run `write_ota_marker "ota:kernel"` on custom, confirm PLR tombstoned before the actual switch, if this path is exercised | Journal shows a tombstone record; stock page 0 unchanged |

**Summary**: everything already hardware-qualified in Phase 1.8B and earlier needs no re-test (their dependency paths are provably untouched). Everything genuinely new since Phase 1.9A (host MCU, ADXL345, at24 EEPROM, the full PLR stack, stock-switch tombstone) needs its first real hardware test tomorrow — that is expected and is exactly what Session 1/2/3 are structured around.
