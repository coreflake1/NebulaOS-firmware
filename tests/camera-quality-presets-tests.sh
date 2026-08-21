#!/bin/sh
#
# Offline, repeatable tests for the camera quality presets mission
# (2026-08-04): S50webcam's LOW/MED/HIGH marker logic, set_camera_quality.py,
# and camera-quality.cfg's macro wiring. Does not and cannot exercise the
# real camera/V4L2 device - that needs live hardware (see this repo's other
# missions for that pattern).
#
# Usage: sh tests/camera-quality-presets-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S50WEBCAM="$REPO_ROOT/scripts/build/overlay/etc/init.d/S50webcam"
SET_QUALITY_PY="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/GuppyScreen/scripts/set_camera_quality.py"
CAMERA_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/camera-quality.cfg"
PRINTER_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/printer.cfg"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$S50WEBCAM" ] || { echo "SKIP: $S50WEBCAM not present"; exit 0; }

# --- Test 1: S50webcam is still valid POSIX sh after the edit. ---
if sh -n "$S50WEBCAM" 2>/dev/null; then
	pass
else
	fail "$S50WEBCAM has a shell syntax error"
fi

# --- Extract just the RESOLUTION/DESIRED_FPS + quality-marker case block,
# so a marker value can be evaluated in isolation without needing the real
# device, v4l2-ctl, or /usr/data/nebulaos to exist. ---
QUALITY_BLOCK=$(awk '/^RESOLUTION=1920x1080$/,/^esac$/' "$S50WEBCAM")
if [ -z "$QUALITY_BLOCK" ]; then
	fail "could not extract the RESOLUTION/quality-marker block from $S50WEBCAM"
	echo ""
	echo "$PASS passed, $FAIL failed"
	exit 1
fi

run_with_marker() {
	# $1 = fake marker content ("" for missing/empty marker)
	fake_bin=$(mktemp -d)
	cat > "$fake_bin/cat" <<EOF
#!/bin/sh
if [ "\$1" = "/usr/data/nebulaos/maintenance/camera-quality-mode" ]; then
	printf '%s' '$1'
	exit 0
fi
exec /bin/cat "\$@"
EOF
	chmod +x "$fake_bin/cat"
	out=$(PATH="$fake_bin:$PATH" sh -c "$QUALITY_BLOCK; echo \"\$RESOLUTION \$DESIRED_FPS\"")
	rm -rf "$fake_bin"
	echo "$out"
}

# --- Test 2: LOW marker selects 640x480, uncapped (0) fps. ---
result=$(run_with_marker "LOW")
if [ "$result" = "640x480 0" ]; then
	pass
else
	fail "marker=LOW: expected '640x480 0', got '$result'"
fi

# --- Test 3: MED marker selects 1280x720, uncapped (0) fps. ---
result=$(run_with_marker "MED")
if [ "$result" = "1280x720 0" ]; then
	pass
else
	fail "marker=MED: expected '1280x720 0', got '$result'"
fi

# --- Test 4: HIGH marker keeps the qualified default (1920x1080 @ 30fps). ---
result=$(run_with_marker "HIGH")
if [ "$result" = "1920x1080 30" ]; then
	pass
else
	fail "marker=HIGH: expected '1920x1080 30', got '$result'"
fi

# --- Test 5: missing/unrecognized marker also falls back to the qualified
# default - a build that has never had the marker written must behave
# exactly like today's shipped default. ---
result=$(run_with_marker "")
if [ "$result" = "1920x1080 30" ]; then
	pass
else
	fail "marker=<missing>: expected '1920x1080 30', got '$result'"
fi

result=$(run_with_marker "bogus")
if [ "$result" = "1920x1080 30" ]; then
	pass
else
	fail "marker=bogus: expected '1920x1080 30', got '$result'"
fi

# --- Test 6: set_camera_quality.py is present, executable, and rejects an
# invalid preset name (source-inspection - can't run it for real here since
# it shells out to mkdir/S50webcam restart against real device paths). ---
if [ -x "$SET_QUALITY_PY" ]; then
	pass
else
	fail "$SET_QUALITY_PY missing or not executable"
fi

if grep -q 'VALID = ("LOW", "MED", "HIGH")' "$SET_QUALITY_PY"; then
	pass
else
	fail "$SET_QUALITY_PY does not restrict input to LOW/MED/HIGH"
fi

# --- Test 7: camera-quality.cfg defines exactly the three expected
# parameterless macros, each routed through the same shell command, and the
# shell command's script path matches the runtime (/opt/printer_data/...)
# path convention used by every other GuppyScreen script in this config -
# Phase 1.5 persistent-namespace mission (2026-08) moved every such
# hardcoded path off the removed /usr/data/printer_data top-level alias. ---
for quality in LOW MED HIGH; do
	if grep -q "^\[gcode_macro SET_CAMERA_QUALITY_${quality}\]$" "$CAMERA_CFG" \
		&& grep -A3 "^\[gcode_macro SET_CAMERA_QUALITY_${quality}\]$" "$CAMERA_CFG" \
			| grep -q "RUN_SHELL_COMMAND CMD=set_camera_quality PARAMS=${quality}$"; then
		pass
	else
		fail "camera-quality.cfg missing a well-formed SET_CAMERA_QUALITY_${quality} macro"
	fi
done

if grep -q '^command: /opt/printer_data/config/GuppyScreen/scripts/set_camera_quality.py$' "$CAMERA_CFG"; then
	pass
else
	fail "camera-quality.cfg's gcode_shell_command does not point at the runtime script path"
fi

# --- Test 8: printer.cfg actually includes camera-quality.cfg - a macro
# file nobody [include]s is invisible to both Mainsail and GuppyScreen. ---
if grep -q '^\[include camera-quality.cfg\]$' "$PRINTER_CFG"; then
	pass
else
	fail "printer.cfg does not [include camera-quality.cfg]"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
