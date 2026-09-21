#!/bin/sh
#
# Final Baseline Closure mission (2026-08-08): offline regression coverage
# for S56moonraker's automatic recovery from the real, live-found
# update_manager first-boot startup race (see that script's own header
# for the full root-cause writeup, derived from reading the actual pinned
# Moonraker source at manifests/dependencies.conf's MOONRAKER_PIN).
#
# Exercises recover_update_manager_if_needed() directly against a real,
# local, throwaway HTTP fixture standing in for Moonraker's own
# /server/info endpoint (same "real, not synthetic" testing convention as
# tests/app-migration-tests.sh's real git fixtures) - not the real
# moonraker.py, which needs a working printer_data/klippy/full Python
# dependency set this offline test suite has no business standing up.
# start_daemon()/stop() are overridden AFTER sourcing (S56MOONRAKER_NO_AUTORUN
# seam, same convention as S04's own NO_AUTORUN scripts) with recording
# stubs, so this test proves the DECISION logic (poll -> inspect
# failed_components -> restart exactly once) without ever touching a real
# process.
#
# Usage: sh tests/moonraker-update-manager-recovery-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
MOONRAKER_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S56moonraker"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/moonraker-recovery-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: moonraker-update-manager-recovery-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# A real, local, one-body HTTP fixture standing in for Moonraker's own
# /server/info - serves the same JSON body to every request it receives
# until killed. $1: port. $2: JSON body.
start_fixture_server() {
	port="$1"; body="$2"
	python3 - "$port" "$body" > "$WORK/server.log" 2>&1 <<'PYEOF' &
import http.server, sys

port = int(sys.argv[1])
body = sys.argv[2].encode()

class Handler(http.server.BaseHTTPRequestHandler):
	def do_GET(self):
		self.send_response(200)
		self.send_header("Content-Type", "application/json")
		self.end_headers()
		self.wfile.write(body)
	def log_message(self, *a):
		pass

http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF
	SERVER_PID=$!
	# Bounded wait for the fixture to actually be listening before the
	# test proceeds - avoids a flaky first poll racing the server's own
	# startup, which is not what this test exists to exercise.
	i=0
	while [ "$i" -lt 30 ]; do
		wget -q -O /dev/null --timeout=1 "http://127.0.0.1:$port/server/info" 2>/dev/null && return 0
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}

