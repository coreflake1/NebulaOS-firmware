# MCU Lifecycle Guard

Phase 1.8B Workstream B: boot-time MCU identity verification for the
GD32F303RET6 on Creality Ender-3 V3 KE.

## Problem

Booting the stock Creality OS slot automatically overwrites the MCU with
old firmware. NebulaOS needs a boot-time guard that verifies MCU identity
BEFORE Klipper starts, so that:

- A correct native MCU is confirmed and Klipper starts normally.
- A stock-clobbered MCU is detected (and, in a future phase, restored).
- A hardware mismatch or unresponsive MCU is caught before Klipper
  attempts communication with a misconfigured or absent MCU.

## 9-Case State Matrix

The MCU lifecycle has these possible states at boot:

| Case | State at boot | Guard action | Phase |
|------|--------------|-------------|-------|
| 1 | Native firmware present, correct identity | PASS - start Klipper normally | **1.8B (implemented)** |
| 2 | Native firmware present, wrong identity | FAIL - block Klipper (hardware mismatch) | **1.8B (implemented)** |
| 3 | Stock firmware present (after stock boot clobbered MCU) | Restore candidate-001 | Deferred |
| 4 | Bootloader-only (CRC fail, waiting for flash) | Restore candidate-001 | Deferred |
| 5 | MCU not responding on serial | WARN - let Klipper try (timing/hardware fault) | **1.8B (implemented)** |
| 6 | Native firmware, identity query fails | WARN - let Klipper try | **1.8B (implemented)** |
| 7 | Unknown firmware (not native, not stock) | FAIL - block | Deferred |
| 8 | Flash restore succeeds | Start Klipper | Deferred |
| 9 | Flash restore fails | FAIL - block (no infinite retry) | Deferred |

### Phase 1.8B scope (identity check only)

Cases 1, 2, 5, and 6 are implemented. The service is **read-only** - it
queries the MCU's identity via the bootloader protocol and logs the
finding. It never flashes, erases, or writes to the MCU.

### Deferred scope (automatic flash restoration)

Cases 3, 4, 7, 8, and 9 require:
- Hardware qualification of the flash-restore path on real hardware.
- Validation that creality_flash.py's `flash()` function works reliably
  from an init.d context (serial timing, baud switching, bootloader
  window).
- A candidate-001 firmware image deployed alongside the guard.
- Bounded retry logic (at most one restore attempt per boot).

These will be implemented in a future phase after the identity-check
path has been proven on hardware.

## Architecture

### Boot sequence position

```
S05nebulaos-activate
  |
S40nebulaos-ntpsync
  |
S45nebulaos-cleanup
  |
S50nebulaos-mcu-guard  <-- identity check here
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

**S50nebulaos-mcu-guard** (shell, init.d service):
- Calls the Python helper to perform the identity check.
- Parses the structured key=value output.
- Writes a state file to `/run/nebulaos-mcu-guard.state` (tmpfs).
- Exits 0 (allow Klipper) or 1 (block Klipper) based on the result.

**mcu_identity_check.py** (Python helper):
- Imports `creality_flash` from the MCU tooling repo.
- Opens `/dev/ttyS1` as a `SerialTransport`.
- Calls `identify()` which does: `enter_bootloader()` then `get_version()`.
- **Always calls `app_start()` to return the MCU to application mode.**
- Prints structured output: `MCU_GUARD_RESULT`, `MCU_IDENTITY`, `MCU_GUARD_DETAIL`.

### Protocol detail

The `identify()` function in creality_flash.py performs:

1. Set baud to 230400 (application baud).
2. Send 32-byte bootloader-request magic.
3. Wait 1 second.
4. Switch to 115200 (bootloader baud).
5. Send handshake byte (0x75), expect 0x75 back.
6. Send version request (0x00, 0xFF), read 26-byte response.
7. Parse version string from response (25 bytes + 1 checksum).

After `identify()`, the helper must call `app_start()` (sends 0x02, 0xFD)
to return the MCU from bootloader to application mode. This is critical
because:
- The bootloader has a ~15-second handshake window.
- If left in bootloader mode, Klipper cannot connect to the MCU.
- `app_start()` is a no-op if the MCU is already in application mode.

### State file

Written to `/run/nebulaos-mcu-guard.state` (tmpfs, lost on reboot):

```
MCU_GUARD_RESULT=PASS|WARN|FAIL
MCU_IDENTITY=<version string from bootloader>
MCU_GUARD_DETAIL=<human-readable detail>
MCU_GUARD_TIMESTAMP=<ISO 8601 UTC>
MCU_GUARD_EXPECTED=mcu0_001_G32
```

## Hardware configuration

| Parameter | Value |
|-----------|-------|
| MCU | GD32F303RET6 |
| Serial port | /dev/ttyS1 |
| Application baud | 230400 |
| Bootloader baud | 115200 |
| Expected hardware ID | mcu0_001_G32 |
| Candidate-001 SHA256 | c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c |

## Hardware test plan

Before the guard service can be deployed to a real device, these tests
must pass on actual KE hardware:

### Identity check qualification (Phase 1.8B)

1. **Cold boot identity check**: Power cycle the printer. Verify the
   guard correctly identifies the native MCU firmware before Klipper
   starts. Check `/run/nebulaos-mcu-guard.state` for PASS result.

2. **Timing validation**: Measure the time from guard start to Klipper
   start. The identity check (magic -> handshake -> version -> app_start)
   should complete in under 10 seconds. Verify Klipper starts normally
   after the guard completes.

3. **Serial recovery**: After the identity check, verify Klipper can
   connect to the MCU normally. The `app_start()` call should return the
   MCU to application mode without interfering with Klipper's own serial
   connection.

4. **Failure mode**: Disconnect the MCU serial cable and boot. Verify
   the guard logs WARN and allows Klipper to start (Klipper will fail on
   its own, but the guard should not be the blocker).

### Flash restoration qualification (deferred)

5. **Stock-clobber detection**: Boot stock, then boot NebulaOS. Verify
   the guard detects that the MCU is running stock firmware (serial magic
   may fail because stock firmware does not respond to the bootloader
   magic - this is Case 3).

6. **Restore path**: After stock clobber, verify `creality_flash.py flash`
   can restore candidate-001 from an init.d context (serial timing, no
   competing serial users).

7. **Post-restore verification**: After a successful restore, verify the
   guard reports PASS on the next boot.

8. **Bounded retry**: Verify that a flash failure does not cause an
   infinite retry loop (at most one attempt per boot).

## Safety rules

1. The init.d service NEVER flashes the MCU.
2. The init.d service NEVER writes to `/dev/mmcblk0p1`.
3. The Python helper ALWAYS calls `app_start()` after querying identity.
4. The service is read-only identity verification for Phase 1.8B.
5. Automatic flash restoration requires separate hardware qualification.
