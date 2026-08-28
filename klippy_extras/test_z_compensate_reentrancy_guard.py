# Regression tests for the 2026-08-10 Z_OFFSET_CALIBRATION non-reentrancy guard (see
# docs/NEBULAOS_PRTOUCH_MCU_TIMER_FORENSICS.md and z_compensate.py's own guard comment) - a
# second, higher-level guard on top of prtouch_probe.py's own PrtouchProbe._own_raw_operation
# (see test_prtouch_raw_op_guard.py), protecting the whole multi-step calibration sequence
# (positioning move + touch_probe + SET_GCODE_OFFSET) as one logical unit, not just each
# individual raw MCU dispatch within it.
#
# Run from klippy/: python3 -m unittest extras.test_z_compensate_reentrancy_guard -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import unittest

from . import prtouch_test_support as fake
from . import z_compensate


def _build(stub_measurement=0.0):
    printer, mcu, _pins, _values = fake.build_environment()

    zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
    zc = z_compensate.ZCompensate(zc_config)

    fake.connect(printer, mcu)
    zc_config.assert_all_consumed()

    calls = []

    def fake_touch_probe(down_min_z, **kwargs):
        calls.append({'down_min_z': down_min_z, 'kwargs': kwargs})
        return stub_measurement

    z_offset_probe = printer.lookup_object('nebulaos_z_offset_probe')
    z_offset_probe.touch_probe = fake_touch_probe
    return printer, mcu, z_offset_probe, zc, calls


class ReentrancyGuardTest(unittest.TestCase):
    def test_second_call_while_running_is_rejected_before_any_motion(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.05)
        gcmd = fake.FakeGCmd()

        def reentrant_touch_probe(down_min_z, **kwargs):
            calls.append({'down_min_z': down_min_z, 'kwargs': kwargs})
            with self.assertRaises(fake.CommandError) as ctx:
                zc.cmd_z_offset_calibration(fake.FakeGCmd())
            self.assertIn('already in progress', str(ctx.exception))
            return 0.05

        z_probe.touch_probe = reentrant_touch_probe
        zc.cmd_z_offset_calibration(gcmd)
        # only the outer call's own probe attempt happened - the rejected reentrant call
        # never reached touch_probe() a second time.
        self.assertEqual(len(calls), 1)
        offset_scripts = [s for s in zc.gcode.scripts_run if 'SET_GCODE_OFFSET' in s]
        self.assertEqual(len(offset_scripts), 1)

    def test_rejected_call_does_not_bump_calibration_id_or_touch_status(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.05)
        gcmd = fake.FakeGCmd()
        seen = {}

        def reentrant_touch_probe(down_min_z, **kwargs):
            seen['id_before_reentry'] = zc.calibration_id
            try:
                zc.cmd_z_offset_calibration(fake.FakeGCmd())
            except fake.CommandError:
                pass
            seen['id_after_reentry'] = zc.calibration_id
            seen['state_after_reentry'] = zc.calibration_state
            return 0.05

        z_probe.touch_probe = reentrant_touch_probe
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(seen['id_before_reentry'], seen['id_after_reentry'],
                          "a rejected reentrant call must not bump calibration_id")
        self.assertEqual(seen['state_after_reentry'], "running",
                          "a rejected reentrant call must not disturb the in-progress state")

    def test_guard_clears_after_success_allowing_next_sequential_call(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.05)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, "complete")
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, "complete")
        self.assertEqual(len(calls), 2)

    def test_guard_clears_after_failure_allowing_next_sequential_call(self):
        printer, mcu, _pins, _values = fake.build_environment()
        zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
        zc = z_compensate.ZCompensate(zc_config)
        fake.connect(printer, mcu)

        z_offset_probe = printer.lookup_object('nebulaos_z_offset_probe')

        def raising_touch_probe(down_min_z, **kwargs):
            raise fake.CommandError("simulated no-trigger failure")

        z_offset_probe.touch_probe = raising_touch_probe
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, "error")

        z_offset_probe.touch_probe = lambda down_min_z, **kw: 0.10
        zc.cmd_z_offset_calibration(gcmd)
        self.assertEqual(zc.calibration_state, "complete")


if __name__ == '__main__':
    unittest.main()
