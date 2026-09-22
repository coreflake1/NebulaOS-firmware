#!/bin/sh
#
# Offline, repeatable tests for migrate_printer_cfg_to_managed_tree() and
# materialize_active_config() in
# scripts/build/overlay/etc/init.d/S04nebulaos-migrate (Phase 2 final
# software closure mission, 2026-09-09, sections 3-4).
#
# Migrates printer.cfg from the CURRENT final generation (ten direct
# /etc/nebulaos/klipper/*.cfg includes) to the NEW final generation (ten
# relative nebulaos/*.cfg includes pointing at a materialized copy on
# persistent storage, plus [include macros/*.cfg] for the new permanently
# user-owned macros directory).
#
# Usage: sh tests/printer-cfg-managed-tree-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
CONFIG_MATERIALIZE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/config-materialize.sh"

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }
[ -f "$CONFIG_MATERIALIZE_LIB" ] || { echo "SKIP: $CONFIG_MATERIALIZE_LIB not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pcfg-managed-tree-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: printer-cfg-managed-tree-migration-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

FINAL_GEN_FIXTURE='# NebulaOS Ender-3 V3 KE - persistent, user-owned printer configuration.
[nebulaos_compat]
[include /etc/nebulaos/klipper/platform.cfg]
[include /etc/nebulaos/klipper/machine.cfg]
[include /etc/nebulaos/klipper/prtouch.cfg]
[include /etc/nebulaos/klipper/z_offset_probe.cfg]
[include /etc/nebulaos/klipper/calibration.cfg]
[include /etc/nebulaos/klipper/homing.cfg]
[include /etc/nebulaos/klipper/print.cfg]
[include /etc/nebulaos/klipper/filament.cfg]
[include /etc/nebulaos/klipper/camera.cfg]
[include /etc/nebulaos/klipper/beeper.cfg]

# Your own additional includes/macros go below this line.

[z_compensate]
tri_min_hold: 1400

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.
#*#
#*# [bltouch]
#*# z_offset = 1.755
'

run_fn() {
	pdc="$1"; sysdir="$2"; fn="$3"; log="$4"; kcfgdir="${5:-}"
	mkdir -p "$sysdir/diagnostics"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$sysdir" \
		SEEDS="$WORK/seeds-unused" NEBULAOS_KLIPPER_CFG_DIR="${kcfgdir:-$WORK/immutable-unused}" \
		CONFIG_MATERIALIZE_LIB="$CONFIG_MATERIALIZE_LIB" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; $fn || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}

make_manifest_and_materialize() {
	pdc="$1"; sysdir="$2"; immutable="$3"
	mkdir -p "$immutable"
	files_json=""; hash_input=""
	for f in platform.cfg machine.cfg prtouch.cfg z_offset_probe.cfg calibration.cfg homing.cfg print.cfg filament.cfg camera.cfg beeper.cfg; do
		echo "# $f content" > "$immutable/$f"
		sha=$(sha256sum "$immutable/$f" | cut -d' ' -f1)
		files_json="$files_json    \"$f\": \"$sha\",
"
		hash_input="$hash_input$f:$sha
"
	done
	files_json=$(printf '%s' "$files_json" | sed '$ s/,$//')
	generation=$(printf '%s' "$hash_input" | sha256sum | cut -d' ' -f1)
	cat > "$immutable/.manifest.json" <<EOF
{"schema_version": 1, "generation": "$generation", "build_date": "test", "files": {
$files_json
}}
EOF
	env NEBULAOS_KLIPPER_CFG_DIR="$immutable" PRINTER_DATA_CONFIG="$pdc" SYSTEM="$sysdir" \
		BACKUP_ROOT="$sysdir/migration-backups" \
		sh -c ". '$CONFIG_MATERIALIZE_LIB'; log() { :; }; materialize_config_tree boot-materialization" >/dev/null
}

# =========================================================================
# Test 1: materialized tree present, printer.cfg on the old final shape -
#     migrates cleanly
# =========================================================================

t1="$WORK/t1"; mkdir -p "$t1/config" "$t1/system"
printf '%s' "$FINAL_GEN_FIXTURE" > "$t1/config/printer.cfg"
make_manifest_and_materialize "$t1/config" "$t1/system" "$WORK/t1-immutable"

log1="$WORK/log1"
run_fn "$t1/config" "$t1/system" "migrate_printer_cfg_to_managed_tree" "$log1"
[ "$(grep '^RC=' "$log1" | tail -1 | sed 's/RC=//')" = "0" ] && pass "test 1: reports success" \
	|| fail "test 1: reported failure ($(cat "$log1"))"

if grep -qxF '[include nebulaos/platform.cfg]' "$t1/config/printer.cfg" \
	&& grep -qxF '[include nebulaos/beeper.cfg]' "$t1/config/printer.cfg" \
	&& grep -qxF '[include macros/*.cfg]' "$t1/config/printer.cfg"; then
	pass "test 1: printer.cfg now includes nebulaos/*.cfg and macros/*.cfg"
else
	fail "test 1: printer.cfg does not have the expected new includes"
fi

if grep -qxF '[include /etc/nebulaos/klipper/platform.cfg]' "$t1/config/printer.cfg"; then
	fail "test 1: an old absolute include line survived the migration"
else
	pass "test 1: no old absolute /etc/nebulaos/klipper/*.cfg include lines remain"
fi

if grep -qF 'tri_min_hold: 1400' "$t1/config/printer.cfg" && grep -qF '#*# z_offset = 1.755' "$t1/config/printer.cfg"; then
	pass "test 1: trailing user content and real SAVE_CONFIG calibration data preserved"
else
	fail "test 1: trailing content or SAVE_CONFIG data lost"
fi

[ -d "$t1/config/macros" ] && pass "test 1: macros/ directory was created" \
	|| fail "test 1: macros/ directory was not created"

sum_a=$(sha256sum "$t1/config/printer.cfg" | cut -d' ' -f1)
run_fn "$t1/config" "$t1/system" "migrate_printer_cfg_to_managed_tree" "$WORK/log1b"
sum_b=$(sha256sum "$t1/config/printer.cfg" | cut -d' ' -f1)
[ "$sum_a" = "$sum_b" ] && pass "test 1: second run is a true no-op" || fail "test 1: second run modified the file further"

# =========================================================================
# Test 2: materialized tree NOT present yet - refuses gracefully (not an
#     error - retried next boot), printer.cfg left untouched
# =========================================================================

t2="$WORK/t2"; mkdir -p "$t2/config" "$t2/system"
printf '%s' "$FINAL_GEN_FIXTURE" > "$t2/config/printer.cfg"
cp "$t2/config/printer.cfg" "$t2/config/printer.cfg.orig"
# deliberately do NOT materialize anything into $t2/config/nebulaos

log2="$WORK/log2"
run_fn "$t2/config" "$t2/system" "migrate_printer_cfg_to_managed_tree" "$log2"
[ "$(grep '^RC=' "$log2" | tail -1 | sed 's/RC=//')" = "0" ] && pass "test 2: reports success (a graceful skip, not a failure)" \
	|| fail "test 2: did not report success for a graceful skip"
if cmp -s "$t2/config/printer.cfg" "$t2/config/printer.cfg.orig"; then
	pass "test 2: printer.cfg is completely untouched when the materialized tree does not exist yet"
else
	fail "test 2: printer.cfg was modified despite the materialized tree not existing"
fi

# =========================================================================
# Test 3: materialized tree only PARTIALLY present (simulating a failed/
#     interrupted materialization) - also refuses, not a partial rewrite
# =========================================================================

t3="$WORK/t3"; mkdir -p "$t3/config" "$t3/system" "$t3/config/nebulaos"
printf '%s' "$FINAL_GEN_FIXTURE" > "$t3/config/printer.cfg"
cp "$t3/config/printer.cfg" "$t3/config/printer.cfg.orig"
echo "# only platform.cfg present" > "$t3/config/nebulaos/platform.cfg"
# machine.cfg, prtouch.cfg, etc. deliberately missing

log3="$WORK/log3"
run_fn "$t3/config" "$t3/system" "migrate_printer_cfg_to_managed_tree" "$log3"
if cmp -s "$t3/config/printer.cfg" "$t3/config/printer.cfg.orig"; then
	pass "test 3: printer.cfg untouched when the materialized tree is only partially present"
else
	fail "test 3: printer.cfg was modified despite an incomplete materialized tree"
fi

# =========================================================================
# Test 4: an unrecognized shape (reordered/modified includes) safely
#     refuses rather than guessing
# =========================================================================

t4="$WORK/t4"; mkdir -p "$t4/config" "$t4/system"
{
	echo '[include /etc/nebulaos/klipper/machine.cfg]'
	echo '[include /etc/nebulaos/klipper/platform.cfg]'
	echo '[include /etc/nebulaos/klipper/prtouch.cfg]'
	echo '[include /etc/nebulaos/klipper/z_offset_probe.cfg]'
	echo '[include /etc/nebulaos/klipper/calibration.cfg]'
	echo '[include /etc/nebulaos/klipper/homing.cfg]'
	echo '[include /etc/nebulaos/klipper/print.cfg]'
	echo '[include /etc/nebulaos/klipper/filament.cfg]'
	echo '[include /etc/nebulaos/klipper/camera.cfg]'
	echo '[include /etc/nebulaos/klipper/beeper.cfg]'
} > "$t4/config/printer.cfg"
cp "$t4/config/printer.cfg" "$t4/config/printer.cfg.orig"
make_manifest_and_materialize "$t4/config" "$t4/system" "$WORK/t4-immutable"

log4="$WORK/log4"
run_fn "$t4/config" "$t4/system" "migrate_printer_cfg_to_managed_tree" "$log4"
if cmp -s "$t4/config/printer.cfg" "$t4/config/printer.cfg.orig"; then
	pass "test 4: reordered includes (platform/machine swapped) is safely refused, file untouched"
else
	fail "test 4: a reordered-include file was modified instead of refused"
fi
refused_backup=$(find "$t4/system/migration-backups/printer-cfg-managed-tree-migration-refused" -name 'printer.cfg.*' 2>/dev/null | head -1)
[ -n "$refused_backup" ] && pass "test 4: a backup was written to the refused-migration directory" \
	|| fail "test 4: no refused-migration backup was found"

# =========================================================================
# Test 5: materialize_active_config() end to end - first boot materializes,
#     second boot (same generation) is a no-op, chained correctly with the
#     printer.cfg rewrite
# =========================================================================

t5="$WORK/t5"; mkdir -p "$t5/config" "$t5/system"
printf '%s' "$FINAL_GEN_FIXTURE" > "$t5/config/printer.cfg"
immutable5="$WORK/t5-immutable"
mkdir -p "$immutable5"
files_json=""; hash_input=""
for f in platform.cfg machine.cfg prtouch.cfg z_offset_probe.cfg calibration.cfg homing.cfg print.cfg filament.cfg camera.cfg beeper.cfg; do
	echo "# $f real content" > "$immutable5/$f"
	sha=$(sha256sum "$immutable5/$f" | cut -d' ' -f1)
	files_json="$files_json    \"$f\": \"$sha\",
"
	hash_input="$hash_input$f:$sha
"
done
files_json=$(printf '%s' "$files_json" | sed '$ s/,$//')
generation5=$(printf '%s' "$hash_input" | sha256sum | cut -d' ' -f1)
cat > "$immutable5/.manifest.json" <<EOF
{"schema_version": 1, "generation": "$generation5", "build_date": "test", "files": {
$files_json
}}
EOF

log5="$WORK/log5"
run_fn "$t5/config" "$t5/system" "materialize_active_config; migrate_printer_cfg_to_managed_tree" "$log5" "$immutable5"
[ -f "$t5/config/nebulaos/platform.cfg" ] && pass "test 5: materialize_active_config() materialized the tree" \
	|| fail "test 5: materialize_active_config() did not materialize anything"
grep -qxF '[include nebulaos/platform.cfg]' "$t5/config/printer.cfg" \
	&& pass "test 5: printer.cfg was correctly rewritten in the same pass" \
	|| fail "test 5: printer.cfg was not rewritten after materialization"

sum5a=$(find "$t5/config/nebulaos" -type f -exec sha256sum {} \; | sort | sha256sum)
run_fn "$t5/config" "$t5/system" "materialize_active_config" "$WORK/log5b" "$immutable5"
sum5b=$(find "$t5/config/nebulaos" -type f -exec sha256sum {} \; | sort | sha256sum)
[ "$sum5a" = "$sum5b" ] && pass "test 5: a second boot on the same generation does not rematerialize" \
	|| fail "test 5: the materialized tree changed on a same-generation reboot"

echo ""
echo "printer-cfg-managed-tree-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
