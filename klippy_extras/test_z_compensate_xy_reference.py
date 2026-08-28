# Z-offset calibration XY-reference mission (2026-08-14) - proves cmd_z_offset_calibration's
# touch target comes from the printer's own real Z-homing XY ([gcode_macro _HOMING_PARAMS]'
# home_x/home_y - the actual position simpleaf/homing.cfg's _POST_HOME_XY leaves the toolhead
# at before G28 Z probes), not from [bed_mesh]'s own mesh_min/mesh_max center. Real,
# independently-confirmed bug on this printer's own live config: home=(110,111) vs the old
# bed_mesh-center approximation of (110.0,112.5) - a full 1.5mm mismatch in Y that silently
# skewed every calibration's target away from the exact bed spot BLTouch's own probe touched
# during Z-homing.
#
# Run from klippy/: python3 -m unittest extras.test_z_compensate_xy_reference -v (this fork's
# own layout - klippy/extras/ is a real Python package named 'extras', not 'klippy_extras' -
# see NebulaOS-firmware's klippy_extras/ mirror of this same file for that repo's own
# invocation form)
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import unittest

from . import prtouch_test_support as fake
from . import z_compensate


class _FakeHomingParams:
    """Minimal stand-in for the real [gcode_macro _HOMING_PARAMS] object. Real Klipper's
    PrinterGCodeMacro (gcode_macro.py) exposes its variable_* config values as a plain dict at
    self.variables - the exact same dict Jinja's own printer["gcode_macro _HOMING_PARAMS"].
    home_x resolves against inside homing.cfg itself. This fake matches that shape precisely
    so _resolve_z_home_xy() reads the identical structure the real object would provide."""

    def __init__(self, variables):
        self.variables = variables


def _build(homing_params_variables=None, mesh_min=(5., 10.), mesh_max=(215., 215.)):
    """homing_params_variables=None means [gcode_macro _HOMING_PARAMS] is not registered at
    all (proves the fallback path for printer.cfgs that don't use this SimpleAF-style homing
    macro); a dict registers it with exactly those variables, matching either a real
    home_x/home_y-defining macro or one that (like a bare _HOMING_PARAMS with unrelated
    variables) doesn't."""
    printer, mcu, _pins, _values = fake.build_environment(mesh_min=mesh_min, mesh_max=mesh_max)

    if homing_params_variables is not None:
        printer.add_object('gcode_macro _HOMING_PARAMS',
                            _FakeHomingParams(homing_params_variables))

    zc_config = fake.make_z_compensate_config(printer, dict(fake.REAL_Z_COMPENSATE_CONFIG))
    zc = z_compensate.ZCompensate(zc_config)

    fake.connect(printer, mcu)
    zc_config.assert_all_consumed()
    z_offset_probe = printer.lookup_object('nebulaos_z_offset_probe')
    return printer, mcu, z_offset_probe, zc


def _g1_target(zc):
    g1_scripts = [s for s in zc.gcode.scripts_run if s.startswith('G1 ')]
    assert g1_scripts, "cmd_z_offset_calibration must have issued a G1 positioning move"
    return g1_scripts[0]


class CalibrationTargetSourceTest(unittest.TestCase):
    """This printer's own real values: [gcode_macro _HOMING_PARAMS] home_x=110/home_y=111
    (simpleaf/homing.cfg), bl_offset=0,27 (fake.REAL_Z_COMPENSATE_CONFIG, matching this
    printer's own real [z_compensate] section) -> expected target (110, 138)."""

    def test_target_uses_real_homing_params_not_bed_mesh_center(self):
        _, mcu, z_probe, zc = _build(homing_params_variables={'home_x': 110, 'home_y': 111})
        self.assertEqual((zc.home_x, zc.home_y), (110.0, 111.0))
        z_probe.touch_probe = lambda down_min_z, **kw: 0.0
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn('X110.000 Y138.000', _g1_target(zc))

    def test_changing_bed_mesh_bounds_does_not_change_the_target(self):
        # Same _HOMING_PARAMS as above, but with [bed_mesh] mesh_min/mesh_max set to wildly
        # different bounds than this printer's own real ones - the target must not move at
        # all, proving [bed_mesh] is no longer consulted once _HOMING_PARAMS is available.
        _, mcu, z_probe, zc = _build(homing_params_variables={'home_x': 110, 'home_y': 111},
                                  mesh_min=(0., 0.), mesh_max=(300., 300.))
        self.assertEqual((zc.home_x, zc.home_y), (110.0, 111.0))
        z_probe.touch_probe = lambda down_min_z, **kw: 0.0
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn('X110.000 Y138.000', _g1_target(zc))

    def test_fractional_home_xy_is_preserved(self):
        # int-vs-float coming out of a real gcode_macro's variable_* parsing must not be
        # truncated - a printer whose real home position isn't a whole-number mm value must
        # still resolve exactly.
        _, mcu, z_probe, zc = _build(homing_params_variables={'home_x': 110.25, 'home_y': 111.75})
        self.assertEqual((zc.home_x, zc.home_y), (110.25, 111.75))


