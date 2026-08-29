# Native nozzle-wipe routine using upstream Klipper's load-cell probe
#
# Replacement for prtouch_nozzle.py's clear_nozzle() function. Same physical wipe
# sequence (heat, probe two randomized points on the wipe pad, drag the nozzle between
# them at wipe temp, cool down), but uses nebulaos_z_offset_probe.touch_probe() instead
# of PRTouch's custom MCU commands (start_step_prtouch/start_pres_prtouch). This
# eliminates the last runtime dependency on the PRTouch MCU protocol for the
# CRTENSE_NOZZLE_CLEAR command path.
#
# HARDWARE_BEHAVIOR_BLOCKED: intentionally set to False for the Phase 1.8B integration
# candidate (source-level activation only - see NebulaOS workspace
# _project/missions/phase1.8b-pre-build-review.md and its integration-candidate
# follow-up for the full decision record). This module still has NOT been exercised on
# real hardware as of this commit: the nebulaos_z_offset_probe uses a fundamentally
# different sensor processing pipeline (upstream Klipper's HX711 -> LoadCell ->
# trigger_analog -> LCBestFit) compared to PRTouch's own custom MCU-side hold-count
# trigger logic. The physical sensor is the same (HX711 on PA4/PC6), but the trigger
# thresholds, filtering, and contact detection algorithm differ. Known, accepted risks
# pending the hardware qualification gate of this same candidate:
#   - Different effective trigger height (could push too hard or not make contact)
#   - Different noise response on the wipe pad surface (different from bed probing)
#   - No retries parameter (PRTouch used retries=5 for wipe-pad touches)
# This flag being False means "the source is ready to be tested," not "this has been
# proven safe on real hardware" - that proof is a separate, owner-attended hardware
# gate, not a source-code state.
#
# NozzleClearConfig is parameter-identical to prtouch_nozzle.ClearNozzleConfig: same
# config keys, same defaults, same bounds. The only difference is in the probe interface
# clear_nozzle() uses.
#
# Heater control uses standard Klipper heater objects directly via the printer's own
# heater registry, rather than through prtouch_nozzle.NozzleHeaters. Functionally
# equivalent: both call pheaters.set_temperature() and poll smoothed_temp in a reactor
# loop.
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import random

# Phase 1.8B integration candidate: source-level activation. clear_nozzle() itself
# checks this constant before proceeding (see its own guard below) - flipping it here
# is what makes this the live CRTENSE_NOZZLE_CLEAR implementation once built. Hardware
# qualification (the actual physical wipe-pad test) is a separate, owner-attended gate
# that has NOT happened as of this commit - see the module docstring above.
HARDWARE_BEHAVIOR_BLOCKED = False


class NozzleClearConfig:
    """All config.get*() reads clear_nozzle() needs, resolved once by the owning module's
    own __init__ (ZCompensate for [z_compensate]) - see prtouch_nozzle.py's
    ClearNozzleConfig docstring for why this can't happen lazily inside clear_nozzle()
    itself.

    Parameter-identical to prtouch_nozzle.ClearNozzleConfig. Duplicated rather than
    imported because the eventual goal is to remove prtouch_nozzle.py entirely - this
    module must not depend on the code it replaces."""

    def __init__(self, config):
        # clr_noz_start_x allows negative (this printer's real value is -3 - the wipe pad
        # sits partly off the near edge of the bed's own X origin, not a typo).
        self.clr_noz_start_x = config.getfloat('clr_noz_start_x', default=0.,
                                                 minval=-50, maxval=1000)
        self.clr_noz_start_y = config.getfloat('clr_noz_start_y', default=0.,
                                                 minval=0, maxval=1000)
        self.clr_noz_len_x = config.getfloat('clr_noz_len_x', default=1., minval=1)
        self.clr_noz_len_y = config.getfloat('clr_noz_len_y', default=1., minval=1)
        self.pa_clr_dis_mm_x = config.getfloat('pa_clr_dis_mm_x', default=30,
                                                minval=-100, maxval=100)
        self.pa_clr_dis_mm_y = config.getfloat('pa_clr_dis_mm_y', default=0,
                                                minval=-100, maxval=100)
        self.pa_clr_down_mm = config.getfloat('pa_clr_down_mm', default=-0.15,
                                               minval=-1, maxval=1)
        self.clr_xy_spd = config.getfloat('clr_xy_spd', default=2.0, minval=0.1)
        self.rdy_xy_spd = config.getfloat('rdy_xy_spd', default=200, minval=1)
        self.bed_max_err = config.getfloat('bed_max_err', default=5, minval=1)
        self.g29_down_min_z = config.getfloat('g29_down_min_z', default=25, minval=1)
        # vs_start_z_pos (real key): hover height before each wipe-pad touch probe. Falls
        # back to bed_max_err (the pre-existing dual-use default) when unset.
        self.hover_z = config.getfloat('vs_start_z_pos', default=self.bed_max_err)
        # pr_clear_probe_cnt (real key): probe-agreement count for these two wipe-pad
        # touches, distinct from Z_OFFSET_CALIBRATION's own pr_probe_cnt (read in
        # z_compensate.py).
        self.pr_clear_probe_cnt = config.getint('pr_clear_probe_cnt', default=3, minval=1)


