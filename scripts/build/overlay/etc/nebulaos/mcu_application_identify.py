"""Pre-Klippy application identity handshake for the KE GD32F303 MCU.

Reads the MCU's own IDENTIFY dictionary - the same handshake Klipper itself
performs on every normal connect - WITHOUT starting full Klippy (no Printer,
no config, no toolhead). This lets the boot-time guard learn which
application firmware is currently running before deciding whether it's safe
to let S55klipper start normally.

This is not a novel protocol implementation. It follows the exact pattern
already shipped in upstream Klipper's own scripts/dump_mcu.py (present in
the same 58bd67db3ce1be1951c3e4a6d1156a79903d4edc commit this project's
native MCU candidate is built from): construct a bare reactor.Reactor(),
hand it to serialhdl.SerialReader(), call connect_uart(), then read the
version string via get_msgparser().get_version_info() - the identify
handshake completes synchronously inside connect_uart() itself, before it
returns, with no config or Printer object ever involved.

klippy.mcu.MCU surfaces this exact same field as the `mcu_version` status
value at runtime (see klippy/mcu.py: self._get_status_info['mcu_version'] =
version from msgparser.get_version_info()) - so this script's result is
directly comparable to what `printer/objects/query?mcu` reports once
Klipper is running.

SAFETY CONTRACT:
  - READ-ONLY. Connects, reads the identify dictionary, disconnects.
  - Never sends any command beyond the identify handshake itself.
  - Never touches the bootloader protocol (that's creality_flash.py's job,
    a separate, deliberately distinct check - see mcu_lifecycle.py).
"""

import os
import sys

KLIPPY_LIB_PATH = os.environ.get("KLIPPY_LIB_PATH", "/opt/klipper/klippy")


class ApplicationIdentifyError(Exception):
    pass


def get_application_identity(port, baud, timeout=5.0, klippy_lib_path=None):
    """Connect to the MCU at the application baud rate, complete the
    identify handshake, and return (version, build_versions). Raises
    ApplicationIdentifyError on any failure (port unopenable, handshake
    timeout, malformed dictionary). Always disconnects before returning."""
    lib_path = klippy_lib_path or KLIPPY_LIB_PATH
    if lib_path not in sys.path:
        sys.path.insert(0, lib_path)

    try:
        import reactor
        import serialhdl
    except ImportError as e:
        raise ApplicationIdentifyError(f"cannot_import_klippy_serial_modules: {e}")

    r = reactor.Reactor()
    serial_reader = serialhdl.SerialReader(r)
    try:
        completion = r.completion()
        connected = {"ok": False}

        def _do_connect(eventtime):
            try:
                serial_reader.connect_uart(port, baud)
                connected["ok"] = True
            except Exception as e:
                connected["error"] = str(e)
            completion.complete(connected["ok"])

        r.register_callback(_do_connect)
        curtime = r.monotonic()
        deadline = curtime + timeout
        while curtime < deadline:
            curtime = r.pause(min(curtime + 0.1, deadline))
            if completion.test():
                break
        else:
            raise ApplicationIdentifyError("identify_handshake_timeout")

        if not completion.wait():
            raise ApplicationIdentifyError(
                connected.get("error", "connect_uart_failed"))

        version, build_versions = serial_reader.get_msgparser().get_version_info()
        if not version:
            raise ApplicationIdentifyError("empty_version_in_identify_dict")
        return version, build_versions
    finally:
        try:
            serial_reader.disconnect()
        except Exception:
            pass


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", default=os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1"))
    p.add_argument("--baud", type=int, default=int(os.environ.get("MCU_APP_BAUD", "230400")))
    args = p.parse_args()
    try:
        version, build_versions = get_application_identity(args.port, args.baud)
        print(f"version={version}")
        print(f"build_versions={build_versions}")
    except ApplicationIdentifyError as e:
        print(f"error={e}")
        sys.exit(1)
