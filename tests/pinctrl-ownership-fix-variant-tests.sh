#!/bin/sh
#
# Offline, repeatable tests for
# scripts/build/pinctrl-ownership-fix-variant.sh (NebulaOS Pinctrl Cleanup
# Mission, 2026-08-03). Operates against the real vendor kernel checkout's
# tracked pinctrl-ingenic.c/.h source - source-inspection only, the same
# "provable offline, by source structure alone" honesty boundary as
# tests/backlight-final-controller-variant-tests.sh (see its own header).
# There is no running kernel available from this environment, so this
# suite cannot prove the fix compiles or behaves correctly on real
# hardware - only that the toggle script is idempotent and that the
# applied source has the exact structural properties the fix is supposed
# to have.
#
# Background: pinctrl-ingenic.c's ingenic_dt_node_to_map() (the
# .dt_node_to_map callback, called for EVERY pinctrl-N property a device
# declares while building pinctrl maps, whether or not that state is ever
# actually selected) used to unconditionally OR a group's pins into
# used_pins_bitmap - conflating "a map was parsed" with "this pin is
# actively claimed". A device declaring a deliberately-never-auto-selected
# named alternate pinctrl state (e.g. nebulaos_backlight_final's own
# "pwm-active") got its pin silently pre-marked used at probe time, so its
# real first-ever runtime GPIO claim later falsely warned "gpio functions
# has redefinition" - live-reproduced 4 times during this mission's own
# acceptance testing, even though nothing ever actually held the pin
# concurrently.
#
# Usage: sh tests/pinctrl-ownership-fix-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/pinctrl-ownership-fix-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
C_REL="kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.c"
H_REL="kernel/kernel-6.6/module_drivers/drivers/pinctrl/pinctrl-ingenic.h"
C_FILE="$KERNEL_DIR/$C_REL"
H_FILE="$KERNEL_DIR/$H_REL"
AFFECTED_FILES="$C_REL $H_REL"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$VARIANT_SCRIPT" ] || { echo "SKIP: $VARIANT_SCRIPT not present"; exit 0; }
[ -d "$KERNEL_DIR/.git" ] || { echo "SKIP: $KERNEL_DIR not a git checkout - run 00-fetch-vendor-sources.sh first"; exit 0; }

