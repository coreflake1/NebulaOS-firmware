#!/bin/sh
#
# Offline, repeatable tests for the intermediate-generation fix to
# migrate_printer_cfg() in scripts/build/overlay/etc/init.d/S04nebulaos-migrate
# (Phase 2 overnight convergence mission, 2026-09-09).
#
# Real device found live during Phase 2 RC4 overnight qualification: a
# physically-qualified printer had a printer.cfg from AFTER the Phase 1.5
# split (commit 7b4a2ec - has platform.cfg/machine.cfg/z_offset_probe.cfg/
# calibration.cfg includes) but BEFORE commit 8889ef0 ("Phase 2
# upstream-first config refactor: remove SimpleAF/GuppyScreen deps") - it
# still included GuppyScreen/guppy_cmd.cfg and simpleaf/*.cfg directly,
# never got homing.cfg/print.cfg/filament.cfg/beeper.cfg, and consequently
# had NO [filament_switch_sensor] object loaded at all (a real
# runout-detection gap). migrate_printer_cfg()'s old idempotency check
# (`grep platform.cfg -> return 0`) treated this shape as "already
# migrated" and never touched it, on every single boot, forever.
#
# A first version of the fix that recognized this shape and always
# migrated it had a serious secondary bug, ALSO discovered against this
# exact device's real config: the anchor-based cut discards everything
# from the top of the file through the anchor line unconditionally, with
# no way to preserve a technician's own insertion BETWEEN calibration.cfg's
# include and the anchor (as opposed to genuine trailing content AFTER the
# anchor, which it already preserves correctly). This device's real
# printer.cfg had exactly such an insertion: a documented, safety-critical
# live-qualification override ([axis_twist_compensation] calibrate_end_y,
# preventing the probe frame from exceeding the real Y-axis travel by
# 4mm) sitting right there - the first fix would have silently deleted a
# crash-preventing safety override while "fixing" the filament sensor.
#
# The final fix instead requires that middle region to be narrowly
# recognized (only the exact known GuppyScreen/simpleaf include lines,
# blank lines, comments) before treating case 3 as a known shape at all -
# anything else (like this device's real override) makes it fall through
# to "unrecognized shape", which REFUSES to touch the file, backs it up,
# and logs clearly. That refusal is the correct, safe outcome for this
# specific device: an architect must manually relocate the override (e.g.
# into the trailing/user-owned region, or fix machine.cfg's own default
# directly) before an automated migration can run safely.
#
# This file tests both outcomes:
#   1. A clean intermediate-gen fixture (no mid-block insertion) - must
#      migrate successfully, gaining the full include set, no data loss.
#   2. The real device's exact fixture (WITH the safety override) - must
#      be safely REFUSED, backed up, and left completely untouched.
#
# Usage: sh tests/printer-cfg-intermediate-generation-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/printer.cfg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/printer-cfg-intermediate-gen-tests.XXXXXX")

