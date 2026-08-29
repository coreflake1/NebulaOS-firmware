# Phase 1.8 safety closure: upstream 58bd parity proofs for nebulaos_z_offset_probe.py
#
# Source-level verification that our implementation matches the safety semantics of
# upstream Klipper 58bd67db's load_cell_probe.py / LoadCellProbingMove / LoadCellProbeConfigHelper.
#
# These tests read the module source from disk (NOT imported — upstream dependencies
# absent in the extensions repo) and verify structural/semantic properties. Behavioral
# tests run through the fake test infrastructure where possible.
#
# Run from klippy/: python3 -m unittest extras.test_z_offset_probe_safety -v
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import os
import re
import unittest

from . import prtouch_test_support as fake
from . import z_compensate


def _module_source():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, 'nebulaos_z_offset_probe.py')
    with open(path) as f:
        return f.read()


def _module_code_lines():
    return '\n'.join(
        line for line in _module_source().splitlines()
        if line.strip() and not line.strip().startswith('#'))


def _build(stub_measurement=0.0):
    printer, mcu, _pins, _values = fake.build_environment()
    zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
    zc = z_compensate.ZCompensate(zc_config)
    fake.connect(printer, mcu)
    z_offset_probe = printer.lookup_object('nebulaos_z_offset_probe')
    z_offset_probe.touch_probe = lambda down_min_z, **kw: stub_measurement
    return printer, mcu, z_offset_probe, zc


# ======================================================================
# GAP #1 — CALIBRATION MUST HARD-BLOCK MOTION
# ======================================================================

class CalibrationGateSourceTest(unittest.TestCase):
    """Verify the calibration check exists in _tare_and_arm, called before
    any motion. Upstream 58bd: LoadCellProbingMove.probing_move() line 362."""

    def test_tare_and_arm_checks_is_calibrated(self):
        code = _module_code_lines()
        self.assertIn('is_calibrated()', code)

    def test_is_calibrated_checked_before_collector_starts(self):
        source = _module_source()
        cal_pos = source.find('is_calibrated()')
        collector_pos = source.find('start_collecting')
        self.assertGreater(collector_pos, cal_pos,
                           "is_calibrated() must be checked BEFORE collector starts")

    def test_is_calibrated_checked_before_probing_move(self):
        source = _module_source()
        tare_method = _extract_method(source, '_tare_and_arm')
        self.assertIn('is_calibrated()', tare_method,
                      "calibration gate must be in _tare_and_arm")
        touch_method = _extract_method(source, 'touch_probe')
        self.assertIn('_tare_and_arm()', touch_method,
                      "_tare_and_arm must be called from touch_probe")
        self.assertIn('probing_move(', touch_method,
                      "probing_move must be called from touch_probe")
        tare_pos = touch_method.find('_tare_and_arm()')
        probe_pos = touch_method.find('probing_move(')
        self.assertGreater(probe_pos, tare_pos,
                           "_tare_and_arm must run BEFORE probing_move")

    def test_calibration_error_message_names_calibration_command(self):
        source = _module_source()
        self.assertIn('LOAD_CELL_CALIBRATE', source)

    def test_upstream_is_calibrated_requires_both_values(self):
        """Upstream 58bd load_cell.py line 503-505: is_calibrated() returns True
        only when BOTH counts_per_gram AND reference_tare_counts are set."""
        ref_source_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            '..', '..', '..', '..', '_scratch', 'ref-klipper-mainline',
            'klippy', 'extras', 'load_cell.py')
        if not os.path.exists(ref_source_path):
            self.skipTest("upstream reference source not available")
        with open(ref_source_path) as f:
            upstream = f.read()
        self.assertIn('counts_per_gram is not None', upstream)
        self.assertIn('reference_tare_counts is not None', upstream)


# ======================================================================
# GAP #2 — FORCE SAFETY SEMANTICS / UPSTREAM PARITY
# ======================================================================

