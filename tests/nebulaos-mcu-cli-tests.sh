#!/bin/sh
#
# Offline tests for nebulaos-mcu CLI tool (Phase 2 §18).
#
# Validates the CLI script's structure, subcommand coverage, status display,
# managed flag handling, and flash refusal logic. Does NOT require serial
# hardware or a real MCU - all checks use mock state files and structural
# analysis.
#
# Usage: sh tests/nebulaos-mcu-cli-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI_SCRIPT="$REPO_ROOT/scripts/build/overlay/usr/bin/nebulaos-mcu"
IDENTITY_CHECK="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_identity_check.py"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. File existence and permissions
# =========================================================================

echo "--- File existence and permissions ---"

if [ -f "$CLI_SCRIPT" ]; then
    pass "nebulaos-mcu exists"
else
    fail "nebulaos-mcu does not exist at $CLI_SCRIPT"
fi

if [ -x "$CLI_SCRIPT" ]; then
    pass "nebulaos-mcu is executable"
else
    fail "nebulaos-mcu is not executable"
fi

# =========================================================================
# 2. Script structure - required subcommands
# =========================================================================

echo ""
echo "--- Subcommand coverage ---"

for cmd in status flash managed; do
    if grep -q "cmd_${cmd}" "$CLI_SCRIPT"; then
        pass "subcommand function cmd_${cmd} exists"
    else
        fail "subcommand function cmd_${cmd} missing"
    fi
done

if grep -q 'case.*command' "$CLI_SCRIPT" || grep -q 'case "\$command"' "$CLI_SCRIPT"; then
    pass "main dispatch uses case statement"
else
    fail "main dispatch does not use case statement"
fi

for cmd in status flash managed; do
    if grep -q "^[[:space:]]*${cmd})" "$CLI_SCRIPT"; then
        pass "dispatch handles '$cmd'"
    else
        fail "dispatch does not handle '$cmd'"
    fi
done

if grep -q 'help)' "$CLI_SCRIPT"; then
    pass "dispatch handles 'help'"
else
    fail "dispatch does not handle 'help'"
fi

# =========================================================================
# 3. Safety properties
# =========================================================================

echo ""
echo "--- Safety properties ---"

if grep -q 'set -eu' "$CLI_SCRIPT" || grep -q 'set -e' "$CLI_SCRIPT"; then
    pass "script uses errexit"
else
    fail "script does not use errexit (set -e)"
fi

if grep -q 'mcu_identity_check' "$CLI_SCRIPT"; then
    pass "flash delegates to mcu_identity_check.py"
else
    fail "flash does not reference mcu_identity_check.py"
fi

if grep -q 'UNKNOWN_APPLICATION' "$CLI_SCRIPT"; then
    pass "flash handles UNKNOWN_APPLICATION explicitly"
else
    fail "flash does not handle UNKNOWN_APPLICATION"
fi

if grep -q 'REFUSED\|refuse' "$CLI_SCRIPT"; then
    pass "unknown app results in REFUSED message"
else
    fail "unknown app does not produce REFUSED message"
fi

if grep -q 'NATIVE_CANDIDATE_001' "$CLI_SCRIPT"; then
    pass "flash recognizes NATIVE_CANDIDATE_001 (no-op)"
else
    fail "flash does not recognize NATIVE_CANDIDATE_001"
fi

# =========================================================================
# 4. Status subcommand - mock state file
# =========================================================================

echo ""
echo "--- Status subcommand (mock state file) ---"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

MOCK_STATE="$TMPDIR/guard.state"
cat > "$MOCK_STATE" <<'EOF'
MCU_GUARD_RESULT=PASS
MCU_IDENTITY=v0.13.0-742-g01a9c2f92
MCU_GUARD_DETAIL=native_candidate_001_confirmed_via_application_identity
MCU_GUARD_TIMESTAMP=2026-09-08T01:00:00Z
MCU_GUARD_EXPECTED=mcu0_001_G32
MCU_LIFECYCLE_STATE=SUPPORTED_HW_NATIVE_APP
MCU_APPLICATION_IDENTITY=v0.13.0-742-g01a9c2f92
MCU_APPLICATION_CLASS=NATIVE_CANDIDATE_001
MCU_HW_ID_STATUS=not_checked_not_needed
MCU_RESTORE_RESULT=not_attempted
EOF

status_output=$(MCU_GUARD_STATE="$MOCK_STATE" MCU_MANAGED_FLAG="$TMPDIR/managed" "$CLI_SCRIPT" status 2>&1)

if echo "$status_output" | grep -q 'PASS'; then
    pass "status shows PASS from state file"
else
    fail "status does not show PASS (output: $status_output)"
fi

if echo "$status_output" | grep -q 'SUPPORTED_HW_NATIVE_APP'; then
    pass "status shows lifecycle state"
else
    fail "status does not show lifecycle state"
fi

if echo "$status_output" | grep -q 'NATIVE_CANDIDATE_001'; then
    pass "status shows application class"
else
    fail "status does not show application class"
fi

if echo "$status_output" | grep -q 'v0.13.0-742-g01a9c2f92'; then
    pass "status shows application identity"
else
    fail "status does not show application identity"
fi

if echo "$status_output" | grep -q '2026-09-08'; then
    pass "status shows timestamp"
else
    fail "status does not show timestamp"
fi

