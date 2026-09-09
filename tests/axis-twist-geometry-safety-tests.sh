#!/bin/sh
#
# Offline regression test for [axis_twist_compensation]'s calibrate_end_x/y
# geometry in scripts/build/overlay/etc/nebulaos/klipper/machine.cfg
# (Phase 2 final live convergence mission, 2026-09-09).
#
# Real bug found live: the shipped calibrate_end_y value (200) was a
# software-only estimate (see _project/missions/
# phase2-calibration-final-architecture-investigation.md section 9,
# "NOT independently hardware-validated") that, combined with this
# printer's own [bltouch] y_offset:27, puts the PROBE (not the nozzle) at
# Y=227 during the axis-twist sweep - stepper_y's own position_max is 223,
# so the shipped default exceeded real physical Y travel by 4mm. A live
# qualification session (2026-08-31,
# _evidence/phase2-axis-twist-qualification-20260831-203913/) found this
# and applied 190 as a printer.cfg override (6mm margin instead of a 4mm
# violation) - but that override's own comment explaining the derivation
# didn't match the value actually left in the file, which itself still
# read 200 (the value the comment calls "found unsafe") until this
# mission's live correction. machine.cfg's own canonical default has now
# been corrected to 190 to match.
#
# This test parses the REAL machine.cfg directly - not a hardcoded
# assertion that today's value happens to be 190 - and computes the
# actual probe-frame sweep bounds from the real stepper position_max and
# bltouch offset values, the same way a technician would by hand. It
# would catch this exact class of bug (a sweep endpoint that violates
# real axis travel once the probe offset is accounted for) regardless of
# which specific numbers change in the future.
#
# Usage: sh tests/axis-twist-geometry-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MACHINE_CFG="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/machine.cfg"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

[ -f "$MACHINE_CFG" ] || { echo "SKIP: $MACHINE_CFG not present"; exit 0; }

# Extracts the value of `key:` from within a `[section]` block (first
# occurrence of the section, stops at the next `[`). Same awk convention
# already used elsewhere in this project's own shell tooling (see
# S04nebulaos-migrate's own small awk extractors) rather than a real INI
# parser, since this project's configs are known-simple.
cfg_get() {
	section="$1"; key="$2"; file="$3"
	awk -v want="[$section]" -v key="$key" '
		/^\[.*\]$/ { in_sec = ($0 == want); next }
		in_sec && $0 ~ ("^" key "[ \t]*:") {
			sub("^" key "[ \t]*:[ \t]*", "")
			gsub(/[ \t]+$/, "")
			print
			exit
		}
	' "$file"
}

stepper_x_max=$(cfg_get "stepper_x" "position_max" "$MACHINE_CFG")
stepper_y_max=$(cfg_get "stepper_y" "position_max" "$MACHINE_CFG")
bltouch_x_offset=$(cfg_get "bltouch" "x_offset" "$MACHINE_CFG")
bltouch_y_offset=$(cfg_get "bltouch" "y_offset" "$MACHINE_CFG")
calibrate_end_x=$(cfg_get "axis_twist_compensation" "calibrate_end_x" "$MACHINE_CFG")
calibrate_end_y=$(cfg_get "axis_twist_compensation" "calibrate_end_y" "$MACHINE_CFG")
calibrate_start_x=$(cfg_get "axis_twist_compensation" "calibrate_start_x" "$MACHINE_CFG")
calibrate_start_y=$(cfg_get "axis_twist_compensation" "calibrate_start_y" "$MACHINE_CFG")

for v in stepper_x_max stepper_y_max bltouch_x_offset bltouch_y_offset \
	calibrate_end_x calibrate_end_y calibrate_start_x calibrate_start_y; do
	eval "val=\$$v"
	if [ -z "$val" ]; then
		fail "could not extract $v from machine.cfg - test cannot proceed"
	else
		pass "extracted $v = $val"
	fi
done
[ "$FAIL" -eq 0 ] || { echo ""; echo "axis-twist-geometry-safety-tests: $PASS passed, $FAIL failed (extraction failure, geometry not checked)"; exit 1; }