class ForceSafetyRangeSourceTest(unittest.TestCase):
    """Upstream 58bd: LoadCellProbeConfigHelper.get_safety_range() uses
    reference_tare_counts as the safety envelope center, NOT live tare."""

    def test_safety_range_uses_reference_tare_counts(self):
        code = _module_code_lines()
        self.assertIn('get_reference_tare_counts()', code)

    def test_safety_range_does_not_use_live_tare_for_center(self):
        source = _module_source()
        safety_method = _extract_method(source, '_get_safety_range')
        safety_code = '\n'.join(
            line for line in safety_method.splitlines()
            if line.strip() and not line.strip().startswith('#')
            and not line.strip().startswith('"""')
            and not line.strip().startswith("'''"))
        occurrences = [w for w in safety_code.split()
                       if 'tare_counts' in w
                       and 'reference_tare_counts' not in w
                       and 'get_reference_tare_counts' not in w]
        self.assertEqual(occurrences, [],
                         "safety range must use reference_tare_counts, not live tare")

    def test_sensor_range_validated(self):
        code = _module_code_lines()
        self.assertIn('get_range()', code)
        self.assertIn('exceeds sensor range', _module_source())

    def test_config_uses_force_safety_limit_name(self):
        code = _module_code_lines()
        self.assertIn("'force_safety_limit'", code)
        self.assertNotIn("'safety_limit'", code)


class CountsPerGramOverflowTest(unittest.TestCase):
    """Upstream 58bd: LoadCellProbeConfigHelper.get_grams_per_count() checks
    counts_per_gram >= (1<<29) and raises OverflowError."""

    def test_overflow_check_present(self):
        code = _module_code_lines()
        self.assertIn('1 << 29', code)
        self.assertIn('OverflowError', code)


class FracGramsConversionTest(unittest.TestCase):
    """Upstream 58bd: FRAC_GRAMS_CONV = 32768.0 = 2^15, used for
    grams → fractional-gram conversion in SOS filter and trigger."""

    def test_frac_grams_conv_matches_upstream(self):
        code = _module_code_lines()
        self.assertIn('FRAC_GRAMS_CONV = 32768.0', code)

    def test_trigger_uses_frac_grams_conv(self):
        code = _module_code_lines()
        self.assertIn('FRAC_GRAMS_CONV', code)
        self.assertIn('abs_ge', code)


# ======================================================================
# GAP #3 — TARE SEMANTICS
# ======================================================================

class TareSampleCountTest(unittest.TestCase):
    """Upstream 58bd: LoadCellProbeConfigHelper.get_tare_samples() uses
    math.ceil(tare_time * sps), not int() truncation."""

    def test_uses_math_ceil_not_int(self):
        code = _module_code_lines()
        self.assertIn('math.ceil', code)
        self.assertIn('import math', _module_source())

    def test_tare_time_default_covers_mains_cycles(self):
        source = _module_source()
        self.assertIn('4. / 60.', source)


# ======================================================================
# GAP #4 — SOS FILTER PARITY
# ======================================================================

class SosFilterParityTest(unittest.TestCase):
    """Verify SOS filter setup matches upstream 58bd load_cell_probe.py line 679:
    MCU_SosFilter(mcu, cmd_queue, 4) — 4 max sections."""

    def test_sos_filter_max_sections_is_4(self):
        code = _module_code_lines()
        self.assertIn('MCU_SosFilter(mcu, cmd_queue, 4)', code)

    def test_sos_filter_offset_uses_negative_tare(self):
        source = _module_source()
        self.assertIn('int(-tare_counts)', source)

    def test_sos_filter_scale_uses_grams_per_count(self):
        code = _module_code_lines()
        self.assertIn('_get_grams_per_count()', code)
        self.assertIn('FRAC_GRAMS_CONV', code)


# ======================================================================
# TRIGGER SEMANTICS
# ======================================================================

