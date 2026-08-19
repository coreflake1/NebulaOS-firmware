#!/bin/sh
#
# Offline, repeatable tests for migrate_printer_cfg() and
# migrate_moonraker_pin_include() in scripts/build/overlay/etc/init.d/
# S04nebulaos-migrate (Phase 1.5 persistent-namespace mission, 2026-08):
# the one-time, idempotent rewrites that move an existing device's
# persistent printer.cfg/moonraker.conf onto the new /etc/nebulaos/
# klipper|moonraker/ split-entrypoint shape.
#
# Sources the real S04nebulaos-migrate with S04NEBULAOS_MIGRATE_NO_AUTORUN=1
# (same seam app-migration-tests.sh already uses) and PRINTER_DATA_CONFIG/
# SYSTEM/GATE_LIB pointed at sandbox paths under mktemp -d. Never touches a
# real device.
#
# migrate_printer_cfg() reads its replacement template from
# "$SEEDS/printer_data-config/printer.cfg" (SEEDS defaults to
# /opt/nebulaos-seeds, same override convention every other seed reference
# in this file already uses - reseed_git_app's "$SEEDS/$name.tar.gz",
# "$SEEDS/seed-manifest.json"). Overridden to a sandbox path below, so
# cases A/B/C/F (the successful-migration path) run for real without
# needing root or touching anything outside mktemp -d.
#
# Usage: sh tests/printer-cfg-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_CFG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config/printer.cfg"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/printer-cfg-migration-tests.XXXXXX")

SEEDS_SANDBOX="$WORK/seeds"
NEW_SEED_FILE="$SEEDS_SANDBOX/printer_data-config/printer.cfg"

