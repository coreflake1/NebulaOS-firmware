#!/usr/bin/env python3
"""Real-Klipper-module tests for the Phase 1.8B candidate-002 MCU fix
(2026-08-28): unlike mcu-lifecycle-decision-tests.py, which mocks
creality_flash/transport/application_identify_fn to test decision LOGIC,
these tests use Klipper's own real reactor.py, serialhdl.py, and
msgproto.py - no mocks of Klipper's own code - mocking only the physical
serial/device boundary (a nonexistent port, in the connect_uart test; no
device at all, in the pure-reactor and msgproto tests, which don't touch
a serial port).

Covers exactly the two things candidate-001's hardware qualification found
broken and could not have been caught by the mocked test suite:
  1. reactor.Reactor.pause() only dispatches registered callbacks once its
     own greenlet dispatch loop is running (inside run()) - called before
     that, it silently falls back to a plain time.sleep(). The OLD
     mcu_application_identify.py registered a callback and then waited on
     it via a bare top-level pause() loop, so it NEVER fired - this was
     never caught because every decision test injects
     application_identify_fn directly, mocking Klipper's reactor away
     entirely.
  2. mcu_restart.py's "reset"/"config_reset" lookup uses
     msgparser.lookup_command()/MessageFormat.encode() - real msgproto
     code, operating on this project's own real, actual candidate-001
     dictionary (vendored into tests/fixtures/candidate-001.klipper.dict,
     byte-for-byte identical to _evidence/phase1.8-candidate/klipper.dict,
     produced by NebulaOS-klipper-mcu's real build - vendored rather than
     read from the workspace's _evidence/ tree so this test suite is
     self-contained within this repo), not an invented/hand-written one.

A full pty-based end-to-end simulation of connect_uart()'s IDENTIFY wire
protocol (chunked dictionary fetch with real checksummed message framing)
was considered and deliberately NOT attempted here: implementing Klipper's
receive-side frame parsing/ACK sequencing by hand to build a believable fake
MCU carries meaningful bug risk of its own for what would still only be
testing already-proven-correct Klipper library code (connect_uart() itself
is unmodified, upstream, and exercised daily by every real Klipper
installation) rather than this project's own new code. The three tests
below directly exercise the two things this project's own code actually
changed (reactor dispatch pattern, and msgproto command lookup/encoding),
using real Klipper modules throughout - see
_project/missions/phase1.8b-candidate-002-mcu-fix-summary.md for this
scoping decision recorded explicitly, not silently skipped.

Run: python3 tests/mcu-real-reactor-msgproto-tests.py
"""

import os
import sys
import time
import unittest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..")
HELPER_DIR = os.path.join(
    REPO_ROOT, "scripts", "build", "overlay", "etc", "nebulaos")
KLIPPY_DIR = os.path.join(REPO_ROOT, "vendor", "klipper", "klippy")
REAL_DICT_PATH = os.path.join(
    os.path.dirname(__file__), "fixtures", "candidate-001.klipper.dict")

sys.path.insert(0, os.path.abspath(HELPER_DIR))
sys.path.insert(0, os.path.abspath(KLIPPY_DIR))

import reactor  # noqa: E402 - real Klipper module, not a mock
import serialhdl  # noqa: E402 - real Klipper module, not a mock
import msgproto  # noqa: E402 - real Klipper module, not a mock

import mcu_application_identify as app_identify  # noqa: E402


class RealReactorDispatchTests(unittest.TestCase):
    """No serial port, no MCU, no mocks of Klipper's own code at all - just
    reactor.Reactor(), proving the exact dispatch behavior
    mcu_application_identify.py depends on."""

    def test_old_pattern_never_dispatches_before_run(self):
        """Documents the actual bug: register_callback() + a bare top-level
        pause() loop (the OLD, broken pattern) never fires the callback,
        because pause() falls back to a plain time.sleep() until run() has
        been called at least once (self._g_dispatch is None until then)."""
        r = reactor.Reactor()
        fired = {"ok": False}

        def _cb(eventtime):
            fired["ok"] = True

        r.register_callback(_cb)
        curtime = r.monotonic()
        deadline = curtime + 0.3
        while curtime < deadline:
            curtime = r.pause(min(curtime + 0.05, deadline))
        r.finalize()
        self.assertFalse(
            fired["ok"],
            "the OLD top-level-pause pattern must NOT dispatch the "
            "callback - if this assertion ever fails, reactor.py's own "
            "pause()/run() contract has changed and "
            "mcu_application_identify.py's fix should be re-examined")

    def test_new_pattern_dispatches_correctly_via_run(self):
        """The FIX: nest the callback registration and pause() polling
        inside one top-level callback that is itself dispatched via
        run()/end() - exactly mcu_application_identify.run_connected()'s
        structure. Real reactor.Reactor, no mocks."""
        r = reactor.Reactor()
        fired = {"ok": False}

        def _outer(eventtime):
            def _inner(eventtime):
                fired["ok"] = True

            r.register_callback(_inner)
            curtime = r.monotonic()
            deadline = curtime + 1.0
            while curtime < deadline:
                curtime = r.pause(min(curtime + 0.05, deadline))
                if fired["ok"]:
                    break
            r.end()

        r.register_callback(_outer)
        r.run()
        r.finalize()
        self.assertTrue(
            fired["ok"],
            "the fixed pattern (nested inside a run()-dispatched callback) "
            "must dispatch the inner callback")


