#!/usr/bin/env python3
"""MCU identity check helper for S50nebulaos-mcu-guard.

Queries the GD32F303 MCU's bootloader identity via the Creality serial
protocol and prints structured key=value results on stdout for the
calling init.d script to parse.

SAFETY CONTRACT:
  - This script is READ-ONLY. It enters the bootloader, queries the
    version string, and ALWAYS calls app_start() to return the MCU to
    its application firmware before exiting.
  - It NEVER calls flash_image(), flash(), or any write/erase command.
  - It NEVER writes to /dev/mmcblk0p1 or any block device.

DEPLOYMENT NOTE:
  On the target device, creality_flash.py lives in the NebulaOS-klipper-mcu
  repo and is deployed to a known path (e.g. /opt/nebulaos/tools/ or as
  part of the MCU tooling package). The CREALITY_FLASH_PATH environment
  variable can override the default import path. Integration with the MCU
  repo's deployment is tracked separately from this init.d service.

Protocol flow:
  1. Open /dev/ttyS1 at app baud (230400)
  2. Send 32-byte bootloader-request magic
  3. Switch to bootloader baud (115200)
  4. Handshake (0x75 exchange)
  5. Get version (25-byte identity + 1-byte checksum)
  6. App start (return MCU to application mode)
  7. Print result and exit
"""

import os
import sys
import time

# --- Configuration (overridable via environment) -------------------------

MCU_SERIAL_PORT = os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1")
MCU_APP_BAUD = int(os.environ.get("MCU_APP_BAUD", "230400"))
MCU_BOOTLOADER_BAUD = int(os.environ.get("MCU_BOOTLOADER_BAUD", "115200"))
MCU_EXPECTED_HW_ID = os.environ.get("MCU_EXPECTED_HW_ID", "mcu0_001_G32")
MCU_BOOTLOADER_ATTEMPTS = int(os.environ.get("MCU_BOOTLOADER_ATTEMPTS", "3"))

# Path to creality_flash.py's parent directory. On target:
#   /opt/nebulaos/tools  (where the MCU repo deploys its tooling)
# For development/testing, set CREALITY_FLASH_PATH to the local checkout.
CREALITY_FLASH_PATH = os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools")


def emit(result, identity="unknown", detail=""):
    """Print structured key=value output for the init.d script to parse."""
    print(f"MCU_GUARD_RESULT={result}")
    print(f"MCU_IDENTITY={identity}")
    print(f"MCU_GUARD_DETAIL={detail}")


def main():
    # Import creality_flash from the configured path.
    if CREALITY_FLASH_PATH not in sys.path:
        sys.path.insert(0, CREALITY_FLASH_PATH)

    try:
        import creality_flash
    except ImportError as e:
        emit("FAIL", detail=f"cannot_import_creality_flash: {e}")
        sys.exit(1)

    # Open the serial transport.
    try:
        transport = creality_flash.SerialTransport(
            MCU_SERIAL_PORT, baud=MCU_APP_BAUD, timeout=2.0
        )
    except Exception as e:
        emit("FAIL_SERIAL", detail=f"serial_open_failed: {e}")
        sys.exit(1)

    # Enter bootloader and query identity. The identify() function calls
    # enter_bootloader() (magic + baud switch + handshake) then
    # get_version(). We call it directly rather than reimplementing the
    # protocol, but we MUST call app_start() afterward regardless of
    # success or failure.
    version_string = None
    bootloader_entered = False
    try:
        version_string = creality_flash.identify(transport)
        bootloader_entered = True
    except creality_flash.FlashError as e:
        error_msg = str(e)
        if "could not enter" in error_msg.lower():
            # Could not enter bootloader at all - serial magic failed.
            # This is Case 5 (MCU not responding) or the MCU is running
            # application firmware that does not respond to the magic
            # sequence (stock firmware path, requires FIRMWARE_RESTART).
            emit("FAIL_SERIAL", detail=f"bootloader_entry_failed: {error_msg}")
            sys.exit(1)
        else:
            # Entered bootloader but version query failed.
            bootloader_entered = True
            emit("FAIL_BOOTLOADER", detail=f"version_query_failed: {error_msg}")
            # Fall through to app_start below.
    except Exception as e:
        emit("FAIL_SERIAL", detail=f"unexpected_error: {e}")
        sys.exit(1)

    # CRITICAL: always return the MCU to application mode after entering
    # the bootloader. The bootloader has a 15-second handshake window;
    # leaving it in bootloader mode would prevent Klipper from connecting.
    if bootloader_entered:
        try:
            # Ensure we are at bootloader baud for app_start.
            transport.set_baudrate(MCU_BOOTLOADER_BAUD)
            creality_flash.app_start(transport)
        except Exception as e:
            # Log the app_start failure but do not change the primary
            # result - the identity check outcome is what matters for
            # the decision tree. The MCU's bootloader will time out and
            # return to app mode on its own after ~15 seconds if
            # app_start fails.
            print(f"MCU_GUARD_WARNING=app_start_failed: {e}", file=sys.stderr)

    # If we got here without a version string, the error was already
    # emitted above (FAIL_BOOTLOADER path with fall-through).
    if version_string is None:
        sys.exit(1)

    # Check the hardware identity against the expected value.
    if creality_flash.check_identity(version_string, (MCU_EXPECTED_HW_ID,)):
        # Case 1: correct identity.
        emit("PASS", identity=version_string, detail="identity_verified")
        sys.exit(0)
    else:
        # Case 2: wrong identity.
        emit("FAIL_WRONG_ID", identity=version_string,
             detail=f"expected={MCU_EXPECTED_HW_ID}")
        sys.exit(1)


if __name__ == "__main__":
    main()
