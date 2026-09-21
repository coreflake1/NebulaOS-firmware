#!/bin/sh
#
# Offline tests for factory-clean-provision.sh (Clean-Update + Virgin
# Baseline mission, Phase 4). Runs the real script as a subprocess against
# a fixture $NEBULAOS_ROOT, using the REAL S02nebulaos-namespace script
# (via its own NEBULAOS_ROOT override) to recreate the namespace, rather
# than a second reimplementation of its layout logic.
#
# Usage: sh tests/factory-clean-provision-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
PROVISION_SCRIPT="$REPO_ROOT/scripts/build/overlay/opt/nebulaos/factory-clean-provision.sh"
NAMESPACE_SCRIPT_REAL="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-namespace"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/factory-clean-provision-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: factory-clean-provision-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A populated, already-provisioned fixture namespace: real klipper/
# moonraker git checkouts under apps/, fake venv dirs under envs/, a
# generation record under system/, and real USER OWNED printer_data
# content that must survive completely untouched.
build_populated_namespace() {
	root="$1"
	rm -rf "$root"
	mkdir -p "$root/apps/klipper" "$root/apps/moonraker" "$root/envs/klipper" "$root/envs/moonraker" "$root/system"
	git -C "$root/apps/klipper" init -q -b master
	echo "klipper-content" > "$root/apps/klipper/file.txt"
	git -C "$root/apps/klipper" add -A
	git -C "$root/apps/klipper" commit -q -m "klipper-content"
	echo "fake-venv" > "$root/envs/klipper/marker.txt"
	echo '{"migration_version": "gen-v1"}' > "$root/system/app-generation.json"

	mkdir -p "$root/printer_data/config" "$root/printer_data/gcodes" "$root/updates/locks"
	echo "user-authored-printer-cfg" > "$root/printer_data/config/printer.cfg"
	echo "user-authored-moonraker-conf" > "$root/printer_data/config/moonraker.conf"
	echo "a-real-print-file" > "$root/printer_data/gcodes/test.gcode"
}

# --- Test 1: refuses to run without the exact confirmation flag ---------

test_refuses_without_flag() {
	ROOT="$WORK/t1-root"
	build_populated_namespace "$ROOT"
	before_klipper=$(git -C "$ROOT/apps/klipper" rev-parse HEAD)

	env NEBULAOS_ROOT="$ROOT" NAMESPACE_SCRIPT="$NAMESPACE_SCRIPT_REAL" \
		sh "$PROVISION_SCRIPT" > "$WORK/t1.log" 2>&1
	rc=$?

	after_klipper=$(git -C "$ROOT/apps/klipper" rev-parse HEAD 2>/dev/null)
	if [ "$rc" -ne 0 ] && [ "$before_klipper" = "$after_klipper" ] && [ ! -d "$ROOT/factory-clean-backups" ]; then
		pass "refuses to run and makes no change without --archive-and-reset"
	else
		fail "expected a no-op refusal, got rc=$rc before=$before_klipper after=$after_klipper ($(cat "$WORK/t1.log"))"
	fi
}

# --- Test 2: real run - archives, resets, and never touches user data ---

test_archive_and_reset() {
	ROOT="$WORK/t2-root"
	build_populated_namespace "$ROOT"
	original_klipper_hash=$(git -C "$ROOT/apps/klipper" rev-parse HEAD)

	env NEBULAOS_ROOT="$ROOT" NAMESPACE_SCRIPT="$NAMESPACE_SCRIPT_REAL" \
		sh "$PROVISION_SCRIPT" --archive-and-reset > "$WORK/t2.log" 2>&1

	backup_dir=$(find "$ROOT/factory-clean-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)

	if [ -z "$backup_dir" ]; then
		fail "archive-and-reset: no backup directory created ($(cat "$WORK/t2.log"))"
		return
	fi
	if [ "$(git -C "$backup_dir/apps/klipper" rev-parse HEAD 2>/dev/null)" = "$original_klipper_hash" ]; then
		pass "archive-and-reset: backup directory holds the real pre-reset klipper checkout"
	else
		fail "archive-and-reset: backup does not contain the original klipper checkout"
	fi

	if [ ! -e "$ROOT/apps/klipper/.git" ] && [ -d "$ROOT/apps/klipper" ]; then
		pass "archive-and-reset: apps/klipper reset to an empty, unseeded directory"
	else
		fail "archive-and-reset: apps/klipper was not reset (still has old .git, or missing entirely)"
	fi

	if [ ! -e "$ROOT/system/app-generation.json" ] && [ -d "$ROOT/system" ]; then
		pass "archive-and-reset: system/ generation record cleared, ready for a fresh baseline"
	else
		fail "archive-and-reset: system/app-generation.json still present after reset"
	fi

	if [ "$(cat "$ROOT/printer_data/config/printer.cfg" 2>/dev/null)" = "user-authored-printer-cfg" ] \
		&& [ "$(cat "$ROOT/printer_data/config/moonraker.conf" 2>/dev/null)" = "user-authored-moonraker-conf" ] \
		&& [ "$(cat "$ROOT/printer_data/gcodes/test.gcode" 2>/dev/null)" = "a-real-print-file" ]; then
		pass "archive-and-reset: USER OWNED printer_data/config and gcodes left completely untouched"
	else
		fail "archive-and-reset: user data was modified or lost - printer.cfg/moonraker.conf/gcodes changed"
	fi
}

# --- Test 3: failure path - missing namespace script leaves backup intact -

test_missing_namespace_script_is_recoverable() {
	ROOT="$WORK/t3-root"
	build_populated_namespace "$ROOT"
	original_klipper_hash=$(git -C "$ROOT/apps/klipper" rev-parse HEAD)

	env NEBULAOS_ROOT="$ROOT" NAMESPACE_SCRIPT="$WORK/does-not-exist.sh" \
		sh "$PROVISION_SCRIPT" --archive-and-reset > "$WORK/t3.log" 2>&1

	backup_dir=$(find "$ROOT/factory-clean-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
	if [ -n "$backup_dir" ] && [ "$(git -C "$backup_dir/apps/klipper" rev-parse HEAD 2>/dev/null)" = "$original_klipper_hash" ] \
		&& grep -q "ERROR" "$WORK/t3.log"; then
		pass "missing namespace script: reports an error but the archived state is still fully intact and recoverable"
	else
		fail "missing namespace script: expected an intact backup plus a clear error ($(cat "$WORK/t3.log"))"
	fi
}

test_refuses_without_flag
test_archive_and_reset
test_missing_namespace_script_is_recoverable

echo
echo "factory-clean-provision-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
