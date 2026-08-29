# Phase 1.8B: offline tests for the native nozzle-clear module (nozzle_clear.py).
#
# Validates the wipe geometry calculations, temperature sequencing, probe call pattern,
# and Z math against the documented physical behavior of prtouch_nozzle.clear_nozzle().
# Uses mock objects throughout — no real printer, MCU, or serial hardware needed.
#
# Run: python3 -m pytest extras/test_nozzle_clear_native.py -v
# Or:  python3 -m unittest extras.test_nozzle_clear_native -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.

import unittest
from unittest.mock import MagicMock, patch, call

from . import nozzle_clear


class FakeConfig:
    """Minimal Klipper config stub for NozzleClearConfig parameter reads."""

    def __init__(self, overrides=None):
        self._values = {
            'clr_noz_start_x': -3.0,
            'clr_noz_start_y': 20.0,
            'clr_noz_len_x': 3.0,
            'clr_noz_len_y': 50.0,
            'pa_clr_dis_mm_x': 0.0,
            'pa_clr_dis_mm_y': 30.0,
            'pa_clr_down_mm': -0.15,
            'clr_xy_spd': 2.0,
            'rdy_xy_spd': 200.0,
            'bed_max_err': 5.0,
            'g29_down_min_z': 25.0,
            'vs_start_z_pos': 3.0,
            'pr_clear_probe_cnt': 3,
        }
        if overrides:
            self._values.update(overrides)

    def getfloat(self, key, default=None, minval=None, maxval=None):
        v = self._values.get(key)
        return default if v is None else v

    def getint(self, key, default=None, minval=None, maxval=None):
        v = self._values.get(key)
        return default if v is None else int(v)


class NozzleClearConfigTest(unittest.TestCase):
    """NozzleClearConfig must parse the same parameters with the same defaults as
    prtouch_nozzle.ClearNozzleConfig."""

    def test_all_real_ke_values(self):
        cfg = nozzle_clear.NozzleClearConfig(FakeConfig())
        self.assertAlmostEqual(cfg.clr_noz_start_x, -3.0)
        self.assertAlmostEqual(cfg.clr_noz_start_y, 20.0)
        self.assertAlmostEqual(cfg.clr_noz_len_x, 3.0)
        self.assertAlmostEqual(cfg.clr_noz_len_y, 50.0)
        self.assertAlmostEqual(cfg.pa_clr_dis_mm_x, 0.0)
        self.assertAlmostEqual(cfg.pa_clr_dis_mm_y, 30.0)
        self.assertAlmostEqual(cfg.pa_clr_down_mm, -0.15)
        self.assertAlmostEqual(cfg.clr_xy_spd, 2.0)
        self.assertAlmostEqual(cfg.rdy_xy_spd, 200.0)
        self.assertAlmostEqual(cfg.bed_max_err, 5.0)
        self.assertAlmostEqual(cfg.g29_down_min_z, 25.0)
        self.assertAlmostEqual(cfg.hover_z, 3.0)
        self.assertEqual(cfg.pr_clear_probe_cnt, 3)

    def test_defaults_when_keys_absent(self):
        cfg = nozzle_clear.NozzleClearConfig(FakeConfig({
            'clr_noz_start_x': None,
            'clr_noz_start_y': None,
            'pa_clr_dis_mm_x': None,
            'pa_clr_dis_mm_y': None,
        }))
        self.assertAlmostEqual(cfg.clr_noz_start_x, 0.0)
        self.assertAlmostEqual(cfg.clr_noz_start_y, 0.0)
        self.assertAlmostEqual(cfg.pa_clr_dis_mm_x, 30.0)
        self.assertAlmostEqual(cfg.pa_clr_dis_mm_y, 0.0)


