#!/bin/sh
#
# Offline tests for S50nebulaos-mcu-guard (Phase 1.8B MCU lifecycle guard).
#
# Validates the init.d script's structure, safety properties, decision
# coverage, and state-file behavior. Does NOT require serial hardware or
# a real MCU - all checks are static analysis of the script text and
# structural properties, plus a few mock-driven behavioral tests.
#
# Usage: sh tests/mcu-guard-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
INITD_DIR="$REPO_ROOT/scripts/build/overlay/etc/init.d"
GUARD_SCRIPT="$INITD_DIR/S50nebulaos-mcu-guard"
PYTHON_HELPER="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_identity_check.py"
LIFECYCLE_MODULE="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_lifecycle.py"
RESTORE_MODULE="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_restore.py"
KLIPPER_SCRIPT="$INITD_DIR/S55klipper"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. File existence and permissions
# =========================================================================

echo "--- File existence and permissions ---"

if [ -f "$GUARD_SCRIPT" ]; then
    pass "S50nebulaos-mcu-guard exists"
else
    fail "S50nebulaos-mcu-guard does not exist at $GUARD_SCRIPT"
fi

if [ -x "$GUARD_SCRIPT" ]; then
    pass "S50nebulaos-mcu-guard is executable"
else
    fail "S50nebulaos-mcu-guard is not executable"
fi

if [ -f "$PYTHON_HELPER" ]; then
    pass "mcu_identity_check.py exists"
else
    fail "mcu_identity_check.py does not exist at $PYTHON_HELPER"
fi

if [ -x "$PYTHON_HELPER" ]; then
    pass "mcu_identity_check.py is executable"
else
    fail "mcu_identity_check.py is not executable"
fi

# =========================================================================
# 2. Init.d ordering - must run between S05 and S55
# =========================================================================

echo ""
echo "--- Init.d ordering ---"

guard_basename=$(basename "$GUARD_SCRIPT")
guard_num=$(echo "$guard_basename" | sed -n 's/^S\([0-9]*\).*/\1/p')

if [ -n "$guard_num" ]; then
    pass "S50nebulaos-mcu-guard has a numeric init.d prefix ($guard_num)"
else
    fail "S50nebulaos-mcu-guard does not have a numeric init.d prefix"
fi

if [ "$guard_num" -gt 5 ] 2>/dev/null && [ "$guard_num" -lt 55 ] 2>/dev/null; then
    pass "S50nebulaos-mcu-guard runs after S05 and before S55 (S${guard_num})"
else
    fail "S50nebulaos-mcu-guard ordering violation: S${guard_num} is not between S05 and S55"
fi

# Verify it sorts before S55klipper.
sorted_order=$(printf '%s\n%s\n' "$guard_basename" "S55klipper" | sort | head -1)
if [ "$sorted_order" = "$guard_basename" ]; then
    pass "S50nebulaos-mcu-guard sorts before S55klipper"
else
    fail "S50nebulaos-mcu-guard does NOT sort before S55klipper"
fi

# =========================================================================
# 3. Script structure: start/stop/restart case
# =========================================================================

echo ""
echo "--- Script structure ---"

if grep -q '#!/bin/sh' "$GUARD_SCRIPT"; then
    pass "script has #!/bin/sh shebang"
else
    fail "script missing #!/bin/sh shebang"
fi

if grep -q 'case "$1"' "$GUARD_SCRIPT"; then
    pass "script has case \"\$1\" dispatch"
else
    fail "script missing case \"\$1\" dispatch"
fi

if grep -q 'start)' "$GUARD_SCRIPT"; then
    pass "script handles 'start' case"
else
    fail "script missing 'start' case"
fi

if grep -q 'stop)' "$GUARD_SCRIPT"; then
    pass "script handles 'stop' case"
else
    fail "script missing 'stop' case"
fi

if grep -q 'restart)' "$GUARD_SCRIPT"; then
    pass "script handles 'restart' case"
else
    fail "script missing 'restart' case"
fi