# =========================================================================
# 5. Status subcommand - no state file
# =========================================================================

echo ""
echo "--- Status subcommand (no state file) ---"

no_state_output=$(MCU_GUARD_STATE="$TMPDIR/nonexistent.state" MCU_MANAGED_FLAG="$TMPDIR/managed" "$CLI_SCRIPT" status 2>&1)

if echo "$no_state_output" | grep -q 'No boot-time MCU check'; then
    pass "status reports no check has run when state file missing"
else
    fail "status does not report missing state file properly"
fi

# =========================================================================
# 6. Managed subcommand - default state (no flag file)
# =========================================================================

echo ""
echo "--- Managed subcommand ---"

managed_output=$(MCU_MANAGED_FLAG="$TMPDIR/nonexistent_managed" "$CLI_SCRIPT" managed 2>&1)

if echo "$managed_output" | grep -q 'true'; then
    pass "managed defaults to true when flag file missing"
else
    fail "managed does not default to true (output: $managed_output)"
fi

# =========================================================================
# 7. Managed subcommand - set on/off
# =========================================================================

MANAGED_FLAG="$TMPDIR/managed_test"
MANAGED_DIR="$TMPDIR"

MCU_MANAGED_FLAG="$MANAGED_FLAG" MCU_MANAGED_DIR="$MANAGED_DIR" "$CLI_SCRIPT" managed off >/dev/null 2>&1

if [ -f "$MANAGED_FLAG" ]; then
    flag_val=$(cat "$MANAGED_FLAG")
    if [ "$flag_val" = "false" ]; then
        pass "managed off writes 'false' to flag file"
    else
        fail "managed off wrote '$flag_val' instead of 'false'"
    fi
else
    fail "managed off did not create flag file"
fi

managed_off_output=$(MCU_MANAGED_FLAG="$MANAGED_FLAG" "$CLI_SCRIPT" managed 2>&1)

if echo "$managed_off_output" | grep -q 'false'; then
    pass "managed reads false after 'managed off'"
else
    fail "managed does not read false after off"
fi

MCU_MANAGED_FLAG="$MANAGED_FLAG" MCU_MANAGED_DIR="$MANAGED_DIR" "$CLI_SCRIPT" managed on >/dev/null 2>&1
flag_val=$(cat "$MANAGED_FLAG")
if [ "$flag_val" = "true" ]; then
    pass "managed on writes 'true' to flag file"
else
    fail "managed on wrote '$flag_val' instead of 'true'"
fi

# =========================================================================
# 8. Unknown command handling
# =========================================================================

echo ""
echo "--- Error handling ---"

if "$CLI_SCRIPT" bogus 2>&1 | grep -q 'unknown command'; then
    pass "unknown command produces error message"
else
    fail "unknown command does not produce error message"
fi

if ! "$CLI_SCRIPT" bogus >/dev/null 2>&1; then
    pass "unknown command exits non-zero"
else
    fail "unknown command exits zero"
fi

if "$CLI_SCRIPT" 2>&1 | grep -q 'Usage'; then
    pass "no args produces usage"
else
    fail "no args does not produce usage"
fi

# =========================================================================
# 9. Managed flag invalid values
# =========================================================================

echo ""
echo "--- Managed flag edge cases ---"

EDGE_FLAG="$TMPDIR/edge_managed"
echo "garbage" > "$EDGE_FLAG"
edge_output=$(MCU_MANAGED_FLAG="$EDGE_FLAG" "$CLI_SCRIPT" managed 2>&1)
if echo "$edge_output" | grep -q 'true\|garbage'; then
    pass "non-false flag value treated as managed (true)"
else
    fail "non-false flag value not handled correctly"
fi

if ! MCU_MANAGED_FLAG="$MANAGED_FLAG" MCU_MANAGED_DIR="$MANAGED_DIR" "$CLI_SCRIPT" managed invalid 2>/dev/null; then
    pass "managed rejects invalid argument"
else
    fail "managed accepts invalid argument"
fi

# =========================================================================
# 10. mcu_identity_check.py managed gate
# =========================================================================

echo ""
echo "--- mcu_identity_check.py managed gate ---"

if grep -q '_is_managed' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py has _is_managed() function"
else
    fail "mcu_identity_check.py missing _is_managed()"
fi

if grep -q 'MCU_MANAGED_FLAG' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py reads MCU_MANAGED_FLAG"
else
    fail "mcu_identity_check.py does not read MCU_MANAGED_FLAG"
fi

if grep -q 'skipped_not_managed' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py skips restore when not managed"
else
    fail "mcu_identity_check.py does not skip restore when not managed"
fi

if grep -q 'RESTORE_AUTHORIZED' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py still checks RESTORE_AUTHORIZED"
else
    fail "mcu_identity_check.py does not check RESTORE_AUTHORIZED"
fi

# =========================================================================
# 11. Status shows managed state
# =========================================================================

echo ""
echo "--- Status includes managed state ---"

status_managed_output=$(MCU_GUARD_STATE="$MOCK_STATE" MCU_MANAGED_FLAG="$TMPDIR/nonexistent" "$CLI_SCRIPT" status 2>&1)
if echo "$status_managed_output" | grep -q 'Auto-restore at boot'; then
    pass "status includes auto-restore state"
else
    fail "status does not show auto-restore state"
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "==================================="
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed, $FAIL failed"
echo "==================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
