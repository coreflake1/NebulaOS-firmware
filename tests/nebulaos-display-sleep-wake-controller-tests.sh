#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-display-
# sleep-wake-controller.sh (the touch-wake watcher daemon's own library) -
# same pattern as tests/nebulaos-camera-idle-controller-tests.sh: sources
# the actual production library, fakes the two debugfs status/command
# files as plain temp files (the same fake-status-file-on-a-temp-path
# convention tests/nebulaos-display-qualified-tests.sh already establishes
# for these exact two debugfs files), never a real kernel.
#
# HONESTY NOTE, same as tests/nebulaos-display-qualified-tests.sh's own:
# there is no running kernel and no live BusyBox init system available
# from this environment. What this file genuinely proves is the watcher's
# own tick/loop logic (state tracking across ticks, the asleep-detection
# gate, the touch_down_count baseline/comparison, the wake write, the
# config-gated no-op, and the TERM/INT safety-net wake) against fakes. It
# does NOT and cannot prove the real ns2009_final_qualification/nebulaos_
# backlight_final_controller kernel drivers behave as expected - only live
# hardware qualification can do that. It ALSO cannot prove the exact
# "state: asleep" status-line spelling this file assumes is what the real,
# concurrently-developed backlight driver will actually report - see the
# ASSUMPTION block at the top of nebulaos-display-sleep-wake-controller.sh
# itself for where to fix that if wrong.
#
# Usage: sh tests/nebulaos-display-sleep-wake-controller-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-sleep-wake-controller.sh"
NDQ_LIB_REAL="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-display-qualified.sh"
INITD_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S98nebulaos-display-sleep-wake-controller"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-display-sleep-wake-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-display-sleep-wake-controller-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
[ -f "$NDQ_LIB_REAL" ] || { echo "FATAL: $NDQ_LIB_REAL not found"; exit 1; }
[ -f "$INITD_SCRIPT" ] || { echo "FATAL: $INITD_SCRIPT not found"; exit 1; }

# Fake debugfs files - plain temp files, reset before each scenario.
BACKLIGHT_STATUS="$WORK/backlight-status"
BACKLIGHT_CMD="$WORK/backlight-cmd"
TOUCH_STATUS="$WORK/touch-status"

reset_fake_kernel() {
	printf 'state: safe-on\n' > "$BACKLIGHT_STATUS"
	: > "$BACKLIGHT_CMD"
	printf 'touch_down_count: 0\n' > "$TOUCH_STATUS"
}
set_asleep() {
	printf 'state: asleep\n' > "$BACKLIGHT_STATUS"
}
set_awake() {
	printf 'state: safe-on\n' > "$BACKLIGHT_STATUS"
}
set_touch_count() {
	printf 'touch_down_count: %s\n' "$1" > "$TOUCH_STATUS"
}

NDQ_LIB="$NDQ_LIB_REAL"
NDQ_BACKLIGHT_STATUS_FILE="$BACKLIGHT_STATUS"
NDQ_BACKLIGHT_CMD_FILE="$BACKLIGHT_CMD"
NDQ_TOUCH_STATUS_FILE="$TOUCH_STATUS"
export NDQ_LIB NDQ_BACKLIGHT_STATUS_FILE NDQ_BACKLIGHT_CMD_FILE NDQ_TOUCH_STATUS_FILE

reset_fake_kernel
# shellcheck disable=SC1090
. "$LIB"

echo "============================================================"
echo "ndq_swc_backlight_is_asleep"
echo "============================================================"

reset_fake_kernel
if ndq_swc_backlight_is_asleep; then
	fail "state: safe-on was reported as asleep"
else
	pass
fi

set_asleep
if ndq_swc_backlight_is_asleep; then
	pass
else
	fail "state: asleep was not detected"
fi

rm -f "$BACKLIGHT_STATUS"
if ndq_swc_backlight_is_asleep; then
	fail "an unreadable backlight status file was treated as asleep"
else
	pass
fi
reset_fake_kernel

echo "============================================================"
echo "ndq_swc_touch_down_count"
echo "============================================================"

set_touch_count 42
got=$(ndq_swc_touch_down_count)
[ "$got" = "42" ] && pass || fail "touch_down_count read '$got', expected 42"

rm -f "$TOUCH_STATUS"
got=$(ndq_swc_touch_down_count)
[ -z "$got" ] && pass || fail "an unreadable touch status file did not read back empty (got '$got')"
reset_fake_kernel

echo "============================================================"
echo "ndq_swc_tick - awake: never touches touch count, never wakes"
echo "============================================================"

