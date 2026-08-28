# MCU Lifecycle Guard

Phase 1.8B Workstream B: boot-time MCU identity verification (and, as of
this offline pre-build review, bounded automatic restoration) for the
GD32F303RET6 on Creality Ender-3 V3 KE.

**Revision note (offline pre-build review, same Phase 1.8B):** this
document originally described a bootloader-hardware-ID-only identity check,
with automatic flash restoration deferred to a future phase pending
hardware qualification. An offline review found that design conflated two
distinct identities: the bootloader hardware ID has been observed identical
whether candidate-001 or stock Creality firmware is installed (compare
`_evidence/phase1.8-candidate/identity-query-result.txt`, taken with
candidate-001 flashed, against `_evidence/phase1.8-candidate/phase1.8-os-candidate-004.txt`,
taken moments after the stock slot had just auto-flashed stock firmware back
on - both report `mcu0_001_G32`). A bootloader-only PASS could never
actually prove candidate-001 was running. This document now describes the
corrected design: two separately-checked identities, and restoration
implemented (behind mocks, never run against real hardware in this review)
rather than left deferred.

## Problem

Booting the stock Creality OS slot automatically overwrites the MCU with
old firmware. NebulaOS needs a boot-time guard that verifies MCU identity
BEFORE Klipper starts, so that:

- A correct native MCU application is confirmed and Klipper starts normally.
- A stock-clobbered MCU is detected and, only in that specific case,
  restoration is authorized.
- A hardware mismatch or unresponsive MCU is caught before Klipper
  attempts communication with a misconfigured or absent MCU.
- An application that's neither the known candidate nor known stock is
  never auto-flashed, on the assumption that guessing wrong is worse than
  asking a human.

## Two identities, checked separately

- **APPLICATION identity** (`mcu_application_identify.py`): which firmware
  is currently running. Read via Klipper's own MCU IDENTIFY protocol - the
  exact same handshake Klipper performs on every normal connect - without
  starting full Klippy (no Printer, no config, no toolhead). This follows
  the pattern already shipped in upstream Klipper's own `scripts/dump_mcu.py`
  (present in `58bd67db3ce1be1951c3e4a6d1156a79903d4edc`, the exact commit
  candidate-001 is built from): a bare `reactor.Reactor()` +
  `serialhdl.SerialReader()`, `connect_uart()`, then
  `get_msgparser().get_version_info()`. This is non-invasive - it doesn't
  require entering the bootloader, so a healthy native-app connection is
  never disturbed.
- **HARDWARE identity** (`creality_flash.py`'s bootloader protocol, called
  from `mcu_lifecycle.py`): is this a supported physical KE MCU. Requires
  deliberately entering the bootloader, so it is only invoked when needed:
  to gate a restore (application looked like known stock) or to get
  diagnostic context when application identity couldn't be determined.

`mcu_known_identities.py` holds the exact, non-invented values already on
file in this repo's own build evidence:
- `NATIVE_CANDIDATE_001_VERSION = "v0.13.0-742-g01a9c2f92"` - from
  `_evidence/phase1.8-candidate/klipper.dict`'s own `version` field.
- `KNOWN_STOCK_VERSIONS = ("38d96adc-dirty-20231016_135251-longer-virtual-machine",)`
  - observed identically on 2026-08-22 and 2026-08-28. This is a
  single-sample observation of one hardware unit's one firmware build, not
  a verified family/pattern - only an exact match authorizes a restore.

## State matrix

| State | Meaning | Action |
|---|---|---|
| `SUPPORTED_HW_NATIVE_APP` | Application identity exactly matches candidate-001 | `ALLOW_KLIPPER_START` - no flash, bootloader never entered |
| `SUPPORTED_HW_KNOWN_STOCK_APP` | Application identity exactly matches the known stock string, AND bootloader hw-id confirmed supported | `RESTORE_AUTHORIZED` - the only state that may flash |
| `SUPPORTED_HW_UNKNOWN_APP` | Application identity present but unrecognized, OR application identify failed but hardware checks out | `ALLOW_KLIPPER_START_WARN` - never auto-flash, diagnostics preserved |
| `UNSUPPORTED_HW` | Bootloader hw-id reachable but does not match the allow-list | `BLOCK_KLIPPER_START` - never flash, regardless of application class |
| `MCU_UNREACHABLE` | Neither application identify nor the bootloader check could reach the MCU | `ALLOW_KLIPPER_START_WARN` - bounded (one attempt), no stock fallback, let Klipper's own retry logic try |

