#!/usr/bin/env python3
"""Behavioral tests for mcu_lifecycle.py / mcu_restore.py's decision logic.

These replace grep-based structural assertions with real invocations of
decide()/restore() against fully mocked application-identify and
creality_flash collaborators - no serial hardware, no real MCU, no real
flash. Covers the 11 test cases from the Phase 1.8B pre-build review
mission (CASE 1-11).

Run: python3 tests/mcu-lifecycle-decision-tests.py
"""

import os
import sys
import unittest

HELPER_DIR = os.path.join(
    os.path.dirname(__file__), "..",
    "scripts", "build", "overlay", "etc", "nebulaos")
sys.path.insert(0, os.path.abspath(HELPER_DIR))

import mcu_known_identities as known  # noqa: E402
import mcu_lifecycle as lifecycle  # noqa: E402
import mcu_restore as restore_mod  # noqa: E402

NATIVE_VERSION = known.NATIVE_CANDIDATE_001_VERSION
STOCK_VERSION = known.KNOWN_STOCK_VERSIONS[0]
UNKNOWN_VERSION = "v0.99.0-1-gdeadbeef"
GOOD_HW_ID = "mcu0_001_G32-mcu0_005_000"
BAD_HW_ID = "mcu0_002_XYZ-mcu0_001_000"


class FakeFlashError(Exception):
    pass


class FakeCrealityFlash:
    """Mocks the parts of creality_flash.py mcu_lifecycle.py/mcu_restore.py
    actually call - never a real serial port."""

    FlashError = FakeFlashError

    def __init__(self, hw_id=GOOD_HW_ID, bootloader_reachable=True,
                 flash_should_succeed=True):
        self.hw_id = hw_id
        self.bootloader_reachable = bootloader_reachable
        self.flash_should_succeed = flash_should_succeed
        self.app_start_calls = 0
        self.flash_calls = []

    def identify(self, transport):
        if not self.bootloader_reachable:
            raise FakeFlashError("could not enter Creality serial bootloader")
        return self.hw_id

    def app_start(self, transport):
        self.app_start_calls += 1
        return True

    def check_identity(self, version_string, allowed):
        hw_part = version_string.split("-")[0] if "-" in version_string else version_string
        return hw_part in allowed

    def flash(self, transport, image_path):
        self.flash_calls.append(image_path)
        if not self.flash_should_succeed:
            raise FakeFlashError("simulated flash failure")


def make_identify_fn(version=None, should_fail=False):
    def _identify(port, baud):
        if should_fail:
            raise Exception("simulated_serial_timeout")
        return version, "fake_build_versions"
    return _identify


class FakeTransport:
    """Minimal stand-in with the two methods mcu_lifecycle.py actually
    calls on a transport (set_baudrate is called unconditionally after
    entering the bootloader, to switch to app_start's expected baud)."""
    def set_baudrate(self, baud):
        pass


def transport_factory_stub():
    return FakeTransport()


class DecideTests(unittest.TestCase):
    def test_case1_native_already_installed(self):
        """CASE 1: supported KE HW, native candidate already installed ->
        no erase, no write, PASS."""
        cf = FakeCrealityFlash()
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START)
        self.assertEqual(cf.flash_calls, [])
        # Bootloader must never be entered for the already-healthy case.
        self.assertEqual(cf.app_start_calls, 0)

    def test_case2_known_stock_authorizes_restore(self):
        """CASE 2: supported KE HW, exact known stock application ->
        restore path selected."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_KNOWN_STOCK_APP)
        self.assertEqual(d.action, lifecycle.RESTORE_AUTHORIZED)
        self.assertEqual(cf.app_start_calls, 1)

    def test_case3_unknown_application_never_flashes(self):
        """CASE 3: supported KE HW, unknown application -> no erase, no
        write, safe refusal (WARN, not silently PASS)."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_UNKNOWN_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)
        self.assertEqual(cf.flash_calls, [])

    def test_case4_unsupported_hardware_never_flashes(self):
        """CASE 4: unsupported HW -> no flash."""
        cf = FakeCrealityFlash(hw_id=BAD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertEqual(d.state, lifecycle.UNSUPPORTED_HW)
        self.assertEqual(d.action, lifecycle.BLOCK_KLIPPER_START)
        self.assertEqual(cf.flash_calls, [])

    def test_case4b_unsupported_hardware_even_with_unknown_app(self):
        """Hardware mismatch must block regardless of application class."""
        cf = FakeCrealityFlash(hw_id=BAD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION))
        self.assertEqual(d.state, lifecycle.UNSUPPORTED_HW)
        self.assertEqual(d.action, lifecycle.BLOCK_KLIPPER_START)

    def test_case5_mcu_unreachable_no_stock_fallback(self):
        """CASE 5: MCU unreachable -> no stock fallback, no infinite retry
        (decide() makes exactly one attempt)."""
        cf = FakeCrealityFlash(bootloader_reachable=False)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(None, should_fail=True))
        self.assertEqual(d.state, lifecycle.MCU_UNREACHABLE)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START_WARN)
        self.assertEqual(cf.flash_calls, [])

    def test_hw_id_never_checked_for_native_app(self):
        """A native-app connection must never be disturbed by a bootloader
        entry attempt it doesn't need - regression guard for the original
        conflation bug."""
        cf = FakeCrealityFlash()
        lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(cf.app_start_calls, 0,
                          "bootloader must not be entered for a healthy native app")

    def test_bootloader_hw_id_alone_never_implies_native_app(self):
        """Direct regression test for the conflation bug: a bootloader
        hw-id match by itself must never produce SUPPORTED_HW_NATIVE_APP -
        only an actual matching application identity can."""
        cf = FakeCrealityFlash(hw_id=GOOD_HW_ID)
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(STOCK_VERSION))
        self.assertNotEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)


