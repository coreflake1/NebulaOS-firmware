#!/bin/sh
#
# Offline, repeatable tests for scripts/build/display-vsync-variant.sh
# (DISPLAY-V1 prototype, powered-on display investigation mission,
# 2026-08-01). Operates against the real vendor kernel checkout's tracked
# source files and the tracked Kconfig fragment.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/display-vsync-variant.sh.
#
# Usage: sh tests/display-vsync-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/display-vsync-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
AFFECTED_FILES="kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/Kconfig kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/ingenicfb.c kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/include/ingenicfb.h"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: display-vsync-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: display-vsync-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_KERNEL_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_KERNEL_SNAPSHOT/$f"
done

cleanup() {
	cp "$PRETEST_FRAGMENT" "$FRAGMENT"
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_KERNEL_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	rm -f "$PRETEST_FRAGMENT"
	rm -rf "$PRETEST_KERNEL_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: V0 leaves the vendor kernel checkout git-clean on the 3
# affected files, and leaves no fragment block. ---
sh "$VARIANT_SCRIPT" V0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "V0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_FB_INGENIC_PAN_VSYNC_GATE' "$FRAGMENT"; then
	fail "V0 left CONFIG_FB_INGENIC_PAN_VSYNC_GATE in the fragment"
else
	pass
fi

# --- Test 2: V1 applies the patch (new Kconfig symbol present in source)
# and selects it in the fragment exactly once. ---
sh "$VARIANT_SCRIPT" V1 >/dev/null
if grep -q 'config FB_INGENIC_PAN_VSYNC_GATE' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/Kconfig"; then
	pass
else
	fail "V1 did not add the FB_INGENIC_PAN_VSYNC_GATE Kconfig option to source"
fi
count=$(grep -c '^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "V1 produced $count CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y lines, expected exactly 1"
fi

# --- Test 3: V1's patch adds the new struct fields and the pan_display
# bounds check (an independent, always-on correctness fix). ---
if grep -q 'pan_vsync_seq' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/include/ingenicfb.h"; then
	pass
else
	fail "V1 did not add the pan_vsync_seq field to ingenicfb.h"
fi
if grep -q 'out of range' "$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/video/fbdev/ingenic/fb_stage/ingenicfb.c"; then
	pass
else
	fail "V1 did not add the next_frm bounds check to ingenicfb_pan_display()"
fi

# --- Test 4: re-applying V1 twice is idempotent (git apply would itself
# fail loudly on a already-applied patch, which this test also implicitly
# exercises - a non-zero exit here is itself a real failure signal). ---
if sh "$VARIANT_SCRIPT" V1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying V1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying V1 a second time failed - the variant script's own git-checkout-first reset did not make this idempotent"
fi

# --- Test 5: switching from V1 back to V0 restores clean affected files
# and an empty fragment block. ---
sh "$VARIANT_SCRIPT" V0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from V1 back to V0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_FB_INGENIC_PAN_VSYNC_GATE' "$FRAGMENT"; then
	fail "switching from V1 back to V0 left CONFIG_FB_INGENIC_PAN_VSYNC_GATE in the fragment"
else
	pass
fi

# --- Test 6: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" V9 >/dev/null 2>&1; then
	fail "an unknown variant name 'V9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