Design decision worth stating explicitly: `SUPPORTED_HW_UNKNOWN_APP` allows
Klipper to attempt to start rather than blocking outright. Application
identify succeeding via Klipper's real protocol means the MCU is genuinely
running *some* Klipper-compatible firmware, not something alien - Klipper's
own config/pin validation is the second safety net for that case. Blocking
startup entirely would make an unrecognized-but-valid firmware update look
like total device failure. The only thing this state forbids is automatic
restoration.

## Restoration (`mcu_restore.py`)

The only module that erases/writes the MCU, and only when
`mcu_lifecycle.decide()` already returned `RESTORE_AUTHORIZED`.

- **Artifact provenance**: a NEW proposed convention (no prior on-device
  deployment path existed before this review) - the build pipeline is
  responsible for placing the exact GitHub-Actions-built candidate-001
  binary at `/opt/nebulaos/mcu-candidates/candidate-001.bin` (path
  overridable via `MCU_CANDIDATE_PATH`). Source of truth remains
  `NebulaOS-klipper-mcu` (build-time provenance in
  `_evidence/phase1.8-candidate/phase1.8-candidate-001.txt`).
- **Build-time validation** (already done, once, in `NebulaOS-klipper-mcu`'s
  CI): `creality_validator.py`'s `validate_format()`/`validate_target()`
  (ELF section placement, `.config` sanity, GD32F303-specific checks) -
  this is the step that needs `arm-none-eabi-readelf`, which is why
  `stage4_first_flash.py` needed `--skip-validator` on-device. Doing this
  once at build time, rather than on every boot, removes the on-device
  toolchain dependency entirely.
- **Runtime validation** (`mcu_restore.py`, every restore attempt):
  SHA256 verification against the pinned hash (cheap, no toolchain),
  the hardware allow-list (already checked by `mcu_lifecycle.py` before
  authorizing the call, and re-checked inside `creality_flash.flash()`
  itself), flash-result verification (status-byte checking already in
  `flash_image()`), and **post-flash application identity verification** -
  re-running the identify handshake and confirming it now reports exactly
  `NATIVE_CANDIDATE_001_VERSION`, not merely "flash reported success."
- **Bounded**: exactly one flash attempt per `restore()` call, no internal
  retry loop.

## Architecture

### Boot sequence position

```
S05nebulaos-activate
  |
S40nebulaos-ntpsync
  |
S45nebulaos-cleanup
  |
S50nebulaos-mcu-guard  <-- lifecycle decision (+ restore, if authorized) here
S50webcam
  |
S55klipper             <-- Klipper starts here (only if guard passed)
S56moonraker
  ...
S95mcu-boot-recovery   <-- handles post-Klipper MCU transients
```

S50nebulaos-mcu-guard runs before S55klipper by init.d sort order
(same S50 prefix as S50webcam; alphabetical sort: `nebulaos-mcu-guard`
< `webcam`).

### Components

- **S50nebulaos-mcu-guard** (shell, init.d service): calls
  `mcu_identity_check.py`, parses its `MCU_GUARD_RESULT=PASS|WARN|FAIL`
  line plus the diagnostic fields, writes the state file, exits 0 (allow
  Klipper) or 1 (block Klipper).
- **mcu_identity_check.py**: thin orchestrator. Calls
  `mcu_lifecycle.decide()`; if it returns `RESTORE_AUTHORIZED`, calls
  `mcu_restore.restore()` and folds its result into the final PASS/FAIL.
  Performs no serial/bootloader interaction itself.
- **mcu_lifecycle.py**: the state-machine decision (application identity
  first, bootloader hw-id only when needed).
- **mcu_application_identify.py**: the pre-Klippy Klipper-protocol
  identify handshake.
- **mcu_known_identities.py**: the pinned candidate-001/known-stock
  version strings and classification.
- **mcu_restore.py**: the bounded, gated flash-restore path.

All hardware/filesystem interaction points in `mcu_lifecycle.py` and
`mcu_restore.py` are injectable (`creality_flash_module`,
`transport_factory`, `application_identify_fn`, `file_exists_fn`,
`hash_fn`) specifically so `tests/mcu-lifecycle-decision-tests.py` can
exercise every state and CASE 1-11 from the pre-build review mission with
mocks - no real serial hardware.

