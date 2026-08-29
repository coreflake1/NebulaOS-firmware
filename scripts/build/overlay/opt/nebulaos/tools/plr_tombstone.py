#!/usr/bin/env python3
"""NebulaOS PLR (power-loss recovery) journal tombstone tool.

Called from /etc/ota_marker.sh's write_ota_marker() whenever this device
is switching AWAY from custom to stock (write_ota_marker "ota:kernel").
PLR is deliberately OS-local (see NebulaOS-klipper-extensions'
nebulaos_plr_journal.py header): a NebulaOS -> stock switch must tombstone
the NebulaOS journal so a later switch back to custom never attempts to
resume a print using state stock (which has no idea this journal format
even exists) may have printed over, paused, or otherwise invalidated in
the interim. This tool does NOT attempt any cross-OS resume compatibility
- it only ever writes a single TOMBSTONE record, exactly the same
operation NEBULAOS_PLR_DISCARD performs from inside Klipper.

Deliberately standalone and dependency-light: this runs from a plain
shell one-liner (see docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md), which may
happen while Klippy is not running at all - it must not depend on Klipper,
a venv, or any running service. It imports the SAME
nebulaos_plr_journal.py the Klipper extra itself uses (composed at
$NEBULAOS_ROOT/apps/klipper/klippy/extras/ by S05nebulaos-activate) rather
than embedding a second copy of the journal codec, so there is exactly one
source of truth for the record format on a running device.

EEPROM_PATH is hardcoded to the default this board's own [nebulaos_power_
loss_recovery] eeprom_path config value resolves to
(/sys/bus/i2c/devices/2-0050/eeprom, from the eeprom@50 DT node this
project's own accelerometer-eeprom-bus-enable-variant.sh adds) - a plain
shell/system tool has no reasonable way to read Klipper's own printer.cfg
at switch time, and this path is tied to the DT node's real hardware
wiring, not something end users are expected to routinely override. If a
deployment ever DOES override eeprom_path in printer.cfg, this tool's own
hardcoded default will silently diverge from it - documented here rather
than silently assumed correct.

Never fails the stock switch itself: write_ota_marker() calls this as a
best-effort step and continues regardless of this tool's exit code (see
that function's own comment) - a failure to tombstone should not brick
switching back to stock, since stock is unaffected by this journal
regardless (page 0, stock's own format, is never touched by NebulaOS in
either direction).

Usage: plr_tombstone.py [--eeprom-path PATH]
Exit codes: 0 on a verified tombstone commit (or a device genuinely absent
- see below), 1 on any other failure.
"""
import argparse
import os
import sys

DEFAULT_EEPROM_PATH = "/sys/bus/i2c/devices/2-0050/eeprom"

_JOURNAL_MODULE_CANDIDATES = [
    "/usr/data/nebulaos/apps/klipper/klippy/extras/nebulaos_plr_journal.py",
]


def _load_journal_module():
    """Imports nebulaos_plr_journal.py from wherever S05nebulaos-activate
    has actually composed it, without relying on it being on sys.path by
    default (this tool is invoked as a bare script, not as part of any
    Python package)."""
    import importlib.util

    for candidate in _JOURNAL_MODULE_CANDIDATES:
        if os.path.isfile(candidate):
            spec = importlib.util.spec_from_file_location(
                "nebulaos_plr_journal", candidate)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    return None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--eeprom-path", default=DEFAULT_EEPROM_PATH)
    args = parser.parse_args(argv)

    if not os.path.exists(args.eeprom_path):
        # Genuinely no PLR EEPROM on this device/build (e.g. an older
        # candidate without the at24 DT node) - nothing to tombstone, and
        # this is not an error condition for the stock switch itself.
        print("plr_tombstone: %s does not exist - nothing to tombstone"
              % args.eeprom_path)
        return 0

    journal = _load_journal_module()
    if journal is None:
        print("plr_tombstone: nebulaos_plr_journal.py not found under "
              "any of %r - is the klipper-extensions composition "
              "activated on this device?" % (_JOURNAL_MODULE_CANDIDATES,),
              file=sys.stderr)
        return 1

    try:
        with open(args.eeprom_path, "r+b") as eeprom:
            record = journal.commit_tombstone(eeprom)
    except (IOError, OSError) as exc:
        print("plr_tombstone: failed to open/write %s: %s"
              % (args.eeprom_path, exc), file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - report, never mask the cause
        print("plr_tombstone: tombstone commit failed: %s" % exc,
              file=sys.stderr)
        return 1

    print("plr_tombstone: committed TOMBSTONE at page %d (generation %d), "
          "verified by readback" % (record.page, record.generation))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