class FallbackToBedMeshCenterTest(unittest.TestCase):
    """A printer.cfg that doesn't use this SimpleAF-style homing macro at all (no
    [gcode_macro _HOMING_PARAMS], or one that exists but doesn't define home_x/home_y) must
    still get a usable - if approximate - calibration target, not a hard failure."""

    def test_fallback_when_homing_params_not_registered_at_all(self):
        _, mcu, z_probe, zc = _build(homing_params_variables=None)
        # this printer's own real [bed_mesh] mesh_min=5,10 / mesh_max=215,215 -> center
        # (110.0, 112.5) - the pre-2026-08-14 behavior, kept as the fallback.
        self.assertEqual((zc.home_x, zc.home_y), (110.0, 112.5))
        z_probe.touch_probe = lambda down_min_z, **kw: 0.0
        zc.cmd_z_offset_calibration(fake.FakeGCmd())
        self.assertIn('X110.000 Y139.500', _g1_target(zc))

    def test_fallback_when_homing_params_registered_but_missing_home_xy(self):
        _, mcu, z_probe, zc = _build(homing_params_variables={'safe_z': 5, 'homing_current': 1.5})
        self.assertEqual((zc.home_x, zc.home_y), (110.0, 112.5))


class ConfiguredMeshBoundsSourceTest(unittest.TestCase):
    """Official-mainline migration (2026-08-17): the fallback's mesh bounds now come from the
    [bed_mesh] config SECTION via the public ConfigWrapper API, not from
    bed_mesh.bmc.mesh_min/.mesh_max - three hops into BedMeshCalibrate's internals, which
    Klipper offers no compatibility promise about.

    The bounds must be the CONFIGURED ones. bed_mesh.get_status()'s mesh_min/mesh_max look
    like the obvious public replacement but are the bounds of the currently LOADED mesh, and
    are (0., 0.) until one has been probed - and this whole path runs at klippy:connect,
    before any mesh exists."""

    def _bounds(self, bed_mesh_values):
        printer, _mcu, _pins, _values = fake.build_environment()
        config = fake.make_z_compensate_config(
            printer, dict(fake.REAL_Z_COMPENSATE_CONFIG),
            bed_mesh_values=bed_mesh_values)
        return z_compensate.ZCompensate._read_configured_mesh_bounds(config)

    def test_rectangular_bed_reads_mesh_min_and_mesh_max(self):
        mesh_min, mesh_max = self._bounds({'mesh_min': '5, 10', 'mesh_max': '215, 215'})
        self.assertEqual(mesh_min, (5., 10.))
        self.assertEqual(mesh_max, (215., 215.))

    def test_round_bed_derives_bounds_from_mesh_radius(self):
        # Mirrors bed_mesh.py's own round-bed derivation: -radius..+radius on both axes,
        # with radius floored to .1mm precision, and deliberately not offset by mesh_origin
        # (upstream does not offset them either).
        mesh_min, mesh_max = self._bounds({'mesh_radius': '75.0'})
        self.assertEqual(mesh_min, (-75.0, -75.0))
        self.assertEqual(mesh_max, (75.0, 75.0))

    def test_round_bed_radius_is_floored_to_a_tenth_of_a_mm(self):
        mesh_min, mesh_max = self._bounds({'mesh_radius': '75.06'})
        self.assertEqual(mesh_max, (75.0, 75.0))
        self.assertEqual(mesh_min, (-75.0, -75.0))

    def test_no_bed_mesh_section_yields_no_bounds(self):
        self.assertEqual(self._bounds({}), (None, None))

    def test_fake_bed_mesh_object_exposes_no_private_bmc(self):
        # Guard against silently reintroducing the private coupling: if production code goes
        # back to bed_mesh.bmc.mesh_min, it must fail here rather than work by accident.
        printer, _mcu, _pins, _values = fake.build_environment()
        self.assertFalse(hasattr(printer.lookup_object('bed_mesh'), 'bmc'))

    def test_missing_both_sources_refuses_rather_than_guessing(self):
        # No _HOMING_PARAMS macro and no [bed_mesh] section: there is no source at all for a
        # calibration target, so this must raise with an actionable message rather than
        # silently calibrating against (0, 0).
        printer, mcu, _pins, _values = fake.build_environment()
        zc_config = fake.make_z_compensate_config(
            printer, dict(fake.REAL_Z_COMPENSATE_CONFIG), bed_mesh_values={})
        zc = z_compensate.ZCompensate(zc_config)
        with self.assertRaises(fake.ConfigError) as ctx:
            zc._resolve_z_home_xy()
        self.assertIn('_HOMING_PARAMS', str(ctx.exception))
        self.assertIn('bed_mesh', str(ctx.exception))


if __name__ == '__main__':
    unittest.main()