cleanup() {
	chmod -R u+rwx "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }
[ -f "$REAL_PRINTER_CFG" ] || { echo "SKIP: $REAL_PRINTER_CFG not present"; exit 0; }

PASS=0
FAIL=0
SKIP=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

# --- stage the real tracked printer.cfg at the sandboxed seed path --------

mkdir -p "$SEEDS_SANDBOX/printer_data-config"
cp "$REAL_PRINTER_CFG" "$NEW_SEED_FILE"

# --- helpers --------------------------------------------------------------

run_fn() {
	pdc="$1"; sysdir="$2"; fn="$3"; log="$4"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$sysdir" SEEDS="$SEEDS_SANDBOX" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; $fn || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }

require_stage() {
	return 0
}

write_old_monolithic_fixture() {
	out="$1"
	cat > "$out" <<'EOF'
# NebulaOS Ender-3 V3 KE - old monolithic printer.cfg fixture
# (representative of the pre-Phase-1.5-split shape: machine/PRTouch/
# platform definitions all inline, ending with the anchor line
# migrate_printer_cfg() looks for).
[nebulaos_compat]

[tmcstatus]

[nebulaos_version]

[mcu]
serial: /dev/ttyS1
baud: 230400

[printer]
kinematics: cartesian
max_velocity: 500

[stepper_x]
step_pin: PC2
dir_pin: !PB9
enable_pin: !PC3

[extruder]
heater_pin: PA1
sensor_type: EPCOS 100K B57560G104F

[temperature_sensor mcu_temp]
sensor_type: nebulaos_temperature_mcu

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
EOF
}

# =========================================================================
# CASE A - clean known-old monolithic printer.cfg, no SAVE_CONFIG, no
# extra user content. Must migrate, back up first, backup matches the
# original exactly, migrated file has all three new includes.
# =========================================================================

if require_stage "case A"; then
	tA="$WORK/caseA"; mkdir -p "$tA/config" "$tA/system"
	write_old_monolithic_fixture "$tA/config/printer.cfg"
	cp "$tA/config/printer.cfg" "$tA/original.cfg"
	logA="$WORK/caseA.log"
	run_fn "$tA/config" "$tA/system" migrate_printer_cfg "$logA"

	backupA=$(find "$tA/system/migration-backups/printer-cfg-migration" -maxdepth 1 -type f -name 'printer.cfg.pre-migration.*' 2>/dev/null | head -1)
	if [ -n "$backupA" ] && cmp -s "$backupA" "$tA/original.cfg"; then
		pass "case A: backed up first, backup matches the original exactly"
	else
		fail "case A: backup missing or does not match the original ($(cat "$logA"))"
	fi

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tA/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/machine.cfg]' "$tA/config/printer.cfg" \
		&& grep -qxF '[include /etc/nebulaos/klipper/prtouch.cfg]' "$tA/config/printer.cfg"; then
		pass "case A: migrated file has all three /etc/nebulaos/klipper/*.cfg includes"
	else
		fail "case A: migrated file is missing one or more of the new includes"
	fi

	if [ "$(rc_of "$logA")" = "0" ]; then
		pass "case A: migrate_printer_cfg reports success"
	else
		fail "case A: migrate_printer_cfg reported failure ($(cat "$logA"))"
	fi
fi

# =========================================================================
# CASE B - same, but with a real SAVE_CONFIG block appended after the last
# include. Must be preserved byte-for-byte at the end of the migrated file.
# =========================================================================

if require_stage "case B"; then
	tB="$WORK/caseB"; mkdir -p "$tB/config" "$tB/system"
	write_old_monolithic_fixture "$tB/config/printer.cfg"
	save_config_block='#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 1.234000'
	printf '%s\n' "$save_config_block" >> "$tB/config/printer.cfg"
	logB="$WORK/caseB.log"
	run_fn "$tB/config" "$tB/system" migrate_printer_cfg "$logB"

	actual_tail=$(awk '/^#\*# <---------------------- SAVE_CONFIG/{found=1} found' "$tB/config/printer.cfg")
	if [ "$actual_tail" = "$save_config_block" ]; then
		pass "case B: SAVE_CONFIG block is preserved byte-for-byte at the end of the migrated file"
	else
		fail "case B: SAVE_CONFIG block was not preserved correctly ($(cat "$logB"))"
	fi

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tB/config/printer.cfg"; then
		pass "case B: migrated file still has the new includes alongside the preserved SAVE_CONFIG block"
	else
		fail "case B: migrated file is missing the new includes"
	fi
fi

# =========================================================================
# CASE C - same, but with an extra user-added include after the anchor
# line. Must survive the migration, in the same relative position (after
# the standard includes).
# =========================================================================

if require_stage "case C"; then
	tC="$WORK/caseC"; mkdir -p "$tC/config" "$tC/system"
	write_old_monolithic_fixture "$tC/config/printer.cfg"
	echo '[include my_custom_macros.cfg]' >> "$tC/config/printer.cfg"
	logC="$WORK/caseC.log"
	run_fn "$tC/config" "$tC/system" migrate_printer_cfg "$logC"

	if grep -qxF '[include my_custom_macros.cfg]' "$tC/config/printer.cfg"; then
		pass "case C: the user's own added include survives the migration"
	else
		fail "case C: the user's own added include was lost ($(cat "$logC"))"
	fi

	last_standard_line=$(grep -n '^\[include simpleaf/bltouch_macro.cfg\]$' "$tC/config/printer.cfg" | tail -1 | cut -d: -f1)
	custom_line=$(grep -n '^\[include my_custom_macros.cfg\]$' "$tC/config/printer.cfg" | tail -1 | cut -d: -f1)
	if [ -n "$last_standard_line" ] && [ -n "$custom_line" ] && [ "$custom_line" -gt "$last_standard_line" ]; then
		pass "case C: the custom include stays in the same relative position, after the standard includes"
	else
		fail "case C: the custom include's position relative to the standard includes changed"
	fi
fi

# =========================================================================
# CASE D - a printer.cfg that is ALREADY migrated. Must be a true no-op,
# byte-for-byte unchanged, confirmed idempotent by running twice.
# =========================================================================

tD="$WORK/caseD"; mkdir -p "$tD/config" "$tD/system"
cp "$REAL_PRINTER_CFG" "$tD/config/printer.cfg"
cp "$REAL_PRINTER_CFG" "$tD/original.cfg"
logD1="$WORK/caseD1.log"
run_fn "$tD/config" "$tD/system" migrate_printer_cfg "$logD1"

if cmp -s "$tD/config/printer.cfg" "$tD/original.cfg"; then
	pass "case D: an already-migrated printer.cfg is left byte-for-byte unchanged"
else
	fail "case D: an already-migrated printer.cfg was modified ($(cat "$logD1"))"
fi
if [ "$(rc_of "$logD1")" = "0" ]; then
	pass "case D: migrate_printer_cfg reports success (no-op) on an already-migrated file"
else
	fail "case D: migrate_printer_cfg reported failure on an already-migrated file ($(cat "$logD1"))"
fi

logD2="$WORK/caseD2.log"
run_fn "$tD/config" "$tD/system" migrate_printer_cfg "$logD2"
if cmp -s "$tD/config/printer.cfg" "$tD/original.cfg" && [ "$(rc_of "$logD2")" = "0" ]; then
	pass "case D: running migration a second time is genuinely idempotent"
else
	fail "case D: a second migration run was not idempotent ($(cat "$logD2"))"
fi

# =========================================================================
# CASE E - a printer.cfg that does not match the recognized old shape at
# all (a completely custom, hand-written config: no anchor line, no
# [nebulaos_compat]). Must be refused: original completely unchanged, a
# backup written to the "refused" directory, non-zero return.
# =========================================================================

tE="$WORK/caseE"; mkdir -p "$tE/config" "$tE/system"
cat > "$tE/config/printer.cfg" <<'EOF'
# A user's completely custom printer.cfg, unrelated to any shape this
# project has ever shipped.
[mcu]
serial: /dev/ttyUSB0

[stepper_x]
step_pin: PC2
dir_pin: PB9

[printer]
kinematics: cartesian
max_velocity: 300
EOF
cp "$tE/config/printer.cfg" "$tE/original.cfg"
logE="$WORK/caseE.log"
run_fn "$tE/config" "$tE/system" migrate_printer_cfg "$logE"

if cmp -s "$tE/config/printer.cfg" "$tE/original.cfg"; then
	pass "case E: an unrecognized printer.cfg is left completely unchanged"
else
	fail "case E: an unrecognized printer.cfg was modified despite not matching a recognized shape"
fi

refusedE=$(find "$tE/system/migration-backups/printer-cfg-migration-refused" -maxdepth 1 -type f 2>/dev/null | head -1)
if [ -n "$refusedE" ] && cmp -s "$refusedE" "$tE/original.cfg"; then
	pass "case E: a backup was written to the refused-migration directory, matching the original"
else
	fail "case E: no matching backup found in the refused-migration directory ($(cat "$logE"))"
fi

if [ "$(rc_of "$logE")" != "0" ]; then
	pass "case E: migrate_printer_cfg reports failure for an unrecognized shape"
else
	fail "case E: migrate_printer_cfg reported success for an unrecognized shape"
fi

# =========================================================================
# CASE F - interrupted-migration residue: a stray printer.cfg.migrate-
# tmp.<pid> file left behind by a hypothetical killed process, alongside a
# FRESH (unmigrated) fixture. Must not interfere; migration still
# completes correctly.
# =========================================================================

if require_stage "case F"; then
	tF="$WORK/caseF"; mkdir -p "$tF/config" "$tF/system"
	write_old_monolithic_fixture "$tF/config/printer.cfg"
	echo "leftover garbage from a killed migration" > "$tF/config/printer.cfg.migrate-tmp.999999"
	logF="$WORK/caseF.log"
	run_fn "$tF/config" "$tF/system" migrate_printer_cfg "$logF"

	if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$tF/config/printer.cfg" \
		&& [ "$(rc_of "$logF")" = "0" ]; then
		pass "case F: migration completes correctly despite an unrelated stray migrate-tmp file"
	else
		fail "case F: migration did not complete correctly with a stray migrate-tmp file present ($(cat "$logF"))"
	fi

	if [ -f "$tF/config/printer.cfg.migrate-tmp.999999" ]; then
		pass "case F: the unrelated stray temp file is simply orphaned, still present, untouched"
	else
		fail "case F: the stray temp file disappeared unexpectedly"
	fi
fi

# =========================================================================
# migrate_moonraker_pin_include() - tested separately, does not depend on
# the new_seed staging above at all.
# =========================================================================

# --- sub-case 1: old glob line present -> rewritten, only that one line --

tM1="$WORK/moon1"; mkdir -p "$tM1"
cat > "$tM1/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[include nebulaos/*.conf]

[update_manager moonraker]
channel: dev
EOF
cp "$tM1/moonraker.conf" "$tM1/original.conf"
logM1="$WORK/moon1.log"
run_fn "$tM1" "$WORK/moon1-system" migrate_moonraker_pin_include "$logM1"

expectedM1="$WORK/moon1-expected.conf"
sed 's#^\[include nebulaos/\*\.conf\]$#[include /etc/nebulaos/moonraker/klipper-pin.conf]#' \
	"$tM1/original.conf" > "$expectedM1"
if cmp -s "$expectedM1" "$tM1/moonraker.conf"; then
	pass "moonraker pin include: old glob line rewritten to the new absolute include, everything else byte-identical"
else
	fail "moonraker pin include: rewrite did not produce the expected result ($(cat "$logM1"))"
fi
if [ "$(rc_of "$logM1")" = "0" ]; then
	pass "moonraker pin include: reports success when the old line is found and rewritten"
else
	fail "moonraker pin include: reported failure on a successful rewrite ($(cat "$logM1"))"
fi

# --- sub-case 2: already has the new line -> no-op -----------------------

tM2="$WORK/moon2"; mkdir -p "$tM2"
cat > "$tM2/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[include /etc/nebulaos/moonraker/klipper-pin.conf]

[update_manager moonraker]
channel: dev
EOF
cp "$tM2/moonraker.conf" "$tM2/original.conf"
logM2="$WORK/moon2.log"
run_fn "$tM2" "$WORK/moon2-system" migrate_moonraker_pin_include "$logM2"

if cmp -s "$tM2/moonraker.conf" "$tM2/original.conf" && [ "$(rc_of "$logM2")" = "0" ]; then
	pass "moonraker pin include: already-migrated file is a true no-op"
else
	fail "moonraker pin include: an already-migrated file was modified or reported failure ($(cat "$logM2"))"
fi

# --- sub-case 3: neither line present -> no-op, not an error -------------

tM3="$WORK/moon3"; mkdir -p "$tM3"
cat > "$tM3/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[authorization]
trusted_clients:
 127.0.0.1
EOF
cp "$tM3/moonraker.conf" "$tM3/original.conf"
logM3="$WORK/moon3.log"
run_fn "$tM3" "$WORK/moon3-system" migrate_moonraker_pin_include "$logM3"

if cmp -s "$tM3/moonraker.conf" "$tM3/original.conf" && [ "$(rc_of "$logM3")" = "0" ]; then
	pass "moonraker pin include: a custom moonraker.conf with neither line is a no-op, not an error"
else
	fail "moonraker pin include: a custom moonraker.conf with neither line was modified or reported failure ($(cat "$logM3"))"
fi

echo ""
echo "printer-cfg-migration-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
