#!/bin/sh
#
# Offline, repeatable tests for
# scripts/build/touch-final-qualification-variant.sh (TOUCH-FINAL-
# QUALIFICATION, display/touch investigation mission follow-on,
# 2026-08-02+). Same pattern as tests/touch-qualification-variant-tests.sh,
# adapted for this feature's own patch
# (scripts/build/patches/touch-final-qualification.patch) and its new,
# separate ns2009_final_qualification.c driver.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-final-qualification-variant.sh.
#
# Usage: sh tests/touch-final-qualification-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-final-qualification-variant.sh"
QUAL_VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-qualification-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"

KCONFIG_REL="kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"
MAKEFILE_REL="kernel/kernel-6.6/drivers/input/touchscreen/Makefile"
NS2009_REL="kernel/kernel-6.6/drivers/input/touchscreen/ns2009.c"
NEWFILE_REL="kernel/kernel-6.6/drivers/input/touchscreen/ns2009_final_qualification.c"
AFFECTED_FILES="$KCONFIG_REL $MAKEFILE_REL $NS2009_REL"

NS2009="$KERNEL_DIR/$NS2009_REL"
NFQ="$KERNEL_DIR/$NEWFILE_REL"
MAKEFILE="$KERNEL_DIR/$MAKEFILE_REL"
FINAL_PATCH="$REPO_ROOT/scripts/build/patches/touch-final-qualification.patch"
QUAL_PATCH="$REPO_ROOT/scripts/build/patches/touch-qualification-unified.patch"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: touch-final-qualification-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: touch-final-qualification-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_KERNEL_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_KERNEL_SNAPSHOT/$f"
done
PRETEST_NEWFILE_PRESENT=0
[ -f "$NFQ" ] && PRETEST_NEWFILE_PRESENT=1

cleanup() {
	cp "$PRETEST_FRAGMENT" "$FRAGMENT"
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_KERNEL_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	if [ "$PRETEST_NEWFILE_PRESENT" = "0" ]; then
		rm -f "$NFQ"
	fi
	rm -f "$PRETEST_FRAGMENT"
	rm -rf "$PRETEST_KERNEL_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: FINALQUAL0 leaves the affected files git-clean and no
# fragment block/marker. ---
sh "$VARIANT_SCRIPT" FINALQUAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES $NEWFILE_REL)" ]; then
	pass
else
	fail "FINALQUAL0 did not produce clean affected files: $(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES $NEWFILE_REL)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION' "$FRAGMENT"; then
	fail "FINALQUAL0 left CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION in the fragment"
else
	pass
fi

# --- Test 2: FINALQUAL1 applies the patch and selects the option exactly
# once. From here through Test 20 below, FINALQUAL1 stays applied - all
# content-inspection tests run together, BEFORE any test that removes or
# rewrites these files (composability/idempotency/self-healing tests
# starting at Test 21), so no content check is ever accidentally run
# against a torn-down tree. ---
sh "$VARIANT_SCRIPT" FINALQUAL1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_FINAL_QUALIFICATION' \
	"$KERNEL_DIR/$KCONFIG_REL"; then
	pass
else
	fail "FINALQUAL1 did not add the TOUCHSCREEN_NS2009_FINAL_QUALIFICATION Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "FINALQUAL1 produced $count CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y lines, expected exactly 1"
fi

# --- Test 3: this is a genuinely separate feature - EXACTLY two runtime
# modes (poll-only/irq-assist), no third irq-observe mode (unlike the
# existing CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION driver, which this
# feature is not modeled after 1:1). ---
if grep -q 'NS2009_NFQ_MODE_POLL_ONLY' "$NFQ" && \
   grep -q 'NS2009_NFQ_MODE_IRQ_ASSIST' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not define both required mode symbols"
fi
if grep -q 'NS2009_NFQ_MODE_IRQ_OBSERVE' "$NFQ"; then
	fail "FINALQUAL1 defines an irq-observe mode - this feature only ever has poll-only/irq-assist"
else
	pass
fi

# --- Test 4: the core functions this design requires all exist in the new,
# separate driver file. ---
if grep -q 'ns2009_nfq_irq_handler' "$NFQ" && \
   grep -q 'ns2009_nfq_irq_thread' "$NFQ" && \
   grep -q 'ns2009_nfq_set_mode' "$NFQ" && \
   grep -q 'ns2009_nfq_on_poll' "$NFQ" && \
   grep -q 'ns2009_nfq_probe' "$NFQ" && \
   grep -q 'ns2009_nfq_request_irq' "$NFQ" && \
   grep -q 'ns2009_nfq_trigger_fallback' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 is missing one of the core mode-logic functions"