PRETEST_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_SNAPSHOT:-}" ] && [ -e "$PRETEST_SNAPSHOT" ] || { echo "FATAL: pinctrl-ownership-fix-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_SNAPSHOT/$f"
done
cleanup() {
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	rm -rf "$PRETEST_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: FIX0 leaves the affected files git-clean. ---
sh "$VARIANT_SCRIPT" FIX0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "FIX0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi

# --- Test 2: FIX0 (pristine) reproduces the actual root cause - the
# DT-map-parsing function still unconditionally marks used_pins_bitmap.
# If this test itself starts failing because upstream/vendor source
# changed, that's real signal the bug's shape has changed too, not a
# broken test. ---
if grep -q 'jzgc->used_pins_bitmap |= grp->pinmux_bitmap;' "$C_FILE"; then
	pass
else
	fail "FIX0 (pristine) source no longer contains the known-buggy map-parse-time bitmap marking - has upstream changed? re-derive the fix"
fi

# --- Test 3: FIX1 applies cleanly on top of FIX0/pristine. ---
sh "$VARIANT_SCRIPT" FIX0 >/dev/null
OUT=$(sh "$VARIANT_SCRIPT" FIX1 2>&1)
RC=$?
[ "$RC" -eq 0 ] && pass || fail "FIX1 did not apply cleanly: $OUT"

# --- Test 4: FIX1 removes the map-parse-time bitmap marking from
# ingenic_dt_node_to_map() entirely - the root fix. ---
if ! grep -q 'jzgc->used_pins_bitmap |= grp->pinmux_bitmap;' "$C_FILE"; then
	pass
else
	fail "FIX1 still contains the map-parse-time used_pins_bitmap marking - root cause not actually removed"
fi

# --- Test 5: FIX1 adds real, runtime ownership tracking for pinmux
# activation (ingenic_pinmux_enable, the actual .set_mux callback) -
# proves "real GPIO and pinmux requests must still claim pins" wasn't
# lost by deleting the parse-time marking. ---
if grep -q 'pinmux_used_bitmap' "$C_FILE" && grep -q 'jzgc->pinmux_used_bitmap |= grp->pinmux_bitmap;' "$C_FILE"; then
	pass
else
	fail "FIX1 does not mark pinmux_used_bitmap on a real pinmux activation - genuine pinmux ownership is no longer tracked at all"
fi

# --- Test 6: FIX1 still detects a genuine pinmux-vs-pinmux conflict
# (two live activations of the same pin without release) - the
# check-before-set pattern, mirroring the pre-existing GPIO one. ---
if grep -q 'if (jzgc->pinmux_used_bitmap & grp->pinmux_bitmap)' "$C_FILE"; then
	pass
else
	fail "FIX1 does not check pinmux_used_bitmap before marking it - genuine simultaneous pinmux conflicts would no longer be detected"
fi

# --- Test 7: FIX1 allows a legitimate GPIO<->pinmux hand-off - a live
# GPIO request clears the pinmux-side mark for that same pin (the exact
# pinctrl_put() -> gpiod_get() sequence
# nebulaos_backlight_final_controller.c uses to leave PWM-active mode),
# rather than leaving a stale mark that would falsely block/warn on a
# future pinmux reclaim. ---
if grep -q 'jzgc->pinmux_used_bitmap &= ~(1 << offset);' "$C_FILE"; then
	pass
else
	fail "FIX1 does not clear pinmux_used_bitmap on a real GPIO request - a GPIO<->pinmux<->GPIO transition would leak a stale pinmux mark"
fi

# --- Test 8: the pre-existing GPIO ownership check/warn in
# ingenic_gpio_request() is untouched - genuine GPIO-vs-GPIO double
# claims (the ORIGINAL, still-valid purpose of used_pins_bitmap) must
# still be caught exactly as before. ---
if grep -q 'if (jzgc->used_pins_bitmap & (1 << offset))' "$C_FILE" \
	&& grep -q 'gpio functions has redefinition' "$C_FILE"; then
	pass
else
	fail "FIX1 altered or removed the pre-existing GPIO double-request check/warning - genuine GPIO conflicts may no longer be detected"
fi

# --- Test 9: pinmux_used_bitmap is declared in the header, alongside
# (not replacing) the existing used_pins_bitmap field. ---
if grep -q 'u32.*used_pins_bitmap;' "$H_FILE" && grep -q 'u32.*pinmux_used_bitmap;' "$H_FILE"; then
	pass
else
	fail "FIX1's header does not declare both used_pins_bitmap and pinmux_used_bitmap as separate fields"
fi

# --- Test 10: nothing in the fix special-cases GPC0, "backlight", or the
# NebulaOS driver name in actual CODE (comments are allowed and expected
# to reference them, as background/rationale) - this must be a generic
# pinctrl-ingenic.c correctness fix, not a targeted workaround. Strips
# C-style comments first (a simple state machine good enough for this
# file's own comment style), then checks only what remains. ---
CODE_ONLY=$(awk '
	{
		line = $0
		out = ""
		i = 1
		n = length(line)
		while (i <= n) {
			if (!incomment && substr(line, i, 2) == "/*") { incomment = 1; i += 2; continue }
			if (incomment && substr(line, i, 2) == "*/") { incomment = 0; i += 2; continue }
			if (!incomment) out = out substr(line, i, 1)
			i++
		}
		print out
	}
' "$C_FILE")
if echo "$CODE_ONLY" | grep -qiE 'gpc0|nebulaos|backlight'; then
	fail "FIX1 appears to special-case GPC0/backlight/NebulaOS in actual code, not just comments: $(echo "$CODE_ONLY" | grep -inE 'gpc0|nebulaos|backlight')"
else
	pass
fi

# --- Test 11: FIX0 cleanly reverts FIX1 back to a git-clean tree
# (idempotent switching, the same convention every sibling variant
# script follows). ---
sh "$VARIANT_SCRIPT" FIX0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "FIX0 after FIX1 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