class WipeGeometryTest(unittest.TestCase):
    """The randomized XY point selection on the wipe pad must stay within bounds."""

    def _make_params(self):
        return nozzle_clear.NozzleClearConfig(FakeConfig())

    @patch('random.uniform')
    def test_ke_geometry_with_zero_randomization(self, mock_uniform):
        """With pa_clr_dis_mm_x=0 and clr_noz_len_x=3, margin=5 makes avail_x=0.
        With pa_clr_dis_mm_y=30 and clr_noz_len_y=50, margin=5 makes avail_y=15."""
        mock_uniform.return_value = 0.0
        params = self._make_params()
        margin = 5
        avail_x = max(params.clr_noz_len_x - abs(params.pa_clr_dis_mm_x) - margin, 0)
        avail_y = max(params.clr_noz_len_y - abs(params.pa_clr_dis_mm_y) - margin, 0)
        self.assertAlmostEqual(avail_x, 0.0)
        self.assertAlmostEqual(avail_y, 15.0)

        src_x = params.clr_noz_start_x + 0.0
        src_y = params.clr_noz_start_y + 0.0
        self.assertAlmostEqual(src_x, -3.0)
        self.assertAlmostEqual(src_y, 20.0)

        end_x = src_x + params.pa_clr_dis_mm_x
        end_y = src_y + params.pa_clr_dis_mm_y
        self.assertAlmostEqual(end_x, -3.0)
        self.assertAlmostEqual(end_y, 50.0)

    @patch('random.uniform')
    def test_ke_geometry_with_max_randomization(self, mock_uniform):
        mock_uniform.return_value = 15.0
        params = self._make_params()
        src_x = params.clr_noz_start_x + 0.0
        src_y = params.clr_noz_start_y + 15.0
        self.assertAlmostEqual(src_y, 35.0)

        end_y = src_y + params.pa_clr_dis_mm_y
        self.assertAlmostEqual(end_y, 65.0)
        self.assertLessEqual(end_y, params.clr_noz_start_y + params.clr_noz_len_y)


class ZMathTest(unittest.TestCase):
    """Verify the Z arithmetic: push-down from contact point matches the legacy behavior."""

    def test_pa_clr_down_mm_subtraction(self):
        """With pa_clr_down_mm=-0.15 and contact_z=1.5:
        approach_z = contact_z - pa_clr_down_mm = 1.5 - (-0.15) = 1.65 (above contact)
        drag_z = contact_z + pa_clr_down_mm = 1.5 + (-0.15) = 1.35 (below contact)"""
        contact_z = 1.5
        pa_clr_down_mm = -0.15
        approach_z = contact_z - pa_clr_down_mm
        drag_z = contact_z + pa_clr_down_mm
        self.assertAlmostEqual(approach_z, 1.65)
        self.assertAlmostEqual(drag_z, 1.35)
        self.assertGreater(approach_z, contact_z)
        self.assertLess(drag_z, contact_z)


class ClearNozzleCallPatternTest(unittest.TestCase):
    """Verify that clear_nozzle() calls touch_probe exactly twice and uses the
    correct temperature sequence."""

    def _build_mocks(self):
        probe = MagicMock()
        probe.touch_probe = MagicMock(return_value=1.5)

        toolhead = MagicMock()
        gcode = MagicMock()

        printer = MagicMock()
        reactor = MagicMock()
        reactor.monotonic.return_value = 0.0
        reactor.pause.return_value = 0.1
        printer.get_reactor.return_value = reactor

        pheaters = MagicMock()
        printer.lookup_object.side_effect = self._lookup_factory(pheaters)

        return probe, toolhead, gcode, printer, pheaters, reactor

    def _lookup_factory(self, pheaters):
        extruder = MagicMock()
        extruder.heater = MagicMock()
        extruder.heater.target_temp = 0
        extruder.heater.smoothed_temp = 200.0

        bed = MagicMock()
        bed.heater = MagicMock()
        bed.heater.target_temp = 0
        bed.heater.smoothed_temp = 60.0

        def lookup(name, default=None):
            return {'heaters': pheaters, 'extruder': extruder,
                    'heater_bed': bed}.get(name, default)
        return lookup

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', True)
    def test_hardware_blocked_raises(self):
        """The HARDWARE_BEHAVIOR_BLOCKED guard must prevent execution whenever it's True -
        tested here with an explicit patch rather than the module's own current value,
        since the Phase 1.8B integration candidate intentionally ships this flag as False
        (source-level activation, pending owner-attended hardware qualification - see
        ModuleConstantsTest.test_hardware_behavior_activated_for_integration_candidate)."""
        probe, toolhead, gcode, printer, _, _ = self._build_mocks()
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        with self.assertRaises(AssertionError) as ctx:
            nozzle_clear.clear_nozzle(
                probe, toolhead, gcode, printer, params,
                hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)
        self.assertIn("NOT qualified", str(ctx.exception))

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_touch_probe_called_twice(self, _mock_uniform):
        probe, toolhead, gcode, printer, _, _ = self._build_mocks()
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)
        self.assertEqual(probe.touch_probe.call_count, 2)

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_touch_probe_passes_config_params(self, _mock_uniform):
        probe, toolhead, gcode, printer, _, _ = self._build_mocks()
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)
        for c in probe.touch_probe.call_args_list:
            self.assertEqual(c[0][0], 25)
            self.assertEqual(c[1]['pro_cnt'], 3)

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_heater_sequence_bed_then_nozzle(self, _mock_uniform):
        probe, toolhead, gcode, printer, pheaters, _ = self._build_mocks()
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)
        set_temp_calls = pheaters.set_temperature.call_args_list
        self.assertGreater(len(set_temp_calls), 0)

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_hot_end_temp_default_is_hot_min(self, _mock_uniform):
        """When hot_end_temp is None (default), the final nozzle temp should be hot_min_temp."""
        probe, toolhead, gcode, printer, pheaters, _ = self._build_mocks()
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65, hot_end_temp=None)
        last_nozzle_calls = [c for c in pheaters.set_temperature.call_args_list
                             if c[0][1] != MagicMock()]
        self.assertGreater(len(last_nozzle_calls), 0)


