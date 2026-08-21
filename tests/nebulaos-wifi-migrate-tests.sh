#!/bin/sh
#
# Offline, repeatable tests for the Wi-Fi credential migration (Phase 1.5
# persistent-namespace mission, 2026-08): moving
# /usr/data/nebulaos/wpa_supplicant.conf (OLD) to
# /usr/data/nebulaos/network/wpa_supplicant.conf (NEW), safely, on a
# device whose only remote-access path (SSH) rides the same wlan0
# association this file configures.
#
# Sources the real scripts/build/overlay/etc/nebulaos-wifi-migrate.sh
# directly, with NEBULAOS_WIFI_OLD/NEBULAOS_WIFI_NEW overridden to sandbox
# paths under a mktemp -d directory (same convention as
# tests/app-migration-tests.sh and tests/recovery-safety-tests.sh) - never
# touches anything outside its own sandbox. OLD and NEW are always placed
# with a shared parent directory (standing in for /usr/data/nebulaos),
# matching the real script's own rel_target = "network/$(basename "$new")"
# assumption - a relative symlink computed as if OLD and NEW are siblings
# one directory apart.
#
# Usage: sh tests/nebulaos-wifi-migrate-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-wifi-migrate.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-wifi-migrate-tests.XXXXXX")
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# Runs nebulaos_wifi_migrate() for real, in a fresh sh, with
# NEBULAOS_WIFI_OLD/NEW pointed at the given sandbox paths. Writes
# NEBULAOS_WIFI_CONF and the function's own return code to $log for the
# caller to parse - never asserts anything itself.
run_migrate() {
	old="$1"; new="$2"; log="$3"
	env NEBULAOS_WIFI_OLD="$old" NEBULAOS_WIFI_NEW="$new" sh -c "
		. '$MIGRATE_SCRIPT'
		rc=0
		nebulaos_wifi_migrate || rc=\$?
		echo \"CONF=\$NEBULAOS_WIFI_CONF\"
		echo \"RC=\$rc\"
	" > "$log" 2>&1
}

conf_of() { grep '^CONF=' "$1" | tail -1 | sed 's/^CONF=//'; }
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }
mode_of() { stat -c '%a' "$1" 2>/dev/null; }

# =========================================================================
# TEST 1 - existing device: OLD is a regular file with real credential
# content, NEW absent. First migration.
# =========================================================================

t1="$WORK/t1"; mkdir -p "$t1"
old1="$t1/wpa_supplicant.conf"
new1="$t1/network/wpa_supplicant.conf"
cat > "$old1" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="TestNetwork"
	psk="supersecret123"
}
EOF
chmod 0600 "$old1"
cp "$old1" "$t1/old1-original-content"

log1="$WORK/t1.log"
run_migrate "$old1" "$new1" "$log1"

if [ -f "$new1" ] && cmp -s "$new1" "$t1/old1-original-content"; then
	pass "test1: NEW exists and matches OLD's original content exactly"
else
	fail "test1: NEW missing or content mismatch ($(cat "$log1"))"
fi

if [ "$(mode_of "$new1")" = "600" ]; then
	pass "test1: NEW mode is 0600"
else
	fail "test1: NEW mode is $(mode_of "$new1"), expected 600"
fi

if [ -L "$old1" ]; then
	pass "test1: OLD became a symlink"
else
	fail "test1: OLD is not a symlink after migration ($(cat "$log1"))"
fi

target1=$(readlink "$old1" 2>/dev/null)
if [ "$target1" = "network/wpa_supplicant.conf" ]; then
	pass "test1: OLD's symlink target is the correct relative form (network/wpa_supplicant.conf)"
else
	fail "test1: OLD's symlink target is '$target1', expected 'network/wpa_supplicant.conf'"
fi

if [ "$(conf_of "$log1")" = "$new1" ]; then
	pass "test1: NEBULAOS_WIFI_CONF is NEW"
else
	fail "test1: NEBULAOS_WIFI_CONF is '$(conf_of "$log1")', expected '$new1'"
fi

# =========================================================================
# TEST 2 - second boot / idempotency: NEW already exists with real
# content, OLD already a correct symlink. Running again must not reseed
# or otherwise disturb anything.
# =========================================================================

t2="$WORK/t2"; mkdir -p "$t2/network"
old2="$t2/wpa_supplicant.conf"
new2="$t2/network/wpa_supplicant.conf"
cat > "$new2" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="AlreadyMigrated"
	psk="anothersecret"
}
EOF
chmod 0600 "$new2"
ln -s "network/wpa_supplicant.conf" "$old2"
before_new_hash=$(cksum < "$new2")
before_target=$(readlink "$old2")

log2="$WORK/t2.log"
run_migrate "$old2" "$new2" "$log2"

after_new_hash=$(cksum < "$new2")
after_target=$(readlink "$old2" 2>/dev/null)

if [ "$before_new_hash" = "$after_new_hash" ]; then
	pass "test2: NEW is unchanged, no reseed on a second run"
