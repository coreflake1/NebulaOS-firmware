# z_compensate - per-print auto-Z-offset orchestration, host-side Klipper extra
#
# NEW code, not a port - Creality's real z_compensate_wrapper.so has no published source anywhere
# (confirmed via GitHub org-wide search, ANALYSIS.md sec 5). Design is inferred from strong
# evidence (ANALYSIS.md sec 7): the real z_compensate_wrapper.so registers no MCU commands of its
# own, it does lookup_object('prtouch_v2') and calls straight into its primitives, and its
# bl_offset config value matches [bltouch]'s own y_offset exactly - consistent with probing at
# the physical point BLTouch already homed, offset by the nozzle-to-probe-tip distance, then
# reconciling the two readings. Named/config-section-compatible with the existing [z_compensate]
# printer.cfg section on purpose - see ../DESIGN.md.
#
# Real production calls this once per print, before BED_MESH_CALIBRATE (custom_macro.py's
# CX_PRINT_LEVELING_CALIBRATION, ANALYSIS.md sec 7) - a per-print thermal/wear fine-tune, not a
# one-time factory calibration. That matters for how the correction gets applied: baking it
# straight into the saved probe z_offset via stock Klipper's Z_OFFSET_APPLY_PROBE + SAVE_CONFIG
# would trigger a klippy restart in the middle of a print-start sequence, which is clearly wrong.
# So by default this only applies the correction as a live SET_GCODE_OFFSET for the current
# session/print - permanent persistence is opt-in (persist_offset) and needs a real, non-
# restarting save command for whichever environment this ends up running under (Creality's own
# stock image has a restart-free CXSAVE_CONFIG for exactly this reason; nothing has confirmed yet
# whether pellcorp's SimpleAF environment has an equivalent - flagged as a real open question,
# not silently assumed either way).
#
# Config-key reconciliation against the real device's live [z_compensate] section (pulled via
# SSH 2026-08-05, see project memory): this section has its OWN tri_min_hold/tri_max_hold
# (1400/2000, distinct from [prtouch_v2]'s own 1000/1500 defaults - a per-feature sensitivity
# retune, not a duplicate), its own probe speed, and the wipe-pad geometry keys
# (clr_noz_*/pa_clr_dis_mm_x/y/noz_pos_*/pumpback_mm/etc). Klipper's configfile errors on any
# option in a section that's never read via config.get*(), so all of these are read here even
# where their effect is genuinely unconfirmed (see "accepted but not wired" below) - pasting the
# real section in without this would make Klipper refuse to even start.
#
# Because CRTENSE_NOZZLE_CLEAR must use *this* section's tuning and wipe-geometry keys, this
# module calls nozzle_clear.clear_nozzle() directly with its own `config` object. Phase 1.8B
# integration candidate: this used to delegate to prtouch_nozzle.clear_nozzle() (PRTouch's
# own custom MCU commands); PRTouch has been removed from this module entirely - see
# extras/PRTOUCH_REMOVAL_PLAN.md.
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
import math

from . import nozzle_clear

# Phase 1.8B: native nozzle-clear replacement (NOT YET QUALIFIED FOR HARDWARE USE).
# When hardware-qualified, this import replaces the prtouch_nozzle dependency for
# CRTENSE_NOZZLE_CLEAR. See extras/nozzle_clear.py and extras/PRTOUCH_REMOVAL_PLAN.md.
# from . import nozzle_clear

#: Structured status contract, version 1 - see docs/z_compensate_status_api.md. Consumed by
#: GuppyScreen's recalibration wizard via printer.objects.subscribe, replacing its previous
#: dependence on parsing this module's human-readable gcode response text (the "z_offset:"/
#: "PR_ERR_CODE" scan). get_status() below is the only part of this contract Klipper's own
#: object-status machinery requires - any object with a get_status(eventtime) method is
#: automatically queryable/subscribable under its config section name, no separate
#: registration or explicit "notify" call needed. Klipper's own subscription/webhooks layer
#: periodically polls get_status() and diffs it against the last-sent snapshot, pushing only
#: changed fields - so a transition this module makes between two polls (e.g. straight from
#: "running" to "complete" with nothing in between) is still delivered correctly, just as one
#: state or as a coalesced update; nothing here needs to force an intermediate flush.
_CALIBRATION_STATES = ('idle', 'running', 'complete', 'error')
_MAX_CALIBRATION_ERROR_LEN = 200