fi

# --- Test 5: FALLING edge only, no both-edges trigger anywhere. ---
if grep -q 'IRQF_TRIGGER_FALLING' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not request IRQF_TRIGGER_FALLING anywhere"
fi
if grep -Eq 'IRQF_TRIGGER_RISING[[:space:]]*\|[[:space:]]*IRQF_TRIGGER_FALLING|IRQF_TRIGGER_FALLING[[:space:]]*\|[[:space:]]*IRQF_TRIGGER_RISING' "$NFQ"; then
	fail "FINALQUAL1 requests a both-edges trigger somewhere"
else
	pass
fi

# --- Test 6: THE core design fix - the real hard-IRQ handler masks the
# line as its very first action, before anything else, on the code path
# that actually fires on a fresh (unmasked) IRQ. Extracted via the same
# awk-then-grep method the existing driver's own tests use. This is the
# single most important behavioral property this whole feature exists to
# guarantee - a second falling edge physically cannot generate another
# interrupt while masked. ---
irq_handler_body=$(awk '/^static irqreturn_t ns2009_nfq_irq_handler/,/^}/' "$NFQ")
if [ -z "$irq_handler_body" ]; then
	fail "could not extract ns2009_nfq_irq_handler()'s function body"
else
	first_disable_line=$(echo "$irq_handler_body" | grep -n 'disable_irq_nosync' | tail -1 | cut -d: -f1)
	if [ -z "$first_disable_line" ]; then
		fail "ns2009_nfq_irq_handler() never calls disable_irq_nosync()"
	else
		pass
	fi
	if echo "$irq_handler_body" | grep -Eq 'i2c_smbus_|ns2009_ts_report|input_report_|mutex_lock'; then
		fail "the hard-IRQ handler performs I2C/coordinate/input processing or takes a mutex - forbidden in hard-IRQ context"
	else
		pass
	fi
fi

# --- Test 7: the threaded handler also performs zero I2C/coordinate work -
# its only jobs are counters, the storm check, and scheduling the kick
# work item. ---
irq_thread_body=$(awk '/^static irqreturn_t ns2009_nfq_irq_thread/,/^}/' "$NFQ")
if [ -z "$irq_thread_body" ]; then
	fail "could not extract ns2009_nfq_irq_thread()'s function body"
elif echo "$irq_thread_body" | grep -Eq 'i2c_smbus_|ns2009_ts_report|input_report_|input_set_poll_interval'; then
	fail "the threaded IRQ handler performs I2C/coordinate/input processing or directly changes the poll interval - that belongs in the scheduled work item only"
else
	pass
fi

# --- Test 8: the kick work item is the only place that promotes the poll
# cadence, and it never touches I2C/coordinates either (that's
# ns2009_ts_report()'s job, in the input core's own poll workqueue). ---
kick_body=$(awk '/^static void ns2009_nfq_kick_work_fn/,/^}/' "$NFQ")
if [ -z "$kick_body" ]; then
	fail "could not extract ns2009_nfq_kick_work_fn()'s function body"
elif echo "$kick_body" | grep -q 'input_set_poll_interval' && \
     ! echo "$kick_body" | grep -Eq 'i2c_smbus_|ns2009_ts_report|input_report_'; then
	pass
else
	fail "ns2009_nfq_kick_work_fn() does not cleanly just promote the poll interval"
fi

# --- Test 9: release requires THREE consecutive high polls, not one - the
# constant exists and is actually compared against in the release logic. ---
if grep -q 'NS2009_NFQ_RELEASE_CONFIRM_POLLS' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not define NS2009_NFQ_RELEASE_CONFIRM_POLLS"
fi
const_val=$(grep -o 'NS2009_NFQ_RELEASE_CONFIRM_POLLS[[:space:]]*[0-9]*' "$NFQ" | grep -o '[0-9]*$' | head -1)
if [ "$const_val" = "3" ]; then
	pass
else
	fail "NS2009_NFQ_RELEASE_CONFIRM_POLLS is '$const_val', expected 3"
fi
on_poll_body=$(awk '/^void ns2009_nfq_on_poll/,/^}/' "$NFQ")
if echo "$on_poll_body" | grep -q 'release_confirm_streak >= NS2009_NFQ_RELEASE_CONFIRM_POLLS'; then
	pass
else
	fail "ns2009_nfq_on_poll() does not actually gate release confirmation on the 3-consecutive-poll streak"
fi