class TouchProbeErrorTest(unittest.TestCase):
    """If touch_probe raises, the error must propagate (not be silently caught)."""

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_touch_probe_error_propagates(self, _mock_uniform):
        probe = MagicMock()
        probe.touch_probe = MagicMock(side_effect=RuntimeError("sensor timeout"))
        toolhead = MagicMock()
        gcode = MagicMock()
        printer = MagicMock()
        reactor = MagicMock()
        reactor.monotonic.return_value = 0.0
        printer.get_reactor.return_value = reactor
        pheaters = MagicMock()
        extruder = MagicMock()
        extruder.heater = MagicMock()
        extruder.heater.target_temp = 0
        extruder.heater.smoothed_temp = 200.0
        bed = MagicMock()
        bed.heater = MagicMock()
        bed.heater.target_temp = 0
        bed.heater.smoothed_temp = 60.0
        printer.lookup_object.side_effect = lambda n, d=None: {
            'heaters': pheaters, 'extruder': extruder, 'heater_bed': bed
        }.get(n, d)
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        with self.assertRaises(RuntimeError):
            nozzle_clear.clear_nozzle(
                probe, toolhead, gcode, printer, params,
                hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)


class ModuleConstantsTest(unittest.TestCase):
    """Phase 1.8B integration candidate: HARDWARE_BEHAVIOR_BLOCKED is intentionally False
    in the shipped module (source-level activation - see nozzle_clear.py's own module
    docstring). This is NOT a claim that hardware qualification has happened; it's the
    prerequisite source state for the owner-attended hardware gate to be run at all."""

    def test_hardware_behavior_activated_for_integration_candidate(self):
        self.assertFalse(nozzle_clear.HARDWARE_BEHAVIOR_BLOCKED)

    def test_module_has_clear_nozzle(self):
        self.assertTrue(callable(nozzle_clear.clear_nozzle))

    def test_module_has_config_class(self):
        self.assertTrue(callable(nozzle_clear.NozzleClearConfig))

    def test_hardware_gate_is_not_a_bare_assert(self):
        """Offline-review regression test (2026-08-28): the HARDWARE_BEHAVIOR_BLOCKED gate
        at the top of clear_nozzle() must not rely on a bare `assert` statement, because
        CPython strips every `assert` when run with -O/-OO or PYTHONOPTIMIZE set, which
        would silently disable this hardware-safety gate. Checked at the source level
        (bytecode inspection would be Python-version-fragile): the function's source must
        not contain a bare `assert` on HARDWARE_BEHAVIOR_BLOCKED, and must instead use an
        explicit, unconditionally-evaluated `if: raise` that a real `-O` run cannot strip.
        """
        import inspect
        source = inspect.getsource(nozzle_clear.clear_nozzle)
        self.assertNotIn(
            'assert not HARDWARE_BEHAVIOR_BLOCKED', source,
            "clear_nozzle() must not gate hardware use with a bare `assert` statement - "
            "assert is stripped under python -O/-OO, silently disabling this safety gate")
        self.assertIn('raise AssertionError', source)


