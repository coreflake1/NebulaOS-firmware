#!/bin/sh
#
# Offline, repeatable negative tests proving the GuppyScreen-only Klipper
# backend compatibility adapters are gone (Phase 2 final software closure
# mission, 2026-09-09, section 2A).
#
# Z_OFFSET_CALIBRATION and CRTENSE_NOZZLE_CLEAR existed ONLY because the
# compiled GuppyScreen binary's recalibration wizard panel called these two
# literal gcode command names directly - they were never NebulaOS
# functionality themselves, just thin forwarding aliases to the real,
# canonical commands (NEBULAOS_Z_OFFSET_CALIBRATE, NEBULAOS_NOZZLE_CLEAN).
# There are no external NebulaOS users and no shipped image ever depended on
# GuppyScreen calling these names in production, so the aliases are removed
# outright rather than carried forward - if GuppyScreen needs adapting
# later, it adapts to NebulaOS's canonical API, not the other way around.
#
# This test only proves the adapters are gone and the underlying canonical
# functionality remains - it does not re-prove NEBULAOS_Z_OFFSET_CALIBRATE/
# NEBULAOS_NOZZLE_CLEAN's own behavior (already covered elsewhere).
#
# Usage: sh tests/guppy-backend-adapters-removed-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CALIBRATION_CFG="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/calibration.cfg"

[ -f "$CALIBRATION_CFG" ] || { echo "SKIP: $CALIBRATION_CFG not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

if grep -qxF '[gcode_macro Z_OFFSET_CALIBRATION]' "$CALIBRATION_CFG"; then
	fail "obsolete GuppyScreen-only alias [gcode_macro Z_OFFSET_CALIBRATION] is still present"
else
	pass "obsolete GuppyScreen-only alias [gcode_macro Z_OFFSET_CALIBRATION] is absent"
fi

if grep -qxF '[gcode_macro CRTENSE_NOZZLE_CLEAR]' "$CALIBRATION_CFG"; then
	fail "obsolete GuppyScreen-only alias [gcode_macro CRTENSE_NOZZLE_CLEAR] is still present"
else
	pass "obsolete GuppyScreen-only alias [gcode_macro CRTENSE_NOZZLE_CLEAR] is absent"
fi

if grep -qxF '[gcode_macro NEBULAOS_Z_OFFSET_CALIBRATE]' "$CALIBRATION_CFG"; then
	pass "canonical NEBULAOS_Z_OFFSET_CALIBRATE is still present (underlying functionality not removed)"
else
	fail "canonical NEBULAOS_Z_OFFSET_CALIBRATE is missing - removal must not touch underlying functionality"
fi

if grep -qxF '[gcode_macro NEBULAOS_NOZZLE_CLEAN]' "$CALIBRATION_CFG"; then
	pass "canonical NEBULAOS_NOZZLE_CLEAN is still present (underlying functionality not removed)"
else
	fail "canonical NEBULAOS_NOZZLE_CLEAN is missing - removal must not touch underlying functionality"
fi

# No other file in the shipped overlay may reintroduce either alias -
# "do not add more Guppy compatibility into Klipper/Extras" is a standing
# rule, not a one-time cleanup.
OVERLAY_KLIPPER_DIR="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper"
if grep -rl '^\[gcode_macro Z_OFFSET_CALIBRATION\]\|^\[gcode_macro CRTENSE_NOZZLE_CLEAR\]' "$OVERLAY_KLIPPER_DIR" >/dev/null 2>&1; then
	fail "a GuppyScreen-only alias exists somewhere else under $OVERLAY_KLIPPER_DIR"
else
	pass "no GuppyScreen-only alias exists anywhere under $OVERLAY_KLIPPER_DIR"
fi

echo ""
echo "guppy-backend-adapters-removed-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
