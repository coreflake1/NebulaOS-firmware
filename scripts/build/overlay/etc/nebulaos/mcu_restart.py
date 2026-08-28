"""Pre-Klippy MCU restart request via Klipper's own generic restart command.

Phase 1.8B Option C (2026-08-28 architecture decision, following the
candidate-001 hardware qualification finding that creality_flash.py's serial
magic-sequence bootloader entry does not work against genuinely stock
Creality firmware - see stage4_first_flash.py's own module docstring and
docs/MCU_LIFECYCLE_GUARD.md for the full history).

This module sends EXACTLY the operation upstream Klipper's own mcu.py sends
for a normal FIRMWARE_RESTART when restart_method=command (this project's
own configured value - see scripts/build/overlay/etc/nebulaos/klipper/
machine.cfg's [mcu] section) - traced from upstream Klipper
58bd67db3ce1be1951c3e4a6d1156a79903d4edc:

  klippy/mcu.py's MCURestartHelper:
    _mcu_identify(): looks up "reset", then "config_reset", via
      MCU.try_lookup_command() - which is just
      msgparser.lookup_command(name), catching msgparser.error if the name
      isn't in this MCU's command dictionary. Neither lookup ever raises out
      to the caller; a missing command is simply None.
    _restart_via_command(): if neither command exists, it's a no-op ("Unable
      to issue reset command"). Otherwise it sends whichever one exists via
      CommandWrapper.send() - a fire-and-forget raw_send() (not
      send_wait_ack(): the MCU reboots before it could ever ACK).
  Both "reset" (src/generic/armcm_reset.c, HF_IN_SHUTDOWN) and
  "config_reset" (src/linux/main.c, HF_IN_SHUTDOWN) are declared with zero
  parameters.

This module replicates exactly that: look up "reset" then "config_reset" in
the MCU's real command dictionary (obtained via the same identify handshake
mcu_application_identify.py already performs) and raw_send() whichever one
exists - never a hardcoded/invented raw byte sequence, never anything beyond
those two specific, standard, zero-argument Klipper commands.

Empirical evidence this works against genuinely stock firmware, not just
native candidate-001: the 2026-08-28 hardware qualification session's
stage4_first_flash.py run triggered exactly this operation via Moonraker's
/printer/firmware_restart (Klippy's own FIRMWARE_RESTART handling,
restart_method=command per this project's machine.cfg) against the printer
while it was running genuinely stock firmware, and the subsequent bootloader
handshake succeeded - proving the stock MCU's own command dictionary does
expose a usable restart command. See
_project/missions/phase1.8b-candidate-001-hardware-qualification-summary.md
and _evidence/qualification-logs/phase1.8b-candidate-001-2026-08-28/
gate1-manual-remediation-and-restore.txt for that evidence.

SAFETY CONTRACT:
  - Only ever sends "reset" or "config_reset" - looked up from the MCU's
    real command dictionary at connect time, never invented/hardcoded.
  - If neither command exists in the dictionary, raises
    RestartRequestRefused and sends nothing - mirrors mcu.py's own
    _restart_via_command() no-op behavior exactly. Callers must treat this
    as "cannot restart this MCU via this mechanism", not retry with a
    different payload.
  - Never touches MCU flash. This module only ever asks the MCU to restart
    itself, exactly as Klipper's own FIRMWARE_RESTART does - erase/write
    still happens exclusively in mcu_restore.py, via creality_flash.py's
    existing, separately hardware-identity-gated primitives, after this
    module's restart has been confirmed to actually reach the bootloader.
  - Does not require Klippy or Moonraker to be running. Connects directly
    via serialhdl/reactor, the same pre-Klippy machinery
    mcu_application_identify.py already uses.
"""

import mcu_application_identify as app_identify

RESTART_COMMAND_NAMES = ("reset", "config_reset")


class RestartRequestError(Exception):
    """Connection-level failure (could not even reach the MCU to ask)."""


class RestartRequestRefused(Exception):
    """The MCU's own command dictionary exposes neither 'reset' nor
    'config_reset' - mirrors mcu.py's _restart_via_command() no-op path.
    Never attempt an alternate/invented command on this exception - the
    caller's fallback is the existing magic-sequence path
    (creality_flash.enter_bootloader()), not a new packet."""


def request_generic_restart(port, baud, timeout=5.0, klippy_lib_path=None):
    """Connect to the MCU at the application baud, look up 'reset' (falling
    back to 'config_reset'), send it, then disconnect. Returns the command
    name actually sent ('reset' or 'config_reset'). Raises
    RestartRequestError if the connection itself fails, or
    RestartRequestRefused if the MCU's dictionary has neither command."""

    def _send_restart(serial_reader):
        # Returns the command name sent, or None if neither exists - never
        # raises RestartRequestRefused from inside this callback, since
        # run_connected()'s generic `except Exception as e: outcome["error"]
        # = str(e)` handling collapses any exception type to a plain string
        # message before re-raising as error_cls, which would otherwise
        # destroy the RestartRequestError/RestartRequestRefused distinction
        # the caller needs to tell "couldn't even connect" apart from "MCU
        # has neither command" (the former is a transient/environment
        # failure, the latter is a definitive answer about this MCU).
        msgparser = serial_reader.get_msgparser()
        for name in RESTART_COMMAND_NAMES:
            try:
                cmd = msgparser.lookup_command(name)
            except msgparser.error:
                continue
            encoded = cmd.encode(())
            cmd_queue = serial_reader.get_default_command_queue()
            serial_reader.raw_send(encoded, 0, 0, cmd_queue)
            return name
        return None

    sent = app_identify.run_connected(
        port, baud, _send_restart, timeout, klippy_lib_path,
        error_cls=RestartRequestError)
    if sent is None:
        raise RestartRequestRefused(
            "mcu_dictionary_exposes_neither_reset_nor_config_reset")
    return sent
