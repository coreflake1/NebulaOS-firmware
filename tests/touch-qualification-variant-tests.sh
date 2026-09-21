#!/bin/sh
#
# Offline, repeatable tests for scripts/build/touch-qualification-variant.sh
# (TOUCH-QUALIFICATION, display/touch investigation mission unification,
# 2026-08-01+). Same pattern as tests/touch-i0-diag-variant-tests.sh /
# tests/touch-irq-variant-tests.sh, but for the single unified feature that
# now supersedes both TOUCH-D0-DIAG and TOUCH-I0-DIAG (plus the new
# irq-assist mode) - see the header comment in
# scripts/build/touch-qualification-variant.sh for why those two other
# scripts (and the older touch-irq-variant.sh) must never be run against
# this checkout again.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-qualification-variant.sh.
#
# Usage: sh tests/touch-qualification-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-qualification-variant.sh"
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
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: touch-qualification-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: touch-qualification-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

# --- Test 1: QUAL0 leaves the affected files git-clean and no fragment
# block/marker. ---
sh "$VARIANT_SCRIPT" QUAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "QUAL0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION' "$FRAGMENT"; then
	fail "QUAL0 left CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION in the fragment"
else
	pass
fi

# --- Test 2: QUAL1 applies the patch and selects the option exactly
# once. ---
sh "$VARIANT_SCRIPT" QUAL1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_QUALIFICATION' \
	"$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"; then
	pass
else
	fail "QUAL1 did not add the TOUCHSCREEN_NS2009_QUALIFICATION Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "QUAL1 produced $count CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y lines, expected exactly 1"
fi

# --- Test 3: the three runtime modes are real, distinct symbols in the
# driver (poll-only/irq-observe/irq-assist), not just vague strings. ---
if grep -q 'NS2009_QUAL_MODE_POLL_ONLY' "$NS2009" && \
   grep -q 'NS2009_QUAL_MODE_IRQ_OBSERVE' "$NS2009" && \
   grep -q 'NS2009_QUAL_MODE_IRQ_ASSIST' "$NS2009"; then
	pass
else
	fail "QUAL1 does not define all three distinct qualification mode symbols"
fi
if grep -q 'ns2009_qual_irq_thread' "$NS2009" && \
   grep -q 'ns2009_qual_set_mode' "$NS2009" && \
   grep -q 'ns2009_qual_on_touch_down' "$NS2009" && \
   grep -q 'ns2009_qual_on_touch_release' "$NS2009"; then
	pass
else
	fail "QUAL1 is missing one of the core mode-logic functions (irq thread / set_mode / touch-down / touch-release hooks)"
fi

# --- Test 4: FALLING edge is requested, and no both-edges trigger exists
# anywhere in the file (the now-superseded TOUCH-I1 placeholder design). ---
if grep -q 'IRQF_TRIGGER_FALLING' "$NS2009"; then
	pass
else
	fail "QUAL1 does not request IRQF_TRIGGER_FALLING anywhere"
fi
if grep -Eq 'IRQF_TRIGGER_RISING[[:space:]]*\|[[:space:]]*IRQF_TRIGGER_FALLING|IRQF_TRIGGER_FALLING[[:space:]]*\|[[:space:]]*IRQF_TRIGGER_RISING' "$NS2009"; then
	fail "QUAL1 still requests a superseded both-edges trigger somewhere"
else
	pass
fi

# --- Test 5: zero I2C transfers / zero coordinate processing in the
# hard-IRQ-context handler - the same code-inspection method the existing
# I0 tests use: extract the exact threaded handler function body via awk
# and grep it, don't just grep the whole file. Requested with a NULL
# hard-IRQ handler (devm_request_threaded_irq's second callback argument),
# so ns2009_qual_irq_thread is the only handler that ever runs, in both
# irq-observe and irq-assist. ---
if grep -Eq 'devm_request_threaded_irq\(dev, irq, NULL, ns2009_qual_irq_thread' "$NS2009"; then
	pass
else
	fail "QUAL1 does not request the IRQ with a NULL hard-IRQ handler"
fi
irq_thread_body=$(awk '/^static irqreturn_t ns2009_qual_irq_thread/,/^}/' "$NS2009")
if [ -z "$irq_thread_body" ]; then
	fail "could not extract ns2009_qual_irq_thread()'s function body"
elif echo "$irq_thread_body" | grep -Eq 'i2c_smbus_|ns2009_ts_report|input_report_'; then
	fail "the qualification IRQ handler performs I2C transfers or coordinate/input processing - it must only update counters and mask the IRQ"
else
	pass
fi

# --- Test 6: storm protection exists - a rolling-window threshold
# constant, a permanent-fallback flag, and a disable_irq_nosync call. ---
if grep -q 'NS2009_QUAL_STORM_THRESHOLD' "$NS2009" && \
   grep -q 'NS2009_QUAL_STORM_WINDOW_MS' "$NS2009" && \
   grep -q 'qual_permanent_fallback = true' "$NS2009" && \
   grep -q 'disable_irq_nosync' "$NS2009"; then
	pass
else
	fail "QUAL1 does not implement storm protection with a permanent fallback"
fi