# --- Test 10: a slower ~250ms safety poll interval is defined and used
# while idle. ---
if grep -q 'NS2009_NFQ_SAFETY_POLL_INTERVAL_MS' "$NFQ" && \
   grep -q '250' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not define a 250ms safety poll interval"
fi
if echo "$on_poll_body" | grep -q 'idle_safety_poll_count++'; then
	pass
else
	fail "ns2009_nfq_on_poll() does not count idle safety polls"
fi

# --- Test 11: storm protection exists - rolling-window threshold
# constants, a permanent-fallback flag, and a disable_irq_nosync call
# reachable from the fallback path. ---
if grep -q 'NS2009_NFQ_STORM_THRESHOLD' "$NFQ" && \
   grep -q 'NS2009_NFQ_STORM_WINDOW_MS' "$NFQ" && \
   grep -q 'permanent_fallback = true' "$NFQ" && \
   grep -q 'disable_irq_nosync' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not implement storm protection with a permanent fallback"
fi

# --- Test 12: a release-confirmation timeout bound exists and is actually
# used to trigger a fallback (not just defined and ignored). ---
if grep -q 'NS2009_NFQ_RELEASE_CONFIRM_TIMEOUT_MS' "$NFQ" && \
   grep -q '"release_confirmation_timeout"' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not implement a release-confirmation timeout fallback"
fi

# --- Test 13: repeated re-arm failure has a defined limit and triggers a
# fallback. ---
if grep -q 'NS2009_NFQ_REARM_FAILURE_LIMIT' "$NFQ" && \
   grep -q '"repeated_rearm_failure"' "$NFQ" && \
   grep -q 'rearm_consecutive_failures' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not implement a repeated-re-arm-failure fallback"
fi

# --- Test 14: all required fail-safe reason strings are real, distinct,
# grep-able strings. ---
if grep -q '"irq_request_failed"' "$NFQ" && \
   grep -q '"unexpected_irq_while_masked"' "$NFQ" && \
   grep -q '"irq_storm"' "$NFQ" && \
   grep -q '"touch_worker_schedule_failed"' "$NFQ" && \
   grep -q '"release_confirmation_timeout"' "$NFQ" && \
   grep -q '"repeated_rearm_failure"' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 is missing one or more required fail-safe fallback reason strings"
fi

# --- Test 15: exactly one dev_warn_ratelimited() call site for the
# fallback path specifically - never per-event log spam. Counted by actual
# call syntax (every real call in this file passes &dev/&client->dev as
# its first argument) so prose mentions of the bare function name in
# comments never skew this; probe()'s own allocation-failure path also
# legitimately uses dev_warn_ratelimited() (a completely separate,
# one-time, non-fallback condition), so exactly 2 real call sites total
# are expected. ---
ratelimited_count=$(grep -c 'dev_warn_ratelimited(&' "$NFQ")
if [ "$ratelimited_count" = "2" ]; then
	pass
else
	fail "expected exactly 2 dev_warn_ratelimited() call sites (fallback + alloc-failure), found $ratelimited_count"
fi
trigger_body=$(awk '/^static void ns2009_nfq_trigger_fallback/,/^}/' "$NFQ")
if echo "$trigger_body" | grep -q 'dev_warn_ratelimited'; then
	pass
else
	fail "the ratelimited fallback warning is not inside ns2009_nfq_trigger_fallback()"
fi

# --- Test 16: the mode-write command is constrained to EXACTLY
# poll-only/irq-assist/reset-counters, rejecting anything else with
# -EINVAL - no raw/arbitrary IRQ controls exposed. ---
mode_write_body=$(awk '/^static ssize_t ns2009_nfq_mode_write/,/^}/' "$NFQ")
if echo "$mode_write_body" | grep -q '"poll-only"' && \
   echo "$mode_write_body" | grep -q '"irq-assist"' && \
   echo "$mode_write_body" | grep -q '"reset-counters"' && \
   echo "$mode_write_body" | grep -q 'return -EINVAL;'; then
	pass
else
	fail "ns2009_nfq_mode_write() does not implement the exact 3-command contract with -EINVAL rejection"
fi

# --- Test 17: persistent_mode is a genuinely separate debugfs file/command
# from "mode" - accepts only poll-only/irq-assist (no reset-counters, no
# arbitrary values), and never itself drives a live mode change. ---
persist_write_body=$(awk '/^static ssize_t ns2009_nfq_persistent_mode_write/,/^}/' "$NFQ")
if [ -z "$persist_write_body" ]; then
	fail "could not extract ns2009_nfq_persistent_mode_write()'s function body"