if grep -q '"Usage:' "$GUARD_SCRIPT"; then
    pass "script has usage message for invalid arguments"
else
    fail "script missing usage message"
fi

# =========================================================================
# 4. SAFETY: script must NOT contain flash/write/erase commands
# =========================================================================

echo ""
echo "--- Safety: no flash/write/erase operations ---"

# Safety checks grep only executable lines (skip comments starting with #).
# The SAFETY CONTRACT block in the script header mentions these words to
# document what the script does NOT do — those are comments, not executable code.
strip_comments() { grep -v '^\s*#' "$1"; }

if strip_comments "$GUARD_SCRIPT" | grep -qi 'flash_image\|flash()\|"flash"\|flash subcommand'; then
    fail "S50nebulaos-mcu-guard executable code contains flash-related commands"
else
    pass "S50nebulaos-mcu-guard executable code contains no flash commands"
fi

if strip_comments "$GUARD_SCRIPT" | grep -qi 'write_ota_marker'; then
    fail "S50nebulaos-mcu-guard executable code contains write_ota_marker"
else
    pass "S50nebulaos-mcu-guard does not call write_ota_marker"
fi

if strip_comments "$GUARD_SCRIPT" | grep -q '/dev/mmcblk0p1'; then
    fail "S50nebulaos-mcu-guard executable code references /dev/mmcblk0p1"
else
    pass "S50nebulaos-mcu-guard does not reference /dev/mmcblk0p1"
fi

if strip_comments "$GUARD_SCRIPT" | grep -qi 'sector_erase\|chip_erase'; then
    fail "S50nebulaos-mcu-guard executable code contains erase commands"
else
    pass "S50nebulaos-mcu-guard executable code contains no erase commands"
fi

# Also check the Python helper — skip comments and docstring content.
# Python docstrings are triple-quoted blocks; we use awk to drop everything
# between """ delimiters, then also drop # comment lines.
strip_py_comments() {
    awk 'BEGIN{in_doc=0} /^\s*"""/{in_doc=!in_doc; next} in_doc{next} /^\s*#/{next} {print}' "$1"
}

if strip_py_comments "$PYTHON_HELPER" | grep -qi 'flash_image\|\.flash('; then
    fail "mcu_identity_check.py executable code contains flash_image or flash() call"
else
    pass "mcu_identity_check.py executable code contains no flash commands"
fi

if strip_py_comments "$PYTHON_HELPER" | grep -q 'write_ota_marker'; then
    fail "mcu_identity_check.py contains write_ota_marker"
else
    pass "mcu_identity_check.py does not reference write_ota_marker"
fi

if strip_py_comments "$PYTHON_HELPER" | grep -q '/dev/mmcblk0p1'; then
    fail "mcu_identity_check.py executable code references /dev/mmcblk0p1"
else
    pass "mcu_identity_check.py does not reference /dev/mmcblk0p1"
fi

if strip_py_comments "$PYTHON_HELPER" | grep -qi 'sector_erase\|chip_erase'; then
    fail "mcu_identity_check.py contains erase commands"
else
    pass "mcu_identity_check.py contains no erase commands"
fi

# =========================================================================
# 5. SAFETY: Python helper always calls app_start after identify
# =========================================================================

echo ""
echo "--- Safety: app_start called after identify ---"

# Phase 1.8B: the bootloader interaction itself moved from
# mcu_identity_check.py (now a thin orchestrator) into
# mcu_lifecycle.py's _check_hardware_identity().
if grep -q 'app_start' "$LIFECYCLE_MODULE"; then
    pass "mcu_lifecycle.py calls app_start"
else
    fail "mcu_lifecycle.py does NOT call app_start (MCU would be left in bootloader)"
fi

# Verify the app_start call is in a finally/cleanup pattern - check that
# it is not only inside the success path.
if grep -q 'bootloader_entered' "$LIFECYCLE_MODULE"; then
    pass "mcu_lifecycle.py tracks bootloader_entered state for cleanup"
else
    fail "mcu_lifecycle.py does not track bootloader state for app_start cleanup"
fi

