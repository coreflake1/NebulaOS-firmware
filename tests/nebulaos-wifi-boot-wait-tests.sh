#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-wifi-
# boot-wait.sh (pre-qualification mission Phase A6, 2026-07-31). Sources
# the actual production library. Fakes `wpa_cli` on PATH so no real
# wpa_supplicant instance is needed. Uses short timeouts for the event-
# driven-path tests; the one fixed-path test genuinely waits out the
# real, unparameterized `sleep 2` on purpose - it exists specifically to
# prove that path is byte-for-byte the original untouched behavior, not
# a parameterized/shortened stand-in for it.
#
# Usage: sh tests/nebulaos-wifi-boot-wait-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-wifi-boot-wait.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-wifi-boot-wait-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-wifi-boot-wait-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

NEBULAOS_WIFI_BOOT_WAIT_MIN=0
NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT=2

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
FAKE_WPA_STATE="$WORK/wpa-state"

# --- Test 1: no marker present -> requested mode is "fixed". ---
MARKER="$WORK/marker-absent"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "fixed" ]; then
	pass
else
	fail "requested mode with no marker file was '$mode', expected fixed"
fi

# --- Test 2: marker containing event-driven -> requested mode is
# event-driven. ---
MARKER="$WORK/marker-event"
printf 'event-driven\n' > "$MARKER"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "event-driven" ]; then
	pass
else
	fail "requested mode with an event-driven marker was '$mode', expected event-driven"
fi

# --- Test 3: an unrecognized marker value fails safe to "fixed". ---
MARKER="$WORK/marker-garbage"
printf 'banana\n' > "$MARKER"
mode=$(nebulaos_wifi_boot_wait_requested_mode "$MARKER")
if [ "$mode" = "fixed" ]; then
	pass
else
	fail "an unrecognized marker value produced '$mode' instead of failing safe to fixed"
fi

# --- Test 4: event-driven wait returns quickly (fast path) when
# association is already COMPLETED. ---
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_state=COMPLETED"
exit 0
EOF
chmod +x "$FAKE_BIN/wpa_cli"
start_s=$(date +%s 2>/dev/null || echo 0)
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_wait_for_association_event_driven testif >/dev/null 2>&1
rc=$?
end_s=$(date +%s 2>/dev/null || echo 0)
elapsed=$((end_s - start_s))
if [ "$rc" -eq 0 ] && [ "$elapsed" -le 1 ]; then
	pass
else
	fail "fast-path association wait did not return quickly with success (rc=$rc elapsed=${elapsed}s)"
fi

# --- Test 5: event-driven wait times out (not indefinitely) when
# association never completes, and still returns control to the caller. ---
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "wpa_state=SCANNING"
exit 0
EOF
chmod +x "$FAKE_BIN/wpa_cli"
start_s=$(date +%s 2>/dev/null || echo 0)
if PATH="$FAKE_BIN:$PATH" nebulaos_wifi_wait_for_association_event_driven testif >/dev/null 2>&1; then
	fail "wait reported success even though association never completed"
else
	end_s=$(date +%s 2>/dev/null || echo 0)
	elapsed=$((end_s - start_s))
	if [ "$elapsed" -ge "$NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT" ] && [ "$elapsed" -le $((NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT + 2)) ]; then
		pass
	else
		fail "wait did not respect the configured timeout bound (elapsed=${elapsed}s, timeout=${NEBULAOS_WIFI_BOOT_WAIT_TIMEOUT}s)"
	fi
fi

# --- Test 6: orchestration in "fixed" mode does not invoke wpa_cli at
# all (proves it takes the untouched sleep-only path). ---
rm -f "$FAKE_BIN/wpa_cli"
cat > "$FAKE_BIN/wpa_cli" <<'EOF'
#!/bin/sh
echo "called" >> "$FAKE_WPA_CALLED"
echo "wpa_state=COMPLETED"
EOF
chmod +x "$FAKE_BIN/wpa_cli"
FAKE_WPA_CALLED="$WORK/wpa-called"
export FAKE_WPA_CALLED
: > "$FAKE_WPA_CALLED"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/marker-absent-2"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
if [ ! -s "$FAKE_WPA_CALLED" ]; then
	pass
else
	fail "fixed-mode orchestration unexpectedly invoked wpa_cli"
fi

# --- Test 7: orchestration in "event-driven" mode does invoke wpa_cli
# (proves the marker correctly switches which path runs). ---
: > "$FAKE_WPA_CALLED"
NEBULAOS_WIFI_BOOT_WAIT_MARKER="$WORK/marker-event-2"
printf 'event-driven\n' > "$NEBULAOS_WIFI_BOOT_WAIT_MARKER"
PATH="$FAKE_BIN:$PATH" nebulaos_wifi_boot_wait testif >/dev/null 2>&1
if [ -s "$FAKE_WPA_CALLED" ]; then
	pass
else
	fail "event-driven-mode orchestration did not invoke wpa_cli at all"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