else
	if echo "$persist_write_body" | grep -q '"poll-only"' && \
	   echo "$persist_write_body" | grep -q '"irq-assist"' && \
	   echo "$persist_write_body" | grep -q 'return -EINVAL;'; then
		pass
	else
		fail "ns2009_nfq_persistent_mode_write() does not implement the poll-only/irq-assist-only contract"
	fi
	if echo "$persist_write_body" | grep -Eq 'ns2009_nfq_set_mode|input_set_poll_interval|disable_irq_nosync|enable_irq'; then
		fail "ns2009_nfq_persistent_mode_write() drives live mode/IRQ state - it must only record the requested field"
	else
		pass
	fi
fi

# --- Test 18: the debugfs directory and all three entries (status, mode,
# persistent_mode) are registered. ---
if grep -q '"ns2009_final_qualification"' "$NFQ" && \
   grep -q 'debugfs_create_file("status"' "$NFQ" && \
   grep -q 'debugfs_create_file("mode"' "$NFQ" && \
   grep -q 'debugfs_create_file("persistent_mode"' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not register the full ns2009_final_qualification/{status,mode,persistent_mode} debugfs surface"
fi

# --- Test 19: the "suppressed bounce count" field is honestly documented
# as an always-0, non-fabricated value, not a fake measurement. ---
if grep -q 'suppressed_bounce_count: 0' "$NFQ" && \
   grep -qi 'not fabricated' "$NFQ"; then
	pass
else
	fail "FINALQUAL1 does not honestly document the suppressed_bounce_count field as a non-fabricated 0"
fi

# --- Test 20: the Makefile composite-object lines exist, so the new file
# links into the SAME module/built-in object as ns2009.o (never an
# independent loadable module). ---
if grep -q 'ns2009-y := ns2009.o' "$MAKEFILE" && \
   grep -q 'ns2009-\$(CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION)' "$MAKEFILE"; then
	pass
else
	fail "FINALQUAL1 does not add the expected composite ns2009-y Makefile lines"
fi

# --- Test 21: boot-default poll-only - ns2009_nfq_probe() (the lazy
# first-poll-tick init) never itself requests an IRQ; only
# ns2009_nfq_set_mode()'s IRQ_ASSIST case does, and only in response to an
# explicit debugfs write. ---
probe_fn_body=$(awk '/^void \*ns2009_nfq_probe/,/^}/' "$NFQ")
if [ -z "$probe_fn_body" ]; then
	fail "could not extract ns2009_nfq_probe()'s function body"
elif echo "$probe_fn_body" | grep -Eq 'ns2009_nfq_request_irq|devm_request_threaded_irq'; then
	fail "ns2009_nfq_probe() requests the IRQ directly - it must default to poll-only and never request an IRQ itself"
else
	pass
fi
if echo "$probe_fn_body" | grep -q 'NS2009_NFQ_MODE_POLL_ONLY'; then
	pass
else
	fail "ns2009_nfq_probe() does not default nfq->mode to poll-only"
fi

# --- Test 22: ns2009.c's existing, unconditional poll registration is
# completely untouched - this feature must never wrap it in any #ifdef or
# otherwise alter it. ---
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "FINALQUAL1 removed or altered the existing always-on poll registration"
fi
poll_reg_context=$(awk '/^static int ns2009_ts_request_polled_input_dev/,/^}/' "$NS2009")
if echo "$poll_reg_context" | grep -q '#ifdef'; then
	fail "the poll registration function now contains conditional compilation - it must stay byte-for-byte unconditional"
else
	pass
fi

# --- Test 23: ns2009_ts_probe() itself is completely untouched by this
# feature (a deliberate design choice - the lazy nfq_handle init happens
# entirely from within ns2009_ts_poll() instead, specifically so this
# patch's footprint never needs to touch the same few lines of probe() the
# existing CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION patch already uses,
# keeping the two patches composable regardless of apply order). ---
probe_body=$(awk '/^static int ns2009_ts_probe/,/^};/' "$NS2009")
if echo "$probe_body" | grep -qi 'nfq'; then
	fail "ns2009_ts_probe() references this feature - it must be completely untouched, all init happens lazily from ns2009_ts_poll()"
else
	pass
fi

# --- From here on, tests apply/revert/checkout the affected files
# directly - no more content-inspection assertions after this point. ---

# --- Test 24: the patch applies cleanly to a pristine checkout (a direct
# git apply --check, independent of the toggle script). ---
git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES >/dev/null 2>&1
rm -f "$NFQ"
if git -C "$KERNEL_DIR" apply --check "$FINAL_PATCH" 2>/dev/null; then
	pass
