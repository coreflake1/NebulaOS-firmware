#!/bin/sh
#
# Tests for scripts/build/preempt-variant.sh, rewritten 2026-09-23 (D-03).
#
# WHAT WAS WRONG BEFORE
#
# The old suite asserted that variant state R0 leaves the tracked fragment
# git-CLEAN. That can only be true if the committed fragment is the
# "not-selected" baseline. It is not. The canonical model is:
#
#     the tracked halley5-nebulaos-fragment.config IS the qualified
#     production baseline, with every accepted variant block applied
#
# derived mechanically, highest authority first:
#   1. the committed fragment carries all six accepted variant marker blocks;
#   2. 02-configure-buildroot.sh:90,106 copies it straight into Buildroot, so
#      whatever is committed is what a plain build consumes - under the other
#      model a plain build would silently produce a non-RT kernel;
#   3. assert-baseline-config.sh:108-109 gates on CONFIG_PREEMPT_RT=y being
#      present in the TRACKED fragment, and :179-180 on the generated config;
#   4. nothing in the build scripts ever resets the fragment to not-selected -
#      that is an unenforced convention in apply-qualified-baseline.sh's
#      header, and per this workspace's authority order committed artifact
#      plus build script outrank a comment.
#
# So R0 makes the tracked file dirty BY CONSTRUCTION, and the old Tests 1 and
# 5 could never pass. They were copied from wifi-sdio-variant-tests.sh, where
# the same shape is valid because its target is a gitignored vendor checkout
# that really is pristine upstream. Transplanted onto a tracked product
# artifact, the premise does not hold.
#
# The product configuration is NOT changed to make these tests pass.
# CONFIG_PREEMPT_RT=y stays exactly where it is in the committed fragment.
#
# AND: this suite no longer touches the canonical artifact at all. It used to
# mutate the real tracked fragment under snapshot-restore, so a crash, an OOM
# kill or a SIGKILL mid-run could leave the shipped fragment without
# CONFIG_PREEMPT_RT=y and the next build would silently produce a non-RT
# kernel - precisely the bug class this suite exists to catch. Everything now
# runs on disposable copies via NEBULAOS_PREEMPT_VARIANT_FRAGMENT/_MARKER.
#
# Usage: sh tests/preempt-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/preempt-variant.sh"
CANONICAL="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
BEGIN_MARK="#--- NEBULAOS_PREEMPT_RT_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_PREEMPT_RT_VARIANT_END ---"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W=$(mktemp -d "${TMPDIR:-/tmp}/preempt-variant.XXXXXX") || exit 1
[ -n "$W" ] || { echo "FATAL: mktemp gave no path"; exit 1; }
trap 'rm -rf "$W"' EXIT

# Record the canonical file's exact bytes up front so the final test can prove
# this suite never modified it. Not a restore mechanism - nothing here writes
# to it, which is the point.
CANON_SHA_BEFORE=$(sha256sum "$CANONICAL" | cut -d' ' -f1)