def _move(gcode, toolhead, pos, speed):
    """Issue a G1 move and wait for completion. Identical to prtouch_nozzle._move()."""
    gcode.run_script_from_command(
        'G1 F%d X%.3f Y%.3f Z%.3f' % (speed * 60, pos[0], pos[1], pos[2]))
    toolhead.wait_moves()


def _set_temp(pheaters, heater, reactor, temp, wait=False, tolerance=5.0):
    """Set a heater target and optionally wait for it to reach tolerance.

    Functionally equivalent to prtouch_nozzle.NozzleHeaters.set_hot_temp() /
    set_bed_temp(), but operates on the heater objects directly without a wrapper class.
    Uses the same polling pattern: set temperature non-blocking, then loop on
    reactor.pause() checking smoothed_temp convergence."""
    pheaters.set_temperature(heater, temp, False)
    if not wait:
        return
    eventtime = reactor.monotonic()
    while (heater.target_temp > 0
           and abs(heater.target_temp - heater.smoothed_temp) > tolerance):
        eventtime = reactor.pause(eventtime + 0.1)


def clear_nozzle(z_offset_probe, toolhead, gcode, printer, params,
                 hot_min_temp, hot_max_temp, bed_max_temp, hot_end_temp=None,
                 approach_speed=2.0):
    """Native nozzle-wipe equivalent of prtouch_nozzle.clear_nozzle().

    Same physical sequence:
      1. Set bed and nozzle to start temps (non-blocking)
      2. Pick two randomized XY points on the wipe pad
      3. Wait for nozzle to reach start temp, then boost 40C above
      4. Move to src point at hover height, touch-probe Z
      5. Move to end point at hover height, touch-probe Z
      6. Return to src, lower to contact - pa_clr_down_mm (approach from above)
      7. Heat to wipe temp, wait
      8. Drag to end at contact + pa_clr_down_mm (pressed into pad surface)
      9. Cool nozzle to start temp, wait
     10. Lift off, set final nozzle temp, wait for bed

    `z_offset_probe` is a nebulaos_z_offset_probe.ZOffsetProbe instance. Its
    touch_probe(down_min_z, pro_cnt=N) returns the averaged fitted Z contact position
    as a single float.

    `printer` is the Klipper printer object, used to look up heater objects. This
    replaces the NozzleHeaters wrapper - heater control uses the same Klipper API
    (pheaters.set_temperature) but without an intermediate object.

    `approach_speed` replaces prtouch_probe.PrtouchProbe.tri_z_up_spd. In the PRTouch
    path this was the probe's own lift speed (~2.0 mm/s with this printer's real config);
    here it's an explicit parameter since the native probe has no such attribute. Used
    for the post-probe approach to the wipe-pad surface from hover height.

    `hot_end_temp`: final nozzle temp to settle at once the wipe finishes, defaulting to
    hot_min_temp when omitted (matching prtouch_nozzle.clear_nozzle's behavior)."""

    # Offline-review fix (2026-08-28): this used to be a bare `assert`. A bare assert is
    # NOT a reliable hardware-safety gate - CPython strips every `assert` statement
    # whenever the interpreter runs with -O/-OO (or PYTHONOPTIMIZE is set), which would
    # silently turn this into a no-op and let an unqualified probe pipeline drive real
    # hardware with no gate at all. Rewritten as an explicit, unconditionally-evaluated
    # check that raises the same AssertionError/message (so existing callers/tests that
    # match on AssertionError keep working) without depending on assert-stripping being
    # disabled somewhere upstream.
    if HARDWARE_BEHAVIOR_BLOCKED:
        raise AssertionError(
            "nozzle_clear.clear_nozzle() is NOT qualified for hardware use. "
            "HARDWARE_BEHAVIOR_BLOCKED must be set to False after hardware qualification "
            "before this code path can be activated.")

    # Look up heater objects directly from the printer
    reactor = printer.get_reactor()
    pheaters = printer.lookup_object('heaters')
    extruder_heater = printer.lookup_object('extruder').heater
    bed_heater = printer.lookup_object('heater_bed').heater

    # Offline-review fix (2026-08-28): prtouch_probe.PrtouchProbe.touch_probe() suspends
    # any active bed mesh for the duration of each raw probe descent (see its own
    # docstring: "a loaded mesh applies a Z-compensation transform to every toolhead
    # move, which would skew a raw touch-probe reading taken at a specific mesh-relative
    # point"). nebulaos_z_offset_probe.ZOffsetProbe.touch_probe() has no equivalent - it
    # was hardware-qualified (Phase 1.8/1.8A) only for Z_OFFSET_CALIBRATION's own probe
    # point (self.home_x/home_y, inside the homed/meshed area), not for this module's two
    # wipe-pad points, which sit off the print area (e.g. clr_noz_start_x=-3) and are
    # exactly the case a stale/active mesh from a previous print could still be loaded
    # for. Reproducing the same suspend/restore here - around each touch_probe() call
    # only, matching PRTouch's own per-call scope, not the whole clear_nozzle() sequence
    # (the wipe drag moves below still go through the ordinary gcode move transform in
    # both the old and new backends, so that part stays intentionally at parity) - closes
    # this gap without touching nebulaos_z_offset_probe.py itself, which stays exactly as
    # already hardware-qualified for its other caller.
    bed_mesh = printer.lookup_object('bed_mesh', None)

    def _touch_probe_no_mesh(down_min_z, pro_cnt):
        saved_mesh = bed_mesh.get_mesh() if bed_mesh is not None else None
        if saved_mesh is not None:
            bed_mesh.set_mesh(None)
        try:
            return z_offset_probe.touch_probe(down_min_z, pro_cnt=pro_cnt)
        finally:
            if saved_mesh is not None:
                bed_mesh.set_mesh(saved_mesh)

    # Unpack config params (same set as prtouch_nozzle.clear_nozzle)
    clr_noz_start_x = params.clr_noz_start_x
    clr_noz_start_y = params.clr_noz_start_y
    clr_noz_len_x = params.clr_noz_len_x
    clr_noz_len_y = params.clr_noz_len_y
    pa_clr_dis_mm_x = params.pa_clr_dis_mm_x
    pa_clr_dis_mm_y = params.pa_clr_dis_mm_y
    pa_clr_down_mm = params.pa_clr_down_mm
    clr_xy_spd = params.clr_xy_spd
    rdy_xy_spd = params.rdy_xy_spd
    bed_max_err = params.bed_max_err
    g29_down_min_z = params.g29_down_min_z
    hover_z = params.hover_z
    pr_clear_probe_cnt = params.pr_clear_probe_cnt

    # Step 1: start heating bed and nozzle (non-blocking)
    _set_temp(pheaters, bed_heater, reactor, bed_max_temp, wait=False)
    _set_temp(pheaters, extruder_heater, reactor, hot_min_temp, wait=False)

    # Step 2: pick two randomized XY points on the wipe pad
    margin = 5
    avail_x = max(clr_noz_len_x - abs(pa_clr_dis_mm_x) - margin, 0)
    avail_y = max(clr_noz_len_y - abs(pa_clr_dis_mm_y) - margin, 0)
    src_x = clr_noz_start_x + random.uniform(0, avail_x)
    src_y = clr_noz_start_y + random.uniform(0, avail_y)
    src_pos = [src_x, src_y, hover_z]
    end_pos = [src_x + pa_clr_dis_mm_x, src_y + pa_clr_dis_mm_y, hover_z]

    # Step 3: wait for nozzle to reach start temp, then boost
    _set_temp(pheaters, extruder_heater, reactor, hot_min_temp, wait=True)
    _set_temp(pheaters, extruder_heater, reactor, hot_min_temp + 40, wait=False)

    # Step 4: move to src point, touch-probe Z
    _move(gcode, toolhead, src_pos, rdy_xy_spd)
    src_pos[2] = _touch_probe_no_mesh(g29_down_min_z, pr_clear_probe_cnt)

    # Step 5: move to end point, touch-probe Z
    _move(gcode, toolhead, end_pos, rdy_xy_spd)
    end_pos[2] = _touch_probe_no_mesh(g29_down_min_z, pr_clear_probe_cnt)

    # Step 6: return to src at hover height, then lower to wipe approach position
    # (contact_z - pa_clr_down_mm: with pa_clr_down_mm=-0.15, this is contact_z + 0.15,
    # slightly above the pad surface - the nozzle enters at a slight angle and digs in
    # as it drags to end_pos)
    _move(gcode, toolhead, [src_pos[0], src_pos[1], hover_z], rdy_xy_spd)
    _move(gcode, toolhead, [src_pos[0], src_pos[1], src_pos[2] - pa_clr_down_mm],
          approach_speed)

    # Step 7: heat to wipe temp, wait
    _set_temp(pheaters, extruder_heater, reactor, hot_max_temp, wait=True)

    # Step 8: drag to end position, pressed into pad surface
    # (contact_z + pa_clr_down_mm: with pa_clr_down_mm=-0.15, this is contact_z - 0.15,
    # pushed 0.15mm below the pad surface)
    _move(gcode, toolhead, [end_pos[0], end_pos[1], end_pos[2] + pa_clr_down_mm],
          clr_xy_spd)

    # Step 9: cool nozzle, wait
    _set_temp(pheaters, extruder_heater, reactor, hot_min_temp, wait=True)

    # Step 10: lift off and set final temp
    _move(gcode, toolhead,
          [end_pos[0] + pa_clr_dis_mm_x, end_pos[1] + pa_clr_dis_mm_y,
           end_pos[2] + bed_max_err],
          clr_xy_spd)
    _set_temp(pheaters, extruder_heater, reactor,
              hot_min_temp if hot_end_temp is None else hot_end_temp, wait=False)
    _set_temp(pheaters, bed_heater, reactor, bed_max_temp, wait=True)