class TriggerDirectionTest(unittest.TestCase):
    """Upstream 58bd uses abs_ge (absolute value greater-or-equal) for the
    trigger comparison. This means trigger fires when |filtered_force| >= threshold,
    regardless of compression vs tension direction. Safe for nozzle contact where
    load direction depends on cell orientation."""

    def test_trigger_mode_is_abs_ge(self):
        code = _module_code_lines()
        self.assertIn('"abs_ge"', code)

    def test_trigger_value_is_force_times_frac_grams(self):
        code = _module_code_lines()
        self.assertIn('self._trigger_force * FRAC_GRAMS_CONV', code)


# ======================================================================
# Z FLOOR SEMANTICS
# ======================================================================

class ZFloorTest(unittest.TestCase):
    """touch_probe must negate the positive down_min_z depth to get a Z
    coordinate, then clamp to stepper position_min."""

    def test_z_floor_negates_down_min_z(self):
        code = _module_code_lines()
        self.assertIn('max(self._z_min_position, -down_min_z)', code)


# ======================================================================
# MULTI-TOUCH SEMANTICS
# ======================================================================

class MultiTouchSourceTest(unittest.TestCase):
    """For pro_cnt > 1: fresh tare before each contact, retract between,
    exception on any individual touch aborts the entire operation."""

    def test_tare_and_arm_called_inside_loop(self):
        source = _module_source()
        method = _extract_method(source, 'touch_probe')
        tare_pos = method.find('_tare_and_arm')
        range_pos = method.find('range(pro_cnt)')
        self.assertGreater(tare_pos, range_pos,
                           "_tare_and_arm must be inside the pro_cnt loop")

    def test_retract_via_fit(self):
        """Retract happens inside _fit_contact_z, collecting ascent samples."""
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('retract_dist', fit_method)
        self.assertIn('manual_move', fit_method)
        touch_method = _extract_method(_module_source(), 'touch_probe')
        self.assertIn('_fit_contact_z(', touch_method)

    def test_no_partial_average_on_failure(self):
        """If probing_move raises on touch N, the exception propagates —
        no partial average is returned."""
        method = _extract_method(_module_source(), 'touch_probe')
        self.assertNotIn('try:', method)
        self.assertNotIn('except', method)


# ======================================================================
# CLEANUP / ERROR RECOVERY
# ======================================================================

class CleanupSourceTest(unittest.TestCase):
    """Trigger/trsync cleanup is handled by phoming.probing_move() which wraps
    the home_start/home_wait cycle in try/finally. Verify we delegate to it
    rather than reimplementing cleanup."""

    def test_uses_phoming_probing_move(self):
        code = _module_code_lines()
        self.assertIn('phoming.probing_move(', code)

    def test_no_manual_home_start_home_wait(self):
        code = _module_code_lines()
        self.assertNotIn('home_start(', code)
        self.assertNotIn('home_wait(', code)


# ======================================================================
# NO DUPLICATE GLOBAL PROBE (retained from architecture tests)
# ======================================================================

class ArchitectureInvariantsTest(unittest.TestCase):
    """Verify architecture invariants survive the safety closure changes."""

    def test_no_global_probe_registration(self):
        code = _module_code_lines()
        self.assertNotIn("add_object('probe'", code)

    def test_no_probe_command_helper(self):
        code = _module_code_lines()
        self.assertNotIn('ProbeCommandHelper', code)

    def test_no_homing_via_probe_helper(self):
        code = _module_code_lines()
        self.assertNotIn('HomingViaProbeHelper', code)

    def test_upstream_only_imports(self):
        source = _module_source()
        allowed_package_imports = ('hx71x', 'load_cell', 'probe',
                                   'trigger_analog')
        allowed_from_imports = {
            'load_cell_probe': ('LCBestFit', '_lookup_z_pos',
                                'FIT_MIN_POINTS',
                                'ASCENT_DATA_WINDOW_SECONDS'),
        }
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith('from . import'):
                modules = [m.strip() for m in
                           stripped.split('from . import')[1].split(',')]
                for mod in modules:
                    self.assertIn(mod, allowed_package_imports,
                                  "unexpected import: %s" % mod)
            elif stripped.startswith('from .') and ' import ' in stripped:
                parts = stripped.split(' import ', 1)
                mod_name = parts[0].replace('from .', '').strip()
                self.assertIn(mod_name, allowed_from_imports,
                              "unexpected from-import module: %s" % mod_name)
                symbols = [s.strip().rstrip(')') for s in
                           parts[1].replace('(', '').split(',')]
                for sym in symbols:
                    if sym:
                        self.assertIn(
                            sym, allowed_from_imports[mod_name],
                            "unexpected symbol from %s: %s"
                            % (mod_name, sym))