# --- Test 7: mode-string validation rejects invalid strings, and
# rejects irq-assist before irq-observe has been entered. ---
mode_write_body=$(awk '/^static ssize_t ns2009_qual_mode_write/,/^}/' "$NS2009")
if echo "$mode_write_body" | grep -q 'return -EINVAL;'; then
	pass
else
	fail "ns2009_qual_mode_write() does not reject invalid mode strings with -EINVAL"
fi
set_mode_body=$(awk '/^static int ns2009_qual_set_mode/,/^}/' "$NS2009")
if echo "$set_mode_body" | grep -q 'qual_irq_observe_entered' && \
   echo "$set_mode_body" | grep -q '\-EINVAL'; then
	pass
else
	fail "ns2009_qual_set_mode() does not gate irq-assist on irq-observe having been entered first"
fi

# --- Test 8: the existing poll registration call is untouched and
# unconditional - must not be wrapped in any #ifdef, must remain the sole
# always-on touch-reporting path regardless of qualification mode. ---
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "QUAL1 removed or altered the existing always-on poll registration - this must remain unconditional"
fi
poll_reg_context=$(awk '/^static int ns2009_ts_request_polled_input_dev/,/^}/' "$NS2009")
if echo "$poll_reg_context" | grep -q '#ifdef'; then
	fail "the poll registration function now contains conditional compilation - it must stay byte-for-byte unconditional"
else
	pass
fi

# --- Test 9: mode 0 (poll-only) requests no IRQ at probe time - the IRQ
# request only ever happens lazily, from within ns2009_qual_set_mode() on
# first entry to irq-observe, never unconditionally in probe(). ---
probe_body=$(awk '/^static int ns2009_ts_probe/,/^};/' "$NS2009")
if echo "$probe_body" | grep -q 'ns2009_qual_setup(data)' && \
   ! echo "$probe_body" | grep -q 'ns2009_qual_request_irq'; then
	pass
else
	fail "probe() must call ns2009_qual_setup() but never directly request the qualification IRQ itself"
fi

# --- Test 10: fail-safe reasons are real, distinct, grep-able strings
# (not just one generic message) - covering IRQ request failure, storm,
# repeated IRQ during a held contact, and a failed release confirmation. ---
if grep -q '"irq_request_failed"' "$NS2009" && \
   grep -q '"irq_storm"' "$NS2009" && \
   grep -q '"repeated_irq_during_contact"' "$NS2009" && \
   grep -q '"release_confirmation_failed"' "$NS2009"; then
	pass
else
	fail "QUAL1 is missing one or more of the required fail-safe fallback reason strings"
fi

# --- Test 11: exactly one ratelimited kernel warning site exists for the
# fallback path (never per-event log spam) - dev_warn_ratelimited() is
# used, and only inside the single central fallback-trigger function. ---
ratelimited_count=$(grep -c 'dev_warn_ratelimited' "$NS2009")
if [ "$ratelimited_count" = "1" ]; then
	pass
else
	fail "expected exactly 1 dev_warn_ratelimited() call site, found $ratelimited_count"
fi
trigger_body=$(awk '/^static void ns2009_qual_trigger_fallback/,/^}/' "$NS2009")
if echo "$trigger_body" | grep -q 'dev_warn_ratelimited'; then
	pass
else
	fail "the ratelimited fallback warning is not inside ns2009_qual_trigger_fallback()"
fi

# --- Test 12: the debugfs directory and its three entries (status, mode,
# reset_counters) are all registered. ---
if grep -q '"ns2009_qualification"' "$NS2009" && \
   grep -q 'debugfs_create_file("status"' "$NS2009" && \
   grep -q 'debugfs_create_file("mode"' "$NS2009" && \
   grep -q 'debugfs_create_file("reset_counters"' "$NS2009"; then
	pass
else
	fail "QUAL1 does not register the full ns2009_qualification/{status,mode,reset_counters} debugfs surface"
fi

# --- Test 13: re-applying QUAL1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" QUAL1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying QUAL1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying QUAL1 a second time failed - not idempotent"
fi

# --- Test 14: switching from QUAL1 back to QUAL0 restores clean affected
# files and an empty fragment block. ---
sh "$VARIANT_SCRIPT" QUAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from QUAL1 back to QUAL0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION' "$FRAGMENT"; then
	fail "switching from QUAL1 back to QUAL0 left CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION in the fragment"
else
	pass
fi

# --- Test 15: an unknown variant name is rejected, not silently
# applied. ---
if sh "$VARIANT_SCRIPT" QUAL9 >/dev/null 2>&1; then
	fail "an unknown variant name 'QUAL9' was accepted instead of rejected"
else
	pass
fi

# --- Test 16: the patch applies cleanly from a pristine checkout (a
# direct git apply --check, independent of the toggle script, as the
# mission's own required verification method). ---
git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES >/dev/null 2>&1
if git -C "$KERNEL_DIR" apply --check "$REPO_ROOT/scripts/build/patches/touch-qualification-unified.patch" 2>/dev/null; then
	pass
else
	fail "scripts/build/patches/touch-qualification-unified.patch does not apply cleanly to a pristine checkout"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
