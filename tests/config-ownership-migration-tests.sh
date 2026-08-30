#!/bin/sh
#
# Offline, repeatable tests for S04nebulaos-migrate's migrate_config_ownership()
# (Phase 2 calibration-framework mission). Same NO_AUTORUN sourcing convention
# as tests/app-migration-tests.sh. Exercises the shell wrapper (path plumbing,
# missing-tool/missing-python handling, log() call) - the migration LOGIC
# itself is covered exhaustively, including a byte-exact cross-check against
# the real pinned Klipper parser, by tests/test_migrate_config_ownership.py.
#
# Usage: sh tests/config-ownership-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_TOOL="$REPO_ROOT/scripts/build/overlay/opt/nebulaos/tools/migrate_config_ownership.py"
# Same convention as tests/app-migration-tests.sh: points the script's own
# GATE_LIB override at the real, tracked shared gate (not the real device
# path, which does not exist on a dev machine) - migrate_config_ownership()
# itself never calls maintenance_gate_ok(), but S04nebulaos-migrate sources
# $GATE_LIB unconditionally at the top level, so every sourcing test needs
# a real, resolvable value regardless of which function it goes on to call.
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/config-ownership-migration-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

VIRGIN_PRINTER_CFG='[include /etc/nebulaos/klipper/platform.cfg]
[include /etc/nebulaos/klipper/machine.cfg]

# Your own additional includes/macros go below this line.
'

run_migrate() {
	printer_cfg="$1"; shift
	env \
		PRINTER_DATA_CONFIG="$(dirname "$printer_cfg")" \
		SYSTEM="$WORK/system" \
		"$@" \
		S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
		sh -c '. "$1"; migrate_config_ownership' _ "$MIGRATE_SCRIPT"
}

# --- happy path: real tool, real python3, virgin printer.cfg -------------
d="$WORK/happy"; mkdir -p "$d"
printf '%s' "$VIRGIN_PRINTER_CFG" > "$d/printer.cfg"
if out=$(run_migrate "$d/printer.cfg" MIGRATE_CONFIG_OWNERSHIP_TOOL="$REAL_TOOL"); then
	if grep -q '\[bltouch\]' "$d/printer.cfg" && grep -q 'z_offset = 0.000' "$d/printer.cfg"; then
		pass "happy path: virgin printer.cfg gets the pre-baked calibration-ownership block"
	else
		fail "happy path: expected block not found in printer.cfg after migration ($out)"
	fi
else
	fail "happy path: migrate_config_ownership returned non-zero ($out)"
fi

# --- idempotent: running it twice is a true no-op the second time --------
d="$WORK/idempotent"; mkdir -p "$d"
printf '%s' "$VIRGIN_PRINTER_CFG" > "$d/printer.cfg"
run_migrate "$d/printer.cfg" MIGRATE_CONFIG_OWNERSHIP_TOOL="$REAL_TOOL" >/dev/null 2>&1
first_pass_md5=$(md5sum "$d/printer.cfg" | awk '{print $1}')
run_migrate "$d/printer.cfg" MIGRATE_CONFIG_OWNERSHIP_TOOL="$REAL_TOOL" >/dev/null 2>&1
second_pass_md5=$(md5sum "$d/printer.cfg" | awk '{print $1}')
if [ "$first_pass_md5" = "$second_pass_md5" ]; then
	pass "idempotent: second run makes no further change"
else
	fail "idempotent: second run modified an already-migrated printer.cfg"
fi

# --- missing printer.cfg entirely: quiet no-op, not an error -------------
d="$WORK/missing"; mkdir -p "$d"
if run_migrate "$d/printer.cfg" MIGRATE_CONFIG_OWNERSHIP_TOOL="$REAL_TOOL" >/dev/null 2>&1; then
	pass "missing printer.cfg: treated as a no-op, not a failure"
else
	fail "missing printer.cfg: should not fail the whole migration pass"
fi

# --- tool binary missing: fails loudly (logged), does not crash the caller
d="$WORK/no-tool"; mkdir -p "$d"
printf '%s' "$VIRGIN_PRINTER_CFG" > "$d/printer.cfg"
if run_migrate "$d/printer.cfg" MIGRATE_CONFIG_OWNERSHIP_TOOL="$WORK/does-not-exist.py" >/dev/null 2>&1; then
	fail "missing tool: expected a non-zero return, got success"
else
	pass "missing tool: reports failure rather than silently doing nothing"
fi
if grep -q '\[bltouch\]' "$d/printer.cfg" 2>/dev/null; then
	fail "missing tool: printer.cfg was somehow modified anyway"
else
	pass "missing tool: printer.cfg left genuinely untouched"
fi

echo "config-ownership-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