def _sanitize_calibration_error(exc):
    """Turns a raised exception into the calibration_error string: the same plain message
    Klipper's own command_error/config_error already carry (str() on a Klipper error never
    includes a traceback, object repr, or memory address - those only appear if something
    explicitly formats the traceback module's output, which this does not do), collapsed to
    one line and length-bounded so a UI status field can't be handed something pathological."""
    text = str(exc).strip()
    if not text:
        text = exc.__class__.__name__
    text = ' '.join(text.split())  # collapse embedded newlines/whitespace to one line
    if len(text) > _MAX_CALIBRATION_ERROR_LEN:
        text = text[:_MAX_CALIBRATION_ERROR_LEN - 3].rstrip() + '...'
    return text


class ZCompensate:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.gcode = self.printer.lookup_object('gcode')
        self.config = config
        # Must be built here, not lazily inside cmd_nozzle_clear() - see nozzle_clear.py's
        # NozzleClearConfig docstring (confirmed live 2026-08-05: a lazy config.get*() read
        # inside a gcode-command handler is too late, Klipper hard-errors at startup instead).
        #
        # Phase 1.8B integration candidate: the native path is now the ONLY nozzle-clear
        # backend. PRTouch's own clear_nozzle()/ClearNozzleConfig, and [prtouch_v2] itself,
        # are no longer runtime dependencies of this command - see
        # extras/PRTOUCH_REMOVAL_PLAN.md for the full removal accounting. NozzleClearConfig
        # reads the same config keys with the same defaults as PRTouch's own
        # ClearNozzleConfig did, so no printer.cfg changes are needed.
        self.native_clear_nozzle_config = nozzle_clear.NozzleClearConfig(config)
        self.probe = None
        self.bed_mesh = None
        self.home_x = None
        self.home_y = None
        self.mesh_min, self.mesh_max = self._read_configured_mesh_bounds(config)

        self.hot_start_temp = config.getfloat('hot_start_temp', default=140, minval=80, maxval=200)
        self.hot_rub_temp = config.getfloat('hot_rub_temp', default=180, minval=80, maxval=300)
        # hot_end_temp (real key): final nozzle temp after the wipe - threaded through to
        # prtouch_nozzle.clear_nozzle()'s hot_end_temp param.
        self.hot_end_temp = config.getfloat('hot_end_temp', default=None,
                                             minval=80, maxval=300)
        # bed_add_temp (real key): additive delta applied to the bed's current target
        # temperature for the duration of the nozzle-wipe (bed_target + bed_add_temp, see
        # cmd_nozzle_clear() below). Virgin-Baseline Fix + Rebuild mission (2026-08-08):
        # maxval=100 is not an arbitrary widening - Creality's own real, factory-shipped
        # default for this exact printer model is bed_add_temp: 60 (confirmed via
        # artifacts/reference/stock-printer.cfg, the genuine tracked OEM config, cross-
        # checked independently against a second, separately-derived real-device fixture -
        # see klippy_extras/test_printer_cfg_config_validation.py). An earlier maxval=20
        # bound rejected this genuine factory value outright, halting Klipper entirely -
        # exactly the bug this comment exists to prevent recurring. 100 gives headroom
        # above the real factory value without needing to be a full physical-safety bound
        # itself: [heater_bed]'s own max_temp: 120 is the actual hard ceiling, enforced
        # independently by Klipper's heater code at the moment any command tries to set
        # that temperature - this config-time bound only needs to catch a clearly
        # unreasonable typo'd value, not replace that separate safety layer.
        self.bed_add_temp = config.getfloat('bed_add_temp', default=0, minval=-20, maxval=100)
        bl_offset = config.getfloatlist('bl_offset', default=(0., 0.), count=2)
        self.bl_offset_x, self.bl_offset_y = bl_offset
        self.down_min_z = config.getfloat('z_offset_down_min_z', default=10, minval=1, maxval=50)
        # vs_start_z_pos (real key, replaces the old Klipper-only z_offset_hover_height default):
        # hover height before the Z_OFFSET_CALIBRATION touch, and passed through to
        # clear_nozzle() for its own two wipe-pad touches.
        self.hover_height = config.getfloat('vs_start_z_pos', default=5, minval=1, maxval=50)

        # tri_min_hold/tri_max_hold/speed (real keys): PRTouch-probe-sensitivity tuning that
        # this module used to apply as a temporary override of prtouch_v2's PrtouchProbe
        # attributes (the old _probe_overrides() context manager, removed in the Phase 1.8B
        # PRTouch-removal integration - see extras/PRTOUCH_REMOVAL_PLAN.md). The native
        # nebulaos_z_offset_probe backend has no equivalent per-caller sensitivity-override
        # mechanism, and building one is explicitly out of scope for this integration (no
        # trigger_force/contact_speed tuning). These three values are still read here, unused,
        # purely because the real device's live [z_compensate] section sets all three
        # (tri_min_hold: 1400, tri_max_hold: 2000, speed: 5) and Klipper's configfile hard-
        # errors at startup on any section option that's never read via config.get*().
        self.tri_min_hold = config.getint('tri_min_hold', default=None)
        self.tri_max_hold = config.getint('tri_max_hold', default=None)
        self.probe_speed = config.getfloat('speed', default=None, minval=0.1)
        # tri_expand_mm (real key): no source exists for z_compensate_wrapper.so (see module
        # docstring), so this is an inference, not a confirmed port - applied as a fixed additive
        # correction to the Z_OFFSET_CALIBRATION measurement, on the theory that it accounts for
        # a systematic gap between the load cell's electrical trigger point and true mechanical
        # nozzle-bed contact (compliance in the load-cell mount). Defaults to 0 (no correction)
        # so an unset/misread value can't silently bias every print's Z offset.
        self.tri_expand_mm = config.getfloat('tri_expand_mm', default=0.)
        # pr_probe_cnt (real key): probe-agreement count for this command's own touch, distinct
        # from clear_nozzle()'s own pr_clear_probe_cnt (read in prtouch_nozzle.py).
        self.pr_probe_cnt = config.getint('pr_probe_cnt', default=3, minval=1)
        # max_offset_correction_mm (2026-08-09 hardening mission, new): a sanity ceiling on the
        # magnitude of a candidate correction before it's ever applied as a live offset - this
        # command is documented (module docstring) as a per-print THERMAL/WEAR FINE-TUNE, not a
        # full re-leveling; a multi-millimeter "correction" can only mean something went wrong
        # upstream (a bad touch, a corrupted measurement, a miscalibrated BLTouch reference),
        # never a genuine thermal/wear drift this feature is meant to compensate. The prior
        # `math.isfinite` check below already caught NaN/inf; this catches a finite but
        # physically implausible value the same way. Conservative default (2mm) pending real
        # measurement of this printer's own genuine thermal-drift range - mark for hardware
        # qualification if real, larger corrections turn out to be legitimate.
        self.max_offset_correction_mm = config.getfloat('max_offset_correction_mm', default=2.,
                                                          minval=0.1, maxval=10.)

        # Accepted (so Klipper doesn't reject the real config section) but deliberately left
        # unwired - no reference source and no confirmed evidence of their effect, and each
        # would need to be right on the first live attempt: type_nozz (nozzle-type selector,
        # meaning unknown), noz_pos_center/noz_pos_offset (plausibly another XY reference point
        # but nothing confirms it - misapplying it would send the toolhead somewhere unintended),
        # pumpback_mm (plausibly a pre-wipe retract, but unconfirmed - wiring untested E-axis
        # motion into a probe/heat sequence isn't worth the risk on a guess). Flag if any of
        # these turn out to matter after real testing - same "flagged, not silently omitted"
        # pattern as Z_OFFSET_AUTO/env_self_check elsewhere in this file/DESIGN.md.
        self.type_nozz = config.getint('type_nozz', default=0)
        self.noz_pos_center = config.getfloatlist('noz_pos_center', default=(0., 0.), count=2)
        self.noz_pos_offset = config.getfloatlist('noz_pos_offset', default=(0., 0.), count=2)
        self.pumpback_mm = config.getfloat('pumpback_mm', default=0.)

        # Opt-in permanent persistence (see module docstring) - off by default.
        self.persist_offset = config.getboolean('persist_offset', default=False)
        self.save_config_command = config.get('save_config_command', default='SAVE_CONFIG')

        # Structured status contract v1 (see module-level comment + docs/
        # z_compensate_status_api.md) - independent of persist_offset above, which stays a
        # console/config concern; GuppyScreen's own persistence step consumes
        # calibration_z_offset directly and does its own save, regardless of this setting.
        self.calibration_id = 0
        self.calibration_state = "idle"
        self.calibration_z_offset = None
        self.calibration_error = None

        self.printer.register_event_handler("klippy:connect", self._handle_connect)

        self.gcode.register_command('CRTENSE_NOZZLE_CLEAR', self.cmd_nozzle_clear,
                                     desc=self.cmd_nozzle_clear_help)
        self.gcode.register_command('Z_OFFSET_CALIBRATION', self.cmd_z_offset_calibration,
                                     desc=self.cmd_z_offset_calibration_help)
        # Z_OFFSET_AUTO: registered by the real z_compensate_wrapper.so but never actually
        # called by any macro on this printer (DESIGN.md open question 2, resolved: skip for
        # v1) - not registering unless something turns out to need it.

    def _handle_connect(self):
        self.z_offset_probe = self.printer.lookup_object('nebulaos_z_offset_probe')
        self.probe = self.printer.lookup_object('probe')
        self.bed_mesh = self.printer.lookup_object('bed_mesh', None)
        self.home_x, self.home_y = self._resolve_z_home_xy()

    @staticmethod
    def _read_configured_mesh_bounds(config):
        """The CONFIGURED [bed_mesh] area bounds, read from the config rather than off
        BedMeshCalibrate's internals.

        Official-mainline migration (2026-08-17). This used to be
        `self.bed_mesh.bmc.mesh_min` / `.bmc.mesh_max` - reaching through BedMesh's public
        object into `bmc`, a BedMeshCalibrate instance, and then into two of its instance
        attributes. Nothing about that is part of any interface Klipper offers; all three hops
        are internal, and upstream is free to rename or restructure any of them in a routine
        refactor. It still resolves at the qualified pin, but "it happens to work today" is
        not a compatibility contract.

        The obvious-looking public replacement is WRONG and was rejected after reading
        mainline's source. `bed_mesh.get_status()` does expose `mesh_min`/`mesh_max`, but
        `BedMesh.update_status()` populates them from `self.z_mesh` - the mesh currently
        LOADED - and leaves them at (0., 0.) when no mesh has been probed or loaded. The
        configured bounds and the loaded-mesh bounds are different quantities. This call site
        needs the configured ones, and runs at klippy:connect, before any mesh exists; taking
        get_status() would have silently produced a (0., 0.) fallback target - a worse bug
        than the coupling it replaced, and one no offline test of a probed printer would show.

        So this reads the same config keys `BedMeshCalibrate._init_mesh_config()` itself reads,
        through `config.getsection()` - the ordinary, documented ConfigWrapper API that this
        module set already uses for `[printer]` and `[stepper_z]`. The
        derivation mirrors upstream's own: a round bed (`mesh_radius`) yields
        (-radius, -radius)..(radius, radius) with the same .1mm floor upstream applies; a
        rectangular bed yields `mesh_min`..`mesh_max` verbatim. Both produce values identical
        to what `bmc.mesh_min`/`bmc.mesh_max` held.

        Returns (None, None) when `[bed_mesh]` is absent - this whole path is only a fallback
        for printers without a `_HOMING_PARAMS` macro, and `_resolve_z_home_xy()` reports the
        missing-section case itself rather than failing here at config time.
        """
        if not config.has_section('bed_mesh'):
            return None, None
        mesh_cfg = config.getsection('bed_mesh')
        radius = mesh_cfg.getfloat('mesh_radius', None, above=0.)
        if radius is not None:
            # Mirrors bed_mesh.py's own "radius may have precision to .1mm" floor, and its
            # own choice not to offset these bounds by mesh_origin.
            radius = math.floor(radius * 10) / 10
            return (-radius, -radius), (radius, radius)
        min_x, min_y = mesh_cfg.getfloatlist('mesh_min', count=2)
        max_x, max_y = mesh_cfg.getfloatlist('mesh_max', count=2)
        return (min_x, min_y), (max_x, max_y)

    def _resolve_z_home_xy(self):
        """home_x/home_y must be the real toolhead XY the printer's own homing sequence sits
        at when G28 Z actually probes - see cmd_z_offset_calibration's own docstring for why
        (the whole point of touching bl_offset away from this point is to land the NOZZLE on
        the exact bed spot BLTouch's probe already touched during Z-homing).

        2026-08-14 (XY-reference mission): this used to be computed purely from [bed_mesh]'s
        own mesh_min/mesh_max - a real, independently-confirmed bug, not a design choice.
        [bed_mesh]'s center has no necessary relationship to where this printer's own homing
        macro (simpleaf/homing.cfg's [homing_override]) actually leaves the toolhead before
        G28 Z probes: that macro's own _POST_HOME_XY moves to the FIXED (not bed_mesh-derived)
        [gcode_macro _HOMING_PARAMS] home_x/home_y (110, 111 on this printer), and neither of
        _PRE_HOME_Z's own two conditional re-positioning branches (klicky's ATTACH_PROBE, or
        the _saf_z_endstop elif) are active on this config, so nothing moves the toolhead again
        before the real probe touch - confirmed by reading both macros directly, not assumed.
        On this printer [bed_mesh]'s own center is (110.0, 112.5) - a full 1.5mm off in Y from
        where Z-homing actually happens, silently skewing every calibration's target point.

        Prefers _HOMING_PARAMS' own home_x/home_y (the actual source of truth for where G28 Z
        probes) when that macro exists and defines them - this is the same object Jinja's own
        printer["gcode_macro _HOMING_PARAMS"].home_x resolves to inside homing.cfg itself, so
        this reads the identical value the real homing sequence uses, not a second, potentially-
        divergent copy. Falls back to the old [bed_mesh]-center approximation, with a loud
        warning, for any printer.cfg that doesn't use this SimpleAF-style homing macro at all -
        this module is not specific to one printer's macro pack, so that fallback must stay
        usable, just no longer silent about being an approximation."""
        homing_params = self.printer.lookup_object('gcode_macro _HOMING_PARAMS', None)
        if homing_params is not None:
            variables = homing_params.variables
            if 'home_x' in variables and 'home_y' in variables:
                return float(variables['home_x']), float(variables['home_y'])
            logging.warning(
                "z_compensate: [gcode_macro _HOMING_PARAMS] exists but defines no home_x/"
                "home_y - falling back to the [bed_mesh]-center approximation for the "
                "Z-offset calibration target, which is NOT proven to match where this "
                "printer's own homing sequence actually probes Z")
        if self.mesh_min is None:
            raise self.printer.config_error(
                "z_compensate: cannot determine the Z-offset calibration XY target. Neither "
                "[gcode_macro _HOMING_PARAMS] (with home_x/home_y) nor a [bed_mesh] section "
                "is present, so there is no source for either the real Z-homing position or "
                "the fallback bed-centre approximation. Add home_x/home_y to a "
                "[gcode_macro _HOMING_PARAMS] section - the accurate option - or configure "
                "[bed_mesh].")
        min_x, min_y = self.mesh_min
        max_x, max_y = self.mesh_max
        return min_x + (max_x - min_x) / 2., min_y + (max_y - min_y) / 2.

    def get_status(self, eventtime):
        """Structured status contract v1 - see the module-level comment and
        docs/z_compensate_status_api.md. Deliberately does no work, no hardware access, and
        no state mutation: a fresh dict of the four already-computed fields, safe to call at
        any time (including before klippy:connect) and safe for a caller to mutate without
        touching this object's own state."""
        return {
            "calibration_id": self.calibration_id,
            "calibration_state": self.calibration_state,
            "calibration_z_offset": self.calibration_z_offset,
            "calibration_error": self.calibration_error,
        }

    cmd_nozzle_clear_help = "Wipe the nozzle before Z-offset calibration"

    def cmd_nozzle_clear(self, gcmd):
        """Reads HOT_START_TEMP/HOT_RUB_TEMP/HOT_END_TEMP/BED_ADDTEMP params - matches the real
        call site in custom_macro.py's CX_PRINT_LEVELING_CALIBRATION exactly. Calls
        nozzle_clear.clear_nozzle() with this section's own config (see module docstring).

        Phase 1.8B integration candidate: this is now the ONLY implementation of
        CRTENSE_NOZZLE_CLEAR. It uses nebulaos_z_offset_probe.touch_probe() (upstream Klipper's
        HX711/LoadCell/trigger_analog/LCBestFit) for Z positioning on the wipe pad, replacing
        PRTouch's custom MCU commands entirely - [prtouch_v2] is no longer a dependency of this
        command, or of this module at all. See extras/nozzle_clear.py and
        extras/PRTOUCH_REMOVAL_PLAN.md for the full parity review and removal accounting."""
        hot_start_temp = gcmd.get_float('HOT_START_TEMP', self.hot_start_temp)
        hot_rub_temp = gcmd.get_float('HOT_RUB_TEMP', self.hot_rub_temp)
        hot_end_temp = gcmd.get_float('HOT_END_TEMP', self.hot_end_temp)
        bed_add_temp = gcmd.get_float('BED_ADDTEMP', self.bed_add_temp)
        heater_bed = self.printer.lookup_object('heater_bed')
        bed_target = heater_bed.get_status(self.printer.get_reactor().monotonic())['target']
        toolhead = self.printer.lookup_object('toolhead')
        nozzle_clear.clear_nozzle(
            self.z_offset_probe, toolhead, self.gcode, self.printer,
            self.native_clear_nozzle_config,
            hot_start_temp, hot_rub_temp, bed_target + bed_add_temp,
            hot_end_temp=hot_end_temp)

    cmd_z_offset_calibration_help = "Auto-tune Z offset via the load-cell nozzle touch"

    def cmd_z_offset_calibration(self, gcmd):
        """Touch-probe at the point BLTouch already homed (self.home_x/self.home_y - see
        _resolve_z_home_xy()'s own docstring for where that really comes from, as of
        2026-08-14 no longer a [bed_mesh]-center approximation - adjusted by bl_offset, the
        nozzle-to-probe-tip distance) via nebulaos_z_offset_probe.touch_probe(), then apply the
        result as a live Z gcode-offset for this print (see module docstring for why not a permanent
        z_offset rewrite by default).

        The math: touch_probe() returns the toolhead Z position (in the current coordinate
        frame, where Z=0 is BLTouch's calibrated bed surface) at which the *nozzle* contacts the
        bed. If BLTouch's static z_offset were perfectly accurate this would read exactly 0; any
        deviation is precisely the correction needed - the same 'offset' value stock Klipper's
        own Z_OFFSET_APPLY_PROBE reads from SET_GCODE_OFFSET and subtracts from the probe's
        z_offset (verified against pellcorp/klipper's probe.py: new_calibrate = z_offset -
        offset), so setting a gcode offset equal to the raw measurement is the correct
        equivalent of "reconciling the two readings" (ANALYSIS.md sec 7) without needing to read
        the probe's current z_offset directly. tri_expand_mm (see __init__) is then applied as a
        fixed additive correction on top - see its own comment for the caveat.
        """
        # Non-reentrancy guard (2026-08-10, see docs/NEBULAOS_PRTOUCH_MCU_TIMER_FORENSICS.md -
        # a live incident showed two Z_OFFSET_CALIBRATION invocations landing close together
        # while raw MCU step commands were in flight; that overlap was NOT proven to be the
        # incident's cause, but there is no legitimate reason to let a second calibration
        # start or queue behind one already in flight, so this closes that door regardless of
        # root cause. (Historical note: this used to be described as a second, higher-level
        # guard layered on top of PRTouch's own PrtouchProbe._own_raw_operation, which
        # protected every individual raw MCU dispatch across PRTouch's callers - PRTouch has
        # since been removed from this module entirely, per the Phase 1.8B integration
        # candidate, so this guard now stands on its own.) This protects the whole multi-step
        # calibration sequence (the positioning move + touch_probe + SET_GCODE_OFFSET) as one
        # logical unit. Checked and
        # set with no yield in between - Klipper's reactor is single-threaded/cooperative, so
        # this is race-free without needing a lock: whichever invocation's gcode handler is
        # entered first always sets "running" before it ever yields, so any second invocation
        # is guaranteed to observe "running" already set.
        if self.calibration_state == "running":
            raise self.printer.command_error(
                "Z_OFFSET_CALIBRATION: a calibration is already in progress")

        # Structured status: a new attempt always gets a new id and clears any previous
        # result before doing anything else - a caller polling get_status() must never see a
        # stale "complete"/offset left over from an earlier invocation once a new one has
        # started (see docs/z_compensate_status_api.md's ID-correlation section).
        self.calibration_id += 1
        self.calibration_state = "running"
        self.calibration_z_offset = None
        self.calibration_error = None

        try:
            toolhead = self.printer.lookup_object('toolhead')
            cur_pos = toolhead.get_position()
            target = [self.home_x + self.bl_offset_x, self.home_y + self.bl_offset_y,
                      self.hover_height, cur_pos[3]]
            self.gcode.run_script_from_command(
                'G1 F%d X%.3f Y%.3f Z%.3f' % (200 * 60, target[0], target[1], target[2]))
            toolhead.wait_moves()

            measured_z = self.z_offset_probe.touch_probe(
                self.down_min_z, pro_cnt=self.pr_probe_cnt)
            measured_z += self.tri_expand_mm

            # A NaN/inf measurement can only mean a bug in the calibration math upstream
            # (prtouch_calibration.py's own interpolation is unconditionally finite for
            # finite inputs - see its own test suite) - surfacing it as a clear command_error
            # here, before it's ever applied as a live offset or published as a completed
            # status, is strictly better than silently accepting a broken value.
            if not math.isfinite(measured_z):
                raise self.printer.command_error(
                    "Z_OFFSET_CALIBRATION: measured value %r is not a finite number"
                    % (measured_z,))
            # A finite but implausibly large candidate (see max_offset_correction_mm's own
            # comment in __init__) gets the same treatment - rejected before it is ever applied
            # or published as a completed result, not silently clamped or accepted.
            if abs(measured_z) > self.max_offset_correction_mm:
                raise self.printer.command_error(
                    "Z_OFFSET_CALIBRATION: measured value %.5fmm exceeds "
                    "max_offset_correction_mm=%.5fmm - refusing to apply an implausibly large "
                    "correction" % (measured_z, self.max_offset_correction_mm))

            self.gcode.run_script_from_command('SET_GCODE_OFFSET Z=%.5f MOVE=0' % measured_z)
        except Exception as e:
            self.calibration_state = "error"
            self.calibration_z_offset = None
            self.calibration_error = _sanitize_calibration_error(e)
            raise

        # The calibration itself has now genuinely succeeded - a real measurement was taken
        # and applied as this print's live Z offset. Publish "complete" here, before the
        # optional persist_offset block below, deliberately: GuppyScreen's own persistence
        # step consumes calibration_z_offset directly and does its own save/restart,
        # entirely independent of persist_offset (which stays a separate, opt-in,
        # console/config-file concern - see this module's own docstring on why a restart
        # here would be wrong for the common per-print case). If persist_offset's own extra
        # steps below fail, that failure still propagates as a normal command_error (existing
        # behavior, unchanged) but does not retroactively invalidate a result that was
        # already correct and already applied.
        self.calibration_state = "complete"
        self.calibration_z_offset = measured_z
        self.calibration_error = None

        gcmd.respond_info(
            "Z_OFFSET_CALIBRATION: measured %.5f mm, applied as this print's Z offset"
            % measured_z)

        if self.persist_offset:
            self.gcode.run_script_from_command('Z_OFFSET_APPLY_PROBE')
            self.gcode.run_script_from_command(self.save_config_command)


def load_config(config):
    return ZCompensate(config)
