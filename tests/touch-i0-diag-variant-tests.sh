#!/bin/sh
#
# Offline, repeatable tests for scripts/build/touch-i0-diag-variant.sh
# (TOUCH-I0-DIAG prototype, display/touch investigation mission follow-on,
# 2026-08-01+). Same pattern as tests/touch-irq-variant-tests.sh.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-i0-diag-variant.sh.
#
# Usage: sh tests/touch-i0-diag-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-i0-diag-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
AFFECTED_FILES="kernel/kernel-6.6/drivers/input/touchscreen/Kconfig kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"
NS2009="$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: touch-i0-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: touch-i0-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

# --- Test 1: IRQDIAG0 leaves the affected files git-clean and no
# fragment block. ---
sh "$VARIANT_SCRIPT" IRQDIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "IRQDIAG0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG' "$FRAGMENT"; then
	fail "IRQDIAG0 left CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG in the fragment"
else
	pass
fi

# --- Test 2: IRQDIAG1 applies the patch and selects the option exactly
# once. ---
sh "$VARIANT_SCRIPT" IRQDIAG1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_IRQ_DIAG' \
	"$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"; then
	pass
else
	fail "IRQDIAG1 did not add the TOUCHSCREEN_NS2009_IRQ_DIAG Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "IRQDIAG1 produced $count CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG=y lines, expected exactly 1"
fi

# --- Test 3: IRQDIAG1 adds the threaded IRQ handler, requests the
# evidence-based FALLING-only trigger (finalized 2026-08-01 from real
# TOUCH-D0-DIAG live evidence classifying GPIO79 as IDLE_HIGH_ACTIVE_LOW -
# see docs/NEBULAOS_TOUCH_IRQ_TRIGGER_FINDINGS.md - superseding the
# earlier both-edges placeholder), and leaves the existing poll path
# structurally intact (input_setup_polling call still present,
# unmodified). ---
if grep -q 'ns2009_irq_diag_thread' "$NS2009"; then
	pass
else
	fail "IRQDIAG1 did not add the threaded IRQ-diagnostic handler"
fi
if grep -q 'diag_irq_trigger_type = IRQF_TRIGGER_FALLING;' "$NS2009"; then
	pass
else
	fail "IRQDIAG1 did not request the evidence-based FALLING-only trigger"
fi
if grep -q 'IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING' "$NS2009"; then
	fail "IRQDIAG1 still requests the superseded both-edges trigger"
else
	pass
fi
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "IRQDIAG1 removed or altered the existing always-on poll registration - this must remain unconditional"
fi

# --- Test 4: zero I2C transfers / zero coordinate processing in the IRQ
# handler - grep its exact function body (from definition to the matching
# closing brace) for any I2C or input-report call. This is the mission's
# own required verification method: code inspection, not just a design
# claim. ---
irq_thread_body=$(awk '/^static irqreturn_t ns2009_irq_diag_thread/,/^}/' "$NS2009")
if echo "$irq_thread_body" | grep -Eq 'i2c_smbus_|ns2009_ts_report|input_report_'; then
	fail "the IRQ-diagnostic handler performs I2C transfers or coordinate/input processing - it must only update counters"
else
	pass
fi

# --- Test 5: storm protection exists (rolling window threshold, permanent
# fallback via disable_irq_nosync, a distinct storm counter). ---
if grep -q 'NS2009_IRQ_DIAG_STORM_THRESHOLD' "$NS2009" && \
   grep -q 'diag_storm_fallback_active = true' "$NS2009" && \
   grep -q 'disable_irq_nosync(irq)' "$NS2009"; then
	pass
else
	fail "IRQDIAG1 does not implement storm protection with a permanent fallback"
fi

# --- Test 6: IRQ request failure is handled non-fatally - setup function
# never fails probe(), and records a failure reason field. ---
setup_body=$(awk '/^static void ns2009_irq_diag_setup/,/^}/' "$NS2009")
if echo "$setup_body" | grep -q 'diag_irq_request_failure = error' && \
   echo "$setup_body" | grep -q 'diag_irq_request_failure = irq'; then
	pass
else
	fail "ns2009_irq_diag_setup() does not record both possible failure paths (gpiod_to_irq failure and IRQ request failure)"
fi
probe_body=$(awk '/^static int ns2009_ts_probe/,/^};/' "$NS2009")
if echo "$probe_body" | grep -q 'ns2009_irq_diag_setup(data)'; then
	pass
else
	fail "ns2009_ts_probe() does not call ns2009_irq_diag_setup()"
fi

# --- Test 7: re-applying IRQDIAG1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" IRQDIAG1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying IRQDIAG1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying IRQDIAG1 a second time failed - not idempotent"
fi

# --- Test 8: switching from IRQDIAG1 back to IRQDIAG0 restores clean
# affected files and an empty fragment block. ---
sh "$VARIANT_SCRIPT" IRQDIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from IRQDIAG1 back to IRQDIAG0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG' "$FRAGMENT"; then
	fail "switching from IRQDIAG1 back to IRQDIAG0 left CONFIG_TOUCHSCREEN_NS2009_IRQ_DIAG in the fragment"
else
	pass
fi

# --- Test 9: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" IRQDIAG9 >/dev/null 2>&1; then
	fail "an unknown variant name 'IRQDIAG9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
