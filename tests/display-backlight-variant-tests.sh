#!/bin/sh
#
# Offline, repeatable tests for scripts/build/display-backlight-variant.sh
# (display hardware analysis mission, 2026-08-01, DISPLAY-B1 prototype).
# Operates against the real vendor kernel checkout's tracked DTS
# (vendor/x2000_kernel_6.6/kernel/kernel-6.6/module_drivers/dts/x2000/
# halley5_v30.dts) - same pattern as tests/wifi-sdio-variant-tests.sh.
#
# Powered-on investigation mission (2026-08-01) fix: the original version of
# this suite checked git-clean state via `git -C "$REPO_ROOT" status
# --porcelain -- "$DTS"` - the OUTER repo, which ignores the entire vendor/
# tree via .gitignore, so that check always reported "clean" regardless of
# the file's actual content. This made tests 1 and 6 (clean-baseline /
# clean-revert) vacuously pass every time, real bug or not - exactly the
# kind of gap this project's own "never trust exit 0 alone" discipline
# warns about. Fixed to check `git -C "$KERNEL_DIR" status --porcelain`
# instead, the nested vendor git checkout that actually tracks this file -
# matching tests/wifi-sdio-variant-tests.sh's own (correct) pattern.
#
# Usage: sh tests/display-backlight-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/display-backlight-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$DTS" ] || {
	echo "SKIP: $DTS not present"
	exit 0
}

# Snapshot the REAL pre-test state (whatever it actually is) so cleanup can
# restore exactly that state rather than assuming S0/git-HEAD was it.
PRETEST_SNAPSHOT=$(mktemp)
[ -n "${PRETEST_SNAPSHOT:-}" ] && [ -e "$PRETEST_SNAPSHOT" ] || { echo "FATAL: display-backlight-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$DTS" "$PRETEST_SNAPSHOT"

cleanup() {
	cp "$PRETEST_SNAPSHOT" "$DTS"
	rm -f "$PRETEST_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: S0 leaves the vendor kernel checkout git-clean (today's real
# baseline needs no override at all). Checked against the NESTED vendor
# repo, not the outer repo (which ignores vendor/ entirely). ---
sh "$VARIANT_SCRIPT" S0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- "$DTS_REL")" ]; then
	pass
else
	fail "S0 did not produce a git-clean DTS file: $(git -C "$KERNEL_DIR" diff -- "$DTS_REL")"
fi

# --- Test 2: S1 adds exactly one nebulaos_backlight node. ---
sh "$VARIANT_SCRIPT" S1 >/dev/null
count=$(grep -c 'nebulaos_backlight:' "$DTS")
if [ "$count" = "1" ]; then
	pass
else
	fail "S1 produced $count nebulaos_backlight node(s), expected exactly 1"
fi

# --- Test 3: S1 repoints &pwm's pinctrl-0 to pwm0_pc (real backlight pin),
# not the previously-unused pwm1_pc. ---
if grep -q 'pinctrl-0 = <&pwm0_pc>;' "$DTS"; then
	pass
else
	fail "S1 did not repoint &pwm to pwm0_pc"
fi
if grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS"; then
	fail "S1 left a stale pinctrl-0 = <&pwm1_pc>; reference in the DTS"
else
	pass
fi

# --- Test 4: S1's backlight node references PWM channel 0 (not channel 1),
# at 20000ns period (50kHz, matching stock's real pwm_freq=50000). ---
if grep -q 'pwms = <&pwm 0 20000>;' "$DTS"; then
	pass
else
	fail "S1's backlight node does not reference channel 0 at a 20000ns/50kHz period"
fi

# --- Test 5: re-applying S1 twice in a row is idempotent (no duplicate
# blocks/nodes). ---
sh "$VARIANT_SCRIPT" S1 >/dev/null
count=$(grep -c 'nebulaos_backlight:' "$DTS")
if [ "$count" = "1" ]; then
	pass
else
	fail "re-applying S1 produced $count nebulaos_backlight node(s), expected exactly 1 (not idempotent)"
fi

# --- Test 6: switching from S1 back to S0 restores a byte-identical,
# git-clean baseline (no residual blank lines, partial blocks, or a
# dangling pwm0_pc repoint left behind). Checked against the NESTED vendor
# repo - this is the exact check that was vacuous before this fix. ---
sh "$VARIANT_SCRIPT" S0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- "$DTS_REL")" ]; then
	pass
else
	fail "switching from S1 back to S0 left the DTS modified: $(git -C "$KERNEL_DIR" diff -- "$DTS_REL")"
fi

# --- Test 7: a forced failure while S1 is active does not corrupt the file
# beyond what the next S0/S1 invocation can cleanly recover from (this
# script has no partial-write window since it operates via a single `git
# checkout` reset followed by plain sed/append - simulate an interrupted
# state by leaving S1 applied, then confirm S0 still cleanly recovers). ---
sh "$VARIANT_SCRIPT" S1 >/dev/null
sh "$VARIANT_SCRIPT" S0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- "$DTS_REL")" ]; then
	pass
else
	fail "recovering to S0 after S1 was left active did not produce a clean file"
fi

# --- Test 8: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" S9 >/dev/null 2>&1; then
	fail "an unknown variant name 'S9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