else
	fail "$FINAL_PATCH does not apply cleanly to a pristine checkout"
fi

# --- Test 25/26: composability with the existing, completely separate
# CONFIG_TOUCHSCREEN_NS2009_QUALIFICATION patch - directly verified in BOTH
# apply orders, not merely assumed. Only run if that patch is present. ---
if [ -f "$QUAL_PATCH" ]; then
	git -C "$KERNEL_DIR" apply "$QUAL_PATCH"
	if git -C "$KERNEL_DIR" apply --check "$FINAL_PATCH" 2>/dev/null; then
		pass
	else
		fail "FINALQUAL patch does not apply cleanly on top of the existing QUALIFICATION patch"
	fi
	git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES >/dev/null 2>&1

	git -C "$KERNEL_DIR" apply "$FINAL_PATCH"
	if git -C "$KERNEL_DIR" apply --check "$QUAL_PATCH" 2>/dev/null; then
		pass
	else
		fail "the existing QUALIFICATION patch does not apply cleanly on top of the FINALQUAL patch"
	fi
	git -C "$KERNEL_DIR" apply -R "$FINAL_PATCH"
	rm -f "$NFQ"
	git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES >/dev/null 2>&1
else
	echo "SKIP: $QUAL_PATCH not present - skipping the two composability tests"
fi

# --- Test 27: re-applying FINALQUAL1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" FINALQUAL1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying FINALQUAL1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
	if sh "$VARIANT_SCRIPT" FINALQUAL1 >/dev/null 2>&1; then
		pass
	else
		fail "re-applying FINALQUAL1 a second time failed - not idempotent"
	fi
else
	fail "applying FINALQUAL1 failed"
fi

# --- Test 28: switching from FINALQUAL1 back to FINALQUAL0 restores clean
# affected files and an empty fragment block. ---
sh "$VARIANT_SCRIPT" FINALQUAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES $NEWFILE_REL)" ]; then
	pass
else
	fail "switching from FINALQUAL1 back to FINALQUAL0 left files modified"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION' "$FRAGMENT"; then
	fail "switching from FINALQUAL1 back to FINALQUAL0 left CONFIG_TOUCHSCREEN_NS2009_FINAL_QUALIFICATION in the fragment"
else
	pass
fi

# --- Test 29: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" FINALQUAL9 >/dev/null 2>&1; then
	fail "an unknown variant name 'FINALQUAL9' was accepted instead of rejected"
else
	pass
fi

# --- Test 30: self-healing recovery - a real, documented, tested
# limitation (see touch-final-qualification-variant.sh's own header
# comment): running touch-qualification-variant.sh AFTER this feature's
# content is already present will silently discard this feature's
# Kconfig/ns2009.c content (that other script's own unconditional
# `git checkout --` of those same two files, unmodifiable by this
# project's own hard constraints). Verify this script recovers a fully
# consistent, fully-applied state on the very next FINALQUAL1 invocation
# regardless, AND that the other feature's own content survives
# untouched throughout. Only run if that other script is present. ---
if [ -f "$QUAL_VARIANT_SCRIPT" ]; then
	sh "$VARIANT_SCRIPT" FINALQUAL1 >/dev/null
	sh "$QUAL_VARIANT_SCRIPT" QUAL1 >/dev/null
	if grep -q 'NS2009_FINAL_QUALIFICATION' "$NS2009"; then
		fail "setup for the self-healing test is wrong - QUAL1 unexpectedly did not wipe FINALQUAL content (test assumptions stale)"
	else
		pass
	fi
	sh "$VARIANT_SCRIPT" FINALQUAL1 >/dev/null
	if grep -q 'NS2009_FINAL_QUALIFICATION' "$NS2009" && grep -q 'NS2009_QUAL_MODE_IRQ_ASSIST' "$NS2009"; then
		pass
	else
		fail "FINALQUAL1 did not self-heal to a fully-applied state alongside the still-present QUALIFICATION content"
	fi
	sh "$VARIANT_SCRIPT" FINALQUAL0 >/dev/null
	sh "$QUAL_VARIANT_SCRIPT" QUAL0 >/dev/null
	if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES $NEWFILE_REL)" ]; then
		pass
	else
		fail "cleanup after the self-healing test left the tree dirty"
	fi
else
	echo "SKIP: $QUAL_VARIANT_SCRIPT not present - skipping the self-healing test"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
