#!/bin/sh
#
# Offline, repeatable tests for migrate_guppy_stale_modules() in
# scripts/build/overlay/etc/init.d/S04nebulaos-migrate (Phase 2 overnight
# convergence mission, 2026-09-09): the one-time, idempotent rewrite that
# comments out [guppy_module_loader]/[guppy_config_helper] from an existing
# device's persistent GuppyScreen/guppy_cmd.cfg. Those two sections are
# Guppy-fork-only Klipper modules; NebulaOS runs upstream pristine Klipper,
# so their presence makes Klipper refuse to start with a hard config error
# ("Section 'guppy_module_loader' is not a valid config section") - this was
# discovered live on real hardware during Phase 2 RC4 qualification.
#
# Same seam/sandbox convention as printer-cfg-migration-tests.sh: sources
# the real S04nebulaos-migrate with S04NEBULAOS_MIGRATE_NO_AUTORUN=1 and
# PRINTER_DATA_CONFIG pointed at a mktemp -d sandbox. Never touches a real
# device.
#
# Usage: sh tests/guppy-stale-module-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/guppy-stale-module-migration-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: guppy-stale-module-migration-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }

cleanup() {
	chmod -R u+rwx "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

run_fn() {
	pdc="$1"; log="$2"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$WORK/system" SEEDS="$WORK/seeds" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; migrate_guppy_stale_modules || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }

guppy_path() { echo "$1/GuppyScreen/guppy_cmd.cfg"; }

# A representative slice of a real guppy_cmd.cfg: the shell-command and
# macro sections above/below both stale sections must survive byte-for-byte.
UNRELATED_HEADER='[gcode_shell_command guppy_input_shaper]
command: /opt/printer_data/config/GuppyScreen/scripts/calibrate_shaper.py
timeout: 600.0
verbose: True

[calibrate_shaper_config]
'
UNRELATED_FOOTER='
[respond]
default_type: echo
default_prefix:

[gcode_macro GUPPY_SHAPERS]
description: Shaper Tuning + Plot Generation
gcode:
  RESPOND TYPE=command MSG="Homing"
'

# --- Case 1: both stale sections present -----------------------------------

t1="$WORK/case1"; mkdir -p "$(dirname "$(guppy_path "$t1")")" "$t1"
f1=$(guppy_path "$t1")
mkdir -p "$(dirname "$f1")"
{
	printf '%s' "$UNRELATED_HEADER"
	echo '[guppy_module_loader]'
	echo ''
	echo '# Lets the on-screen Save buttons (TMC Autotune, etc.) write back to config.'
	echo '[guppy_config_helper]'
	printf '%s' "$UNRELATED_FOOTER"
} > "$f1"
cp "$f1" "$f1.orig"

log1="$WORK/log1"
run_fn "$t1" "$log1"

if grep -qxF '# [guppy_module_loader]  # removed by NebulaOS migration: not in upstream Klipper' "$f1" \
	&& grep -qxF '# [guppy_config_helper]  # removed by NebulaOS migration: not in upstream Klipper' "$f1"; then
	pass "case 1: both stale sections commented out"
else
	fail "case 1: stale sections not correctly commented out"
fi
if ! grep -qE '^\[guppy_module_loader\]$|^\[guppy_config_helper\]$' "$f1"; then
	pass "case 1: no live (uncommented) stale section remains"
else
	fail "case 1: a live stale section still remains"
fi
if grep -qF '[gcode_shell_command guppy_input_shaper]' "$f1" \
	&& grep -qF '[gcode_macro GUPPY_SHAPERS]' "$f1" \
	&& grep -qF '# Lets the on-screen Save buttons (TMC Autotune, etc.) write back to config.' "$f1"; then
	pass "case 1: unrelated sections and comments preserved"
else
	fail "case 1: unrelated content was lost or altered"
fi
if [ "$(rc_of "$log1")" = "0" ]; then
	pass "case 1: migrate_guppy_stale_modules reports success"
else
	fail "case 1: migrate_guppy_stale_modules reported failure ($(cat "$log1"))"
fi

# --- Case 2: only guppy_module_loader present -------------------------------

t2="$WORK/case2"; f2=$(guppy_path "$t2"); mkdir -p "$(dirname "$f2")"
{
	printf '%s' "$UNRELATED_HEADER"
	echo '[guppy_module_loader]'
	printf '%s' "$UNRELATED_FOOTER"
} > "$f2"

log2="$WORK/log2"
run_fn "$t2" "$log2"

if grep -qxF '# [guppy_module_loader]  # removed by NebulaOS migration: not in upstream Klipper' "$f2" \
	&& ! grep -q 'guppy_config_helper' "$f2"; then
	pass "case 2: only guppy_module_loader present is commented out correctly"
else
	fail "case 2: guppy_module_loader-only case not handled correctly"
fi
[ "$(rc_of "$log2")" = "0" ] && pass "case 2: reports success" || fail "case 2: reported failure ($(cat "$log2"))"

# --- Case 3: only guppy_config_helper present -------------------------------

t3="$WORK/case3"; f3=$(guppy_path "$t3"); mkdir -p "$(dirname "$f3")"
{
	printf '%s' "$UNRELATED_HEADER"
	echo '[guppy_config_helper]'
	printf '%s' "$UNRELATED_FOOTER"
} > "$f3"

log3="$WORK/log3"
run_fn "$t3" "$log3"

if grep -qxF '# [guppy_config_helper]  # removed by NebulaOS migration: not in upstream Klipper' "$f3" \
	&& ! grep -q 'guppy_module_loader' "$f3"; then
	pass "case 3: only guppy_config_helper present is commented out correctly"
else
	fail "case 3: guppy_config_helper-only case not handled correctly"
fi
[ "$(rc_of "$log3")" = "0" ] && pass "case 3: reports success" || fail "case 3: reported failure ($(cat "$log3"))"

# --- Case 4: neither stale section present (true no-op) ---------------------

t4="$WORK/case4"; f4=$(guppy_path "$t4"); mkdir -p "$(dirname "$f4")"
{
	printf '%s' "$UNRELATED_HEADER"
	printf '%s' "$UNRELATED_FOOTER"
} > "$f4"
cp "$f4" "$f4.orig"

log4="$WORK/log4"
run_fn "$t4" "$log4"

if cmp -s "$f4" "$f4.orig"; then
	pass "case 4: file with neither stale section is left byte-for-byte unchanged"
else
	fail "case 4: file was modified despite having no stale sections"
fi
[ "$(rc_of "$log4")" = "0" ] && pass "case 4: reports success (no-op)" || fail "case 4: reported failure on a no-op ($(cat "$log4"))"

# --- Case 5: already commented out (idempotent on a pre-migrated file) -----

t5="$WORK/case5"; f5=$(guppy_path "$t5"); mkdir -p "$(dirname "$f5")"
{
	printf '%s' "$UNRELATED_HEADER"
	echo '# [guppy_module_loader]  # removed by NebulaOS migration: not in upstream Klipper'
	echo '# [guppy_config_helper]  # removed by NebulaOS migration: not in upstream Klipper'
	printf '%s' "$UNRELATED_FOOTER"
} > "$f5"
cp "$f5" "$f5.orig"

log5="$WORK/log5"
run_fn "$t5" "$log5"

if cmp -s "$f5" "$f5.orig"; then
	pass "case 5: already-migrated file is a true no-op, byte-for-byte unchanged"
else
	fail "case 5: an already-migrated file was modified"
fi
[ "$(rc_of "$log5")" = "0" ] && pass "case 5: reports success on already-migrated file" || fail "case 5: reported failure on already-migrated file ($(cat "$log5"))"

# --- Case 6: repeated execution is idempotent (run twice on case 1's file) --

log6="$WORK/log6"
run_fn "$t1" "$log6"
if cmp -s "$f1" "$f1"; then :; fi
after_second_run=$(md5sum "$f1" | cut -d' ' -f1)
run_fn "$t1" "$WORK/log6b"
after_third_run=$(md5sum "$f1" | cut -d' ' -f1)
if [ "$after_second_run" = "$after_third_run" ]; then
	pass "case 6: running migration repeatedly is idempotent (content stable across reruns)"
else
	fail "case 6: repeated execution changed the file further"
fi

# --- Case 7: file missing entirely (safe no-op, no error) ------------------

t7="$WORK/case7"; mkdir -p "$t7"
log7="$WORK/log7"
run_fn "$t7" "$log7"
if [ "$(rc_of "$log7")" = "0" ]; then
	pass "case 7: missing GuppyScreen/guppy_cmd.cfg is a safe no-op, not an error"
else
	fail "case 7: missing file caused a reported failure ($(cat "$log7"))"
fi
if [ ! -e "$(guppy_path "$t7")" ]; then
	pass "case 7: no file was created where none existed"
else
	fail "case 7: a file was unexpectedly created"
fi

# --- Case 8: no temp-file litter left behind after a run --------------------

t8="$WORK/case8"; f8=$(guppy_path "$t8"); mkdir -p "$(dirname "$f8")"
{
	printf '%s' "$UNRELATED_HEADER"
	echo '[guppy_module_loader]'
	echo '[guppy_config_helper]'
	printf '%s' "$UNRELATED_FOOTER"
} > "$f8"
log8="$WORK/log8"
run_fn "$t8" "$log8"
leftover=$(find "$(dirname "$f8")" -name '*.migrate-tmp.*' 2>/dev/null)
if [ -z "$leftover" ]; then
	pass "case 8: no stray .migrate-tmp.* file left behind after a successful run"
else
	fail "case 8: stray temp file left behind: $leftover"
fi

echo ""
echo "guppy-stale-module-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
