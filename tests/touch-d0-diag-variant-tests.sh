#!/bin/sh
#
# Offline, repeatable tests for scripts/build/touch-d0-diag-variant.sh
# (TOUCH-D0-DIAG prototype, display/touch investigation mission follow-on,
# 2026-08-01+). Same pattern as tests/touch-irq-variant-tests.sh.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/touch-d0-diag-variant.sh.
#
# Usage: sh tests/touch-d0-diag-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/touch-d0-diag-variant.sh"
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
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: touch-d0-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: touch-d0-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

# --- Test 1: D0 leaves the affected files git-clean and no fragment block. ---
sh "$VARIANT_SCRIPT" D0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "D0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG' "$FRAGMENT"; then
	fail "D0 left CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG in the fragment"
else
	pass
fi

# --- Test 2: D1 applies the patch and selects the option exactly once. ---
sh "$VARIANT_SCRIPT" D1 >/dev/null
if grep -q 'config TOUCHSCREEN_NS2009_POLL_DIAG' \
	"$KERNEL_DIR/kernel/kernel-6.6/drivers/input/touchscreen/Kconfig"; then
	pass
else
	fail "D1 did not add the TOUCHSCREEN_NS2009_POLL_DIAG Kconfig option to source"
fi
count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "D1 produced $count CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y lines, expected exactly 1"
fi

# --- Test 3: D1 adds the diagnostic hook call sites at the poll tick and
# both transition points, and leaves the existing poll/report logic
# structurally untouched (still exactly one input_report_key(..., 1) and
# one input_report_key(..., 0) call, and the always-on poll registration
# call unchanged). ---
if grep -q 'ns2009_diag_on_poll(data)' "$NS2009" && \
   grep -q 'ns2009_diag_on_touch_down(data)' "$NS2009" && \
   grep -q 'ns2009_diag_on_touch_release(data)' "$NS2009"; then
	pass
else
	fail "D1 did not wire all three diagnostic hook call sites (poll/down/release)"
fi
down_reports=$(grep -c 'input_report_key(data->input, BTN_TOUCH, 1)' "$NS2009")
up_reports=$(grep -c 'input_report_key(data->input, BTN_TOUCH, 0)' "$NS2009")
if [ "$down_reports" = "1" ] && [ "$up_reports" = "1" ]; then
	pass
else
	fail "D1 changed the number of BTN_TOUCH report call sites (down=$down_reports, up=$up_reports, expected 1 each) - zero behavior change was required"
fi
if grep -q 'input_setup_polling(data->input, ns2009_ts_poll)' "$NS2009"; then
	pass
else
	fail "D1 removed or altered the existing always-on poll registration - this must remain unconditional"
fi

# --- Test 4: D1 exposes read-only status + an explicit-only reset file,
# and the reset handler never touches the live transition-tracking state
# (diag_raw_level/diag_last_transition_was_down/diag_last_down_jiffies/
# diag_last_up_jiffies), only counters/min-max. ---
if grep -q 'debugfs_create_file("status", 0444' "$NS2009" && \
   grep -q 'debugfs_create_file("reset", 0200' "$NS2009"; then
	pass
else
	fail "D1 did not expose both a read-only status file and a write-only reset file"
fi
reset_body=$(awk '/^static ssize_t ns2009_diag_reset_write/,/^}/' "$NS2009")
if echo "$reset_body" | grep -Eq 'diag_raw_level|diag_last_transition_was_down|diag_last_down_jiffies|diag_last_up_jiffies'; then
	fail "the reset handler touches live transition-tracking state, not just counters - it must only zero counters/min-max"
else
	pass
fi
if echo "$reset_body" | grep -q 'diag_poll_count = 0'; then
	pass
else
	fail "the reset handler does not zero diag_poll_count"
fi

# --- Test 5: re-applying D1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" D1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying D1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying D1 a second time failed - not idempotent"
fi

# --- Test 6: switching from D1 back to D0 restores clean affected files
# and an empty fragment block. ---
sh "$VARIANT_SCRIPT" D0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from D1 back to D0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG' "$FRAGMENT"; then
	fail "switching from D1 back to D0 left CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG in the fragment"
else
	pass
fi

# --- Test 7: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" D9 >/dev/null 2>&1; then
	fail "an unknown variant name 'D9' was accepted instead of rejected"
else
	pass
fi

# Re-apply D1 for the remaining source-logic assertions below.
sh "$VARIANT_SCRIPT" D1 >/dev/null

setup_body=$(awk '/^static void ns2009_diag_setup/,/^}/' "$NS2009")
on_poll_body=$(awk '/^static void ns2009_diag_on_poll/,/^}/' "$NS2009")
on_down_body=$(awk '/^static void ns2009_diag_on_touch_down/,/^}/' "$NS2009")
on_release_body=$(awk '/^static void ns2009_diag_on_touch_release/,/^}/' "$NS2009")
status_body=$(awk '/^static int ns2009_diag_status_show/,/^}/' "$NS2009")

