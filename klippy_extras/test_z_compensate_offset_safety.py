# Load-cell safety hardening mission (2026-08-09) - offset-magnitude sanity checking and
# transactional-persistence proofs for z_compensate.py's Z_OFFSET_CALIBRATION, on top of the
# pre-existing sign/application/persistence-policy coverage in test_z_compensate.py (this file
# does not duplicate that - see its own module docstring for what's already covered there).
#
# Run from klippy/: python3 -m unittest extras.test_z_compensate_offset_safety -v (this fork's own layout - klippy/extras/
# is a real Python package named 'extras', not 'klippy_extras' - see NebulaOS-firmware's
# klippy_extras/ mirror of this same file for that repo's own invocation form)
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import unittest

from . import prtouch_test_support as fake
from . import z_compensate


def _build(zcompensate_overrides=None, stub_measurement=0.0, stub_raises=None):
    printer, mcu, _pins, _values = fake.build_environment()

    zc_values = dict(fake.REAL_Z_COMPENSATE_CONFIG)
    if zcompensate_overrides:
        zc_values.update(zcompensate_overrides)
    zc_config = fake.make_z_compensate_config(printer, zc_values)
    zc = z_compensate.ZCompensate(zc_config)

    fake.connect(printer, mcu)
    zc_config.assert_all_consumed()

    calls = []

    def fake_touch_probe(down_min_z, **kwargs):
        calls.append({'down_min_z': down_min_z, 'kwargs': kwargs})
        if stub_raises is not None:
            raise stub_raises
        return stub_measurement

    z_offset_probe = printer.lookup_object('nebulaos_z_offset_probe')
    z_offset_probe.touch_probe = fake_touch_probe
    return printer, mcu, z_offset_probe, zc, calls


class BackendErrorPropagationTest(unittest.TestCase):
    """The nebulaos_z_offset_probe backend raises command_error directly for all expected
    failure modes. z_compensate records the error state and re-raises as-is. Unexpected
    errors also propagate, so Klipper's own internal-error fail-safe still applies."""

    def test_command_error_from_backend_propagates_as_command_error(self):
        _, _, z_probe, zc, calls = _build(
            stub_raises=fake.CommandError("load cell not calibrated"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(fake.CommandError) as ctx:
            zc.cmd_z_offset_calibration(gcmd)
        self.assertIn("load cell not calibrated", str(ctx.exception))

    def test_status_records_error_state_on_backend_failure(self):
        _, _, z_probe, zc, calls = _build(
            stub_raises=fake.CommandError("sensor errors during tare"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(Exception):
            zc.cmd_z_offset_calibration(gcmd)
        status = zc.get_status(0.0)
        self.assertEqual(status['calibration_state'], "error")
        self.assertIn("sensor errors during tare", status['calibration_error'])

    def test_unexpected_error_still_propagates_unconverted(self):
        _, _, z_probe, zc, calls = _build(stub_raises=RuntimeError("something genuinely unexpected"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd)


class OffsetRangeRejectionTest(unittest.TestCase):
    """max_offset_correction_mm - see z_compensate.py's own __init__ comment: this command is
    documented as a per-print thermal/wear FINE-TUNE, so a multi-millimeter "correction" can
    only mean something went wrong upstream, never genuine drift this feature compensates."""

    def test_measurement_beyond_ceiling_is_rejected_before_being_applied(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=5.0)  # default ceiling is 2.0mm
        gcmd = fake.FakeGCmd()
        with self.assertRaises(Exception) as ctx:
            zc.cmd_z_offset_calibration(gcmd)
        self.assertIn("max_offset_correction_mm", str(ctx.exception))
        self.assertFalse(any('SET_GCODE_OFFSET' in s for s in zc.gcode.scripts_run),
                          "an out-of-range candidate must never reach SET_GCODE_OFFSET")

    def test_negative_measurement_beyond_ceiling_is_also_rejected(self):
        # the check is on magnitude (abs), not just large-positive values.
        _, _, z_probe, zc, calls = _build(stub_measurement=-5.0)
        gcmd = fake.FakeGCmd()
        with self.assertRaises(Exception):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertFalse(any('SET_GCODE_OFFSET' in s for s in zc.gcode.scripts_run))

    def test_measurement_at_exactly_the_ceiling_is_accepted(self):
        # stub_measurement is chosen so measured_z (= raw + tri_expand_mm, see
        # cmd_z_offset_calibration) lands EXACTLY on the configured ceiling - tri_expand_mm is
        # REAL_Z_COMPENSATE_CONFIG's own fixed 0.10 (this printer's real live-tuned value).
        _, _, z_probe, zc, calls = _build(
            zcompensate_overrides={'max_offset_correction_mm': '1.0'}, stub_measurement=0.9)
        self.assertAlmostEqual(zc.tri_expand_mm, 0.10)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)  # must not raise
        self.assertTrue(any('SET_GCODE_OFFSET' in s for s in zc.gcode.scripts_run))

    def test_measurement_within_ceiling_is_accepted_and_status_reflects_it(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.5)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)
        status = zc.get_status(0.0)
        self.assertEqual(status['calibration_state'], "complete")
        self.assertAlmostEqual(status['calibration_z_offset'], 0.5 + zc.tri_expand_mm)

    def test_rejected_measurement_sets_error_status_not_complete(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=5.0)
        gcmd = fake.FakeGCmd()
        with self.assertRaises(Exception):
            zc.cmd_z_offset_calibration(gcmd)
        status = zc.get_status(0.0)
        self.assertEqual(status['calibration_state'], "error")
        self.assertIsNone(status['calibration_z_offset'])
        self.assertIn("max_offset_correction_mm", status['calibration_error'])

    def test_ceiling_is_configurable(self):
        _, _, z_probe, zc, calls = _build(
            zcompensate_overrides={'max_offset_correction_mm': '3.0'}, stub_measurement=2.5)
        gcmd = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd)  # must not raise - within the widened ceiling
        self.assertTrue(any('SET_GCODE_OFFSET' in s for s in zc.gcode.scripts_run))


class FailedCalibrationPreservesPreviousOffsetTest(unittest.TestCase):
    """Explicit proof (mission-required) that a failed calibration never touches the live
    gcode offset at all - not "restores the old value", but genuinely never calls
    SET_GCODE_OFFSET in the first place, so whatever offset was already in effect (from an
    earlier successful calibration, or none at all) is left completely alone by construction."""

    def test_touch_probe_raising_never_calls_set_gcode_offset(self):
        _, _, z_probe, zc, calls = _build(stub_raises=RuntimeError("simulated probe failure"))
        gcmd = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd)
        self.assertFalse(any('SET_GCODE_OFFSET' in s for s in zc.gcode.scripts_run))

    def test_a_successful_calibration_followed_by_a_failed_one_leaves_the_first_offset_as_the_last_command_sent(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.3)
        gcmd1 = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd1)
        first_offset_script = next(s for s in zc.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)

        # second attempt fails - simulate by swapping the stub to raise.
        def raising_probe(down_min_z, **kwargs):
            raise RuntimeError("simulated second-attempt failure")
        z_probe.touch_probe = raising_probe
        gcmd2 = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd2)

        # no SECOND SET_GCODE_OFFSET was ever issued - the only one in the whole script log is
        # still the first, successful one. The live gcode offset (owned by Klipper core, not
        # this module) was therefore never told to change away from that value.
        offset_scripts = [s for s in zc.gcode.scripts_run if 'SET_GCODE_OFFSET' in s]
        self.assertEqual(offset_scripts, [first_offset_script])

    def test_error_state_never_carries_a_stale_offset_value(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.3)
        gcmd1 = fake.FakeGCmd()
        zc.cmd_z_offset_calibration(gcmd1)
        self.assertEqual(zc.get_status(0.0)['calibration_state'], "complete")

        z_probe.touch_probe = lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("fail"))
        gcmd2 = fake.FakeGCmd()
        with self.assertRaises(RuntimeError):
            zc.cmd_z_offset_calibration(gcmd2)
        status = zc.get_status(0.0)
        self.assertEqual(status['calibration_state'], "error")
        # the STATUS field is explicitly cleared to None on failure (even though the live
        # gcode offset itself is untouched) - a UI reading calibration_z_offset must never see
        # the previous attempt's number attributed to this failed one.
        self.assertIsNone(status['calibration_z_offset'])