else
	fail "test2: NEW content changed on a second run ($(cat "$log2"))"
fi

if [ -L "$old2" ] && [ "$after_target" = "$before_target" ]; then
	pass "test2: OLD's symlink is unchanged"
else
	fail "test2: OLD's symlink changed (was '$before_target', now '$after_target')"
fi

if [ "$(conf_of "$log2")" = "$new2" ]; then
	pass "test2: NEBULAOS_WIFI_CONF is NEW"
else
	fail "test2: NEBULAOS_WIFI_CONF is '$(conf_of "$log2")', expected '$new2'"
fi

# =========================================================================
# TEST 3 - virgin device: neither OLD nor NEW exists. A fresh,
# credential-free skeleton must be seeded at NEW only.
# =========================================================================

t3="$WORK/t3"; mkdir -p "$t3"
old3="$t3/wpa_supplicant.conf"
new3="$t3/network/wpa_supplicant.conf"

log3="$WORK/t3.log"
run_migrate "$old3" "$new3" "$log3"

if [ -f "$new3" ]; then
	pass "test3: NEW was created"
else
	fail "test3: NEW was not created ($(cat "$log3"))"
fi

if [ -f "$new3" ] && grep -q '^ctrl_interface=' "$new3" && grep -q '^update_config=1$' "$new3" \
	&& ! grep -q 'network={' "$new3"; then
	pass "test3: NEW is credential-free (ctrl_interface/update_config only, no network={} block)"
else
	fail "test3: NEW is not the expected credential-free skeleton ($(cat "$new3" 2>/dev/null))"
fi

if [ "$(mode_of "$new3")" = "600" ]; then
	pass "test3: NEW mode is 0600"
else
	fail "test3: NEW mode is $(mode_of "$new3"), expected 600"
fi

if [ "$(conf_of "$log3")" = "$new3" ]; then
	pass "test3: NEBULAOS_WIFI_CONF is NEW"
else
	fail "test3: NEBULAOS_WIFI_CONF is '$(conf_of "$log3")', expected '$new3'"
fi

# Case C, read closely: after seeding NEW, nebulaos_wifi_migrate() still
# calls _nebulaos_wifi_establish_compat_symlink() when old_is_safe and OLD
# is not already a symlink - on a virgin device that means OLD gets
# CREATED as a compat symlink pointing at the freshly seeded NEW (the
# `[ ! -e "$old" ]` branch inside establish_compat_symlink: `ln -s
# "$rel_target" "$old"`), so anything that still hardcodes the OLD path
# finds the same fresh skeleton too. Verified against the source rather
# than assumed - a first read suggests "neither exists" should stay that
# way, but the code deliberately extends the compat symlink to this case.
if [ -L "$old3" ] && [ "$(readlink "$old3")" = "network/wpa_supplicant.conf" ]; then
	pass "test3: OLD is created as a compat symlink to the freshly seeded NEW, even on a virgin device"
else
	fail "test3: OLD is '$([ -e "$old3" ] && echo present || echo absent)' (expected a compat symlink to network/wpa_supplicant.conf)"
fi

# =========================================================================
# TEST 4 - write failure: the atomic-copy step must fail partway through.
# _nebulaos_wifi_atomic_copy() does `mkdir -p "$dst_dir"` before writing,
# so making NEW's grandparent directory read-only (no write bit) makes
# that mkdir fail - the cleanest real failure injection point without
# touching the script itself. OLD is a real file, present throughout.
# =========================================================================

t4="$WORK/t4"; mkdir -p "$t4"
old4="$t4/wpa_supplicant.conf"
new4="$t4/network/wpa_supplicant.conf"
cat > "$old4" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="MustSurvive"
	psk="donotlosethis"
}
EOF
chmod 0600 "$old4"
cp "$old4" "$t4/old4-original-content"

chmod 0500 "$t4"
log4="$WORK/t4.log"
run_migrate "$old4" "$new4" "$log4"
chmod 0700 "$t4"

if cmp -s "$old4" "$t4/old4-original-content"; then
	pass "test4: OLD is byte-for-byte unchanged after a failed migration"
else
	fail "test4: OLD was modified despite the migration failing ($(cat "$log4"))"
fi

if [ ! -e "$new4" ]; then
	pass "test4: NEW does not exist - no blank/partial file left behind"
else
	fail "test4: NEW unexpectedly exists after a failed migration"
fi

if [ "$(conf_of "$log4")" = "$old4" ]; then
	pass "test4: NEBULAOS_WIFI_CONF falls back to OLD (documented Case D fallback)"
else
	fail "test4: NEBULAOS_WIFI_CONF is '$(conf_of "$log4")', expected fallback to OLD ('$old4')"
fi

if [ "$(rc_of "$log4")" != "0" ]; then
	pass "test4: nebulaos_wifi_migrate reports failure (non-zero return)"
else
	fail "test4: nebulaos_wifi_migrate reported success despite the injected write failure"
