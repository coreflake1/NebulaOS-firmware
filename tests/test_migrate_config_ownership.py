#!/usr/bin/env python3
"""Tests for scripts/build/overlay/opt/nebulaos/tools/migrate_config_ownership.py
(Phase 2 calibration-framework mission).

Two layers of confidence:
  1. Cross-checks this tool's own find_autosave_data() against the REAL
     pinned klippy/configfile.py's _find_autosave_data() on shared fixture
     text, so the reimplementation is proven to agree with upstream, not
     merely assumed to (see the tool's own module docstring for why it
     cannot simply import configfile.py at migration time).
  2. Exercises migrate() end-to-end against realistic printer.cfg fixtures
     (virgin/no-autosave, already-has-an-unrelated-autosave-section,
     already-migrated/idempotent, partially-already-user-owned, and
     corrupted) and, for every fixture that produces output, re-parses the
     result with the REAL configfile.py to prove Klipper itself would read
     it back cleanly with the expected values and with zero SAVE_CONFIG
     include-conflicts for the 4 target sections.

Run from the repo root: python3 -m unittest tests.test_migrate_config_ownership -v
(requires the pinned Klipper checkout - set KLIPPER_SRC, or this test SKIPs
layer 1's cross-check and the real-parser round-trip in layer 2, but still
runs this tool's own self-consistency checks.)

This file may be distributed under the terms of the GNU GPLv3 license.
"""
import importlib.util
import os
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL_PATH = os.path.join(
    REPO_ROOT, "scripts/build/overlay/opt/nebulaos/tools/migrate_config_ownership.py")

_spec = importlib.util.spec_from_file_location("migrate_config_ownership", TOOL_PATH)
mco = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mco)


def _find_klipper_src():
    for candidate in (
        os.environ.get("KLIPPER_SRC"),
        os.path.join(os.path.dirname(REPO_ROOT), "_scratch/ref-klipper-mainline"),
    ):
        if candidate and os.path.isdir(os.path.join(candidate, "klippy")):
            return candidate
    return None


_KLIPPER_SRC = _find_klipper_src()
_configfile = None
if _KLIPPER_SRC:
    sys.path.insert(0, os.path.join(_KLIPPER_SRC, "klippy"))
    import configfile as _configfile  # noqa: E402


class FakePrinterForConfigfile:
    def command_error(self, msg):
        return Exception(msg)


VIRGIN_PRINTER_CFG = """[include /etc/nebulaos/klipper/platform.cfg]
[include /etc/nebulaos/klipper/machine.cfg]
[include /etc/nebulaos/klipper/prtouch.cfg]

# Your own additional includes/macros go below this line.
"""

ALREADY_MIGRATED_PRINTER_CFG = VIRGIN_PRINTER_CFG + mco.AUTOSAVE_HEADER + "\n".join(
    "#*# [%s]\n%s" % (section, "\n".join(
        "#*# %s = %s" % (k, v) for k, v in opts.items()))
    for section, opts in mco.FACTORY_DEFAULTS.items()
) + "\n"

UNRELATED_AUTOSAVE_PRINTER_CFG = (
    VIRGIN_PRINTER_CFG + mco.AUTOSAVE_HEADER +
    "#*# [nebulaos_z_offset_probe]\n"
    "#*# counts_per_gram = 85.72084\n"
    "#*# reference_tare_counts = -249399\n"
)

PARTIALLY_OWNED_PRINTER_CFG = (
    VIRGIN_PRINTER_CFG + mco.AUTOSAVE_HEADER +
    "#*# [bltouch]\n"
    "#*# z_offset = -0.842\n"  # a real (hypothetical) user calibration
)

CORRUPTED_PRINTER_CFG = (
    VIRGIN_PRINTER_CFG + mco.AUTOSAVE_HEADER +
    "#*# [bltouch]\n"
    "not a hash-star-hash line at all\n"
)