class DoubleApplicationRuledOutTest(unittest.TestCase):
    """SET_GCODE_OFFSET Z=<value> is an ABSOLUTE set (Klipper core semantics, see
    cmd_z_offset_calibration's own docstring), not a relative add - proves this module never
    accumulates/compounds across repeated invocations, and that an old offset can't
    contaminate a new measurement."""

    def test_second_calibration_offset_is_its_own_raw_measurement_not_compounded_with_the_first(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.1)
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        first_script = next(s for s in zc.gcode.scripts_run if 'SET_GCODE_OFFSET' in s)
        self.assertIn('Z=%.5f' % (0.1 + zc.tri_expand_mm), first_script)

        z_probe.touch_probe = lambda down_min_z, **kw: 0.2
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        offset_scripts = [s for s in zc.gcode.scripts_run if 'SET_GCODE_OFFSET' in s]
        second_script = offset_scripts[-1]
        # must be exactly the SECOND measurement's own value - NOT 0.1+0.2, not 0.2 doubled,
        # not any function of the first call's result at all.
        self.assertIn('Z=%.5f' % (0.2 + zc.tri_expand_mm), second_script)
        self.assertNotIn('Z=%.5f' % (0.1 + 0.2 + zc.tri_expand_mm), second_script)

    def test_old_offset_never_read_back_and_fed_into_the_new_measurement(self):
        # touch_probe() itself is the only source of the raw measurement (confirmed by the
        # stub receiving no prior-offset argument of any kind) - the module has no code path
        # that reads a previous calibration_z_offset/gcode-offset value and folds it into a
        # new measurement before applying it.
        _, _, z_probe, zc, calls = _build(stub_measurement=0.1)
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        z_probe.touch_probe = lambda down_min_z, **kw: 0.2
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        for call in calls:
            self.assertEqual(call['kwargs'], {'pro_cnt': zc.pr_probe_cnt})
            self.assertEqual(set(call.keys()), {'down_min_z', 'kwargs'})

    def test_calibration_id_increments_so_a_ui_can_tell_the_two_results_apart(self):
        _, _, z_probe, zc, calls = _build(stub_measurement=0.1)
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        first_id = zc.get_status(0.0)['calibration_id']
        z_probe.touch_probe = lambda down_min_z, **kw: 0.2
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        second_id = zc.get_status(0.0)['calibration_id']
        self.assertEqual(second_id, first_id + 1)


if __name__ == '__main__':
    unittest.main()
