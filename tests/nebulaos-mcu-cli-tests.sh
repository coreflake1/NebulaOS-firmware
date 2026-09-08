#!/bin/sh
#
# Offline tests for nebulaos-mcu CLI tool (Phase 2 §18, C2 correction).
#
# Validates the CLI script's structure, subcommand coverage, status display,
# flash <file> refusal logic, and managed-as-action contract. Does NOT
# require serial hardware or a real MCU — all checks use mock state files
# and structural analysis.
#
# Usage: sh tests/nebulaos-mcu-cli-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CLI_SCRIPT="$REPO_ROOT/scripts/build/overlay/usr/bin/nebulaos-mcu"
IDENTITY_CHECK="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_identity_check.py"
FLASH_FILE_HELPER="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_flash_file.py"

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

if [ -f "$FLASH_FILE_HELPER" ]; then
    pass "mcu_flash_file.py exists"
else
    fail "mcu_flash_file.py does not exist at $FLASH_FILE_HELPER"
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
    pass "managed delegates to mcu_identity_check.py"
else
    fail "managed does not reference mcu_identity_check.py"
fi

if grep -q 'mcu_flash_file' "$CLI_SCRIPT"; then
    pass "flash delegates to mcu_flash_file.py"
else
    fail "flash does not reference mcu_flash_file.py"
fi

if grep -q 'UNKNOWN_APPLICATION' "$CLI_SCRIPT"; then
    pass "managed handles UNKNOWN_APPLICATION explicitly"
else
    fail "managed does not handle UNKNOWN_APPLICATION"
fi

if grep -q 'REFUSED\|refuse' "$CLI_SCRIPT"; then
    pass "unknown app or busy printer results in REFUSED message"
else
    fail "does not produce REFUSED message for refusal cases"
fi

if grep -q 'NATIVE_CANDIDATE_001' "$CLI_SCRIPT"; then
    pass "managed recognizes NATIVE_CANDIDATE_001 (already native)"
else
    fail "managed does not recognize NATIVE_CANDIDATE_001"
fi

# =========================================================================
# 4. flash <file> contract
# =========================================================================

echo ""
echo "--- flash <file> contract ---"

if grep -q 'flash requires' "$CLI_SCRIPT" || grep -q 'flash.*file' "$CLI_SCRIPT"; then
    pass "flash requires a file argument"
else
    fail "flash does not require a file argument"
fi

if grep -q 'check_printer_idle' "$CLI_SCRIPT"; then
    pass "flash checks printer state before flashing"
else
    fail "flash does not check printer state"
fi

if grep -q 'printing' "$CLI_SCRIPT" && grep -q 'paused' "$CLI_SCRIPT"; then
    pass "flash refuses printing and paused states"
else
    fail "flash does not refuse printing/paused"
fi

if grep -q '"false".*MCU_MANAGED_FLAG\|MCU_MANAGED_FLAG.*false\|set_managed.*false' "$CLI_SCRIPT"; then
    pass "flash sets managed=false on success"
else
    fail "flash does not set managed=false"
fi

# =========================================================================
# 5. managed-as-action contract (not a toggle)
# =========================================================================

echo ""
echo "--- managed-as-action contract ---"

if grep -q 'on|true\|off|false' "$CLI_SCRIPT"; then
    fail "managed still has on/off toggle (should be action-only)"
else
    pass "managed has no on/off toggle"
fi

if grep -q 'RESTORED_AND_VERIFIED' "$CLI_SCRIPT"; then
    pass "managed checks for RESTORED_AND_VERIFIED"
else
    fail "managed does not check for RESTORED_AND_VERIFIED"
fi

if grep -q 'set_managed.*true' "$CLI_SCRIPT"; then
    pass "managed sets managed=true on success"
else
    fail "managed does not set managed=true on success"
fi

# =========================================================================
# 6. Status subcommand - mock state file
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
# 7. Status subcommand - no state file
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
# 8. flash requires argument
# =========================================================================

echo ""
echo "--- flash argument handling ---"

if ! "$CLI_SCRIPT" flash 2>/dev/null; then
    pass "flash with no argument exits non-zero"
else
    fail "flash with no argument exits zero"
fi

flash_noarg_output=$("$CLI_SCRIPT" flash 2>&1) || true
if echo "$flash_noarg_output" | grep -q 'requires\|file'; then
    pass "flash with no argument mentions file requirement"
else
    fail "flash with no argument does not mention file requirement"
fi

if ! "$CLI_SCRIPT" flash /nonexistent/file.bin 2>/dev/null; then
    pass "flash with nonexistent file exits non-zero"
else
    fail "flash with nonexistent file exits zero"
fi

# =========================================================================
# 9. Unknown command handling
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
# 10. mcu_identity_check.py boot guard - stock always restores
# =========================================================================

echo ""
echo "--- mcu_identity_check.py boot guard ---"

if grep -q 'RESTORE_AUTHORIZED' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py still checks RESTORE_AUTHORIZED"
else
    fail "mcu_identity_check.py does not check RESTORE_AUTHORIZED"
fi

# Known stock should always restore — no managed gate
if grep -q 'skipped_not_managed' "$IDENTITY_CHECK"; then
    fail "mcu_identity_check.py still has managed gate on stock restore (should always restore)"
else
    pass "mcu_identity_check.py does not skip stock restore based on managed flag"
fi

if grep -q 'Known stock ALWAYS restores\|stock.*always.*restore' "$IDENTITY_CHECK"; then
    pass "mcu_identity_check.py documents stock-always-restores policy"
else
    fail "mcu_identity_check.py does not document stock-always-restores policy"
fi

# =========================================================================
# 11. mcu_flash_file.py structure
# =========================================================================

echo ""
echo "--- mcu_flash_file.py structure ---"

if grep -q 'creality_flash' "$FLASH_FILE_HELPER"; then
    pass "flash helper uses creality_flash backend"
else
    fail "flash helper does not reference creality_flash"
fi

if grep -q 'check_identity' "$FLASH_FILE_HELPER"; then
    pass "flash helper verifies hardware identity"
else
    fail "flash helper does not verify hardware identity"
fi

if grep -q 'flash_image' "$FLASH_FILE_HELPER"; then
    pass "flash helper calls flash_image"
else
    fail "flash helper does not call flash_image"
fi

if grep -q 'app_start' "$FLASH_FILE_HELPER"; then
    pass "flash helper calls app_start after flash"
else
    fail "flash helper does not call app_start"
fi

if grep -q 'mcu_restart' "$FLASH_FILE_HELPER"; then
    pass "flash helper uses mcu_restart for bootloader entry"
else
    fail "flash helper does not use mcu_restart"
fi

# =========================================================================
# 12. Status shows managed state
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
# 13. Managed flag default
# =========================================================================

echo ""
echo "--- Managed flag defaults ---"

# read_managed_flag is used internally — test via status output
status_default_output=$(MCU_GUARD_STATE="$MOCK_STATE" MCU_MANAGED_FLAG="$TMPDIR/nonexistent_managed" "$CLI_SCRIPT" status 2>&1)
if echo "$status_default_output" | grep -q 'true'; then
    pass "managed defaults to true when flag file missing"
else
    fail "managed does not default to true"
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