class FindAutosaveDataAgreesWithRealKlipper(unittest.TestCase):
    @unittest.skipUnless(_configfile, "no pinned Klipper checkout found (set KLIPPER_SRC)")
    def test_agrees_on_every_fixture(self):
        fake_autosave = _configfile.ConfigAutoSave.__new__(_configfile.ConfigAutoSave)
        fake_autosave.printer = FakePrinterForConfigfile()
        for name, text in (
            ("virgin", VIRGIN_PRINTER_CFG),
            ("already_migrated", ALREADY_MIGRATED_PRINTER_CFG),
            ("unrelated_autosave", UNRELATED_AUTOSAVE_PRINTER_CFG),
            ("partially_owned", PARTIALLY_OWNED_PRINTER_CFG),
        ):
            with self.subTest(fixture=name):
                real_regular, real_autosave = fake_autosave._find_autosave_data(text)
                mine_regular, mine_autosave = mco.find_autosave_data(text)
                self.assertEqual(real_regular, mine_regular)
                self.assertEqual(real_autosave, mine_autosave)

    @unittest.skipUnless(_configfile, "no pinned Klipper checkout found (set KLIPPER_SRC)")
    def test_agrees_that_corrupted_is_corrupted(self):
        fake_autosave = _configfile.ConfigAutoSave.__new__(_configfile.ConfigAutoSave)
        fake_autosave.printer = FakePrinterForConfigfile()
        real_regular, real_autosave = fake_autosave._find_autosave_data(CORRUPTED_PRINTER_CFG)
        # Real Klipper's own behavior on this shape: it logs a warning and
        # returns (data, "") rather than raising - it treats a malformed
        # autosave block as "no usable autosave data", not a hard error.
        # This tool's find_autosave_data() matches that exactly; migrate()
        # is the layer that turns "malformed" into an explicit refusal
        # (see test_corrupted_file_is_refused_and_backed_up below).
        self.assertEqual(real_autosave, "")
        mine_regular, mine_autosave = mco.find_autosave_data(CORRUPTED_PRINTER_CFG)
        self.assertEqual(mine_autosave, "")
        self.assertEqual(mine_regular, real_regular)

    def test_autosave_header_constant_is_exact(self):
        """This tool's AUTOSAVE_HEADER must be byte-identical to Klipper's
        own, or nothing here works at all - the single highest-value
        assertion in this file."""
        if not _configfile:
            self.skipTest("no pinned Klipper checkout found (set KLIPPER_SRC)")
        self.assertEqual(mco.AUTOSAVE_HEADER, _configfile.AUTOSAVE_HEADER)


class MigrateEndToEnd(unittest.TestCase):
    def _run(self, initial_text):
        d = tempfile.mkdtemp(prefix="mco-test-")
        path = os.path.join(d, "printer.cfg")
        with open(path, "w") as f:
            f.write(initial_text)
        backup_dir = os.path.join(d, "backups")
        rc = mco.migrate(path, backup_dir)
        with open(path) as f:
            result = f.read()
        return rc, result, backup_dir

    def test_virgin_file_gets_full_autosave_block(self):
        rc, result, _ = self._run(VIRGIN_PRINTER_CFG)
        self.assertEqual(rc, 0)
        self.assertIn(mco.AUTOSAVE_HEADER.strip("\n"), result)
        for section in mco.TARGET_SECTIONS:
            self.assertIn("[%s]" % section, result)
        self.assertIn("z_offset = 0.000", result)
        self.assertIn("rotation_distance = 7.530", result)

    def test_already_migrated_is_a_true_noop(self):
        rc, result, backup_dir = self._run(ALREADY_MIGRATED_PRINTER_CFG)
        self.assertEqual(rc, 0)
        self.assertEqual(result, ALREADY_MIGRATED_PRINTER_CFG)
        # A true no-op must not even create a backup - nothing was at risk.
        self.assertFalse(os.path.isdir(backup_dir) and os.listdir(backup_dir))

    def test_unrelated_autosave_section_is_preserved_and_extended(self):
        rc, result, _ = self._run(UNRELATED_AUTOSAVE_PRINTER_CFG)
        self.assertEqual(rc, 0)
        self.assertIn("[nebulaos_z_offset_probe]", result)
        self.assertIn("counts_per_gram = 85.72084", result)
        for section in mco.TARGET_SECTIONS:
            self.assertIn("[%s]" % section, result)
        # Exactly one occurrence of the header - never a second block.
        self.assertEqual(result.count("SAVE_CONFIG ---"), 1)

    def test_partially_owned_section_is_never_touched(self):
        rc, result, _ = self._run(PARTIALLY_OWNED_PRINTER_CFG)
        self.assertEqual(rc, 0)
        # The real (hypothetical) user value must survive untouched...
        self.assertIn("z_offset = -0.842", result)
        self.assertNotIn("z_offset = 0.000", result)
        # ...but extruder/heater_bed, which had nothing, still get seeded.
        self.assertIn("[extruder]", result)
        self.assertIn("[heater_bed]", result)

    def test_corrupted_file_is_refused_and_backed_up(self):
        rc, result, backup_dir = self._run(CORRUPTED_PRINTER_CFG)
        self.assertEqual(rc, 1)
        self.assertEqual(result, CORRUPTED_PRINTER_CFG)  # untouched
        self.assertTrue(os.listdir(backup_dir))

    def test_result_round_trips_through_real_klipper_with_no_conflicts(self):
        if not _configfile:
            self.skipTest("no pinned Klipper checkout found (set KLIPPER_SRC)")
        _, result, _ = self._run(VIRGIN_PRINTER_CFG)
        # Strip the [include ...] lines - this fixture's paths do not exist
        # on the test host, and this check only cares about the autosave
        # region's own internal consistency, not full include resolution
        # (that is covered by tests/klipper-config-load-smoke-tests.py).
        text_no_includes = "\n".join(
            line for line in result.split("\n")
            if not line.strip().startswith("[include"))
        cfgrdr = _configfile.ConfigFileReader()
        fake_autosave = _configfile.ConfigAutoSave.__new__(_configfile.ConfigAutoSave)
        fake_autosave.printer = FakePrinterForConfigfile()
        regular_data, autosave_data = fake_autosave._find_autosave_data(text_no_includes)
        regular_fileconfig = cfgrdr.build_fileconfig(regular_data, "printer.cfg")
        for section, opts in mco.FACTORY_DEFAULTS.items():
            for opt in opts:
                self.assertFalse(
                    regular_fileconfig.has_option(section, opt),
                    "%s.%s must not be a literal regular-config value, or "
                    "SAVE_CONFIG would conflict on it forever" % (section, opt))
        autosave_fileconfig = cfgrdr.build_fileconfig(autosave_data, "printer.cfg")
        self.assertEqual(autosave_fileconfig.get("bltouch", "z_offset"), "0.000")
        self.assertEqual(autosave_fileconfig.get("extruder", "rotation_distance"), "7.530")