stop_fixture_server() {
	[ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
}

# --- Test 1: update_manager present in failed_components -> exactly one
# --- automatic restart, matching the proven-working manual fix ---------

test_restarts_once_when_update_manager_failed() {
	CALLS="$WORK/t1-calls.log"
	rm -f "$CALLS"
	start_fixture_server 18765 '{"result": {"klippy_connected": true, "failed_components": ["update_manager"], "components": ["klippy_connection", "database"]}}' \
		|| { fail "update_manager recovery: fixture server never came up"; return; }

	env S56MOONRAKER_NO_AUTORUN=1 \
		MOONRAKER_INFO_URL="http://127.0.0.1:18765/server/info" \
		MOONRAKER_INFO_POLL_TIMEOUT=3 MOONRAKER_INFO_POLL_INTERVAL=1 \
		sh -c ". '$MOONRAKER_SCRIPT'; \
			stop() { echo stop >> '$CALLS'; }; \
			start_daemon() { echo start_daemon >> '$CALLS'; }; \
			recover_update_manager_if_needed" > "$WORK/t1.log" 2>&1
	stop_fixture_server

	if [ "$(cat "$CALLS" 2>/dev/null)" = "$(printf 'stop\nstart_daemon')" ]; then
		pass "update_manager recovery: a failed update_manager triggers exactly one stop+restart, in the right order"
	else
		fail "update_manager recovery: expected exactly one stop then start_daemon call, got: $(cat "$CALLS" 2>/dev/null || echo '(nothing)') ($(cat "$WORK/t1.log"))"
	fi
}

# --- Test 2: update_manager healthy -> no restart, no unnecessary churn -

test_no_restart_when_update_manager_healthy() {
	CALLS="$WORK/t2-calls.log"
	rm -f "$CALLS"
	start_fixture_server 18766 '{"result": {"klippy_connected": true, "failed_components": [], "components": ["klippy_connection", "database", "update_manager"]}}' \
		|| { fail "update_manager recovery: fixture server never came up"; return; }

	env S56MOONRAKER_NO_AUTORUN=1 \
		MOONRAKER_INFO_URL="http://127.0.0.1:18766/server/info" \
		MOONRAKER_INFO_POLL_TIMEOUT=3 MOONRAKER_INFO_POLL_INTERVAL=1 \
		sh -c ". '$MOONRAKER_SCRIPT'; \
			stop() { echo stop >> '$CALLS'; }; \
			start_daemon() { echo start_daemon >> '$CALLS'; }; \
			recover_update_manager_if_needed" > "$WORK/t2.log" 2>&1
	stop_fixture_server

	if [ ! -s "$CALLS" ]; then
		pass "update_manager recovery: a healthy first start is left alone - no restart, no churn"
	else
		fail "update_manager recovery: healthy start triggered an unnecessary restart: $(cat "$CALLS") ($(cat "$WORK/t2.log"))"
	fi
}

# --- Test 3: some OTHER component failed (not update_manager) - must not
# --- restart for a condition this specific recovery was never meant to
# --- treat as its own responsibility -----------------------------------

test_no_restart_for_unrelated_failed_component() {
	CALLS="$WORK/t3-calls.log"
	rm -f "$CALLS"
	start_fixture_server 18767 '{"result": {"klippy_connected": true, "failed_components": ["webcam"], "components": ["klippy_connection", "database"]}}' \
		|| { fail "update_manager recovery: fixture server never came up"; return; }

	env S56MOONRAKER_NO_AUTORUN=1 \
		MOONRAKER_INFO_URL="http://127.0.0.1:18767/server/info" \
		MOONRAKER_INFO_POLL_TIMEOUT=3 MOONRAKER_INFO_POLL_INTERVAL=1 \
		sh -c ". '$MOONRAKER_SCRIPT'; \
			stop() { echo stop >> '$CALLS'; }; \
			start_daemon() { echo start_daemon >> '$CALLS'; }; \
			recover_update_manager_if_needed" > "$WORK/t3.log" 2>&1
	stop_fixture_server

	if [ ! -s "$CALLS" ]; then
		pass "update_manager recovery: an unrelated failed component is left to its own devices, not treated as this race"
	else
		fail "update_manager recovery: an unrelated failed component incorrectly triggered a restart: $(cat "$CALLS") ($(cat "$WORK/t3.log"))"
	fi
}

# --- Test 4: /server/info never answers at all - must not restart-loop
# --- against a server that may not even be up yet ----------------------

test_no_restart_when_server_never_responds() {
	CALLS="$WORK/t4-calls.log"
	rm -f "$CALLS"
	# Deliberately no fixture server started - nothing listens on this
	# port, so wget will fail every attempt within the bounded timeout.
	env S56MOONRAKER_NO_AUTORUN=1 \
		MOONRAKER_INFO_URL="http://127.0.0.1:18768/server/info" \
		MOONRAKER_INFO_POLL_TIMEOUT=2 MOONRAKER_INFO_POLL_INTERVAL=1 \
		sh -c ". '$MOONRAKER_SCRIPT'; \
			stop() { echo stop >> '$CALLS'; }; \
			start_daemon() { echo start_daemon >> '$CALLS'; }; \
			recover_update_manager_if_needed" > "$WORK/t4.log" 2>&1

	if [ ! -s "$CALLS" ] && grep -q "did not respond" "$WORK/t4.log"; then
		pass "update_manager recovery: a server that never answers is left alone, not restart-looped"
	else
		fail "update_manager recovery: unexpected behavior when server never responds: calls=$(cat "$CALLS" 2>/dev/null || echo none) ($(cat "$WORK/t4.log"))"
	fi
}

test_restarts_once_when_update_manager_failed
test_no_restart_when_update_manager_healthy
test_no_restart_for_unrelated_failed_component
test_no_restart_when_server_never_responds

echo
echo "moonraker-update-manager-recovery-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