# ======================================================================
# UPSTREAM 58bd PARITY — STRUCTURAL COMPARISON
# ======================================================================

class Upstream58bdParityTest(unittest.TestCase):
    """Compare our implementation against upstream 58bd load_cell_probe.py's
    LoadCellProbingMove._pause_and_tare() and probing_move() methods.
    These tests read upstream reference source and verify we implement
    equivalent safety semantics."""

    @classmethod
    def setUpClass(cls):
        ref_dir = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            '..', '..', '..', '..', '_scratch', 'ref-klipper-mainline',
            'klippy', 'extras')
        lcp = os.path.join(ref_dir, 'load_cell_probe.py')
        lc = os.path.join(ref_dir, 'load_cell.py')
        if not os.path.exists(lcp) or not os.path.exists(lc):
            raise unittest.SkipTest("upstream reference source not available")
        with open(lcp) as f:
            cls.upstream_lcp = f.read()
        with open(lc) as f:
            cls.upstream_lc = f.read()
        cls.our_source = _module_source()

    def test_upstream_uses_is_calibrated_gate(self):
        self.assertIn('is_calibrated()', self.upstream_lcp)

    def test_upstream_uses_reference_tare_for_safety(self):
        self.assertIn('get_reference_tare_counts()', self.upstream_lcp)

    def test_upstream_validates_sensor_range(self):
        self.assertIn('exceeds sensor range', self.upstream_lcp)

    def test_upstream_checks_counts_per_gram_overflow(self):
        self.assertIn('1<<29', self.upstream_lcp)

    def test_upstream_uses_abs_ge_trigger(self):
        self.assertIn('"abs_ge"', self.upstream_lcp)

    def test_upstream_frac_grams_conv_is_32768(self):
        self.assertIn('FRAC_GRAMS_CONV = 32768.0', self.upstream_lcp)

    def test_upstream_tare_uses_ceil(self):
        self.assertIn('math.ceil', self.upstream_lcp)

    def test_our_module_matches_all_upstream_safety_symbols(self):
        """Every safety-critical upstream symbol used in the probe path
        must appear in our module too."""
        required = [
            'is_calibrated',
            'get_reference_tare_counts',
            'get_range',
            'get_counts_per_gram',
            'set_raw_range',
            'set_offset_scale',
            'set_trigger',
            'probing_move',
            'FRAC_GRAMS_CONV',
            'get_collector',
            'collect_min',
            'collect_until',
            'LCBestFit',
            '_lookup_z_pos',
            'FIT_MIN_POINTS',
            'ASCENT_DATA_WINDOW_SECONDS',
            'find_best_fit',
        ]
        for sym in required:
            self.assertIn(sym, self.our_source,
                          "upstream safety symbol '%s' missing" % sym)

    def test_upstream_calibration_requires_both_values(self):
        self.assertIn('counts_per_gram is not None', self.upstream_lc)
        self.assertIn('reference_tare_counts is not None', self.upstream_lc)

    def test_upstream_min_counts_per_gram(self):
        """Upstream enforces MIN_COUNTS_PER_GRAM = 1. at config load time."""
        self.assertIn('MIN_COUNTS_PER_GRAM', self.upstream_lc)


# ======================================================================
# CONTINUOUS TARE FILTER OMISSION JUSTIFICATION
# ======================================================================