### State file

Written to `/run/nebulaos-mcu-guard.state` (tmpfs, lost on reboot):

```
MCU_GUARD_RESULT=PASS|WARN|FAIL
MCU_IDENTITY=<application identity string>
MCU_GUARD_DETAIL=<human-readable detail>
MCU_GUARD_TIMESTAMP=<ISO 8601 UTC>
MCU_GUARD_EXPECTED=mcu0_001_G32
MCU_LIFECYCLE_STATE=<one of the 5 states above>
MCU_APPLICATION_IDENTITY=<application identify string, or "unknown">
MCU_APPLICATION_CLASS=NATIVE_CANDIDATE_001|KNOWN_STOCK|UNKNOWN_APPLICATION|unknown
MCU_HW_ID_STATUS=MATCH|MISMATCH|UNREACHABLE|not_checked_not_needed
MCU_RESTORE_RESULT=RESTORED_AND_VERIFIED|CANDIDATE_ARTIFACT_MISSING|CANDIDATE_HASH_BAD|FLASH_FAILED|not_attempted
```

## Hardware configuration

| Parameter | Value |
|-----------|-------|
| MCU | GD32F303RET6 |
| Serial port | /dev/ttyS1 |
| Application baud | 230400 |
| Bootloader baud | 115200 |
| Expected hardware ID | mcu0_001_G32 |
| Candidate-001 application identity | v0.13.0-742-g01a9c2f92 |
| Candidate-001 SHA256 | c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c |
| Known stock application identity | 38d96adc-dirty-20231016_135251-longer-virtual-machine |
| Proposed on-device candidate path | /opt/nebulaos/mcu-candidates/candidate-001.bin (NEW - not yet wired into build.sh) |

## Test coverage

- `tests/mcu-guard-tests.sh`: structural/plumbing checks (file existence,
  init.d ordering, no flash/erase strings in the wrong places, state file
  location, mocked shell-level PASS/WARN/FAIL dispatch).
- `tests/mcu-lifecycle-decision-tests.py`: real behavioral tests against
  `mcu_lifecycle.decide()`/`mcu_restore.restore()` with mocked
  application-identify and creality_flash collaborators - covers CASE 1-11
  from the pre-build review mission, including two explicit regression
  tests for the original hardware-ID/application-ID conflation bug.

## Hardware test plan (still required before real deployment)

Nothing in this document has been run against real hardware. Before this
guard (including the restore path) can be trusted on a real device:

1. **Cold boot identity check**: verify `mcu_application_identify.py`'s
   pre-Klippy handshake actually completes reliably against the real MCU
   at boot time, before S55klipper starts, without racing Klipper's own
   connection attempt.
2. **Timing validation**: measure guard-start to Klipper-start time with
   the new two-stage (application-first, bootloader-conditional) design.
3. **Restore path, once authorized on purpose**: verify
   `mcu_restore.restore()` actually flashes and post-verifies correctly
   from an init.d context (serial timing, no competing serial users) -
   this has only ever been exercised against mocks in this review.
4. **Artifact deployment**: wire the proposed
   `/opt/nebulaos/mcu-candidates/candidate-001.bin` path into the actual
   OS image build pipeline - this does not exist yet.
5. **Failure modes**: disconnect the MCU serial cable and boot; verify
   `MCU_UNREACHABLE` is reported and Klipper is still allowed to attempt
   its own connection.

## Safety rules

1. No erase/write occurs anywhere except inside `mcu_restore.restore()`,
   and only when `mcu_lifecycle.decide()` returned `RESTORE_AUTHORIZED`.
2. The service NEVER writes to `/dev/mmcblk0p1` or any block device.
3. Every bootloader interaction always calls `app_start()` before the
   guard process exits.
4. `UNSUPPORTED_HW` and `SUPPORTED_HW_UNKNOWN_APP` never authorize a flash,
   regardless of what the other identity looked like.
5. `mcu_restore.restore()` makes exactly one bounded attempt per call - no
   internal retry loop, no infinite retry.
6. A Klipper-only runtime failure (after S50 has already run and Klipper
   has already started) has no code path back into this guard or into
   `mcu_restore.py` - restoration is decided once, at boot, before
   S55klipper, never re-triggered by a later application-level failure.