class RealMsgprotoCommandLookupTests(unittest.TestCase):
    """Real msgproto.MessageParser, loaded with this project's own actual
    candidate-001 dictionary (not hand-written/invented) - proves
    mcu_restart.py's command lookup/encoding is exercising genuine Klipper
    wire-protocol code against a genuine dictionary, not an assumption
    about its shape."""

    @classmethod
    def setUpClass(cls):
        if not os.path.isfile(REAL_DICT_PATH):
            raise unittest.SkipTest(
                f"real candidate-001 dictionary not found at {REAL_DICT_PATH}")
        with open(REAL_DICT_PATH, "rb") as f:
            cls.dict_bytes = f.read()

    def _load_parser(self):
        mp = msgproto.MessageParser()
        # klipper.dict is the plain, already-decompressed JSON form (as
        # produced alongside candidate-001's .elf at build time) -
        # decompress=False feeds it directly, exactly matching what
        # process_identify() does with data AFTER the real wire-level
        # identify fetch (chunked "identify_response" messages,
        # reassembled and zlib-decompressed) has already completed - see
        # this module's docstring for why that wire-level fetch itself is
        # not re-simulated here.
        mp.process_identify(self.dict_bytes, decompress=False)
        return mp

    def test_reset_command_is_present_and_zero_argument(self):
        mp = self._load_parser()
        cmd = mp.lookup_command("reset")
        self.assertEqual(cmd.name, "reset")
        self.assertEqual(cmd.param_types, [],
                          "'reset' must be a zero-argument command")

    def test_reset_command_encodes_to_just_its_message_id(self):
        """MessageFormat.encode(()) for a zero-param command returns
        exactly its raw msgid bytes and nothing else - this is the literal
        payload mcu_restart.py's raw_send() transmits."""
        mp = self._load_parser()
        cmd = mp.lookup_command("reset")
        encoded = cmd.encode(())
        self.assertEqual(encoded, list(cmd.msgid_bytes))
        self.assertGreater(len(encoded), 0)

    def test_unknown_command_raises_msgparser_error_not_a_crash(self):
        """mcu_restart.py relies on msgparser.error (not a bare exception)
        being raised for a command name absent from the dictionary - this
        is what lets it distinguish 'try config_reset next' from a genuine
        bug."""
        mp = self._load_parser()
        with self.assertRaises(mp.error):
            mp.lookup_command("this_command_does_not_exist_anywhere")


class RealConnectUartBoundaryTests(unittest.TestCase):
    """run_connected() (shared by mcu_application_identify.py and
    mcu_restart.py) against a real reactor.Reactor and a real
    serialhdl.SerialReader, with the physical device boundary itself being
    the only thing not real (a serial port path that cannot exist) - proves
    the fixed reactor plumbing correctly surfaces a bounded, timely failure
    rather than hanging, using the actual production connect_uart() call
    path end to end."""

    def test_run_connected_fails_promptly_on_nonexistent_port(self):
        """Bounded is the property under test, not fast - connect_uart()
        has its own internal open-retry behavior before it gives up on a
        port that doesn't exist (observed ~4s for a 2.0s `timeout`), which
        is real, unmodified Klipper behavior, not a bug. What this
        regresses against is the OLD, broken pattern hanging forever
        (bare top-level pause() loop before run() - see
        RealReactorDispatchTests): a generous multiple of `timeout` still
        catches that class of failure while tolerating connect_uart()'s own
        legitimate retry overhead."""
        nonexistent_port = "/dev/this-port-does-not-exist-on-any-system"
        connect_timeout = 2.0
        start = time.time()
        with self.assertRaises(app_identify.ApplicationIdentifyError):
            app_identify.run_connected(
                nonexistent_port, 230400, lambda serial_reader: None,
                timeout=connect_timeout)
        elapsed = time.time() - start
        self.assertLess(
            elapsed, connect_timeout * 5,
            "must fail within a bounded multiple of `timeout`, not hang "
            "indefinitely - a regression here would reproduce the exact "
            "class of bug this module was rewritten to fix")


if __name__ == "__main__":
    unittest.main()