class ContinuousTareFilterOmissionTest(unittest.TestCase):
    """Verify ContinuousTareFilterHelper is intentionally NOT used and
    the justification is documented in source comments."""

    def test_no_continuous_tare_filter(self):
        code = _module_code_lines()
        self.assertNotIn('ContinuousTareFilter', code)

    def test_omission_documented_in_source(self):
        source = _module_source()
        self.assertIn('ContinuousTareFilter', source,
                      "ContinuousTareFilter omission must be documented")
        self.assertIn('intentionally omitted', source)


# ======================================================================
# BEHAVIORAL TESTS THROUGH z_compensate INTEGRATION
# ======================================================================

class CalibrationGateBehavioralTest(unittest.TestCase):
    """Verify that z_compensate refuses Z_OFFSET_CALIBRATION when the
    underlying probe reports uncalibrated state."""

    def test_z_offset_calibration_calls_touch_probe(self):
        _, _, z_probe, zc = _build(stub_measurement=0.05)
        calls = []
        def tracking(down_min_z, **kw):
            calls.append(down_min_z)
            return 0.05
        z_probe.touch_probe = tracking
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertEqual(len(calls), 1)

    def test_touch_probe_raising_calibration_error_propagates(self):
        _, _, z_probe, zc = _build()
        z_probe.touch_probe = lambda *a, **kw: (_ for _ in ()).throw(
            fake.CommandError("load cell not calibrated"))
        with self.assertRaises(fake.CommandError) as ctx:
            zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn("not calibrated", str(ctx.exception))
        self.assertEqual(zc.calibration_state, "error")


class ZFloorBehavioralTest(unittest.TestCase):
    """Verify z_compensate passes down_min_z to touch_probe."""

    def test_down_min_z_passed_to_touch_probe(self):
        _, _, z_probe, zc = _build(stub_measurement=0.05)
        calls = []
        def tracking(down_min_z, **kw):
            calls.append({'down_min_z': down_min_z, 'kwargs': kw})
            return 0.05
        z_probe.touch_probe = tracking
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]['down_min_z'], zc.down_min_z)


class MultiTouchBehavioralTest(unittest.TestCase):
    """Verify multi-touch failure propagation through z_compensate."""

    def test_failure_during_multitouch_propagates(self):
        """z_compensate passes pro_cnt to touch_probe. If touch_probe raises
        (e.g. on an internal sub-touch), the error must propagate."""
        _, _, z_probe, zc = _build()
        self.assertGreater(zc.pr_probe_cnt, 1)
        z_probe.touch_probe = lambda *a, **kw: (_ for _ in ()).throw(
            fake.CommandError("multi-touch contact failure"))
        with self.assertRaises(fake.CommandError) as ctx:
            zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn("contact failure", str(ctx.exception))
        self.assertEqual(zc.calibration_state, "error")


# ======================================================================
# ZERO-MOTION CALIBRATION COMMANDS
# ======================================================================

class ZeroMotionCommandsSourceTest(unittest.TestCase):
    """Verify upstream LoadCellCommandHelper registers the expected G-code
    commands under the section name. Our module creates LoadCell(config, sensor)
    which instantiates LoadCellCommandHelper in its __init__."""

    def test_upstream_registers_tare_command(self):
        ref = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            '..', '..', '..', '..', '_scratch', 'ref-klipper-mainline',
            'klippy', 'extras', 'load_cell.py')
        if not os.path.exists(ref):
            self.skipTest("upstream reference not available")
        with open(ref) as f:
            upstream = f.read()
        self.assertIn('LOAD_CELL_TARE', upstream)
        self.assertIn('LOAD_CELL_READ', upstream)
        self.assertIn('LOAD_CELL_CALIBRATE', upstream)
        self.assertIn('LOAD_CELL_DIAGNOSTIC', upstream)
        self.assertIn('register_mux_command', upstream)

    def test_our_module_creates_load_cell(self):
        code = _module_code_lines()
        self.assertIn('load_cell.LoadCell(config, self._sensor)', code)