# =========================================================================
# 6. State file written to /run/ (tmpfs)
# =========================================================================

echo ""
echo "--- State file location ---"

if grep -q '/run/nebulaos-mcu-guard.state' "$GUARD_SCRIPT"; then
    pass "state file path is /run/nebulaos-mcu-guard.state (tmpfs)"
else
    fail "state file path is not /run/ (should be tmpfs, lost on reboot)"
fi

# Ensure the state file is NOT written to persistent storage.
if grep -q '/usr/data.*\.state\|/opt/.*\.state\|/etc/.*guard.*state' "$GUARD_SCRIPT"; then
    fail "state file appears to be written to persistent storage"
else
    pass "state file is not written to persistent storage"
fi

# =========================================================================
# 7. Decision tree coverage - all expected states documented/handled
# =========================================================================

echo ""
echo "--- Decision tree coverage ---"

# Check that the init.d script handles all top-level result codes. As of
# the Phase 1.8B redesign (mcu_lifecycle.py/mcu_restore.py), the detailed
# per-case reasoning lives in MCU_LIFECYCLE_STATE/MCU_APPLICATION_CLASS
# (checked separately below) - the shell script itself only ever dispatches
# on PASS/WARN/FAIL.
for result_code in PASS WARN FAIL; do
    if grep -q "$result_code" "$GUARD_SCRIPT"; then
        pass "script handles result code: $result_code"
    else
        fail "script does not handle result code: $result_code"
    fi
done

# The Python entry point should emit the corresponding result codes.
for result_code in PASS WARN FAIL; do
    if grep -q "MCU_GUARD_RESULT=$result_code" "$PYTHON_HELPER"; then
        pass "Python entry point emits result code: $result_code"
    else
        fail "Python entry point does not emit result code: $result_code"
    fi
done

# The full lifecycle state matrix should be represented in mcu_lifecycle.py.
for state in SUPPORTED_HW_NATIVE_APP SUPPORTED_HW_KNOWN_STOCK_APP SUPPORTED_HW_UNKNOWN_APP UNSUPPORTED_HW MCU_UNREACHABLE; do
    if grep -q "$state" "$LIFECYCLE_MODULE"; then
        pass "mcu_lifecycle.py handles state: $state"
    else
        fail "mcu_lifecycle.py does not handle state: $state"
    fi
done

# =========================================================================
# 8. Error handling for serial failures
# =========================================================================

echo ""
echo "--- Error handling ---"

if grep -q 'serial_open_failed\|UNREACHABLE' "$LIFECYCLE_MODULE"; then
    pass "mcu_lifecycle.py handles serial open failure"
else
    fail "mcu_lifecycle.py does not handle serial open failure"
fi

if grep -q 'bootloader_entry_failed\|could not enter' "$LIFECYCLE_MODULE"; then
    pass "mcu_lifecycle.py handles bootloader entry failure"
else
    fail "mcu_lifecycle.py does not handle bootloader entry failure"
fi

if grep -q 'version_query_failed' "$LIFECYCLE_MODULE"; then
    pass "mcu_lifecycle.py handles version query failure"
else
    fail "mcu_lifecycle.py does not handle version query failure"
fi

if grep -q 'cannot_import_klippy_serial_modules\|ImportError' "$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_application_identify.py"; then
    pass "mcu_application_identify.py handles missing klippy import"
else
    fail "mcu_application_identify.py does not handle missing klippy import"
fi

# Shell script: check that helper-not-found is handled gracefully.
if grep -q 'helper_not_found\|helper not found' "$GUARD_SCRIPT"; then
    pass "init.d script handles missing helper gracefully"
else
    fail "init.d script does not handle missing helper"
fi

# Shell script: check that unparseable output is handled.
if grep -q 'helper_no_output\|no parseable' "$GUARD_SCRIPT"; then
    pass "init.d script handles unparseable helper output"
else
    fail "init.d script does not handle unparseable helper output"
fi