class VerifyFactorySeed(unittest.TestCase):
    """04-cross-compile-app-stack.sh's factory-seed guard (Phase 2
    calibration-framework mission, build-bug fix found by the real pinned
    build): the old form of this check refused ANY SAVE_CONFIG block in
    the tracked printer.cfg seed at all, which is now a guaranteed false
    positive against Task 1's own deliberately-shipped factory-default
    block. verify_factory_seed() must still refuse real, non-factory
    calibration data, just no longer refuse the legitimate seed content."""

    def _write(self, text):
        d = tempfile.mkdtemp(prefix="mco-verify-test-")
        path = os.path.join(d, "printer.cfg")
        with open(path, "w") as f:
            f.write(text)
        return path

    def test_no_autosave_block_at_all_is_valid(self):
        self.assertIsNone(mco.verify_factory_seed(self._write(VIRGIN_PRINTER_CFG)))

    def test_exact_known_factory_defaults_is_valid(self):
        self.assertIsNone(
            mco.verify_factory_seed(self._write(ALREADY_MIGRATED_PRINTER_CFG)))

    def test_real_tracked_seed_file_is_valid(self):
        # The actual tracked seed this guard protects in production -
        # not a synthetic fixture. If this ever fails, the tracked seed
        # itself has drifted from FACTORY_DEFAULTS (or vice versa).
        seed_path = os.path.join(
            REPO_ROOT, "scripts/build/overlay/opt/printer_data/config/printer.cfg")
        self.assertIsNone(mco.verify_factory_seed(seed_path))

    def test_extra_non_factory_section_is_rejected(self):
        error = mco.verify_factory_seed(self._write(UNRELATED_AUTOSAVE_PRINTER_CFG))
        self.assertIsNotNone(error)
        self.assertIn("factory-default", error)

    def test_real_user_calibration_value_is_rejected(self):
        # PARTIALLY_OWNED_PRINTER_CFG's bltouch.z_offset (-0.842) differs
        # from the known factory default (0.000) - exactly the "developer's
        # real device drift accidentally committed" case this guard exists
        # to catch.
        error = mco.verify_factory_seed(self._write(PARTIALLY_OWNED_PRINTER_CFG))
        self.assertIsNotNone(error)

    def test_corrupted_autosave_block_is_rejected(self):
        error = mco.verify_factory_seed(self._write(CORRUPTED_PRINTER_CFG))
        self.assertIsNotNone(error)

    def test_cli_mode_exit_codes(self):
        import subprocess
        ok_path = self._write(ALREADY_MIGRATED_PRINTER_CFG)
        rc = subprocess.run(
            [sys.executable, TOOL_PATH, "--verify-factory-seed", ok_path]).returncode
        self.assertEqual(rc, 0)
        bad_path = self._write(PARTIALLY_OWNED_PRINTER_CFG)
        rc = subprocess.run(
            [sys.executable, TOOL_PATH, "--verify-factory-seed", bad_path],
            stderr=subprocess.DEVNULL).returncode
        self.assertEqual(rc, 1)


if __name__ == "__main__":
    unittest.main()