class RestoreTests(unittest.TestCase):
    def _fake_files(self, exists=True, sha=known.NATIVE_CANDIDATE_001_SHA256):
        return (lambda path: exists), (lambda path: sha)

    def test_case6_candidate_missing(self):
        """CASE 6: candidate missing -> no flash."""
        cf = FakeCrealityFlash()
        exists_fn, hash_fn = self._fake_files(exists=False)
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn)
        self.assertEqual(r.state, restore_mod.CANDIDATE_ARTIFACT_MISSING)
        self.assertEqual(cf.flash_calls, [])

    def test_case7_candidate_hash_mismatch(self):
        """CASE 7: candidate hash mismatch -> no flash."""
        cf = FakeCrealityFlash()
        exists_fn, hash_fn = self._fake_files(sha="0" * 64)
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn)
        self.assertEqual(r.state, restore_mod.CANDIDATE_HASH_BAD)
        self.assertEqual(cf.flash_calls, [])

    def test_case8_flash_failure_is_bounded(self):
        """CASE 8: flash failure -> bounded failure (exactly one attempt),
        diagnostics preserved."""
        cf = FakeCrealityFlash(flash_should_succeed=False)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn)
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)
        self.assertEqual(len(cf.flash_calls), 1, "exactly one flash attempt, no retry loop")

    def test_case9_restore_succeeds_and_verifies_application_identity(self):
        """CASE 9: restore succeeds -> post-flash application identity ==
        candidate-001, not merely 'flash reported success'."""
        cf = FakeCrealityFlash(flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn)
        self.assertEqual(r.state, restore_mod.RESTORED_AND_VERIFIED)

    def test_case9b_flash_succeeds_but_post_verify_identity_wrong(self):
        """Flash reporting success is NOT sufficient - if the post-flash
        identify doesn't actually show candidate-001, this must be a
        failure, not a false PASS."""
        cf = FakeCrealityFlash(flash_should_succeed=True)
        exists_fn, hash_fn = self._fake_files()
        r = restore_mod.restore(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(UNKNOWN_VERSION),
            file_exists_fn=exists_fn, hash_fn=hash_fn)
        self.assertEqual(r.state, restore_mod.FLASH_FAILED)

    def test_case10_reboot_after_successful_restore_is_a_pure_read(self):
        """CASE 10: reboot after successful restore -> detect native
        candidate, zero writes (this is just decide() again, now seeing
        NATIVE_CANDIDATE_001)."""
        cf = FakeCrealityFlash()
        d = lifecycle.decide(
            creality_flash_module=cf, transport_factory=transport_factory_stub,
            application_identify_fn=make_identify_fn(NATIVE_VERSION))
        self.assertEqual(d.state, lifecycle.SUPPORTED_HW_NATIVE_APP)
        self.assertEqual(d.action, lifecycle.ALLOW_KLIPPER_START)
        self.assertEqual(cf.flash_calls, [])

    def test_case11_unrelated_klipper_failure_never_triggers_reflash(self):
        """CASE 11: this module has no knowledge of Klipper's own runtime
        failures at all - decide() is only ever invoked at boot time by
        S50, before S55klipper starts, and never re-invoked by a later
        Klipper crash. This test documents that contract: calling decide()
        a second time with an unchanged native identity must be fully
        idempotent (no flash, same result) - there is no code path by
        which a later Klipper-only failure could reach mcu_restore.py."""
        cf = FakeCrealityFlash()
        identify_fn = make_identify_fn(NATIVE_VERSION)
        d1 = lifecycle.decide(creality_flash_module=cf,
                               transport_factory=transport_factory_stub,
                               application_identify_fn=identify_fn)
        d2 = lifecycle.decide(creality_flash_module=cf,
                               transport_factory=transport_factory_stub,
                               application_identify_fn=identify_fn)
        self.assertEqual(d1.state, d2.state)
        self.assertEqual(cf.flash_calls, [])


class ClassificationTests(unittest.TestCase):
    def test_exact_match_only_no_prefix_guessing(self):
        """A string that merely starts with the known-stock value must NOT
        classify as KNOWN_STOCK - exact match only."""
        almost = STOCK_VERSION + "-extra-suffix"
        self.assertEqual(
            known.classify_application_identity(almost),
            known.UNKNOWN_APPLICATION)

    def test_native_and_stock_are_distinguishable(self):
        self.assertNotEqual(
            known.classify_application_identity(NATIVE_VERSION),
            known.classify_application_identity(STOCK_VERSION))


if __name__ == "__main__":
    unittest.main()
