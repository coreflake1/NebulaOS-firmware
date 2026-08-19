#!/bin/sh
#
# Phase 1.5 closure mission (2026-08-19). 06-verify.sh's klipper seed-
# archive origin check used to hardcode the RETIRED fork's origin
# (coreflake1/NebulaOS-klipper.git), producing a permanent false MISS
# against a genuinely correct image (Phase 1's no-fork migration made
# official Klipper3d/klipper the real, intended origin). Fixed to source
# the expected origin from manifests/dependencies.conf's KLIPPER_REPO
# instead of a second hardcoded copy.
#
# check_seed_archive() itself dumps a real archive out of a real built
# rootfs.ext2 via debugfs, so it cannot be unit-tested in isolation without
# a real build artifact - that positive case is exercised for real by the
# actual build (06-verify.sh's own output, inspected directly). What CAN
# be tested here, statically and repeatably, is the regression this
# mission actually hit: that the expected-origin values are sourced from
# the manifest, not hardcoded, and that no hardcoded reference to the
# retired fork's origin remains anywhere in the verifier as an "expected"
# value.
#
# Usage: sh tests/verify-klipper-origin-check-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VERIFY_SCRIPT="$REPO_ROOT/scripts/build/06-verify.sh"
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

echo "=== Klipper seed-archive origin check regression guard ==="

[ -f "$VERIFY_SCRIPT" ] || { echo "SKIP: $VERIFY_SCRIPT not present"; exit 0; }
[ -f "$DEPS_MANIFEST" ] || { echo "SKIP: $DEPS_MANIFEST not present"; exit 0; }

# TEST 1 - dependencies.conf itself must pin official Klipper, not the
# retired fork. This is the actual source of truth check_seed_archive now
# reads from - if this drifted back to the retired fork, this test fails
# for a completely different (and equally important) reason.
KLIPPER_REPO_VALUE=$(grep -E "^KLIPPER_REPO=" "$DEPS_MANIFEST" | head -1 | sed "s/^KLIPPER_REPO=//")
if [ "$KLIPPER_REPO_VALUE" = "https://github.com/Klipper3d/klipper.git" ]; then
	pass "manifests/dependencies.conf pins official Klipper3d/klipper.git"
else
	fail "manifests/dependencies.conf's KLIPPER_REPO is \"$KLIPPER_REPO_VALUE\", expected the official https://github.com/Klipper3d/klipper.git"
fi

# TEST 2 - the verifier's klipper seed-archive check must source its
# expected origin from \$KLIPPER_REPO, not a literal URL - this is what
# makes it impossible for the check and the manifest to silently diverge
# again the way they did before this fix.
KLIPPER_CHECK_LINE=$(grep -E "^check_seed_archive /opt/nebulaos-seeds/klipper\.tar\.gz" "$VERIFY_SCRIPT")
case "$KLIPPER_CHECK_LINE" in
	*'$KLIPPER_REPO'*)
		pass "06-verify.sh's klipper seed-archive check sources its expected origin from \$KLIPPER_REPO"
		;;
	*)
		fail "06-verify.sh's klipper seed-archive check does not reference \$KLIPPER_REPO: $KLIPPER_CHECK_LINE"
		;;
esac

# TEST 3 - hard regression tripwire: no hardcoded reference to the retired
# fork's origin remains anywhere in the verifier as an expected/positive
# value. (Historical/forensic mentions in comments are fine and expected;
# this specifically looks for it appearing as a literal argument value,
# which is what caused the false MISS.)
if grep -qE 'https://github\.com/coreflake1/NebulaOS-klipper\.git' "$VERIFY_SCRIPT"; then
	fail "06-verify.sh still contains a literal reference to the retired fork origin (coreflake1/NebulaOS-klipper.git) - the exact regression this test exists to catch"
else
	pass "06-verify.sh contains no literal reference to the retired fork origin"
fi

# TEST 4 - the extensions seed archive origin is also checked now (it
# never was before this mission), sourced from \$KLIPPER_EXTENSIONS_REPO.
EXTENSIONS_CHECK_LINE=$(grep -E "^check_seed_archive /opt/nebulaos-seeds/nebulaos-klipper-extensions\.tar\.gz" "$VERIFY_SCRIPT")
case "$EXTENSIONS_CHECK_LINE" in
	*'$KLIPPER_EXTENSIONS_REPO'*)
		pass "06-verify.sh now checks the extensions seed-archive origin, sourced from \$KLIPPER_EXTENSIONS_REPO"
		;;
	*)
		fail "06-verify.sh does not check the extensions seed-archive origin (or does not source it from \$KLIPPER_EXTENSIONS_REPO): $EXTENSIONS_CHECK_LINE"
		;;
esac

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
