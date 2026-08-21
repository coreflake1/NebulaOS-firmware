#!/bin/sh
#
# Offline, repeatable tests for the stale-update-lock reconciliation added by the Phase 1.5
# hardware closure mission (2026-08-19): a real golden printer's
# updates/locks/klipper.lock, abandoned since 2026-08-09 (state.json stuck at "validating"),
# silently blocked BOTH scripts/build/overlay/etc/init.d/S04nebulaos-migrate (via
# nebulaos-maintenance-gate.sh's maintenance_gate_ok()) and S05nebulaos-activate (via that
# lock's presence in validate_app()) on every single boot for 10 days, with nothing anywhere
# ever surfacing why.
#
# Two cooperating fixes are exercised here, and the ordering between them is itself the
# thing most worth pinning down with a test:
#
#   1. nebulaos-maintenance-gate.sh's _maintenance_gate_reconcile_validating_locks() - runs
#      from S04, early in boot, BEFORE nebulaos-update-supervisor.sh's own daemon has even
#      started. Clears ONLY the lock FILE for a component whose state.json says
#      "validating" - this is what actually unblocks migration/activation on the SAME boot
#      the interruption is discovered, not just the boot after next.
#
#   2. nebulaos-update-supervisor.sh's reconcile_stale_component_locks_on_boot() - runs
#      later, from the supervisor daemon's own loop(). Fully repairs state.json (resets
#      last_seen to known_good, marks "interrupted") so the next poll cycle actually
#      re-validates rather than treating a stuck "validating" as "already in flight,
#      skip" forever. Deliberately keyed off state.json, NOT lock presence, so it is
#      correct regardless of whether fix (1) already removed the lock file - the exact
#      ordering bug an earlier revision of this fix had, caught before it shipped.
#
# Neither fix may ever clear a genuinely live lock (a real in-flight or recently-failed
# update, which this project's own conventions require a human to review before retrying) -
# that invariant is exercised as hard as the positive cases below.
#
# Usage: sh tests/stale-lock-reconcile-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
SUPERVISOR="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-update-supervisor.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"