# Run the variant script against a disposable copy.
#   apply <fixture> <variant>
apply() {
	NEBULAOS_PREEMPT_VARIANT_FRAGMENT="$1" NEBULAOS_PREEMPT_VARIANT_MARKER="$W/marker" \
		sh "$VARIANT_SCRIPT" "$2" >/dev/null 2>&1
}
fresh() { cp "$CANONICAL" "$W/$1"; echo "$W/$1"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
# The canonical file with the PREEMPT_RT block stripped - the exact expected
# R0 result.
canon_minus_block() {
	sed "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$CANONICAL"
}
# Same, for an arbitrary file.
minus_block() {
	sed "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$1"
}
# The R1 result is compared this way rather than by byte-identity, because
# preempt-variant.sh strips its block and re-APPENDS it at end of file. On the
# committed fragment the block sits at :582-586 with five other accepted
# variant blocks after it, so R1 yields a semantically identical but REORDERED
# file. That is real, current behaviour of the variant script, not a defect
# this suite may paper over by editing production config - so the assertion is
# "same content everywhere else, block present exactly once", which is the
# property the build actually depends on (Kconfig fragments are order
# independent for distinct symbols).
r1_matches_baseline() {
	_f="$1"
	minus_block "$_f" > "$W/.cmp-f"
	canon_minus_block > "$W/.cmp-c"
	cmp -s "$W/.cmp-f" "$W/.cmp-c" || return 1
	# Markers must be well formed AND paired. Checking BEGIN alone is not
	# enough: after R1 the block is last in the file, so a corrupted END
	# marker makes the strip above run to EOF and the remainder still
	# matches. Injection 2 catches exactly that.
	[ "$(grep -cF "$BEGIN_MARK" "$_f")" -eq 1 ] || return 1
	[ "$(grep -cF "$END_MARK" "$_f")" -eq 1 ] || return 1
	grep -q '^CONFIG_PREEMPT_RT=y$' "$_f" || return 1
	return 0
}

echo "=== Canonical model: the tracked fragment IS the qualified baseline ==="
if grep -qF "$BEGIN_MARK" "$CANONICAL"; then
	pass "the committed fragment carries the PREEMPT_RT variant block (model B)"
else
	fail "the committed fragment has no PREEMPT_RT block - the canonical model assumed here is wrong"
fi
if grep -q '^CONFIG_PREEMPT_RT=y$' "$CANONICAL"; then
	pass "the committed fragment selects CONFIG_PREEMPT_RT=y (what the product requires)"
else
	fail "the committed fragment does not select CONFIG_PREEMPT_RT=y"
fi

echo ""
echo "=== R1: the accepted state reproduces the committed baseline exactly ==="
f=$(fresh r1); apply "$f" R1
if r1_matches_baseline "$f"; then
	pass "R1 on a copy of the baseline reproduces the committed baseline (same content, block present once)"
else
	fail "R1 did not reproduce the committed baseline: $(diff "$CANONICAL" "$f" | head -5)"
fi

echo ""
echo "=== R0: removes ONLY its own block ==="
f=$(fresh r0); apply "$f" R0
if grep -qF "$BEGIN_MARK" "$f"; then
	fail "R0 left the PREEMPT_RT block in place"
else
	pass "R0 removes the PREEMPT_RT block"
fi
if grep -q '^CONFIG_PREEMPT_RT=y$' "$f"; then
	fail "R0 left CONFIG_PREEMPT_RT=y selected"
else
	pass "R0 deselects CONFIG_PREEMPT_RT=y"
fi
# Everything else must be untouched - this is the assertion that replaces the
# old, impossible "git-clean" one.
canon_minus_block > "$W/expected-r0"
if cmp -s "$f" "$W/expected-r0"; then
	pass "R0 changes NOTHING except its own block (every other byte identical)"
else
	fail "R0 altered bytes outside its own block: $(diff "$W/expected-r0" "$f" | head -5)"
fi
# Other accepted variants must survive R0.
for other in NEBULAOS_PAN_VSYNC_GATE_VARIANT NEBULAOS_BACKLIGHT_FINAL_CONTROLLER_VARIANT \
             NEBULAOS_PWM_STATE_READBACK_VARIANT NEBULAOS_TOUCH_FINAL_QUALIFICATION_VARIANT \
             NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT; do
	if grep -qF "#--- ${other}_BEGIN ---" "$f"; then :; else
		fail "R0 destroyed the unrelated variant block $other"
		continue
	fi
done
pass "R0 preserves all five unrelated accepted variant blocks"

echo ""
echo "=== Round trip and idempotence ==="
f=$(fresh rt); apply "$f" R0; apply "$f" R1
if r1_matches_baseline "$f"; then
	pass "R0 then R1 returns to the committed baseline"
else
	fail "R0->R1 did not return to the baseline: $(diff "$CANONICAL" "$f" | head -5)"
fi
f=$(fresh id1); apply "$f" R1; a=$(sha "$f"); apply "$f" R1; b=$(sha "$f")
if [ "$a" = "$b" ]; then pass "R1 is idempotent"; else fail "R1 is not idempotent"; fi
f=$(fresh id0); apply "$f" R0; a=$(sha "$f"); apply "$f" R0; b=$(sha "$f")
if [ "$a" = "$b" ]; then pass "R0 is idempotent"; else fail "R0 is not idempotent"; fi
f=$(fresh dup); apply "$f" R1; apply "$f" R1; apply "$f" R1
n=$(grep -cF "$BEGIN_MARK" "$f")
if [ "$n" -eq 1 ]; then
	pass "repeated R1 never duplicates the marker block (exactly 1)"
else
	fail "repeated R1 produced $n marker blocks"
fi

echo ""
echo "=== Marker and argument handling ==="
f=$(fresh mk); apply "$f" R1
if [ "$(cat "$W/marker" 2>/dev/null)" = "R1" ]; then
	pass "the applied-marker records R1"
else
	fail "the applied-marker does not record R1: $(cat "$W/marker" 2>/dev/null)"
fi
apply "$f" R0
if [ "$(cat "$W/marker" 2>/dev/null)" = "R0" ]; then
	pass "the applied-marker records R0"
else
	fail "the applied-marker does not record R0"
fi
f=$(fresh bad)
if NEBULAOS_PREEMPT_VARIANT_FRAGMENT="$f" NEBULAOS_PREEMPT_VARIANT_MARKER="$W/marker" \
	sh "$VARIANT_SCRIPT" R7 >/dev/null 2>&1; then
	fail "an unknown variant was accepted"
else
	pass "an unknown variant is rejected with a non-zero status"
fi

echo ""
echo "=== Regression injection: prove these assertions can actually fail ==="
# Each case mutates a fixture the way a real regression would, and asserts the
# corresponding check reports a difference. Without this the suite could pass
# by checking nothing.
f=$(fresh inj1); apply "$f" R1
sed -i '/^CONFIG_PREEMPT_RT=y$/d' "$f"
if r1_matches_baseline "$f"; then
	fail "injection 1: dropping CONFIG_PREEMPT_RT=y was NOT detected - the baseline check is vacuous"
else
	pass "injection 1: an unexpectedly missing CONFIG_PREEMPT_RT=y is detected"
fi

f=$(fresh inj2); apply "$f" R1
sed -i "s/^${END_MARK}\$/#--- MALFORMED ---/" "$f"
if r1_matches_baseline "$f"; then
	fail "injection 2: a malformed end marker was NOT detected"
else
	pass "injection 2: a malformed marker block is detected"
fi

f=$(fresh inj3); apply "$f" R1
{ echo "$BEGIN_MARK"; echo "CONFIG_PREEMPT_RT=y"; echo "$END_MARK"; } >> "$f"
n=$(grep -cF "$BEGIN_MARK" "$f")
if [ "$n" -gt 1 ]; then
	pass "injection 3: a duplicated marker block is visible to the duplicate check ($n found)"
else
	fail "injection 3: a duplicated block was not visible"
fi

f=$(fresh inj4); apply "$f" R0
sed -i '/NEBULAOS_PAN_VSYNC_GATE_VARIANT_BEGIN/,/NEBULAOS_PAN_VSYNC_GATE_VARIANT_END/d' "$f"
canon_minus_block > "$W/expected-inj4"
if cmp -s "$f" "$W/expected-inj4"; then
	fail "injection 4: losing an unrelated variant block was NOT detected - the R0 scope check is vacuous"
else
	pass "injection 4: losing unrelated variant state is detected"
fi

echo ""
echo "=== The canonical artifact must be untouched by this suite ==="
if [ "$(sha "$CANONICAL")" = "$CANON_SHA_BEFORE" ]; then
	pass "the tracked fragment is byte-identical to how this suite found it"
else
	fail "THIS SUITE MODIFIED THE CANONICAL TRACKED FRAGMENT"
fi
if [ -z "$(git -C "$REPO_ROOT" status --porcelain -- "$CANONICAL" 2>/dev/null)" ]; then
	pass "the tracked fragment is git-clean after the run"
else
	fail "the tracked fragment is dirty after the run"
fi

echo ""
echo "preempt-variant-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