cleanup() {
	chmod -R u+rwx "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }
[ -f "$REAL_PRINTER_CFG" ] || { echo "SKIP: $REAL_PRINTER_CFG not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

SEEDS_SANDBOX="$WORK/seeds"
mkdir -p "$SEEDS_SANDBOX/printer_data-config"
cp "$REAL_PRINTER_CFG" "$SEEDS_SANDBOX/printer_data-config/printer.cfg"

# Deployed-klipper-cfg-dir sandbox (Phase 2 final live convergence mission,
# 2026-09-09): _pcfg_deployed_calibrate_end_y_is_190() reads THIS device's
# own machine.cfg, not source - the default sandbox here mirrors "already
# rebuilt with the fix" (a real copy of the real, corrected machine.cfg,
# which has calibrate_end_y: 190) since that is the expected steady state.
# Case 6 below builds a SEPARATE sandbox with the pre-fix value 200 to
# reproduce the exact live bug: migrating with source-staged fixes ahead of
# an actual image rebuild must REFUSE, not silently drop a still-load-
# bearing safety override.
REAL_MACHINE_CFG="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/machine.cfg"
KLIPPER_CFG_SANDBOX_REBUILT="$WORK/klipper-cfg-rebuilt"
mkdir -p "$KLIPPER_CFG_SANDBOX_REBUILT"
if [ -f "$REAL_MACHINE_CFG" ]; then
	cp "$REAL_MACHINE_CFG" "$KLIPPER_CFG_SANDBOX_REBUILT/machine.cfg"
else
	printf '[axis_twist_compensation]\ncalibrate_end_y: 190\n' > "$KLIPPER_CFG_SANDBOX_REBUILT/machine.cfg"
fi

run_fn() {
	pdc="$1"; sysdir="$2"; log="$3"; kcfgdir="${4:-$KLIPPER_CFG_SANDBOX_REBUILT}"
	mkdir -p "$sysdir/diagnostics"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$sysdir" SEEDS="$SEEDS_SANDBOX" \
		NEBULAOS_KLIPPER_CFG_DIR="$kcfgdir" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; migrate_printer_cfg || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }

INTERMEDIATE_GEN_HEADER='# NebulaOS Ender-3 V3 KE - persistent, user-owned printer configuration.
[include /etc/nebulaos/klipper/platform.cfg]
[include /etc/nebulaos/klipper/machine.cfg]
#[include /etc/nebulaos/klipper/prtouch.cfg]  # Phase 1.8: disabled for native MCU first boot
[include /etc/nebulaos/klipper/z_offset_probe.cfg]
[include /etc/nebulaos/klipper/calibration.cfg]
'
INTERMEDIATE_GEN_MIDDLE='
[include GuppyScreen/guppy_cmd.cfg]
[include camera-quality.cfg]

[include simpleaf/homing.cfg]
[include simpleaf/useful_macros.cfg]
[include simpleaf/fan_control.cfg]
[include simpleaf/client.cfg]
[include simpleaf/start_end.cfg]
[include simpleaf/Line_Purge.cfg]
[include simpleaf/Smart_Park.cfg]
[include simpleaf/bltouch_macro.cfg]
'
INTERMEDIATE_GEN_TRAILER='
# Your own additional includes/macros go below this line.

[z_compensate]
tri_expand_mm: 0.10
bl_offset: 0,27

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 1.755
'

# --- Case 1: clean intermediate-gen fixture, no mid-block insertion --------

t1="$WORK/case1"; mkdir -p "$t1"; f1="$t1/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f1"
cp "$f1" "$f1.orig"

log1="$WORK/log1"
run_fn "$t1" "$WORK/system1" "$log1"

if grep -qxF '[include /etc/nebulaos/klipper/filament.cfg]' "$f1" \
	&& grep -qxF '[include /etc/nebulaos/klipper/homing.cfg]' "$f1" \
	&& grep -qxF '[include /etc/nebulaos/klipper/print.cfg]' "$f1" \
	&& grep -qxF '[include /etc/nebulaos/klipper/beeper.cfg]' "$f1"; then
	pass "case 1 (clean fixture): upgraded to the full Phase 2 include set"
else
	fail "case 1 (clean fixture): not upgraded to include homing/print/filament/beeper"
fi
[ "$(rc_of "$log1")" = "0" ] && pass "case 1: reports success" || fail "case 1: reported failure ($(cat "$log1"))"
if grep -qF 'tri_expand_mm: 0.10' "$f1" && grep -qF '#*# z_offset = 1.755' "$f1"; then
	pass "case 1: trailing user/calibration content preserved"
else
	fail "case 1: trailing content lost"
fi
sum_a=$(md5sum "$f1" | cut -d' ' -f1)
run_fn "$t1" "$WORK/system1b" "$WORK/log1b"
sum_b=$(md5sum "$f1" | cut -d' ' -f1)
[ "$sum_a" = "$sum_b" ] && pass "case 1: second run is a true no-op" || fail "case 1: second run modified the file further"

# --- Case 2: an UNRECOGNIZED axis-twist override (the pre-correction,
#     found-unsafe value 200) - must still safely refuse, never silently
#     deleted or silently promoted -----------------------------------------

t2="$WORK/case2"; mkdir -p "$t2"; f2="$t2/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	echo ''
	echo '# LIVE QUALIFICATION HOTFIX: overrides machine.cfg calibrate_end_y=200'
	echo '# (probe-frame Y=227 exceeds real axis_maximum=223 by 4mm - unsafe).'
	echo '[axis_twist_compensation]'
	echo 'calibrate_end_y: 200'
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f2"
cp "$f2" "$f2.orig"

log2="$WORK/log2"
run_fn "$t2" "$WORK/system2" "$log2"

if cmp -s "$f2" "$f2.orig"; then
	pass "case 2 (unrecognized override, value 200): left completely untouched - safe refusal"
else
	fail "case 2 (unrecognized override, value 200): file was modified - a mid-block safety override could have been silently deleted"
fi
if [ "$(rc_of "$log2")" != "0" ]; then
	pass "case 2: migrate_printer_cfg reports failure (correctly refuses rather than guesses)"
else
	fail "case 2: migrate_printer_cfg reported success despite unrecognized mid-block content"
fi
if grep -q "does not match a recognized shape" "$log2"; then
	pass "case 2: refusal is logged with a clear diagnostic"
else
	fail "case 2: no clear refusal diagnostic found in the log"
fi
refused_backup=$(find "$WORK/system2/migration-backups/printer-cfg-migration-refused" -name 'printer.cfg.*' 2>/dev/null | head -1)
if [ -n "$refused_backup" ] && cmp -s "$refused_backup" "$f2.orig"; then
	pass "case 2: a backup matching the original was written to the refused-migration directory"
else
	fail "case 2: no matching backup found in the refused-migration directory"
fi

# --- Case 3 (Phase 2 final live convergence mission, 2026-09-09): the
#     CORRECTED, canonical-matching axis-twist override (value 190) - now
#     that machine.cfg's own default is also 190, this exact historical
#     override is genuinely redundant and migration should proceed,
#     consuming it, exactly like the clean case-1 fixture -----------------

t3="$WORK/case3"; mkdir -p "$t3"; f3="$t3/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	echo ''
	echo '# LIVE QUALIFICATION HOTFIX: overrides machine.cfg calibrate_end_y=200'
	echo '# (probe-frame Y=227 exceeds real axis_maximum=223 by 4mm - unsafe).'
	echo '# 190 gives an explicit 6mm safety margin (probe-frame Y=217).'
	echo '[axis_twist_compensation]'
	echo 'calibrate_end_y: 190'
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f3"

log3="$WORK/log3"
run_fn "$t3" "$WORK/system3" "$log3"

if grep -qxF '[include /etc/nebulaos/klipper/filament.cfg]' "$f3" \
	&& grep -qxF '[include /etc/nebulaos/klipper/homing.cfg]' "$f3"; then
	pass "case 3 (recognized override, value 190): migration proceeds, upgraded to the full Phase 2 include set"
else
	fail "case 3 (recognized override, value 190): migration did not proceed despite the override matching the canonical default"
fi
[ "$(rc_of "$log3")" = "0" ] && pass "case 3: reports success" || fail "case 3: reported failure ($(cat "$log3"))"
if ! grep -qF '[axis_twist_compensation]' "$f3"; then
	pass "case 3: the now-redundant override block is consumed, not carried forward as dead config"
else
	fail "case 3: the redundant override block was left behind after migration"
fi
if grep -qF 'tri_expand_mm: 0.10' "$f3" && grep -qF '#*# z_offset = 1.755' "$f3"; then
	pass "case 3: unrelated trailing user/calibration content still preserved"
else
	fail "case 3: unrelated trailing content lost"
fi

# --- Case 4: value 190 (recognized) but with an EXTRA, genuinely custom
#     axis-twist option alongside it - the per-line check must still
#     refuse, since customization beyond the exact known override is not
#     something this migration may silently discard --------------------

t4="$WORK/case4"; mkdir -p "$t4"; f4="$t4/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	echo ''
	echo '[axis_twist_compensation]'
	echo 'calibrate_end_y: 190'
	echo 'speed: 25'
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f4"
cp "$f4" "$f4.orig"

log4="$WORK/log4"
run_fn "$t4" "$WORK/system4" "$log4"

if cmp -s "$f4" "$f4.orig"; then
	pass "case 4 (recognized value plus a genuine extra option): left completely untouched - safe refusal"
else
	fail "case 4 (recognized value plus a genuine extra option): file was modified despite real customization beyond the known override"
fi
[ "$(rc_of "$log4")" != "0" ] && pass "case 4: migrate_printer_cfg reports failure" || fail "case 4: migrate_printer_cfg reported success despite unrecognized extra content"

# --- Case 6 (Phase 2 final live convergence mission, 2026-09-09): value 190
#     (recognized text), but THIS DEVICE's own deployed machine.cfg has NOT
#     actually been rebuilt with the corrected default yet (still 200) -
#     reproduces the exact live bug: a first version of this fix assumed
#     "the override text matches 190" meant "machine.cfg's own default is
#     already 190 too", which is only true once a real image rebuild
#     ships the fix. Migrating with just the source-staged script fix
#     (ahead of any rebuild) against a real device silently dropped the
#     override, leaving the device with NO override and an EFFECTIVE
#     calibrate_end_y of 200 - the unsafe value the override existed to
#     prevent. Must safely REFUSE instead, exactly like an unrecognized
#     value, until the device's own machine.cfg genuinely says 190. -----

t6="$WORK/case6"; mkdir -p "$t6"; f6="$t6/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	echo ''
	echo '# LIVE QUALIFICATION HOTFIX: overrides machine.cfg calibrate_end_y=200'
	echo '[axis_twist_compensation]'
	echo 'calibrate_end_y: 190'
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f6"
cp "$f6" "$f6.orig"

KLIPPER_CFG_SANDBOX_NOT_REBUILT="$WORK/klipper-cfg-not-rebuilt"
mkdir -p "$KLIPPER_CFG_SANDBOX_NOT_REBUILT"
printf '[axis_twist_compensation]\ncalibrate_end_y: 200\n' > "$KLIPPER_CFG_SANDBOX_NOT_REBUILT/machine.cfg"

log6="$WORK/log6"
run_fn "$t6" "$WORK/system6" "$log6" "$KLIPPER_CFG_SANDBOX_NOT_REBUILT"

if cmp -s "$f6" "$f6.orig"; then
	pass "case 6 (override text matches 190, but deployed machine.cfg is still 200): left completely untouched - safe refusal"
else
	fail "case 6 (override text matches 190, but deployed machine.cfg is still 200): file was modified - a still-load-bearing safety override could have been silently dropped, reproducing the exact live bug"
fi
[ "$(rc_of "$log6")" != "0" ] && pass "case 6: migrate_printer_cfg reports failure" || fail "case 6: migrate_printer_cfg reported success despite the deployed machine.cfg not yet matching"

# Sanity check the other direction too: the SAME override, against a
# sandbox where machine.cfg genuinely already says 190, must still succeed
# (this is exactly case 3, re-run through the explicit kcfgdir param
# rather than run_fn's implicit default, to prove the parameter itself
# works both ways).
t6b="$WORK/case6b"; mkdir -p "$t6b"; f6b="$t6b/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	echo ''
	echo '[axis_twist_compensation]'
	echo 'calibrate_end_y: 190'
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$INTERMEDIATE_GEN_TRAILER"
} > "$f6b"
log6b="$WORK/log6b"
run_fn "$t6b" "$WORK/system6b" "$log6b" "$KLIPPER_CFG_SANDBOX_REBUILT"
[ "$(rc_of "$log6b")" = "0" ] && pass "case 6b: the same override against an already-rebuilt machine.cfg (190) still succeeds" \
	|| fail "case 6b: reported failure even though the deployed machine.cfg already matches ($(cat "$log6b"))"

# --- Case 5 (Phase 2 final live convergence mission, 2026-09-09): a device
#     whose OWN trailing content already carries a real, full SAVE_CONFIG
#     autosave block (an already-calibrated printer) - the tracked seed
#     ALSO ships its own placeholder SAVE_CONFIG block (added for virgin
#     devices per docs/NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md), so a
#     naive concatenation puts two "#*# <----SAVE_CONFIG---->" markers in
#     one file. Reproduced live: Klipper's autosave parser only honors the
#     FIRST such marker and, on finding non-"#*#" trailing content (this
#     project's own [z_compensate]/[resonance_tester] sections) before a
#     second marker, silently discards the WHOLE autosave block as
#     "modifications after header" - the real device's genuine BLTouch
#     z_offset, PID, load-cell, and input-shaper calibration, gone, no
#     error logged anywhere Klipper's own startup output would surface it
#     as a hard failure. Migration must instead omit the seed's own
#     placeholder in this case, so exactly one (the real) block survives.

REAL_AUTOSAVE_TRAILER='
# Your own additional includes/macros go below this line.

[z_compensate]
tri_min_hold: 1400
tri_max_hold: 2000

[resonance_tester]
max_freq: 60

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 1.755
#*#
#*# [nebulaos_z_offset_probe]
#*# counts_per_gram = 85.72084
#*# reference_tare_counts = -249399
#*#
#*# [extruder]
#*# control = pid
#*# pid_kp = 24.146
#*# pid_ki = 2.091
#*# pid_kd = 69.723
#*# rotation_distance = 7.530
#*#
#*# [heater_bed]
#*# control = pid
#*# pid_kp = 64.358
#*# pid_ki = 0.689
#*# pid_kd = 1503.566
#*#
#*# [input_shaper]
#*# shaper_type_x = mzv
#*# shaper_freq_x = 58.0
#*# shaper_type_y = mzv
#*# shaper_freq_y = 37.6
'

t5="$WORK/case5"; mkdir -p "$t5"; f5="$t5/printer.cfg"
{
	printf '%s' "$INTERMEDIATE_GEN_HEADER"
	printf '%s' "$INTERMEDIATE_GEN_MIDDLE"
	printf '%s' "$REAL_AUTOSAVE_TRAILER"
} > "$f5"

log5="$WORK/log5"
run_fn "$t5" "$WORK/system5" "$log5"

[ "$(rc_of "$log5")" = "0" ] && pass "case 5: reports success" || fail "case 5: reported failure ($(cat "$log5"))"

marker_count=$(grep -cxF '#*# <---------------------- SAVE_CONFIG ---------------------->' "$f5")
[ "$marker_count" = "1" ] && pass "case 5: migrated file contains exactly one SAVE_CONFIG marker" \
	|| fail "case 5: migrated file contains $marker_count SAVE_CONFIG markers (Klipper's autosave parser only honors the first and discards the rest as corrupted)"

if grep -qF '#*# z_offset = 1.755' "$f5" \
	&& grep -qF '#*# counts_per_gram = 85.72084' "$f5" \
	&& grep -qF '#*# shaper_freq_x = 58.0' "$f5"; then
	pass "case 5: the device's own real calibration data survives the migration"
else
	fail "case 5: the device's own real calibration data was lost"
fi

if grep -qF '#*# z_offset = 0.000' "$f5" || grep -qF '#*# pid_kp = 20.584' "$f5"; then
	fail "case 5: the seed's own placeholder factory-default values leaked into the migrated file alongside the real ones"
else
	pass "case 5: the seed's own placeholder factory-default values are not present"
fi

sum5_a=$(md5sum "$f5" | cut -d' ' -f1)
run_fn "$t5" "$WORK/system5b" "$WORK/log5b"
sum5_b=$(md5sum "$f5" | cut -d' ' -f1)
[ "$sum5_a" = "$sum5_b" ] && pass "case 5: second run is a true no-op" || fail "case 5: second run modified the file further"

echo ""
echo "printer-cfg-intermediate-generation-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