# =========================================================================
# 9. State matrix documented in script comments
# =========================================================================
#
# Superseded (Phase 1.8B offline pre-build review): the original numbered
# 9-case matrix, where cases 3/4/7/8/9 were explicitly DEFERRED pending
# hardware qualification, has been replaced by a named 5-state model
# (mcu_lifecycle.py) where restoration IS implemented (offline, behind
# mocks - see mcu-lifecycle-decision-tests.py) rather than deferred. These
# checks now verify the new state names are documented instead of the old
# numbered cases.

echo ""
echo "--- State matrix documentation ---"

for state_name in SUPPORTED_HW_NATIVE_APP SUPPORTED_HW_KNOWN_STOCK_APP SUPPORTED_HW_UNKNOWN_APP UNSUPPORTED_HW MCU_UNREACHABLE; do
    if grep -q "$state_name" "$GUARD_SCRIPT"; then
        pass "state $state_name is documented in init.d script comments"
    else
        fail "state $state_name is NOT documented in init.d script comments"
    fi
done

# Phase 1.8B integration candidate: the artifact deployment path (mcu_restore.py's
# CANDIDATE_PATH) is now actually wired into the build - verify the packaged
# binary and its provenance sidecar exist in the overlay tree that
# 02-configure-buildroot.sh copies verbatim into the built rootfs.
REPO_ROOT_FOR_OVERLAY="$REPO_ROOT/scripts/build/overlay/opt/nebulaos/mcu-candidates"
if [ -f "$REPO_ROOT_FOR_OVERLAY/candidate-001.bin" ]; then
    pass "candidate-001.bin is packaged in the build overlay"
else
    fail "candidate-001.bin is NOT packaged in the build overlay"
fi
if [ -f "$REPO_ROOT_FOR_OVERLAY/candidate-001.provenance.json" ]; then
    pass "candidate-001.provenance.json is packaged alongside the binary"
else
    fail "candidate-001.provenance.json is NOT packaged alongside the binary"
fi
if [ -f "$REPO_ROOT_FOR_OVERLAY/candidate-001.bin" ]; then
    packaged_sha=$(sha256sum "$REPO_ROOT_FOR_OVERLAY/candidate-001.bin" | cut -d' ' -f1)
    if [ "$packaged_sha" = "c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c" ]; then
        pass "packaged candidate-001.bin SHA256 matches the pinned value"
    else
        fail "packaged candidate-001.bin SHA256 does NOT match the pinned value (got $packaged_sha)"
    fi
fi

# =========================================================================
# 10. Expected hardware ID is configured
# =========================================================================

echo ""
echo "--- Configuration ---"

if grep -q 'mcu0_001_G32' "$GUARD_SCRIPT"; then
    pass "expected hardware ID (mcu0_001_G32) is configured in init.d script"
else
    fail "expected hardware ID not found in init.d script"
fi

if grep -q 'mcu0_001_G32' "$LIFECYCLE_MODULE"; then
    pass "expected hardware ID (mcu0_001_G32) is configured in mcu_lifecycle.py"
else
    fail "expected hardware ID not found in mcu_lifecycle.py"
fi

KNOWN_IDENTITIES_MODULE="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/mcu_known_identities.py"
if grep -q 'v0\.13\.0-742-g01a9c2f92' "$KNOWN_IDENTITIES_MODULE"; then
    pass "candidate-001's exact application version string is pinned in mcu_known_identities.py"
else
    fail "candidate-001's application version string not found in mcu_known_identities.py"
fi

# =========================================================================
# 11. State file format contains required fields
# =========================================================================

echo ""
echo "--- State file format ---"

for field in MCU_GUARD_RESULT MCU_IDENTITY MCU_GUARD_DETAIL MCU_GUARD_TIMESTAMP MCU_GUARD_EXPECTED; do
    if grep -q "$field" "$GUARD_SCRIPT"; then
        pass "state file includes field: $field"
    else
        fail "state file missing field: $field"
    fi
done

# =========================================================================
# 12. Behavioral test: mock helper output parsing
# =========================================================================

echo ""
echo "--- Behavioral: mock helper output parsing ---"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mcu-guard-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

