#!/bin/sh
#
# Offline, repeatable tests for scripts/build/touch-irq-variant.sh
# (TOUCH-I1 prototype, powered-on display/touch investigation mission,
# 2026-08-01). Same pattern as tests/display-vsync-variant-tests.sh.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-irq-variant.sh.
#
# Usage: sh tests/touch-irq-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-irq-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
AFFECTED_FILES="kernel/kernel-6.6/drivers/input/touchscreen/Kconfig kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: touch-irq-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: touch-irq-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

# --- Test 1: I0 leaves the affected files git-clean and no fragment block. ---
sh "$VARIANT_SCRIPT" I0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "I0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ' "$FRAGMENT"; then
	fail "I0 left CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ in the fragment"
else
	pass
fi

# --- Test 2: I1 applies the patch and selects the option exactly once. ---
sh "$VARIANT_SCRIPT" I1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_PENDOWN_IRQ' "$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"; then
	pass
else
	fail "I1 did not add the TOUCHSCREEN_NS2009_PENDOWN_IRQ Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "I1 produced $count CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y lines, expected exactly 1"
fi

# --- Test 3: I1's patch adds the threaded IRQ handler, both-edges trigger
# flags, and storm-protection logic, and leaves the existing poll path
# structurally intact (input_setup_polling call still present unmodified). ---
NS2009="$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"
if grep -q 'ns2009_pendown_irq_thread' "$NS2009"; then
	pass
else
	fail "I1 did not add the threaded IRQ handler"
fi
if grep -q 'IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING' "$NS2009"; then
	pass
else
	fail "I1 did not request both-edges triggering"
fi
if grep -q 'NS2009_IRQ_STORM_THRESHOLD' "$NS2009"; then
	pass
else
	fail "I1 did not add IRQ storm protection"
fi
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "I1 removed or altered the existing always-on poll registration - this must remain unconditional"
fi

# --- Test 4: re-applying I1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" I1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying I1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying I1 a second time failed - not idempotent"
fi

# --- Test 5: switching from I1 back to I0 restores clean affected files
# and an empty fragment block. ---
sh "$VARIANT_SCRIPT" I0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from I1 back to I0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ' "$FRAGMENT"; then
	fail "switching from I1 back to I0 left CONFIG_TOUCHSCREEN_NS2009_PENDOWN_IRQ in the fragment"
else
	pass
fi

# --- Test 6: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" I9 >/dev/null 2>&1; then
	fail "an unknown variant name 'I9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
