#!/bin/sh
#
# Offline, repeatable tests for the NebulaOS printer_data/config factory
# seed (auto-updates-camera-complete mission addendum, 2026-07-28). A
# genuinely wiped printer_data/config left Klipper and Moonraker
# crash-looping forever with no printer.cfg or moonraker.conf at all -
# nothing had ever shipped a seed for these files, since the only code
# that used to populate them was a migration from a legacy /usr/data/openke
# path, removed in an earlier closure mission.
#
# Sources scripts/build/overlay/etc/init.d/S02nebulaos-namespace directly
# (S02NEBULAOS_NAMESPACE_NO_AUTORUN=1, same convention as
# tests/factory-seed-git-tests.sh's S04NEBULAOS_FACTORY_SEED_NO_AUTORUN)
# with NEBULAOS_ROOT/PRINTER_DATA_CONFIG_SEED pointed at fixture
# directories - never touches a real device or /usr/data.
#
# Usage: sh tests/nebulaos-printerdata-seed-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
S02_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-namespace"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/printerdata-seed-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-printerdata-seed-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A real, complete seed source (mirrors what 04-cross-compile-app-stack.sh
# actually produces at /opt/nebulaos-seeds/printer_data-config/).
build_seed_source() {
	dir="$1"
	rm -rf "$dir"
	mkdir -p "$dir/GuppyScreen/scripts"
	cat > "$dir/printer.cfg" <<'EOF'
[printer]
kinematics: cartesian
max_velocity: 500
EOF
	cat > "$dir/moonraker.conf" <<'EOF'
[server]
host: 0.0.0.0
port: 7125
EOF
	cat > "$dir/frontend-controls.cfg" <<'EOF'
[virtual_sdcard]
path: /opt/printer_data/gcodes
on_error_gcode: CANCEL_PRINT

[pause_resume]

[display_status]
EOF
	echo "# songs" > "$dir/songs.conf"
	echo "# guppy" > "$dir/GuppyScreen/guppy_cmd.cfg"
}

run_seed() {
	# $1=NEBULAOS_ROOT fixture $2=PRINTER_DATA_CONFIG_SEED fixture
	(
		NEBULAOS_ROOT="$1"
		PRINTER_DATA_CONFIG_SEED="$2"
		S02NEBULAOS_NAMESPACE_NO_AUTORUN=1
		export NEBULAOS_ROOT PRINTER_DATA_CONFIG_SEED S02NEBULAOS_NAMESPACE_NO_AUTORUN
		# shellcheck disable=SC1090
		. "$S02_SCRIPT"
		create_layout
		seed_printer_data_config
	)
}

# --- Test 1: fresh/missing config gets seeded, marker written ---------

ns="$WORK/t1-root"; seed="$WORK/t1-seed"
rm -rf "$ns"
build_seed_source "$seed"
run_seed "$ns" "$seed" >"$WORK/t1.log" 2>&1

if [ -f "$ns/printer_data/config/printer.cfg" ] && [ -f "$ns/printer_data/config/moonraker.conf" ]; then
	pass "fresh namespace: printer.cfg and moonraker.conf seeded"
else
	fail "fresh namespace: printer.cfg/moonraker.conf not seeded ($(cat "$WORK/t1.log"))"
fi
if [ -f "$ns/printer_data/config/songs.conf" ] && [ -f "$ns/printer_data/config/GuppyScreen/guppy_cmd.cfg" ]; then
	pass "fresh namespace: songs.conf and GuppyScreen defaults also seeded"
else
	fail "fresh namespace: songs.conf/GuppyScreen defaults not seeded"
fi
if [ -f "$ns/printer_data/config/frontend-controls.cfg" ]; then
	pass "fresh namespace: frontend-controls.cfg also seeded"
else
	fail "fresh namespace: frontend-controls.cfg not seeded"
fi
if [ -f "$ns/system/printer-data-config-seeded.json" ]; then
	pass "fresh namespace: seed marker written"
else
	fail "fresh namespace: seed marker not written"
fi