# All values in this section are whole-mm integers in the real config, so
# plain POSIX shell integer arithmetic is used throughout - no `bc`
# dependency, matching this project's existing test-script conventions
# (none of which use bc). If a future edit introduces fractional geometry
# here, this test's extraction/arithmetic would need revisiting anyway.
#
# The axis-twist sweep moves the NOZZLE to calibrate_end_x/y, but the
# physical BLTouch PROBE - offset from the nozzle by x_offset/y_offset -
# is what must stay within stepper_x/y's own position_max. This is
# upstream Klipper's own axis_twist_compensation.py behavior (it probes
# at the requested nozzle position using the configured probe, so the
# probe tip visits nozzle_position + probe_offset), not a NebulaOS-specific
# detail - confirmed by the exact real-device incident this test guards
# against (probe-frame Y=227 from calibrate_end_y=200 + y_offset=27).
probe_frame_x=$((calibrate_end_x + bltouch_x_offset))
probe_frame_y=$((calibrate_end_y + bltouch_y_offset))

if [ "$probe_frame_x" -le "$stepper_x_max" ]; then
	margin=$((stepper_x_max - probe_frame_x))
	pass "X sweep: probe-frame endpoint $probe_frame_x stays within stepper_x position_max $stepper_x_max (margin ${margin}mm)"
else
	over=$((probe_frame_x - stepper_x_max))
	fail "X sweep: probe-frame endpoint $probe_frame_x EXCEEDS stepper_x position_max $stepper_x_max by ${over}mm - calibrate_end_x=$calibrate_end_x with bltouch x_offset=$bltouch_x_offset would drive the probe past physical travel"
fi

if [ "$probe_frame_y" -le "$stepper_y_max" ]; then
	margin=$((stepper_y_max - probe_frame_y))
	pass "Y sweep: probe-frame endpoint $probe_frame_y stays within stepper_y position_max $stepper_y_max (margin ${margin}mm)"
else
	over=$((probe_frame_y - stepper_y_max))
	fail "Y sweep: probe-frame endpoint $probe_frame_y EXCEEDS stepper_y position_max $stepper_y_max by ${over}mm - calibrate_end_y=$calibrate_end_y with bltouch y_offset=$bltouch_y_offset would drive the probe past physical travel (this is the exact real-device incident this test was written for)"
fi

# The margin should be a deliberate buffer, not just barely legal - the
# live qualification session's own reasoning was "190 gives an explicit
# 6mm safety margin", not "196 clears it by 0mm". Guard against a future
# edit that technically satisfies the hard bound above but leaves no
# real-world tolerance for backlash/endstop variance.
MIN_MARGIN_MM=3
y_margin=$((stepper_y_max - probe_frame_y))
if [ "$y_margin" -ge "$MIN_MARGIN_MM" ]; then
	pass "Y sweep margin (${y_margin}mm) meets the minimum deliberate safety buffer (${MIN_MARGIN_MM}mm)"
else
	fail "Y sweep margin (${y_margin}mm) is below the minimum deliberate safety buffer (${MIN_MARGIN_MM}mm) - technically legal is not the same as safely qualified"
fi

# Also check the start coordinates - a sweep has two ends, and only the
# end coordinate happened to be the one found unsafe live, but the same
# math applies to calibrate_start_x/y.
probe_frame_start_x=$((calibrate_start_x + bltouch_x_offset))
probe_frame_start_y=$((calibrate_start_y + bltouch_y_offset))
stepper_x_min=$(cfg_get "stepper_x" "position_min" "$MACHINE_CFG")
stepper_y_min=$(cfg_get "stepper_y" "position_min" "$MACHINE_CFG")

if [ -n "$stepper_x_min" ] && [ "$probe_frame_start_x" -ge "$stepper_x_min" ]; then
	pass "X sweep start: probe-frame $probe_frame_start_x stays within stepper_x position_min $stepper_x_min"
else
	fail "X sweep start: probe-frame $probe_frame_start_x is below stepper_x position_min ${stepper_x_min:-unknown}"
fi
if [ -n "$stepper_y_min" ] && [ "$probe_frame_start_y" -ge "$stepper_y_min" ]; then
	pass "Y sweep start: probe-frame $probe_frame_start_y stays within stepper_y position_min $stepper_y_min"
else
	fail "Y sweep start: probe-frame $probe_frame_start_y is below stepper_y position_min ${stepper_y_min:-unknown}"
fi

echo ""
echo "axis-twist-geometry-safety-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
