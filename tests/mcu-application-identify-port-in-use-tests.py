#!/usr/bin/env python3
"""Offline, repeatable tests for find_process_holding_port() and its wiring
into run_connected() in scripts/build/overlay/etc/nebulaos/
mcu_application_identify.py (Phase 2 overnight convergence mission,
2026-09-09).

Real device found live: mcu_identity_check.py (via this module's
run_connected(), which reuses Klipper's own serialhdl.SerialReader) was run
manually while klippy.py already held /dev/ttyS1 open. The competing open
attempt very plausibly reset the MCU (Klipper's own serialhdl.py uses a
DTR toggle as its own deliberate MCU-reset mechanism over this exact class
of port) - only a full power cycle recovered it. This fix refuses to
attempt the open at all when the port is already visibly held open by
another process, checked via a plain /proc/[pid]/fd scan with no actual
open() call of its own, so the check itself can never disturb a live
connection.

Uses a synthetic proc_root (a tmp directory shaped like /proc) rather than
the real /proc, so this test is deterministic and touches no real
process or device.

Usage: python3 tests/mcu-application-identify-port-in-use-tests.py
"""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_PATH = os.path.join(
    REPO_ROOT, "scripts/build/overlay/etc/nebulaos/mcu_application_identify.py")

spec = importlib.util.spec_from_file_location("mcu_application_identify", MODULE_PATH)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class FindProcessHoldingPortTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix="mcu-app-identify-port-tests-")
        self.proc_root = os.path.join(self.work, "proc")
        os.makedirs(self.proc_root)
        # A real device file to symlink at, so os.path.realpath() has
        # something concrete to resolve against on both sides.
        self.port = os.path.join(self.work, "ttyS1")
        with open(self.port, "w"):
            pass

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def _make_pid_with_fd(self, pid, fd_num, target):
        pid_dir = os.path.join(self.proc_root, str(pid))
        fd_dir = os.path.join(pid_dir, "fd")
        os.makedirs(fd_dir)
        os.symlink(target, os.path.join(fd_dir, str(fd_num)))

    def test_port_free_returns_none(self):
        # A process exists but has an unrelated fd open, not our port.
        other_file = os.path.join(self.work, "unrelated.log")
        with open(other_file, "w"):
            pass
        self._make_pid_with_fd(1234, 3, other_file)

        self.assertIsNone(
            m.find_process_holding_port(self.port, proc_root=self.proc_root))

    def test_port_in_use_returns_holder_pid(self):
        self._make_pid_with_fd(1213, 5, self.port)

        self.assertEqual(
            m.find_process_holding_port(self.port, proc_root=self.proc_root),
            1213)

    def test_no_processes_at_all_returns_none(self):
        # Empty proc_root - nothing to scan, must not raise.
        self.assertIsNone(
            m.find_process_holding_port(self.port, proc_root=self.proc_root))

    def test_non_numeric_proc_entries_are_skipped(self):
        # Real /proc has non-pid entries (self, meminfo, etc.) - must not
        # crash trying to treat them as a pid's fd directory.
        os.makedirs(os.path.join(self.proc_root, "self"))
        os.makedirs(os.path.join(self.proc_root, "meminfo"))
        self._make_pid_with_fd(999, 0, self.port)

        self.assertEqual(
            m.find_process_holding_port(self.port, proc_root=self.proc_root),
            999)

    def test_pid_fd_directory_gone_mid_scan_is_tolerated(self):
        # A process can exit between os.listdir(proc_root) and reading its
        # fd directory - real /proc races constantly. Simulate by listing
        # a pid directory with no fd/ subdirectory at all.
        os.makedirs(os.path.join(self.proc_root, "5555"))
        self._make_pid_with_fd(1213, 5, self.port)

        self.assertEqual(
            m.find_process_holding_port(self.port, proc_root=self.proc_root),
            1213)

    def test_symlink_vs_realpath_resolves_equal(self):
        # /dev/serial/by-id/... -> /dev/ttyS1 style indirection: the port
        # argument and the fd's target can be different paths to the same
        # real device.
        by_id_link = os.path.join(self.work, "by-id-alias")
        os.symlink(self.port, by_id_link)
        self._make_pid_with_fd(4242, 7, self.port)

        self.assertEqual(
            m.find_process_holding_port(by_id_link, proc_root=self.proc_root),
            4242)

    def test_run_connected_refuses_when_port_in_use(self):
        self._make_pid_with_fd(1213, 5, self.port)

        def _should_never_be_called(serial_reader):
            self.fail("action_fn was called despite the port being in use")

        with self.assertRaises(m.ApplicationIdentifyError) as ctx:
            m.run_connected(
                self.port, 250000, _should_never_be_called,
                timeout=1.0,
                # find_process_holding_port has no proc_root override in
                # run_connected's own signature (real /proc in production) -
                # monkeypatch the module-level function for this one test
                # so it consults our synthetic proc_root instead.
            )
        self.assertIn("port_already_in_use_by_pid_1213", str(ctx.exception))

    def test_run_connected_proceeds_when_port_free(self):
        # No fd anywhere points at self.port - the in-use check must pass
        # through to the normal connect path, which then fails for an
        # unrelated, expected reason (no real Klipper serial modules
        # importable from this sandbox) rather than the in-use refusal.
        with self.assertRaises(m.ApplicationIdentifyError) as ctx:
            m.run_connected(
                self.port, 250000, lambda serial_reader: None,
                timeout=1.0, klippy_lib_path="/nonexistent/klippy/lib")
        self.assertNotIn("port_already_in_use", str(ctx.exception))
        self.assertIn("cannot_import_klippy_serial_modules", str(ctx.exception))


if __name__ == "__main__":
    # test_run_connected_refuses_when_port_in_use needs run_connected to
    # consult our synthetic proc_root rather than the real /proc - patch
    # the module-level lookup function for the duration of that one test
    # via a thin wrapper, since run_connected() itself calls
    # find_process_holding_port(port) with no proc_root parameter.
    _real_find = m.find_process_holding_port

    class _PatchedRunConnectedTest(FindProcessHoldingPortTests):
        def test_run_connected_refuses_when_port_in_use(self):
            self._make_pid_with_fd(1213, 5, self.port)
            m.find_process_holding_port = (
                lambda port: _real_find(port, proc_root=self.proc_root))
            try:
                def _should_never_be_called(serial_reader):
                    self.fail(
                        "action_fn was called despite the port being in use")

                with self.assertRaises(m.ApplicationIdentifyError) as ctx:
                    m.run_connected(self.port, 250000,
                                     _should_never_be_called, timeout=1.0)
                self.assertIn(
                    "port_already_in_use_by_pid_1213", str(ctx.exception))
            finally:
                m.find_process_holding_port = _real_find

    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(_PatchedRunConnectedTest))
    # Also load every other test normally from the base class (avoiding
    # double-running the one method the subclass overrides).
    for name in loader.getTestCaseNames(FindProcessHoldingPortTests):
        if name != "test_run_connected_refuses_when_port_in_use":
            suite.addTest(FindProcessHoldingPortTests(name))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