reset_fake_kernel
set_awake
set_touch_count 99
result=$(ndq_swc_tick no -)
state=${result%% *}; lc=${result##* }
if [ "$state" = "no" ] && [ "$lc" = "-" ]; then
	pass
else
	fail "awake tick did not return 'no -' (got '$result')"
fi
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "awake tick wrote to the backlight command file: $(cat "$BACKLIGHT_CMD")"

# Also true even if the loop's own PREV state claims it was asleep -
# reality (the status file) always wins.
result=$(ndq_swc_tick yes 10)
state=${result%% *}
[ "$state" = "no" ] && pass || fail "awake tick with prev_asleep=yes did not correct to 'no' (got '$state')"
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "awake tick (correcting stale prev=yes) wrote to the backlight command file"

echo "============================================================"
echo "ndq_swc_tick - asleep+no touch increment -> no wake"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 5
result=$(ndq_swc_tick yes 5)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "5" ]; then
	pass
else
	fail "asleep/no-increment tick did not return 'yes 5' (got '$result')"
fi
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "asleep/no-increment tick incorrectly wrote to the backlight command file: $(cat "$BACKLIGHT_CMD")"

echo "============================================================"
echo "ndq_swc_tick - asleep+touch increment -> wake"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 6
result=$(ndq_swc_tick yes 5)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "6" ]; then
	pass
else
	fail "asleep/increment tick did not return 'yes 6' (got '$result')"
fi
[ "$(cat "$BACKLIGHT_CMD")" = "wake" ] && pass || fail "asleep/increment tick did not write exactly 'wake' to the backlight command file (got '$(cat "$BACKLIGHT_CMD")')"

echo "============================================================"
echo "ndq_swc_tick - fresh transition into asleep never wakes on a stale count"
echo "============================================================"

