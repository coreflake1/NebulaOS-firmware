#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-wifi-
# power-save.sh (pre-qualification mission Phase A5, 2026-07-31). Sources
# the actual production library. Fakes `iw` on PATH so no real Wi-Fi
# interface is needed.
#
# Usage: sh tests/nebulaos-wifi-power-save-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-wifi-power-save.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-wifi-ps-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-wifi-power-save-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
FAKE_IW_LOG="$WORK/iw.log"
FAKE_IW_PS_STATE="$WORK/iw-ps-state"
echo "on" > "$FAKE_IW_PS_STATE"
cat > "$FAKE_BIN/iw" <<'EOF'
#!/bin/sh
echo "iw $*" >> "$FAKE_IW_LOG"
case "$*" in
	*"set power_save off"*)
		echo "off" > "$FAKE_IW_PS_STATE"
		exit 0
		;;
	*"set power_save on"*)
		echo "on" > "$FAKE_IW_PS_STATE"
		exit 0
		;;
	*"get power_save"*)
		state=$(cat "$FAKE_IW_PS_STATE")
		echo "Power save: $state"
		exit 0
		;;
esac
exit 1
EOF
chmod +x "$FAKE_BIN/iw"
export FAKE_IW_LOG FAKE_IW_PS_STATE
PATH="$FAKE_BIN:$PATH"
export PATH

# --- Test 1: no marker present -> requested mode is P0. ---
MARKER="$WORK/marker-absent"
mode=$(nebulaos_wifi_ps_requested_mode "$MARKER")
if [ "$mode" = "P0" ]; then
	pass
else
	fail "requested mode with no marker file was '$mode', expected P0"
fi

# --- Test 2: marker containing P1 -> requested mode is P1. ---
MARKER="$WORK/marker-p1"
printf 'P1\n' > "$MARKER"
mode=$(nebulaos_wifi_ps_requested_mode "$MARKER")
if [ "$mode" = "P1" ]; then
	pass
else
	fail "requested mode with a P1 marker was '$mode', expected P1"
fi

# --- Test 3: an unrecognized marker value fails safe to P0, not some
# unintended state. ---
MARKER="$WORK/marker-garbage"
printf 'banana\n' > "$MARKER"
mode=$(nebulaos_wifi_ps_requested_mode "$MARKER")
if [ "$mode" = "P0" ]; then
	pass
else
	fail "an unrecognized marker value produced '$mode' instead of failing safe to P0"
fi

# --- Test 4: P0 apply does not call `iw ... set power_save` at all. ---
: > "$FAKE_IW_LOG"
NEBULAOS_WIFI_PS_MARKER="$WORK/marker-absent-2"
nebulaos_wifi_ps_apply testif >/dev/null
if ! grep -q "set power_save" "$FAKE_IW_LOG"; then
	pass
else
	fail "P0 (default) apply unexpectedly called 'iw ... set power_save': $(cat "$FAKE_IW_LOG")"
fi

# --- Test 5: P1 apply calls `iw dev <iface> set power_save off`. ---
: > "$FAKE_IW_LOG"
NEBULAOS_WIFI_PS_MARKER="$WORK/marker-p1-2"
printf 'P1\n' > "$NEBULAOS_WIFI_PS_MARKER"
nebulaos_wifi_ps_apply testif >/dev/null
if grep -q "dev testif set power_save off" "$FAKE_IW_LOG"; then
	pass
else
	fail "P1 apply did not call the expected iw command: $(cat "$FAKE_IW_LOG")"
fi

# --- Test 6: apply is idempotent - calling it twice for P1 does not
# error and leaves the same effective state. ---
: > "$FAKE_IW_LOG"
nebulaos_wifi_ps_apply testif >/dev/null
nebulaos_wifi_ps_apply testif >/dev/null
state=$(nebulaos_wifi_ps_effective_state testif)
if [ "$state" = "off" ]; then
	pass
else
	fail "after two P1 applies, effective state was '$state', expected 'off'"
fi

# --- Test 7: effective_state correctly reports 'on'/'off' from the
# fake iw's own get output, and 'unknown' cleanly on iw failure. ---
echo "on" > "$FAKE_IW_PS_STATE"
state_on=$(nebulaos_wifi_ps_effective_state testif)
echo "off" > "$FAKE_IW_PS_STATE"
state_off=$(nebulaos_wifi_ps_effective_state testif)
if [ "$state_on" = "on" ] && [ "$state_off" = "off" ]; then
	pass
else
	fail "effective_state did not correctly parse on/off (got '$state_on'/'$state_off')"
fi

not_found_state=$(PATH="/nonexistent" nebulaos_wifi_ps_effective_state testif 2>/dev/null)
if [ "$not_found_state" = "unknown" ]; then
	pass
else
	fail "effective_state did not report 'unknown' when iw is unavailable (got '$not_found_state')"
fi

# --- Test 8: apply never aborts the caller even when iw fails (never
# blocks boot) - function returns non-zero but does not exit the shell. ---
rm -f "$FAKE_BIN/iw"
cat > "$FAKE_BIN/iw" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKE_BIN/iw"
NEBULAOS_WIFI_PS_MARKER="$WORK/marker-p1-3"
printf 'P1\n' > "$NEBULAOS_WIFI_PS_MARKER"
if nebulaos_wifi_ps_apply testif >/dev/null 2>&1; then
	fail "apply reported success even though the fake iw always fails"
else
	pass
fi
echo "reached after a failing apply call - proves it did not abort the shell" > /dev/null
pass

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