# --- Test 8: counter initialization - diag_setup seeds the sentinel values
# (unset min-duration, unknown raw level) before anything can be read, and
# the reset path re-seeds the same min-duration sentinel (not 0, which
# would look like a real zero-length contact). ---
if echo "$setup_body" | grep -q 'diag_min_contact_duration_ms = NS2009_DIAG_DURATION_UNSET' && \
   echo "$setup_body" | grep -q 'diag_raw_level = -1'; then
	pass
else
	fail "ns2009_diag_setup does not seed diag_min_contact_duration_ms/diag_raw_level sentinels"
fi
if echo "$reset_body" | grep -q 'diag_min_contact_duration_ms = NS2009_DIAG_DURATION_UNSET'; then
	pass
else
	fail "reset handler does not restore the min-contact-duration sentinel (would look like a real 0ms contact)"
fi

# --- Test 9: idle-state detection - the inferred idle level is only
# reported once at least one raw sample exists, and is derived from the
# majority of raw high/low samples rather than a single reading. ---
if echo "$status_body" | grep -q 'if (data->diag_raw_high_count || data->diag_raw_low_count)' && \
   echo "$status_body" | grep -q 'idle_level = data->diag_raw_high_count >= data->diag_raw_low_count ? 1 : 0'; then
	pass
else
	fail "idle_level_inferred is not gated on having at least one raw sample, or is not majority-derived"
fi
if echo "$on_poll_body" | grep -q 'data->diag_raw_high_count++' && \
   echo "$on_poll_body" | grep -q 'data->diag_raw_low_count++'; then
	pass
else
	fail "ns2009_diag_on_poll does not tally both raw high and raw low samples for idle-level inference"
fi

# --- Test 10: touch-down transition - counts the down, records the
# down timestamp, and flips diag_last_transition_was_down to true (all
# purely additive; the caller already set data->pen_down before this
# runs, per the call-site comment). ---
if echo "$on_down_body" | grep -q 'diag_touch_down_count++' && \
   echo "$on_down_body" | grep -q 'data->diag_last_down_jiffies = now' && \
   echo "$on_down_body" | grep -q 'data->diag_last_transition_was_down = true'; then
	pass
else
	fail "ns2009_diag_on_touch_down does not count/record/flip state as expected"
fi

# --- Test 11: held-touch behavior - contact duration is only computed
# from live state while data->pen_down is actually true; when idle it
# must not fabricate a nonzero duration. ---
if echo "$status_body" | grep -q 'if (data->pen_down)' && \
   echo "$status_body" | grep -Eq 'contact_duration_ms = jiffies_to_msecs\(jiffies - data->diag_last_down_jiffies\)'; then
	pass
else
	fail "contact_duration_ms is not gated on data->pen_down / not derived from diag_last_down_jiffies"
fi
if echo "$status_body" | grep -q 'unsigned long contact_duration_ms = 0;'; then
	pass
else
	fail "contact_duration_ms does not default to 0 while idle"
fi

# --- Test 12: release transition - counts the release, computes duration
# from the recorded down timestamp (using the OLD value, before it is
# ever overwritten by a later down), and flips diag_last_transition_was_down
# to false. ---
if echo "$on_release_body" | grep -q 'diag_release_count++' && \
   echo "$on_release_body" | grep -Eq 'duration_ms = jiffies_to_msecs\(now - data->diag_last_down_jiffies\)' && \
   echo "$on_release_body" | grep -q 'data->diag_last_transition_was_down = false'; then
	pass
else
	fail "ns2009_diag_on_touch_release does not count/compute-duration/flip state as expected"
fi

# --- Test 13: timestamp ordering - each transition function reads jiffies
# into a local 'now' first, uses the previously-recorded timestamp for its
# duration/bounce math, and only afterwards overwrites that timestamp field
# with 'now' - so the math always sees the OLD value, never a value the
# same call already clobbered. ---
down_now_line=$(echo "$on_down_body" | grep -n 'unsigned long now = jiffies' | head -1 | cut -d: -f1)
down_write_line=$(echo "$on_down_body" | grep -n 'data->diag_last_down_jiffies = now' | head -1 | cut -d: -f1)
down_bounce_line=$(echo "$on_down_body" | grep -n 'diag_last_up_jiffies +' | head -1 | cut -d: -f1)
if [ -n "$down_now_line" ] && [ -n "$down_write_line" ] && [ -n "$down_bounce_line" ] && \
   [ "$down_now_line" -lt "$down_bounce_line" ] && [ "$down_bounce_line" -lt "$down_write_line" ]; then
	pass
else
	fail "ns2009_diag_on_touch_down does not read 'now', then use the old down-jiffies for the bounce check, then overwrite it, in that order"