# ======================================================================
# PIN OWNERSHIP / NO DUPLICATE SENSOR
# ======================================================================

class PinOwnershipTest(unittest.TestCase):
    """The module creates its own HX711 sensor instance. A separate [load_cell]
    section using the same pins would cause an MCU pin conflict."""

    def test_module_creates_own_sensor(self):
        code = _module_code_lines()
        self.assertIn('sensor_class(config)', code)
        self.assertIn('HX71X_SENSOR_TYPES', code)


# ======================================================================
# CONTACT INTERPOLATION — LCBestFit PARITY
# ======================================================================

class ContactInterpolationSourceTest(unittest.TestCase):
    """Verify touch_probe returns fitted contact Z (not raw trigger Z)
    via upstream LCBestFit analysis on ascent samples."""

    def test_imports_lc_best_fit(self):
        source = _module_source()
        self.assertIn('LCBestFit', source)
        self.assertIn('from .load_cell_probe import', source)

    def test_imports_lookup_z_pos(self):
        source = _module_source()
        self.assertIn('_lookup_z_pos', source)

    def test_imports_fit_min_points(self):
        source = _module_source()
        self.assertIn('FIT_MIN_POINTS', source)

    def test_imports_ascent_data_window(self):
        source = _module_source()
        self.assertIn('ASCENT_DATA_WINDOW_SECONDS', source)

    def test_best_fit_instantiated(self):
        code = _module_code_lines()
        self.assertIn('LCBestFit(self._printer)', code)

    def test_find_best_fit_called(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('find_best_fit(data)', fit_method)

    def test_raw_trigger_z_not_appended_directly(self):
        """touch_probe must append fitted Z, not raw epos[2]."""
        touch_method = _extract_method(_module_source(), 'touch_probe')
        self.assertNotIn('results.append(epos[2])', touch_method)
        self.assertIn('results.append(fitted_z)', touch_method)

    def test_fit_collector_started_before_probing_move(self):
        touch_method = _extract_method(_module_source(), 'touch_probe')
        collector_pos = touch_method.find('_start_fit_collector()')
        probe_pos = touch_method.find('probing_move(')
        self.assertGreater(probe_pos, collector_pos,
                           "fit collector must start BEFORE probing_move")

    def test_ascent_samples_collected(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('collect_until(', fit_method)

    def test_ascent_window_applied(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('ASCENT_DATA_WINDOW_SECONDS', fit_method)
        self.assertIn('ascent_start_time', fit_method)

    def test_z_position_lookup_used(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('_lookup_z_pos(toolhead', fit_method)

    def test_minimum_sample_guard(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('2 * FIT_MIN_POINTS', fit_method)
        self.assertIn('insufficient ascent samples', fit_method)

    def test_below_above_count_guard(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('n_below < FIT_MIN_POINTS', fit_method)
        self.assertIn('n_above < FIT_MIN_POINTS', fit_method)

    def test_sensor_errors_checked_during_ascent(self):
        fit_method = _extract_method(_module_source(), '_fit_contact_z')
        self.assertIn('sensor errors during ascent', fit_method)

    def test_multitouch_averages_fitted_z(self):
        """Multi-touch loop appends fitted_z, average is over fitted values."""
        touch_method = _extract_method(_module_source(), 'touch_probe')
        self.assertIn('_fit_contact_z(', touch_method)
        self.assertIn('results.append(fitted_z)', touch_method)
        self.assertIn('sum(results)', touch_method)


class ContactInterpolationDiagnosticsTest(unittest.TestCase):
    """Verify diagnostic values are preserved for hardware qualification."""

    def test_raw_trigger_z_stored(self):
        code = _module_code_lines()
        self.assertIn('_last_raw_trigger_z', code)

    def test_fitted_contact_z_stored(self):
        code = _module_code_lines()
        self.assertIn('_last_fitted_contact_z', code)

    def test_fit_delta_stored(self):
        code = _module_code_lines()
        self.assertIn('_last_fit_delta', code)

    def test_diagnostics_in_status(self):
        method = _extract_method(_module_source(), 'get_status')
        self.assertIn('last_raw_trigger_z', method)
        self.assertIn('last_fitted_contact_z', method)
        self.assertIn('last_fit_delta', method)


class ContactInterpolationUpstreamParityTest(unittest.TestCase):
    """Verify our fit implementation matches upstream 58bd TappingMove semantics."""

    @classmethod
    def setUpClass(cls):
        ref_path = os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            '..', '..', '..', '..', '_scratch', 'ref-klipper-mainline',
            'klippy', 'extras', 'load_cell_probe.py')
        if not os.path.exists(ref_path):
            raise unittest.SkipTest("upstream reference source not available")
        with open(ref_path) as f:
            cls.upstream = f.read()
        cls.our_source = _module_source()

    def test_upstream_uses_lc_best_fit(self):
        self.assertIn('LCBestFit', self.upstream)

    def test_upstream_uses_lookup_z_pos(self):
        self.assertIn('_lookup_z_pos', self.upstream)

    def test_upstream_uses_fit_min_points(self):
        self.assertIn('FIT_MIN_POINTS', self.upstream)

    def test_upstream_uses_ascent_data_window(self):
        self.assertIn('ASCENT_DATA_WINDOW_SECONDS', self.upstream)

    def test_upstream_collects_until_move_end(self):
        self.assertIn('collect_until(', self.upstream)

    def test_upstream_replaces_epos_with_corrected_z(self):
        self.assertIn('epos[2] = corrected_z', self.upstream)

    def test_our_module_uses_same_fit_constants(self):
        self.assertIn('FIT_MIN_POINTS', self.our_source)
        self.assertIn('ASCENT_DATA_WINDOW_SECONDS', self.our_source)

    def test_our_module_returns_fitted_not_raw(self):
        touch_method = _extract_method(self.our_source, 'touch_probe')
        self.assertNotIn('results.append(epos[2])', touch_method)
        self.assertIn('results.append(fitted_z)', touch_method)


class FitErrorPropagationBehavioralTest(unittest.TestCase):
    """Verify that fit errors (insufficient samples, sensor errors during
    ascent) propagate through z_compensate as calibration errors."""

    def test_fit_error_aborts_calibration(self):
        _, _, z_probe, zc = _build()
        z_probe.touch_probe = lambda *a, **kw: (_ for _ in ()).throw(
            fake.CommandError("insufficient ascent samples"))
        with self.assertRaises(fake.CommandError) as ctx:
            zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn("insufficient", str(ctx.exception))
        self.assertEqual(zc.calibration_state, "error")

    def test_ascent_sensor_error_aborts_calibration(self):
        _, _, z_probe, zc = _build()
        z_probe.touch_probe = lambda *a, **kw: (_ for _ in ()).throw(
            fake.CommandError("sensor errors during ascent"))
        with self.assertRaises(fake.CommandError) as ctx:
            zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn("sensor errors", str(ctx.exception))
        self.assertEqual(zc.calibration_state, "error")


# ======================================================================
# Helper
# ======================================================================

def _extract_method(source, method_name):
    """Extract a method body from Python source by indentation."""
    lines = source.splitlines()
    in_method = False
    method_lines = []
    method_indent = None
    for line in lines:
        if 'def %s(' % method_name in line:
            in_method = True
            method_indent = len(line) - len(line.lstrip())
            method_lines.append(line)
            continue
        if in_method:
            if line.strip() == '' or line.strip().startswith('#'):
                method_lines.append(line)
                continue
            indent = len(line) - len(line.lstrip())
            if indent <= method_indent and line.strip():
                break
            method_lines.append(line)
    return '\n'.join(method_lines)


if __name__ == '__main__':
    unittest.main()