fi

# =========================================================================
# TEST 5 - interruption residue: a stray *.tmp.<pid> file left behind by a
# hypothetical killed migration must not interfere with a normal one.
# =========================================================================

t5="$WORK/t5"; mkdir -p "$t5/network"
old5="$t5/wpa_supplicant.conf"
new5="$t5/network/wpa_supplicant.conf"
cat > "$old5" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="ResidueTest"
	psk="stillherethough"
}
EOF
chmod 0600 "$old5"
cp "$old5" "$t5/old5-original-content"
# Simulates a killed prior run: the exact naming pattern
# _nebulaos_wifi_atomic_copy() uses ("$dst.tmp.$$"), with an arbitrary
# stale pid suffix that cannot collide with this run's own real $$.
echo "leftover garbage from a killed migration" > "$new5.tmp.999999"

log5="$WORK/t5.log"
run_migrate "$old5" "$new5" "$log5"

if [ -f "$new5" ] && cmp -s "$new5" "$t5/old5-original-content"; then
	pass "test5: migration succeeds cleanly despite a stray leftover temp file, producing a correct NEW"
else
	fail "test5: migration did not produce a correct NEW with a stray temp file present ($(cat "$log5"))"
fi

if [ -f "$new5.tmp.999999" ]; then
	pass "test5: the unrelated stray temp file is simply orphaned, not read or relied upon (still present, untouched)"
else
	fail "test5: the stray temp file disappeared - unexpected, migration should not have touched it either way"
fi

if [ "$(conf_of "$log5")" = "$new5" ]; then
	pass "test5: NEBULAOS_WIFI_CONF is NEW"
else
	fail "test5: NEBULAOS_WIFI_CONF is '$(conf_of "$log5")', expected '$new5'"
fi

# =========================================================================
# TEST 6 - weird OLD path: OLD is a directory (and, if mkfifo is
# available, a second sub-case where OLD is a FIFO), NEW absent. Must be a
# safe refusal - OLD is a "Case E" unexpected filesystem object, and
# per _nebulaos_wifi_is_safe_shape()/nebulaos_wifi_migrate()'s own logic,
# an unsafe OLD only downgrades old_is_safe (a WARNING), it does not
# block NEW from being freshly seeded - so this device still ends up with
# a real, usable, credential-free NEW and NEBULAOS_WIFI_CONF pointing at
# it, exactly as a virgin device would, while the directory itself is
# left completely alone (never read, deleted, or replaced).
# =========================================================================

t6="$WORK/t6"; mkdir -p "$t6"
old6="$t6/wpa_supplicant.conf"
new6="$t6/network/wpa_supplicant.conf"
mkdir -p "$old6"
echo "marker" > "$old6/do-not-touch-me"

log6="$WORK/t6.log"
run_migrate "$old6" "$new6" "$log6"

if [ -d "$old6" ] && [ -f "$old6/do-not-touch-me" ]; then
	pass "test6 (directory): OLD directory and its contents are completely untouched"
else
	fail "test6 (directory): OLD directory was modified/removed ($(cat "$log6"))"
fi

if [ -f "$new6" ]; then
	pass "test6 (directory): NEW was still safely created despite OLD being an unsafe shape"
else
	fail "test6 (directory): NEW was not created ($(cat "$log6"))"
fi

if [ "$(conf_of "$log6")" = "$new6" ]; then
	pass "test6 (directory): NEBULAOS_WIFI_CONF is NEW (the freshly seeded skeleton), not OLD and not empty"
else
	fail "test6 (directory): NEBULAOS_WIFI_CONF is '$(conf_of "$log6")', expected '$new6'"
fi

if command -v mkfifo >/dev/null 2>&1; then
	t6b="$WORK/t6b"; mkdir -p "$t6b"
	old6b="$t6b/wpa_supplicant.conf"
	new6b="$t6b/network/wpa_supplicant.conf"
	mkfifo "$old6b"

	log6b="$WORK/t6b.log"
	run_migrate "$old6b" "$new6b" "$log6b"

	if [ -p "$old6b" ]; then
		pass "test6 (FIFO): OLD FIFO is completely untouched"
	else
		fail "test6 (FIFO): OLD FIFO was modified/removed ($(cat "$log6b"))"
	fi

	if [ -f "$new6b" ]; then
		pass "test6 (FIFO): NEW was still safely created despite OLD being a FIFO"
	else
		fail "test6 (FIFO): NEW was not created ($(cat "$log6b"))"
	fi

	if [ "$(conf_of "$log6b")" = "$new6b" ]; then
		pass "test6 (FIFO): NEBULAOS_WIFI_CONF is NEW"
	else
		fail "test6 (FIFO): NEBULAOS_WIFI_CONF is '$(conf_of "$log6b")', expected '$new6b'"
	fi
else
	echo "SKIP: mkfifo not available - FIFO sub-case of test6 not run"
fi

echo ""
echo "nebulaos-wifi-migrate-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