fi
rel_now_line=$(echo "$on_release_body" | grep -n 'unsigned long now = jiffies' | head -1 | cut -d: -f1)
rel_duration_line=$(echo "$on_release_body" | grep -n 'duration_ms = jiffies_to_msecs' | head -1 | cut -d: -f1)
rel_write_line=$(echo "$on_release_body" | grep -n 'data->diag_last_up_jiffies = now' | head -1 | cut -d: -f1)
if [ -n "$rel_now_line" ] && [ -n "$rel_duration_line" ] && [ -n "$rel_write_line" ] && \
   [ "$rel_now_line" -lt "$rel_duration_line" ] && [ "$rel_duration_line" -lt "$rel_write_line" ]; then
	pass
else
	fail "ns2009_diag_on_touch_release does not read 'now', then compute duration from the old down-jiffies, then overwrite diag_last_up_jiffies, in that order"
fi

# --- Test 14: contact-duration calculation - min is only ever lowered
# (first-sample-or-lower), max is only ever raised, so both converge to
# the true min/max across many contacts rather than the last one seen. ---
if echo "$on_release_body" | grep -q 'diag_min_contact_duration_ms == NS2009_DIAG_DURATION_UNSET ||' && \
   echo "$on_release_body" | grep -q 'duration_ms < data->diag_min_contact_duration_ms'; then
	pass
else
	fail "min_contact_duration_ms is not correctly seeded-or-lowered"
fi
if echo "$on_release_body" | grep -q 'duration_ms > data->diag_max_contact_duration_ms'; then
	pass
else
	fail "max_contact_duration_ms is not correctly raised"
fi

# --- Test 15: bounce accounting - both bounce sites are wired: a new
# down arriving inside the bounce window since the last release, AND a
# release whose own contact was shorter than the bounce window. Either
# alone would miss half of what "debounce noise" looks like on a real
# line. ---
if echo "$on_down_body" | grep -q 'time_before(now, data->diag_last_up_jiffies +' && \
   echo "$on_down_body" | grep -q 'msecs_to_jiffies(NS2009_DIAG_BOUNCE_WINDOW_MS)'; then
	pass
else
	fail "ns2009_diag_on_touch_down does not count a down-side bounce (re-touch too soon after the last release)"
fi
if echo "$on_release_body" | grep -q 'duration_ms < NS2009_DIAG_BOUNCE_WINDOW_MS'; then
	pass
else
	fail "ns2009_diag_on_touch_release does not count a release-side bounce (contact shorter than the bounce window)"
fi
if echo "$on_down_body" | grep -q 'data->diag_release_count > 0 &&'; then
	pass
else
	fail "ns2009_diag_on_touch_down's bounce check does not guard against evaluating an as-yet-unset diag_last_up_jiffies before any release has ever happened"
fi

# --- Test 16: unexpected-transition accounting - both invariant-violation
# sites are wired (down-after-down, up-after-up), as pure sanity/defense
# in depth counters that should read 0 on real hardware. ---
if echo "$on_down_body" | grep -q 'if (data->diag_last_transition_was_down)' && \
   echo "$on_down_body" | grep -q 'diag_unexpected_transition_count++'; then
	pass
else
	fail "ns2009_diag_on_touch_down does not detect a down-after-down invariant violation"
fi
if echo "$on_release_body" | grep -q 'if (!data->diag_last_transition_was_down)' && \
   echo "$on_release_body" | grep -q 'diag_unexpected_transition_count++'; then
	pass
else
	fail "ns2009_diag_on_touch_release does not detect an up-after-up invariant violation"
fi

# --- Test 17: reset-only-affects-counters, strengthened - the reset
# handler must not reference the GPIO descriptor, any gpiod_* call, or
# the poll function at all: it can only be a pure in-memory counter
# clear, never something that could perturb the GPIO direction or the
# polling cadence. ---
if echo "$reset_body" | grep -Eq 'gpiod_|pendown_gpio|ns2009_ts_poll|input_setup_polling'; then
	fail "the reset handler references GPIO/poll machinery - it must be a pure in-memory counter clear"
else
	pass
fi

# --- Test 18: variant idempotency, D0 side - re-applying D0 twice in a
# row is also a no-op (not just D1), leaving affected files clean and the
# fragment free of the diagnostic block. ---
sh "$VARIANT_SCRIPT" D0 >/dev/null
if sh "$VARIANT_SCRIPT" D0 >/dev/null 2>&1; then
	if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ] && \
	   ! grep -q 'CONFIG_TOUCHSCREEN_NS2009_POLL_DIAG' "$FRAGMENT"; then
		pass
	else
		fail "re-applying D0 twice left a dirty tree or a stray fragment entry"
	fi
else
	fail "re-applying D0 a second time failed - not idempotent"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
