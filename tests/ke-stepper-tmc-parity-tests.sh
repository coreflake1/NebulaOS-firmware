#!/bin/sh
#
# KE stepper motor and TMC driver configuration parity test.
#
# Phase 1.8B Workstream E: verifies every stepper and TMC2208 driver
# parameter in machine.cfg against the authoritative values from the
# Creality Ender-3 V3 KE stock config and hardware qualification.
#
# machine.cfg is IMMUTABLE and SLOT-OWNED -- it ships on the read-only
# squashfs.  These values are the physical truth of the KE's wiring,
# pulleys, and driver sense resistors.  A single wrong pin or current
# value can destroy hardware.  This test catches drift at build time.
#
# Usage: sh tests/ke-stepper-tmc-parity-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MACHINE_CFG="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/machine.cfg"
STOCK_CFG="$REPO_ROOT/artifacts/reference/stock-printer.cfg"

PASS=0
FAIL=0
SKIP=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Helper: extract a key's value from a specific INI section.
#
# cfg_get <file> <section> <key>
#
# Klipper config files use "[section]" headers and "key: value" or
# "key = value" lines.  This extracts all lines between the target
# section header and the next section header (or EOF), then greps for
# the key.  Whitespace around the separator and value is stripped.
# Returns empty string (and exit 1) if not found.
# ---------------------------------------------------------------------------
cfg_get() {
    _file="$1"
    _section="$2"
    _key="$3"
    # awk: when we see the target section header, start collecting.
    # Stop when we see the next section header.  Within the section,
    # match lines whose key (before : or =) matches exactly.
    awk -v section="$_section" -v key="$_key" '
        BEGIN { in_section = 0 }
        /^\[/ {
            # Strip leading/trailing whitespace from the header
            header = $0
            gsub(/^[[:space:]]*\[/, "", header)
            gsub(/\][[:space:]]*$/, "", header)
            # Also strip any inline comment from the header line
            gsub(/#.*/, "", header)
            gsub(/[[:space:]]+$/, "", header)
            if (header == section) {
                in_section = 1
            } else {
                in_section = 0
            }
            next
        }
        in_section {
            # Skip comments and blank lines
            if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
            # Split on first : or =
            line = $0
            # Find key portion -- everything before the first : or =
            if (match(line, /^[[:space:]]*[^:=]+[[:space:]]*[:=]/)) {
                k = substr(line, 1, RLENGTH)
                gsub(/[[:space:]]*[:=][[:space:]]*$/, "", k)
                gsub(/^[[:space:]]+/, "", k)
                if (k == key) {
                    v = substr(line, RLENGTH + 1)
                    # Strip leading whitespace and inline comments
                    gsub(/^[[:space:]]+/, "", v)
                    gsub(/[[:space:]]*#.*$/, "", v)
                    gsub(/[[:space:]]+$/, "", v)
                    print v
                    exit 0
                }
            }
        }
    ' "$_file"
}

# ---------------------------------------------------------------------------
# Helper: assert a key in machine.cfg equals an expected value.
#
# assert_cfg <section> <key> <expected> <description>
# ---------------------------------------------------------------------------
assert_cfg() {
    _section="$1"
    _key="$2"
    _expected="$3"
    _desc="$4"
    _got=$(cfg_get "$MACHINE_CFG" "$_section" "$_key")
    if [ "$_got" = "$_expected" ]; then
        pass "$_desc"
    else
        fail "$_desc (expected '$_expected', got '$_got')"
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert that a key in machine.cfg matches the same key in
# stock-printer.cfg within the same section.
#
# assert_stock_parity <section> <key> <description>
# ---------------------------------------------------------------------------
assert_stock_parity() {
    _section="$1"
    _key="$2"
    _desc="$3"
    _machine_val=$(cfg_get "$MACHINE_CFG" "$_section" "$_key")
    _stock_val=$(cfg_get "$STOCK_CFG" "$_section" "$_key")
    if [ -z "$_machine_val" ]; then
        fail "$_desc -- key not found in machine.cfg"
    elif [ -z "$_stock_val" ]; then
        fail "$_desc -- key not found in stock-printer.cfg"
    elif [ "$_machine_val" = "$_stock_val" ]; then
        pass "$_desc"
    else
        fail "$_desc (machine='$_machine_val', stock='$_stock_val')"
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert a section does NOT exist in a config file.
#
# assert_section_absent <file> <section> <description>
# ---------------------------------------------------------------------------
assert_section_absent() {
    _file="$1"
    _section="$2"
    _desc="$3"
    if grep -q "^\[${_section}\]" "$_file"; then
        fail "$_desc"
    else
        pass "$_desc"
    fi
}

# ===========================================================================
# Preflight: config files must exist
# ===========================================================================

if [ ! -f "$MACHINE_CFG" ]; then
    echo "FATAL: machine.cfg not found at $MACHINE_CFG"
    exit 2
fi
if [ ! -f "$STOCK_CFG" ]; then
    echo "FATAL: stock-printer.cfg not found at $STOCK_CFG"
    exit 2
fi

echo "=== KE stepper motor and TMC driver configuration parity ==="
echo "machine.cfg: $MACHINE_CFG"
echo "stock ref:   $STOCK_CFG"
echo

# ===========================================================================
# 1. Printer kinematics
# ===========================================================================

echo "--- Printer kinematics ---"
assert_cfg "printer" "kinematics" "cartesian" \
    "[printer] kinematics is cartesian"
assert_cfg "printer" "max_velocity" "500" \
    "[printer] max_velocity is 500"
assert_cfg "printer" "max_accel" "8000" \
    "[printer] max_accel is 8000"

# ===========================================================================
# 2. Stepper X -- pin assignments and motion parameters
# ===========================================================================

echo
echo "--- Stepper X ---"
assert_cfg "stepper_x" "step_pin"  "PC2"  "[stepper_x] step_pin is PC2"
assert_cfg "stepper_x" "dir_pin"   "!PB9" "[stepper_x] dir_pin is !PB9"
assert_cfg "stepper_x" "enable_pin" "!PC3" "[stepper_x] enable_pin is !PC3"
assert_cfg "stepper_x" "microsteps" "16"   "[stepper_x] microsteps is 16"
assert_cfg "stepper_x" "rotation_distance" "40" \
    "[stepper_x] rotation_distance is 40 (20-tooth GT2 pulley)"
assert_cfg "stepper_x" "endstop_pin" "!PA5" "[stepper_x] endstop_pin is !PA5"
assert_cfg "stepper_x" "position_endstop" "-12" \
    "[stepper_x] position_endstop is -12"
assert_cfg "stepper_x" "position_min" "-12" \
    "[stepper_x] position_min is -12"
assert_cfg "stepper_x" "position_max" "221" \
    "[stepper_x] position_max is 221"

# ===========================================================================
# 3. TMC2208 stepper_x
# ===========================================================================

echo
echo "--- TMC2208 stepper_x ---"
assert_cfg "tmc2208 stepper_x" "uart_pin" "PB12" \
    "[tmc2208 stepper_x] uart_pin is PB12"
assert_cfg "tmc2208 stepper_x" "interpolate" "True" \
    "[tmc2208 stepper_x] interpolate is True"
assert_cfg "tmc2208 stepper_x" "run_current" "0.75" \
    "[tmc2208 stepper_x] run_current is 0.75"
assert_cfg "tmc2208 stepper_x" "sense_resistor" "0.150" \
    "[tmc2208 stepper_x] sense_resistor is 0.150 (non-default; Klipper default is 0.110)"
assert_cfg "tmc2208 stepper_x" "stealthchop_threshold" "0" \
    "[tmc2208 stepper_x] stealthchop_threshold is 0 (spreadCycle at all speeds)"

# ===========================================================================
# 4. Stepper Y -- pin assignments and motion parameters
# ===========================================================================

echo
echo "--- Stepper Y ---"
assert_cfg "stepper_y" "step_pin"  "PB8"  "[stepper_y] step_pin is PB8"
assert_cfg "stepper_y" "dir_pin"   "PB7"  "[stepper_y] dir_pin is PB7"
assert_cfg "stepper_y" "enable_pin" "!PC3" "[stepper_y] enable_pin is !PC3"
assert_cfg "stepper_y" "microsteps" "16"   "[stepper_y] microsteps is 16"
assert_cfg "stepper_y" "rotation_distance" "60" \
    "[stepper_y] rotation_distance is 60 (30-tooth GT2 pulley, not the standard 20-tooth)"
assert_cfg "stepper_y" "endstop_pin" "!PA6" "[stepper_y] endstop_pin is !PA6"
assert_cfg "stepper_y" "position_endstop" "-20" \
    "[stepper_y] position_endstop is -20"
assert_cfg "stepper_y" "position_min" "-20" \
    "[stepper_y] position_min is -20"
assert_cfg "stepper_y" "position_max" "223" \
    "[stepper_y] position_max is 223"

# ===========================================================================
# 5. TMC2208 stepper_y
# ===========================================================================

echo
echo "--- TMC2208 stepper_y ---"
assert_cfg "tmc2208 stepper_y" "uart_pin" "PB13" \
    "[tmc2208 stepper_y] uart_pin is PB13"
assert_cfg "tmc2208 stepper_y" "interpolate" "True" \
    "[tmc2208 stepper_y] interpolate is True"
assert_cfg "tmc2208 stepper_y" "run_current" "0.75" \
    "[tmc2208 stepper_y] run_current is 0.75"
assert_cfg "tmc2208 stepper_y" "sense_resistor" "0.150" \
    "[tmc2208 stepper_y] sense_resistor is 0.150 (non-default; Klipper default is 0.110)"
assert_cfg "tmc2208 stepper_y" "stealthchop_threshold" "0" \
    "[tmc2208 stepper_y] stealthchop_threshold is 0 (spreadCycle at all speeds)"

# ===========================================================================
# 6. Stepper Z -- pin assignments and motion parameters
# ===========================================================================

echo
echo "--- Stepper Z ---"
assert_cfg "stepper_z" "step_pin"  "PB6"  "[stepper_z] step_pin is PB6"
assert_cfg "stepper_z" "dir_pin"   "!PB5" "[stepper_z] dir_pin is !PB5"
assert_cfg "stepper_z" "enable_pin" "!PC3" "[stepper_z] enable_pin is !PC3"
assert_cfg "stepper_z" "microsteps" "16"   "[stepper_z] microsteps is 16"
assert_cfg "stepper_z" "rotation_distance" "8" \
    "[stepper_z] rotation_distance is 8 (T8 leadscrew)"
assert_cfg "stepper_z" "endstop_pin" "probe:z_virtual_endstop" \
    "[stepper_z] endstop_pin is probe:z_virtual_endstop"
assert_cfg "stepper_z" "position_max" "246" \
    "[stepper_z] position_max is 246"
assert_cfg "stepper_z" "position_min" "-5" \
    "[stepper_z] position_min is -5"

# ===========================================================================
# 7. TMC2208 stepper_z
# ===========================================================================

echo
echo "--- TMC2208 stepper_z ---"
assert_cfg "tmc2208 stepper_z" "uart_pin" "PB14" \
    "[tmc2208 stepper_z] uart_pin is PB14"
assert_cfg "tmc2208 stepper_z" "interpolate" "True" \
    "[tmc2208 stepper_z] interpolate is True"
assert_cfg "tmc2208 stepper_z" "run_current" "0.8" \
    "[tmc2208 stepper_z] run_current is 0.8"
assert_cfg "tmc2208 stepper_z" "sense_resistor" "0.150" \
    "[tmc2208 stepper_z] sense_resistor is 0.150 (non-default; Klipper default is 0.110)"
assert_cfg "tmc2208 stepper_z" "stealthchop_threshold" "0" \
    "[tmc2208 stepper_z] stealthchop_threshold is 0 (spreadCycle at all speeds)"

# ===========================================================================
# 8. Extruder -- stepper pin assignments and motion parameters
# ===========================================================================

echo
echo "--- Extruder stepper ---"
assert_cfg "extruder" "step_pin"  "PB4"  "[extruder] step_pin is PB4"
assert_cfg "extruder" "dir_pin"   "PB3"  "[extruder] dir_pin is PB3"
assert_cfg "extruder" "enable_pin" "!PC3" "[extruder] enable_pin is !PC3"
assert_cfg "extruder" "microsteps" "16"   "[extruder] microsteps is 16"
assert_cfg "extruder" "rotation_distance" "7.53" \
    "[extruder] rotation_distance is 7.53"

# ===========================================================================
# 9. Shared enable pin -- all four axes use the same !PC3
# ===========================================================================

echo
echo "--- Shared enable line ---"
_en_x=$(cfg_get "$MACHINE_CFG" "stepper_x" "enable_pin")
_en_y=$(cfg_get "$MACHINE_CFG" "stepper_y" "enable_pin")
_en_z=$(cfg_get "$MACHINE_CFG" "stepper_z" "enable_pin")
_en_e=$(cfg_get "$MACHINE_CFG" "extruder"  "enable_pin")
if [ "$_en_x" = "!PC3" ] && [ "$_en_y" = "!PC3" ] && \
   [ "$_en_z" = "!PC3" ] && [ "$_en_e" = "!PC3" ]; then
    pass "all four axes share enable_pin !PC3 (shared enable line)"
else
    fail "enable_pin mismatch: x='$_en_x' y='$_en_y' z='$_en_z' e='$_en_e' (expected !PC3 for all)"
fi

# ===========================================================================
# 10. No TMC section for the extruder
# ===========================================================================

echo
echo "--- Extruder TMC absence ---"
assert_section_absent "$MACHINE_CFG" "tmc2208 extruder" \
    "no [tmc2208 extruder] section in machine.cfg (extruder is NOT TMC-driven)"
assert_section_absent "$MACHINE_CFG" "tmc2209 extruder" \
    "no [tmc2209 extruder] section in machine.cfg"

# ===========================================================================
# 11. sense_resistor is explicitly 0.150 (non-default) for all TMC axes
# ===========================================================================

echo
echo "--- Non-default sense_resistor check ---"
_sr_x=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_x" "sense_resistor")
_sr_y=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_y" "sense_resistor")
_sr_z=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_z" "sense_resistor")
if [ "$_sr_x" = "0.150" ] && [ "$_sr_y" = "0.150" ] && [ "$_sr_z" = "0.150" ]; then
    pass "all three TMC axes declare sense_resistor=0.150 explicitly (Klipper default is 0.110)"
else
    fail "sense_resistor not uniformly 0.150: x='$_sr_x' y='$_sr_y' z='$_sr_z'"
fi

# ===========================================================================
# 12. stealthchop_threshold=0 for all TMC axes (spreadCycle at all speeds)
# ===========================================================================

echo
echo "--- SpreadCycle mode check ---"
_sc_x=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_x" "stealthchop_threshold")
_sc_y=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_y" "stealthchop_threshold")
_sc_z=$(cfg_get "$MACHINE_CFG" "tmc2208 stepper_z" "stealthchop_threshold")
if [ "$_sc_x" = "0" ] && [ "$_sc_y" = "0" ] && [ "$_sc_z" = "0" ]; then
    pass "all three TMC axes set stealthchop_threshold=0 (spreadCycle at all speeds)"
else
    fail "stealthchop_threshold not uniformly 0: x='$_sc_x' y='$_sc_y' z='$_sc_z'"
fi

# ===========================================================================
# 13. Cross-reference: every stepper pin matches stock-printer.cfg
# ===========================================================================

echo
echo "--- Stock config cross-reference: stepper pins ---"
for axis in stepper_x stepper_y stepper_z; do
    for key in step_pin dir_pin enable_pin endstop_pin; do
        assert_stock_parity "$axis" "$key" \
            "[$axis] $key matches stock-printer.cfg"
    done
done
assert_stock_parity "extruder" "step_pin" \
    "[extruder] step_pin matches stock-printer.cfg"
assert_stock_parity "extruder" "dir_pin" \
    "[extruder] dir_pin matches stock-printer.cfg"
assert_stock_parity "extruder" "enable_pin" \
    "[extruder] enable_pin matches stock-printer.cfg"

# ===========================================================================
# 14. Cross-reference: every stepper motion parameter matches stock
# ===========================================================================

echo
echo "--- Stock config cross-reference: motion parameters ---"
for axis in stepper_x stepper_y stepper_z; do
    for key in microsteps rotation_distance position_max position_min; do
        assert_stock_parity "$axis" "$key" \
            "[$axis] $key matches stock-printer.cfg"
    done
done
assert_stock_parity "stepper_x" "position_endstop" \
    "[stepper_x] position_endstop matches stock-printer.cfg"
assert_stock_parity "stepper_y" "position_endstop" \
    "[stepper_y] position_endstop matches stock-printer.cfg"
assert_stock_parity "extruder" "microsteps" \
    "[extruder] microsteps matches stock-printer.cfg"
assert_stock_parity "extruder" "rotation_distance" \
    "[extruder] rotation_distance matches stock-printer.cfg"

# ===========================================================================
# 15. Cross-reference: every TMC parameter matches stock
# ===========================================================================

echo
echo "--- Stock config cross-reference: TMC parameters ---"
for axis in "tmc2208 stepper_x" "tmc2208 stepper_y" "tmc2208 stepper_z"; do
    for key in uart_pin interpolate run_current sense_resistor stealthchop_threshold; do
        assert_stock_parity "$axis" "$key" \
            "[$axis] $key matches stock-printer.cfg"
    done
done

# ===========================================================================
# 16. Cross-reference: no TMC extruder section in stock either
# ===========================================================================

echo
echo "--- Stock config cross-reference: extruder TMC absence ---"
assert_section_absent "$STOCK_CFG" "tmc2208 extruder" \
    "no [tmc2208 extruder] in stock-printer.cfg either (confirms extruder is not TMC-driven)"
assert_section_absent "$STOCK_CFG" "tmc2209 extruder" \
    "no [tmc2209 extruder] in stock-printer.cfg either"

# ===========================================================================
# 17. Cross-reference: printer kinematics match stock
# ===========================================================================

echo
echo "--- Stock config cross-reference: printer kinematics ---"
assert_stock_parity "printer" "kinematics" \
    "[printer] kinematics matches stock-printer.cfg"
assert_stock_parity "printer" "max_velocity" \
    "[printer] max_velocity matches stock-printer.cfg"
assert_stock_parity "printer" "max_accel" \
    "[printer] max_accel matches stock-printer.cfg"

# ===========================================================================
# Summary
# ===========================================================================

echo
echo "ke-stepper-tmc-parity-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