# The touch driver already shows a HIGH count (accumulated while awake,
# well before sleep) at the exact moment the display transitions to
# asleep - a naive comparison against a leftover/garbage baseline must not
# fire. Baseline must be established fresh here, no wake this tick.
reset_fake_kernel
set_asleep
set_touch_count 500
result=$(ndq_swc_tick no -)
state=${result%% *}; lc=${result##* }
if [ "$state" = "yes" ] && [ "$lc" = "500" ]; then
	pass
else
	fail "fresh transition into asleep did not baseline to the current count (got '$result')"
fi
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "fresh transition into asleep incorrectly wrote to the backlight command file"

# The very next tick, still no real new touch (count unchanged) -> still
# no wake.
result=$(ndq_swc_tick "$state" "$lc")
state2=${result%% *}
[ "$state2" = "yes" ] && pass || fail "expected to remain asleep with no new touch"
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "no-new-touch follow-up tick incorrectly wrote to the backlight command file"

echo "============================================================"
echo "ndq_swc_tick - awake -> asleep -> awake -> asleep resets baseline each time"
echo "============================================================"

reset_fake_kernel
set_awake
set_touch_count 10
result=$(ndq_swc_tick no -)   # awake, tick 1
state=${result%% *}; lc=${result##* }
[ "$state" = "no" ] && [ "$lc" = "-" ] && pass || fail "expected awake/no-baseline, got '$result'"

set_asleep
result=$(ndq_swc_tick "$state" "$lc")  # transitions to asleep, baseline=10
state=${result%% *}; lc=${result##* }
[ "$state" = "yes" ] && [ "$lc" = "10" ] && pass || fail "expected fresh asleep baseline of 10, got '$result'"

set_awake
result=$(ndq_swc_tick "$state" "$lc")  # wakes on its own (e.g. some other mechanism), baseline reset
state=${result%% *}; lc=${result##* }
[ "$state" = "no" ] && [ "$lc" = "-" ] && pass || fail "expected baseline reset on return to awake, got '$result'"

# Touches accumulate while awake (not our concern) then it goes back to
# sleep - the OLD baseline of 10 must never be reused; the new baseline
# must be whatever the count is NOW.
set_touch_count 250
set_asleep
result=$(ndq_swc_tick "$state" "$lc")
state=${result%% *}; lc=${result##* }
[ "$state" = "yes" ] && [ "$lc" = "250" ] && pass || fail "expected a fresh baseline of 250 on the second sleep, got '$result'"
[ ! -s "$BACKLIGHT_CMD" ] && pass || fail "re-entering sleep with a fresh baseline incorrectly wrote to the backlight command file"

echo "============================================================"
echo "ndq_swc_requested_mode"
echo "============================================================"

CONF="$WORK/display-qualified.conf"

# No touch_wake_mode field at all -> disabled (fail-safe default).
: > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "an empty config produced '$mode', expected disabled"

printf 'touch_wake_mode=polling\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "polling" ] && pass || fail "touch_wake_mode=polling produced '$mode', expected polling"

printf 'touch_wake_mode=disabled\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "touch_wake_mode=disabled produced '$mode', expected disabled"

printf 'touch_wake_mode=garbage\n' > "$CONF"
mode=$(ndq_swc_requested_mode "$CONF")
[ "$mode" = "disabled" ] && pass || fail "an unrecognized touch_wake_mode value did not fail safe to disabled (got '$mode')"

mode=$(ndq_swc_requested_mode "$WORK/does-not-exist.conf")
[ "$mode" = "disabled" ] && pass || fail "a missing config file did not fail safe to disabled (got '$mode')"

echo "============================================================"
echo "ndq_swc_run_loop - no-op when touch_wake_mode is not polling"
echo "============================================================"

# The run loop must exit immediately (not hang) when disabled - proven by
# running it with a short timeout via a background job + wait, rather than
# just trusting it "should" return quickly.
reset_fake_kernel
printf 'touch_wake_mode=disabled\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	export NDQ_CONFIG_FILE
	ndq_swc_run_loop
) &
loop_pid=$!
i=0
while [ "$i" -lt 50 ] && kill -0 "$loop_pid" 2>/dev/null; do
	i=$((i + 1))
	sleep 0.1
done
if kill -0 "$loop_pid" 2>/dev/null; then
	fail "ndq_swc_run_loop did not exit promptly when touch_wake_mode != polling (still running after 5s)"
	kill -9 "$loop_pid" 2>/dev/null
else
	pass
fi
wait "$loop_pid" 2>/dev/null

echo "============================================================"
echo "ndq_swc_run_loop - TERM while asleep wakes as a safety net"
echo "============================================================"

reset_fake_kernel
set_asleep
set_touch_count 1
printf 'touch_wake_mode=polling\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL=0.1
	export NDQ_CONFIG_FILE NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL
	ndq_swc_run_loop
) &
loop_pid=$!
# Give it a couple of ticks to observe "asleep" and establish its baseline.
sleep 0.5
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid" 2>/dev/null
if [ "$(cat "$BACKLIGHT_CMD")" = "wake" ]; then
	pass
else
	fail "TERM while the loop believed the display asleep did not issue a safety-net wake (backlight cmd file: '$(cat "$BACKLIGHT_CMD" 2>/dev/null)')"
fi

echo "============================================================"
echo "ndq_swc_run_loop - TERM while awake does not spuriously wake"
echo "============================================================"

reset_fake_kernel
set_awake
printf 'touch_wake_mode=polling\n' > "$CONF"
(
	NDQ_CONFIG_FILE="$CONF"
	NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL=0.1
	export NDQ_CONFIG_FILE NEBULAOS_DISPLAY_SLEEP_WAKE_POLL_INTERVAL
	ndq_swc_run_loop
) &
loop_pid=$!
sleep 0.5
kill -TERM "$loop_pid" 2>/dev/null
wait "$loop_pid" 2>/dev/null
if [ ! -s "$BACKLIGHT_CMD" ]; then
	pass
else
	fail "TERM while awake wrote to the backlight command file unexpectedly: '$(cat "$BACKLIGHT_CMD")'"
fi

echo "============================================================"
echo "S98 init.d script - structural checks"
echo "============================================================"

# start() must be a genuine no-op (never even attempts to background the
# daemon) when touch_wake_mode != polling - verified with a fake
# start-stop-daemon on PATH that logs every invocation, the same
# fake-command-on-PATH convention this project's other test suites already
# use (e.g. the faked wget/ip in tests/nebulaos-display-qualified-tests.sh).
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
SSD_LOG="$WORK/start-stop-daemon.log"
cat > "$FAKE_BIN/start-stop-daemon" <<EOF
#!/bin/sh
echo "start-stop-daemon \$*" >> "$SSD_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/start-stop-daemon"

reset_fake_kernel
printf 'touch_wake_mode=disabled\n' > "$CONF"
: > "$SSD_LOG"
(
	PATH="$FAKE_BIN:$PATH"
	export PATH
	NDQ_SLEEP_WAKE_LIB="$LIB" NDQ_CONFIG_FILE="$CONF" \
	NDQ_BACKLIGHT_STATUS_FILE="$BACKLIGHT_STATUS" NDQ_BACKLIGHT_CMD_FILE="$BACKLIGHT_CMD" \
	NDQ_TOUCH_STATUS_FILE="$TOUCH_STATUS" \
	sh "$INITD_SCRIPT" start
) >/dev/null 2>&1
[ ! -s "$SSD_LOG" ] && pass || fail "S98 start() invoked start-stop-daemon even though touch_wake_mode != polling: $(cat "$SSD_LOG")"

# The mirror case: touch_wake_mode=polling must actually attempt to start
# the daemon (start-stop-daemon -S ... invoked at least once).
reset_fake_kernel
printf 'touch_wake_mode=polling\n' > "$CONF"
: > "$SSD_LOG"
(
	PATH="$FAKE_BIN:$PATH"
	export PATH
	NDQ_SLEEP_WAKE_LIB="$LIB" NDQ_CONFIG_FILE="$CONF" \
	NDQ_BACKLIGHT_STATUS_FILE="$BACKLIGHT_STATUS" NDQ_BACKLIGHT_CMD_FILE="$BACKLIGHT_CMD" \
	NDQ_TOUCH_STATUS_FILE="$TOUCH_STATUS" \
	sh "$INITD_SCRIPT" start
) >/dev/null 2>&1
grep -q '^start-stop-daemon -S' "$SSD_LOG" 2>/dev/null && pass \
	|| fail "S98 start() did not invoke start-stop-daemon -S even though touch_wake_mode=polling (log: $(cat "$SSD_LOG" 2>/dev/null))"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