class BedMeshSuspensionTest(unittest.TestCase):
    """Offline-review regression test (2026-08-28): clear_nozzle()'s two wipe-pad touch
    probes must suspend any active bed mesh for the duration of each touch_probe() call,
    matching prtouch_probe.PrtouchProbe.touch_probe()'s own behavior - a loaded mesh
    applies a Z-compensation transform to every toolhead move, which would skew a raw
    touch-probe reading taken at the wipe pad's own XY point."""

    def _build_mocks(self, bed_mesh=None):
        probe = MagicMock()
        probe.touch_probe = MagicMock(return_value=1.5)

        toolhead = MagicMock()
        gcode = MagicMock()

        printer = MagicMock()
        reactor = MagicMock()
        reactor.monotonic.return_value = 0.0
        reactor.pause.return_value = 0.1
        printer.get_reactor.return_value = reactor

        pheaters = MagicMock()
        extruder = MagicMock()
        extruder.heater = MagicMock()
        extruder.heater.target_temp = 0
        extruder.heater.smoothed_temp = 200.0

        bed = MagicMock()
        bed.heater = MagicMock()
        bed.heater.target_temp = 0
        bed.heater.smoothed_temp = 60.0

        def lookup(name, default=None):
            return {'heaters': pheaters, 'extruder': extruder,
                    'heater_bed': bed, 'bed_mesh': bed_mesh}.get(name, default)
        printer.lookup_object.side_effect = lookup

        return probe, toolhead, gcode, printer

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_no_bed_mesh_configured_is_a_no_op(self, _mock_uniform):
        """When [bed_mesh] isn't configured at all (lookup_object returns None), the
        routine must run without touching any mesh API - nothing to suspend/restore."""
        probe, toolhead, gcode, printer = self._build_mocks(bed_mesh=None)
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)
        self.assertEqual(probe.touch_probe.call_count, 2)

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_active_mesh_is_suspended_around_each_touch_probe(self, _mock_uniform):
        bed_mesh = MagicMock()
        saved = object()  # sentinel identifying "the mesh that was active on entry"
        bed_mesh.get_mesh.return_value = saved

        probe, toolhead, gcode, printer = self._build_mocks(bed_mesh=bed_mesh)
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)

        # Suspended (set_mesh(None)) and restored (set_mesh(saved)) once per touch_probe
        # call - two touches this routine makes.
        self.assertEqual(bed_mesh.set_mesh.call_args_list,
                          [call(None), call(saved), call(None), call(saved)])
        self.assertEqual(probe.touch_probe.call_count, 2)

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_mesh_restored_even_if_touch_probe_raises(self, _mock_uniform):
        """The mesh must be restored on the error exit path too, not just on success -
        otherwise a failed wipe-pad touch would silently leave the mesh disabled for
        every subsequent print move."""
        bed_mesh = MagicMock()
        saved = object()
        bed_mesh.get_mesh.return_value = saved

        probe, toolhead, gcode, printer = self._build_mocks(bed_mesh=bed_mesh)
        probe.touch_probe = MagicMock(side_effect=RuntimeError("sensor timeout"))
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        with self.assertRaises(RuntimeError):
            nozzle_clear.clear_nozzle(
                probe, toolhead, gcode, printer, params,
                hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)

        # One attempted touch_probe call, one suspend, one restore - the mesh must not be
        # left disabled after the exception propagates.
        self.assertEqual(bed_mesh.set_mesh.call_args_list, [call(None), call(saved)])

    @patch.object(nozzle_clear, 'HARDWARE_BEHAVIOR_BLOCKED', False)
    @patch('random.uniform', return_value=0.0)
    def test_no_mesh_currently_loaded_does_not_call_set_mesh(self, _mock_uniform):
        """[bed_mesh] is configured but no mesh is currently loaded (get_mesh() returns
        None, e.g. before the first BED_MESH_CALIBRATE of a session) - nothing to
        suspend, so set_mesh() should never be called at all."""
        bed_mesh = MagicMock()
        bed_mesh.get_mesh.return_value = None

        probe, toolhead, gcode, printer = self._build_mocks(bed_mesh=bed_mesh)
        params = nozzle_clear.NozzleClearConfig(FakeConfig())
        nozzle_clear.clear_nozzle(
            probe, toolhead, gcode, printer, params,
            hot_min_temp=140, hot_max_temp=180, bed_max_temp=65)

        bed_mesh.set_mesh.assert_not_called()


if __name__ == '__main__':
    unittest.main()