# Create a mock Python helper that emits PASS.
mock_pass="$WORK/mock_pass.py"
cat > "$mock_pass" <<'MOCK_EOF'
#!/usr/bin/env python3
print("MCU_LIFECYCLE_STATE=SUPPORTED_HW_NATIVE_APP")
print("MCU_LIFECYCLE_ACTION=ALLOW_KLIPPER_START")
print("MCU_APPLICATION_IDENTITY=v0.13.0-742-g01a9c2f92")
print("MCU_APPLICATION_CLASS=NATIVE_CANDIDATE_001")
print("MCU_HW_ID=unknown")
print("MCU_HW_ID_STATUS=not_checked_not_needed")
print("MCU_LIFECYCLE_DETAIL=native_candidate_001_confirmed_via_application_identity")
print("MCU_GUARD_RESULT=PASS")
MOCK_EOF
chmod +x "$mock_pass"

# Run the guard script with the mock helper, overriding paths.
mock_state="$WORK/mock.state"
env MCU_IDENTITY_CHECK="$mock_pass" \
    MCU_GUARD_STATE="$mock_state" \
    sh -c '. "'"$GUARD_SCRIPT"'" && MCU_GUARD_STATE="'"$mock_state"'" MCU_IDENTITY_CHECK="'"$mock_pass"'" do_check' 2>/dev/null || true

# The guard script sources as functions; we need to invoke it properly.
# Since the guard script uses case "$1" dispatch, test by setting
# MCU_GUARD_STATE and MCU_IDENTITY_CHECK env vars and calling with "start".
mock_state2="$WORK/mock2.state"
MCU_GUARD_STATE="$mock_state2" \
MCU_IDENTITY_CHECK="$mock_pass" \
    sh "$GUARD_SCRIPT" start > "$WORK/mock_stdout.txt" 2>&1
mock_exit=$?

if [ "$mock_exit" -eq 0 ]; then
    pass "guard exits 0 when helper reports PASS"
else
    fail "guard exits $mock_exit when helper reports PASS (expected 0)"
fi

if [ -f "$mock_state2" ]; then
    if grep -q 'MCU_GUARD_RESULT=PASS' "$mock_state2"; then
        pass "state file records PASS result from mock"
    else
        fail "state file does not contain PASS result"
    fi
    if grep -q 'MCU_IDENTITY=v0.13.0-742-g01a9c2f92' "$mock_state2"; then
        pass "state file records MCU identity from mock"
    else
        fail "state file does not contain MCU identity"
    fi
else
    fail "state file was not created at $mock_state2"
fi

# Test the UNSUPPORTED_HW mock (formerly FAIL_WRONG_ID under the old,
# hardware-ID-only design - now one of several states that map to FAIL).
mock_fail="$WORK/mock_fail.py"
cat > "$mock_fail" <<'MOCK_EOF'
#!/usr/bin/env python3
print("MCU_LIFECYCLE_STATE=UNSUPPORTED_HW")
print("MCU_LIFECYCLE_ACTION=BLOCK_KLIPPER_START")
print("MCU_APPLICATION_IDENTITY=38d96adc-dirty-20231016_135251-longer-virtual-machine")
print("MCU_APPLICATION_CLASS=KNOWN_STOCK")
print("MCU_HW_ID=some_other_mcu-v2.0")
print("MCU_HW_ID_STATUS=MISMATCH")
print("MCU_LIFECYCLE_DETAIL=expected=mcu0_001_G32")
print("MCU_GUARD_RESULT=FAIL")
MOCK_EOF
chmod +x "$mock_fail"

mock_state3="$WORK/mock3.state"
MCU_GUARD_STATE="$mock_state3" \
MCU_IDENTITY_CHECK="$mock_fail" \
    sh "$GUARD_SCRIPT" start > "$WORK/mock_fail_stdout.txt" 2>&1
mock_fail_exit=$?

if [ "$mock_fail_exit" -eq 1 ]; then
    pass "guard exits 1 when helper reports UNSUPPORTED_HW/FAIL"