# --- Test 2: marker present - user-deleted files are never recreated --

ns="$WORK/t2-root"; seed="$WORK/t2-seed"
rm -rf "$ns"
build_seed_source "$seed"
mkdir -p "$ns/system" "$ns/printer_data/config"
echo '{"seeded_at": "2020-01-01T00:00:00Z", "result": "seeded_from_immutable_defaults"}' > "$ns/system/printer-data-config-seeded.json"
run_seed "$ns" "$seed" >"$WORK/t2.log" 2>&1

if [ ! -e "$ns/printer_data/config/printer.cfg" ]; then
	pass "marker present: user-deleted printer.cfg is not recreated"
else
	fail "marker present: printer.cfg was recreated despite the marker (user deletion not respected)"
fi

# --- Test 3: real content present, no marker - retroactively marked, --
# --- not touched -------------------------------------------------------

ns="$WORK/t3-root"; seed="$WORK/t3-seed"
rm -rf "$ns"
build_seed_source "$seed"
mkdir -p "$ns/printer_data/config"
printf '[user edited config]\nreal_value: 42\n' > "$ns/printer_data/config/printer.cfg"
printf '[server]\nreal: yes\n' > "$ns/printer_data/config/moonraker.conf"
before_sha=$(sha256sum "$ns/printer_data/config/printer.cfg" | cut -d' ' -f1)
run_seed "$ns" "$seed" >"$WORK/t3.log" 2>&1
after_sha=$(sha256sum "$ns/printer_data/config/printer.cfg" | cut -d' ' -f1)

if [ "$before_sha" = "$after_sha" ]; then
	pass "existing real config: content untouched byte-for-byte"
else
	fail "existing real config: content was overwritten"
fi
if [ -f "$ns/system/printer-data-config-seeded.json" ]; then
	pass "existing real config: marker retroactively recorded"
else
	fail "existing real config: marker not recorded"
fi

# --- Test 4: broken/incomplete seed source fails safely, no marker ----

ns="$WORK/t4-root"; seed="$WORK/t4-seed"
rm -rf "$ns" "$seed"
mkdir -p "$seed"
echo "printer.cfg only, no moonraker.conf" > "$seed/printer.cfg"
run_seed "$ns" "$seed" >"$WORK/t4.log" 2>&1

if [ ! -f "$ns/system/printer-data-config-seeded.json" ]; then
	pass "incomplete seed source: no marker written, safe to retry next boot"
else
	fail "incomplete seed source: marker was written despite an incomplete seed"
fi
if grep -q "ERROR" "$WORK/t4.log"; then
	pass "incomplete seed source: logs a clear error"
else
	fail "incomplete seed source: no error logged"
fi

# --- Test 5: partial destination (one file missing) self-heals --------

ns="$WORK/t5-root"; seed="$WORK/t5-seed"
rm -rf "$ns"
build_seed_source "$seed"
mkdir -p "$ns/printer_data/config"
printf '[printer]\nalready here\n' > "$ns/printer_data/config/printer.cfg"
# moonraker.conf deliberately absent - not yet marked complete
run_seed "$ns" "$seed" >"$WORK/t5.log" 2>&1

if [ -f "$ns/printer_data/config/moonraker.conf" ]; then
	pass "partial destination: missing moonraker.conf completed from the seed"
else
	fail "partial destination: moonraker.conf still missing after seeding"
fi

# --- Test 6: repeated invocation is idempotent - no duplicate work -----

ns="$WORK/t6-root"; seed="$WORK/t6-seed"
rm -rf "$ns"
build_seed_source "$seed"
run_seed "$ns" "$seed" >/dev/null 2>&1
first_marker=$(cat "$ns/system/printer-data-config-seeded.json")
run_seed "$ns" "$seed" >/dev/null 2>&1
second_marker=$(cat "$ns/system/printer-data-config-seeded.json")

if [ "$first_marker" = "$second_marker" ]; then
	pass "repeated boot: marker unchanged, no reseed"
else
	fail "repeated boot: marker changed on a second run (reseeded unnecessarily)"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
