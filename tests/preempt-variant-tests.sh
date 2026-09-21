#!/bin/sh
#
# Offline, repeatable tests for scripts/build/preempt-variant.sh (pre-
# qualification mission Phase A8, 2026-07-31). Operates against the real
# tracked Kconfig fragment (artifacts/buildroot-halley5-v30-image/
# halley5-nebulaos-fragment.config) - it's a small, git-tracked text file
# in the main repo, not a gitignored vendor checkout.
#
# Alpha baseline freeze mission (2026-08-01): real build-integrity defect
# found live - this suite's cleanup used to unconditionally `git checkout
# --` the fragment on exit, which restores whatever is COMMITTED (always
# R0, since R1 is never committed), not whatever was actually selected
# before this suite ran. Running this suite after deliberately applying
# R1 (as part of building a combined W3+R1 alpha image) silently discarded
# that R1 selection back to R0 before the build ever started - the build
# then produced a plain non-RT image despite R1 having been correctly
# applied moments earlier. Caught only by inspecting the built artifact's
# own kernel config, not by this suite's own exit status (a clean pass
# throughout). Fixed: snapshot the fragment's exact real pre-test bytes
# before any mutation, restore exactly those bytes on exit (success,
# failure, or signal) - never assume R0/git-HEAD was the starting state.
#
# Usage: sh tests/preempt-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/preempt-variant.sh"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$FRAGMENT" ] || {
	echo "SKIP: $FRAGMENT not present"
	exit 0
}

# Snapshot the REAL pre-test state (whatever it actually is - R0, R1, or
# anything else) before this suite's first mutation, so cleanup can
# restore exactly that state rather than assuming a fixed baseline.
PRETEST_SNAPSHOT=$(mktemp)
[ -n "${PRETEST_SNAPSHOT:-}" ] && [ -e "$PRETEST_SNAPSHOT" ] || { echo "FATAL: preempt-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_SNAPSHOT"

cleanup() {
	cp "$PRETEST_SNAPSHOT" "$FRAGMENT"
	rm -f "$PRETEST_SNAPSHOT"
}
# See tests/wifi-sdio-variant-tests.sh's identical comment: a bare
# `trap cleanup INT TERM` runs cleanup but does not itself terminate the
# process, so execution would otherwise resume at the next test and
# silently re-mutate the file it just restored. `exit` triggers the EXIT
# trap on its own; it is not called directly here to avoid running
# cleanup twice.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: R0 leaves the tracked fragment file git-clean (today's
# real baseline needs no override at all). ---
sh "$VARIANT_SCRIPT" R0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$FRAGMENT")" ]; then
	pass
else
	fail "R0 did not produce a git-clean fragment file"
fi

# --- Test 2: R1 adds exactly one CONFIG_PREEMPT_RT=y line. ---
sh "$VARIANT_SCRIPT" R1 >/dev/null
count=$(grep -c '^CONFIG_PREEMPT_RT=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "R1 produced $count CONFIG_PREEMPT_RT=y lines, expected exactly 1"
fi

# --- Test 3: R1 never touches CONFIG_HZ (mission's own explicit
# instruction - HZ is never part of this A/B). ---
if grep -q 'CONFIG_HZ' "$FRAGMENT"; then
	fail "R1 introduced a CONFIG_HZ line into the fragment - HZ must never be touched by this variant"
else
	pass
fi

# --- Test 4: re-applying R1 twice in a row is idempotent (no duplicate
# blocks/lines). ---
sh "$VARIANT_SCRIPT" R1 >/dev/null
count=$(grep -c '^CONFIG_PREEMPT_RT=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "re-applying R1 produced $count CONFIG_PREEMPT_RT=y lines, expected exactly 1 (not idempotent)"
fi

# --- Test 5: switching from R1 back to R0 restores a byte-identical,
# git-clean baseline (no residual blank lines or partial blocks left
# behind). ---
sh "$VARIANT_SCRIPT" R0 >/dev/null
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$FRAGMENT")" ]; then
	pass
else
	fail "switching from R1 back to R0 left the fragment file modified: $(git -C "$REPO_ROOT" diff -- "$FRAGMENT")"
fi

# --- Test 6: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" R9 >/dev/null 2>&1; then
	fail "an unknown variant name 'R9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