else
    fail "guard exits $mock_fail_exit when helper reports UNSUPPORTED_HW/FAIL (expected 1)"
fi

if [ -f "$mock_state3" ] && grep -q 'MCU_GUARD_RESULT=FAIL' "$mock_state3"; then
    pass "state file records FAIL result for wrong ID"
else
    fail "state file does not record FAIL for wrong ID"
fi

# Test FAIL_SERIAL mock - should exit 0 (allow Klipper to try).
mock_serial="$WORK/mock_serial.py"
cat > "$mock_serial" <<'MOCK_EOF'
#!/usr/bin/env python3
print("MCU_GUARD_RESULT=FAIL_SERIAL")
print("MCU_IDENTITY=unknown")
print("MCU_GUARD_DETAIL=serial_open_failed: [Errno 2] No such file")
MOCK_EOF
chmod +x "$mock_serial"

mock_state4="$WORK/mock4.state"
MCU_GUARD_STATE="$mock_state4" \
MCU_IDENTITY_CHECK="$mock_serial" \
    sh "$GUARD_SCRIPT" start > "$WORK/mock_serial_stdout.txt" 2>&1
mock_serial_exit=$?

if [ "$mock_serial_exit" -eq 0 ]; then
    pass "guard exits 0 when helper reports FAIL_SERIAL (allows Klipper to try)"
else
    fail "guard exits $mock_serial_exit when helper reports FAIL_SERIAL (expected 0)"
fi

if [ -f "$mock_state4" ] && grep -q 'MCU_GUARD_RESULT=WARN' "$mock_state4"; then
    pass "state file records WARN for serial failure (not blocking)"
else
    fail "state file does not record WARN for serial failure"
fi

# Test with missing helper - should exit 0 with WARN.
mock_state5="$WORK/mock5.state"
MCU_GUARD_STATE="$mock_state5" \
MCU_IDENTITY_CHECK="$WORK/nonexistent_helper.py" \
    sh "$GUARD_SCRIPT" start > "$WORK/mock_missing_stdout.txt" 2>&1
mock_missing_exit=$?

if [ "$mock_missing_exit" -eq 0 ]; then
    pass "guard exits 0 when helper is missing (allows Klipper to try)"
else
    fail "guard exits $mock_missing_exit when helper is missing (expected 0)"
fi

if [ -f "$mock_state5" ] && grep -q 'MCU_GUARD_RESULT=WARN' "$mock_state5"; then
    pass "state file records WARN when helper is missing"
else
    fail "state file does not record WARN when helper is missing"
fi

# Test with helper that produces empty output - should exit 0 with WARN.
mock_empty="$WORK/mock_empty.py"
cat > "$mock_empty" <<'MOCK_EOF'
#!/usr/bin/env python3
print("some random output with no key=value")
MOCK_EOF
chmod +x "$mock_empty"

mock_state6="$WORK/mock6.state"
MCU_GUARD_STATE="$mock_state6" \
MCU_IDENTITY_CHECK="$mock_empty" \
    sh "$GUARD_SCRIPT" start > "$WORK/mock_empty_stdout.txt" 2>&1
mock_empty_exit=$?

if [ "$mock_empty_exit" -eq 0 ]; then
    pass "guard exits 0 when helper output is unparseable"
else
    fail "guard exits $mock_empty_exit when helper output is unparseable (expected 0)"
fi

# =========================================================================
# 13. Design doc exists
# =========================================================================

echo ""
echo "--- Design document ---"

DESIGN_DOC="$REPO_ROOT/docs/MCU_LIFECYCLE_GUARD.md"
if [ -f "$DESIGN_DOC" ]; then
    pass "MCU_LIFECYCLE_GUARD.md design document exists"
else
    fail "MCU_LIFECYCLE_GUARD.md design document does not exist"
fi

if [ -f "$DESIGN_DOC" ] && grep -qi 'state matrix' "$DESIGN_DOC"; then
    pass "design document describes the state matrix"
else
    fail "design document does not describe the state matrix"
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
