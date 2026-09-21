#!/bin/sh
#
# Offline, repeatable tests for
# scripts/build/overlay/etc/init.d/S02nebulaos-wifi-irq-priority (NebulaOS
# WiFi/camera IRQ contention mission, 2026-08-03). Fakes `ps` and `chrt` as
# plain scripts on an overridden PATH - same convention this project's
# other init.d tests use for faking system commands (e.g.
# nebulaos-display-qualified-tests.sh's PATH override for supervisorctl).
#
# Usage: sh tests/wifi-irq-priority-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TARGET="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-wifi-irq-priority"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$TARGET" ] || { echo "SKIP: $TARGET not present"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/wifi-irq-priority-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: wifi-irq-priority-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
CHRT_LOG="$WORK/chrt.log"
PS_OUTPUT="$WORK/ps_output.txt"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$FAKE_BIN/ps" <<EOF
#!/bin/sh
cat "$PS_OUTPUT"
EOF
chmod +x "$FAKE_BIN/ps"

cat > "$FAKE_BIN/chrt" <<EOF
#!/bin/sh
echo "\$@" >> "$CHRT_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/chrt"

run_target() {
	: > "$CHRT_LOG"
	PATH="$FAKE_BIN:$PATH" sh "$TARGET" start
}

# --- Test 1: real-shaped ps output (matching this hardware's actual
# thread names) - both mmc1 IRQ threads found and raised to prio 60. ---
cat > "$PS_OUTPUT" <<'EOF'
  PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
    1     0 root     S     3404   2%   0% {linuxrc} init
   91     2 root     SW       0   0%   0% [irq/9-13500000.]
  155     2 root     SW       0   0%   0% [irq/44-mmc1]
  156     2 root     SW       0   0%   0% [irq/44-s-mmc1]
  740     1 root     S    57524  27%   9% /opt/klipper/klippy/klippy.py
EOF
run_target >/dev/null 2>&1
GOT=$(sort "$CHRT_LOG")
EXPECTED=$(printf '%s\n%s' "-f -p 60 155" "-f -p 60 156" | sort)
[ "$GOT" = "$EXPECTED" ] && pass \
	|| fail "expected chrt calls for pids 155 and 156 at prio 60, got: $GOT"

# --- Test 2: no mmc1 IRQ thread present at all (e.g. WiFi not probed,
# or a build without it) - script must not call chrt and must exit 0
# (never block boot). ---
cat > "$PS_OUTPUT" <<'EOF'
  PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
    1     0 root     S     3404   2%   0% {linuxrc} init
   91     2 root     SW       0   0%   0% [irq/9-13500000.]
  740     1 root     S    57524  27%   9% /opt/klipper/klippy/klippy.py
EOF
run_target >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$CHRT_LOG" ] && pass \
	|| fail "expected exit 0 and zero chrt calls when no mmc1 IRQ thread exists, got rc=$rc log=$(cat "$CHRT_LOG")"

# --- Test 3: only one of the two threads present (unusual, but must
# still work for whichever exists, not fail outright). ---
cat > "$PS_OUTPUT" <<'EOF'
  PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
  155     2 root     SW       0   0%   0% [irq/44-mmc1]
EOF
run_target >/dev/null 2>&1
GOT=$(cat "$CHRT_LOG")
[ "$GOT" = "-f -p 60 155" ] && pass \
	|| fail "expected exactly one chrt call for pid 155, got: $GOT"

# --- Test 4: does not match an unrelated pid whose command merely
# contains "mmc1" as a substring elsewhere (e.g. a hypothetical
# mmc1-something userspace tool) - pattern must anchor on the real
# irq/N-mmc1 kernel thread name shape, not any "mmc1" substring. ---
cat > "$PS_OUTPUT" <<'EOF'
  PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
  999     1 root     S     1000   1%   0% /usr/bin/some-mmc1-tool --verbose
EOF
run_target >/dev/null 2>&1
[ ! -s "$CHRT_LOG" ] && pass \
	|| fail "matched an unrelated process merely containing 'mmc1' in its command line: $(cat "$CHRT_LOG")"

# --- Test 5: exit code is always 0 (never blocks boot), even on a
# chrt failure. ---
cat > "$FAKE_BIN/chrt" <<EOF
#!/bin/sh
echo "\$@" >> "$CHRT_LOG"
exit 1
EOF
chmod +x "$FAKE_BIN/chrt"
cat > "$PS_OUTPUT" <<'EOF'
  PID  PPID USER     STAT   VSZ %VSZ %CPU COMMAND
  155     2 root     SW       0   0%   0% [irq/44-mmc1]
EOF
run_target >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass || fail "script exited $rc on a chrt failure, expected 0 (must never block boot)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