[ -f "$GATE_LIB" ] || { echo "SKIP: $GATE_LIB not present"; exit 0; }
[ -f "$SUPERVISOR" ] || { echo "SKIP: $SUPERVISOR not present"; exit 0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/stale-lock-reconcile.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- helpers ----------------------------------------------------------------------------

# Writes a component's state.json directly (bypassing write_state's own timestamp), for
# fixture setup only.
write_fixture_state() {
	dir="$1"; name="$2"; state="$3"; known_good="${4:-}"; last_seen="${5:-$known_good}"
	mkdir -p "$dir/updates/$name"
	cat > "$dir/updates/$name/state.json" <<EOF
{
  "component": "$name",
  "known_good_commit": "$known_good",
  "last_seen_commit": "$last_seen",
  "state": "$state",
  "last_transition_at": "2026-08-09T19:35:15Z",
  "last_failure_reason": ""
}
EOF
}

write_fixture_stack_state() {
	dir="$1"; state="$2"; kg_k="${3:-}"; kg_e="${4:-}"
	mkdir -p "$dir/updates/klipper-stack"
	cat > "$dir/updates/klipper-stack/state.json" <<EOF
{
  "component": "klipper-stack",
  "known_good_klipper_commit": "$kg_k",
  "known_good_extensions_commit": "$kg_e",
  "last_seen_klipper_commit": "$kg_k",
  "last_seen_extensions_commit": "$kg_e",
  "state": "$state",
  "last_failure_reason": ""
}
EOF
}

# maintenance_gate_ok() also requires a real memory-resilience swap (checked via
# /proc/swaps), a precondition unrelated to the lock-reconciliation logic under test here
# and one a sandbox cannot provide - a dev machine's own /proc/swaps generally does not
# match the exact pattern the gate looks for either (confirmed live: this is a real,
# pre-existing environment gap app-migration-tests.sh's own stale-lock tests already hit).
# A single-purpose fake `grep` ahead of PATH, matching ONLY that one exact invocation and
# falling through to the real grep for everything else (every other grep call in this file,
# including the lock-reconciliation logic actually under test), isolates that precondition
# cleanly rather than leaving these tests flaky on whatever swap happens to be configured.
FAKE_BIN="$WORK/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/grep" <<'EOF'
#!/bin/sh
if [ "$1" = "-qE" ] && [ "$2" = '^(/dev/zram0|.*/system/swapfile) ' ]; then
	exit 0
fi
exec /bin/grep "$@"
EOF
chmod +x "$FAKE_BIN/grep"

# Runs maintenance_gate_ok() (with a real, minimal log()/APPS/LOCKDIR environment) against
# a sandbox, printing GATE_PASSED/GATE_BLOCKED so the test can assert on real control flow,
# not just on which lock files happen to remain afterward.
run_gate() {
	lockdir="$1"; apps="$2"
	env PATH="$FAKE_BIN:$PATH" APPS="$apps" LOCKDIR="$lockdir" \
		sh -c ". '$GATE_LIB'
			log() { :; }
			if maintenance_gate_ok; then echo GATE_PASSED; else echo GATE_BLOCKED; fi" 2>&1
}

seeded_apps() {
	dir="$WORK/apps-seeded-$$-$RANDOM"
	mkdir -p "$dir/klipper/.git"
	echo "$dir"
}

# --- scenario 1: no lock at all ----------------------------------------------------------

t1="$WORK/t1"; mkdir -p "$t1/updates/locks"
apps1=$(seeded_apps)
out1=$(run_gate "$t1/updates/locks" "$apps1")
if echo "$out1" | grep -q GATE_PASSED; then
	pass "no lock: gate proceeds"
else
	fail "no lock: gate unexpectedly blocked ($out1)"
fi

# --- scenario 2: live lock (state=healthy, a real in-flight/legitimate lock) -------------

t2="$WORK/t2"; mkdir -p "$t2/updates/locks"
apps2=$(seeded_apps)
write_fixture_state "$t2" moonraker healthy d5ee171
: > "$t2/updates/locks/moonraker.lock"
out2=$(run_gate "$t2/updates/locks" "$apps2")
if echo "$out2" | grep -q GATE_BLOCKED && [ -e "$t2/updates/locks/moonraker.lock" ]; then
	pass "live lock (state=healthy): NOT cleared, gate still blocks - the core safety invariant"
else
	fail "live lock: incorrectly cleared or gate did not block ($out2)"
fi

# --- scenario 3: stale klipper lock -------------------------------------------------------

t3="$WORK/t3"; mkdir -p "$t3/updates/locks"
apps3=$(seeded_apps)
write_fixture_state "$t3" klipper validating 845396f 4510ee6
: > "$t3/updates/locks/klipper.lock"
out3=$(run_gate "$t3/updates/locks" "$apps3")
if echo "$out3" | grep -q GATE_PASSED && [ ! -e "$t3/updates/locks/klipper.lock" ]; then
	pass "stale klipper lock (state=validating): cleared, gate proceeds on the SAME boot"
else
	fail "stale klipper lock: not reconciled correctly ($out3)"
fi

# --- scenario 4: stale extensions lock ----------------------------------------------------

t4="$WORK/t4"; mkdir -p "$t4/updates/locks"
apps4=$(seeded_apps)
write_fixture_state "$t4" nebulaos-klipper-extensions validating a1a1a1 b2b2b2
: > "$t4/updates/locks/nebulaos-klipper-extensions.lock"
out4=$(run_gate "$t4/updates/locks" "$apps4")
if echo "$out4" | grep -q GATE_PASSED && [ ! -e "$t4/updates/locks/nebulaos-klipper-extensions.lock" ]; then
	pass "stale extensions lock (state=validating): cleared, gate proceeds"
else
	fail "stale extensions lock: not reconciled correctly ($out4)"
fi

# --- scenario 5: stale moonraker lock -----------------------------------------------------

t5="$WORK/t5"; mkdir -p "$t5/updates/locks"
apps5=$(seeded_apps)
write_fixture_state "$t5" moonraker validating d5ee171 d5ee171
: > "$t5/updates/locks/moonraker.lock"
out5=$(run_gate "$t5/updates/locks" "$apps5")
if echo "$out5" | grep -q GATE_PASSED && [ ! -e "$t5/updates/locks/moonraker.lock" ]; then
	pass "stale moonraker lock (state=validating): cleared, gate proceeds"
else
	fail "stale moonraker lock: not reconciled correctly ($out5)"
fi

# --- scenario 6: malformed lock (state.json present but unparseable/missing state) -------

t6="$WORK/t6"; mkdir -p "$t6/updates/locks" "$t6/updates/klipper"
apps6=$(seeded_apps)
echo 'not even json' > "$t6/updates/klipper/state.json"
: > "$t6/updates/locks/klipper.lock"
out6=$(run_gate "$t6/updates/locks" "$apps6")
if echo "$out6" | grep -q GATE_BLOCKED && [ -e "$t6/updates/locks/klipper.lock" ]; then
	pass "malformed state.json: fails safe - lock left in place, gate blocks"
else
	fail "malformed state.json: incorrectly cleared or gate did not block ($out6)"
fi

# --- scenario 6b: lock present, no state.json at all (e.g. a hand-created lock) ----------

t6b="$WORK/t6b"; mkdir -p "$t6b/updates/locks"
apps6b=$(seeded_apps)
: > "$t6b/updates/locks/mystery.lock"
out6b=$(run_gate "$t6b/updates/locks" "$apps6b")
if echo "$out6b" | grep -q GATE_BLOCKED && [ -e "$t6b/updates/locks/mystery.lock" ]; then
	pass "lock with no state.json at all: fails safe - left in place, gate blocks"
else
	fail "lock with no state.json: incorrectly cleared or gate did not block ($out6b)"
fi

# --- scenario 7: pair transaction lock (klipper-stack) ------------------------------------

t7="$WORK/t7"; mkdir -p "$t7/updates/locks"
apps7=$(seeded_apps)
mkdir -p "$apps7/nebulaos-klipper-extensions/.git"
write_fixture_stack_state "$t7" validating 845396f a1a1a1
: > "$t7/updates/locks/klipper-stack.lock"
out7=$(run_gate "$t7/updates/locks" "$apps7")
if echo "$out7" | grep -q GATE_PASSED && [ ! -e "$t7/updates/locks/klipper-stack.lock" ]; then
	pass "pair transaction lock (klipper-stack, state=validating): cleared, gate proceeds"
else
	fail "pair transaction lock: not reconciled correctly ($out7)"
fi

# --- scenario 8: mixed - one stale, one live, present at once -----------------------------

t8="$WORK/t8"; mkdir -p "$t8/updates/locks"
apps8=$(seeded_apps)
write_fixture_state "$t8" klipper validating 845396f 4510ee6
write_fixture_state "$t8" mainsail factory-fallback v1 v2
: > "$t8/updates/locks/klipper.lock"
: > "$t8/updates/locks/mainsail.lock"
out8=$(run_gate "$t8/updates/locks" "$apps8")
if [ ! -e "$t8/updates/locks/klipper.lock" ] && [ -e "$t8/updates/locks/mainsail.lock" ] && echo "$out8" | grep -q GATE_BLOCKED; then
	pass "mixed locks: only the stale one is cleared, the live (factory-fallback) one still blocks the gate"
else
	fail "mixed locks: reconciliation did not discriminate correctly ($out8, klipper.lock exists=$([ -e "$t8/updates/locks/klipper.lock" ] && echo yes || echo no), mainsail.lock exists=$([ -e "$t8/updates/locks/mainsail.lock" ] && echo yes || echo no))"
fi

# --- scenario 9: second boot after recovery is clean/idempotent ---------------------------

t9="$WORK/t9"; mkdir -p "$t9/updates/locks"
apps9=$(seeded_apps)
write_fixture_state "$t9" klipper validating 845396f 4510ee6
: > "$t9/updates/locks/klipper.lock"
out9a=$(run_gate "$t9/updates/locks" "$apps9")
# Second boot: the supervisor would normally have run in between and rewritten state.json
# to "interrupted" by now (exercised directly against the real supervisor function below) -
# simulate that here so this call models a genuine second boot, not a same-state re-run.
write_fixture_state "$t9" klipper interrupted 845396f 845396f
out9b=$(run_gate "$t9/updates/locks" "$apps9")
if echo "$out9a" | grep -q GATE_PASSED && echo "$out9b" | grep -q GATE_PASSED; then
	pass "second boot after recovery: still clean, no error, no re-blocking"
else
	fail "second boot after recovery was not clean ($out9a / $out9b)"
fi

# =========================================================================
# nebulaos-update-supervisor.sh: reconcile_stale_component_locks_on_boot()
# =========================================================================

sup() {
	root="$1"; shift
	env NEBULAOS_UPDATE_SUPERVISOR_NO_AUTORUN=1 NEBULAOS_ROOT="$root" LOCKDIR="$root/updates/locks" \
		sh -c ". '$SUPERVISOR'; $*" 2>&1
}

# --- ordering proof: state=validating, lock ALREADY removed (by the gate) ----------------
# The bug an earlier revision of this fix had: keying reconciliation off lock presence meant
# a lock the gate already cleared left state.json stuck at "validating" forever, which
# poll_once()'s own delta-detection then treats as "already in flight, skip" - permanently.
# Keying off state.json instead (this function's actual, shipped behavior) must repair this
# regardless of the lock already being gone.

tA="$WORK/supA"; mkdir -p "$tA/updates/locks"
write_fixture_state "$tA" klipper validating 845396f 4510ee6
# Deliberately no lock file - models the gate having already removed it.
outA=$(sup "$tA" "reconcile_stale_component_locks_on_boot")
stateA=$(sed -n 's/.*"state": *"\([^"]*\)".*/\1/p' "$tA/updates/klipper/state.json" | head -1)
lastSeenA=$(sed -n 's/.*"last_seen_commit": *"\([^"]*\)".*/\1/p' "$tA/updates/klipper/state.json" | head -1)
if [ "$stateA" = "interrupted" ] && [ "$lastSeenA" = "845396f" ]; then
	pass "ordering proof: state.json is fully repaired even when the lock file is already gone"
else
	fail "ordering proof: state.json was not repaired without a lock file present (state=$stateA, last_seen=$lastSeenA) ($outA)"
fi

# --- interrupted transaction: state repaired AND lock cleared if still present -----------

tB="$WORK/supB"; mkdir -p "$tB/updates/locks"
write_fixture_state "$tB" moonraker validating d5ee171 abcdef1
: > "$tB/updates/locks/moonraker.lock"
sup "$tB" "reconcile_stale_component_locks_on_boot" > /dev/null
stateB=$(sed -n 's/.*"state": *"\([^"]*\)".*/\1/p' "$tB/updates/moonraker/state.json" | head -1)
if [ "$stateB" = "interrupted" ] && [ ! -e "$tB/updates/locks/moonraker.lock" ]; then
	pass "interrupted transaction: state.json reset to 'interrupted' and lock cleared"
else
	fail "interrupted transaction not fully reconciled (state=$stateB, lock exists=$([ -e "$tB/updates/locks/moonraker.lock" ] && echo yes || echo no))"
fi

# --- klipper-stack is left alone by the generic per-component function (it owns itself) --

tC="$WORK/supC"; mkdir -p "$tC/updates/locks"
write_fixture_stack_state "$tC" validating 845396f a1a1a1
: > "$tC/updates/locks/klipper-stack.lock"
sup "$tC" "reconcile_stale_component_locks_on_boot" > /dev/null
stateC=$(sed -n 's/.*"state": *"\([^"]*\)".*/\1/p' "$tC/updates/klipper-stack/state.json" | head -1)
if [ "$stateC" = "validating" ] && [ -e "$tC/updates/locks/klipper-stack.lock" ]; then
	pass "klipper-stack: left untouched by the generic function (reconcile_klipper_stack_on_boot owns it separately)"
else
	fail "klipper-stack was incorrectly touched by the generic per-component reconcile (state=$stateC)"
fi

# --- live (non-validating) component untouched --------------------------------------------

tD="$WORK/supD"; mkdir -p "$tD/updates/locks"
write_fixture_state "$tD" mainsail healthy v3 v3
sup "$tD" "reconcile_stale_component_locks_on_boot" > /dev/null
stateD=$(sed -n 's/.*"state": *"\([^"]*\)".*/\1/p' "$tD/updates/mainsail/state.json" | head -1)
if [ "$stateD" = "healthy" ]; then
	pass "live component (state=healthy): left completely untouched"
else
	fail "live component was incorrectly modified (state=$stateD)"
fi

# =========================================================================
# End-to-end proof: S04nebulaos-migrate no longer silently blocked forever
# =========================================================================

if [ -f "$MIGRATE_SCRIPT" ]; then
	tE="$WORK/e2e"
	mkdir -p "$tE/apps/klipper/.git" "$tE/system" "$tE/updates/locks" "$tE/seeds"
	write_fixture_state "$tE" klipper validating 845396f 4510ee6
	: > "$tE/updates/locks/klipper.lock"
	cat > "$tE/seeds/seed-manifest.json" <<'EOF'
{"migration_version": "test-generation-1"}
EOF
	logE="$WORK/e2e.log"
	env PATH="$FAKE_BIN:$PATH" S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
		SEEDS="$tE/seeds" APPS="$tE/apps" SYSTEM="$tE/system" \
		LOCKDIR="$tE/updates/locks" GATE_LIB="$GATE_LIB" \
		sh -c ". '$MIGRATE_SCRIPT'; start" > "$logE" 2>&1
	# The gate itself is what's under test here - a real seed archive isn't provided, so
	# migration will still fail past the gate (ERROR: seed archive missing), but that is
	# a SEPARATE, later failure. The property this proves is narrower and load-bearing:
	# the gate must not print "BLOCKED: an update transaction lock is present" any more.
	if ! grep -q "BLOCKED: an update transaction lock is present" "$logE"; then
		pass "end-to-end: S04nebulaos-migrate's gate no longer reports BLOCKED for a stale (state=validating) lock"
	else
		fail "end-to-end: the gate still silently blocks migration forever on a stale lock ($(cat "$logE"))"
	fi
	if [ ! -e "$tE/updates/locks/klipper.lock" ]; then
		pass "end-to-end: the stale lock file itself was cleared as part of the real S04 boot sequence"
	else
		fail "end-to-end: the stale lock file was never cleared during the real S04 boot sequence"
	fi
else
	echo "SKIP: $MIGRATE_SCRIPT not present for the end-to-end check"
fi

echo ""
echo "stale-lock-reconcile-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
