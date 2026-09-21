#!/bin/sh
#
# Offline, repeatable tests for scripts/build/wifi-sdio-variant.sh
# (pre-qualification mission Phase A4, 2026-07-31).
#
# Unlike this repo's other offline test suites, this one operates
# against the real vendor/x2000_kernel_6.6 checkout rather than a
# fixture - the script's whole job is editing that real file via git-
# scoped sed ranges, and a fixture DTS would need to duplicate its exact
# msc0/msc1 structure to be meaningful, risking drifting out of sync with
# the real file.
#
# Alpha baseline freeze mission (2026-08-01): real build-integrity defect
# found live - this suite's cleanup used to unconditionally reset the DTS
# to W0 on exit, regardless of what variant was selected before the suite
# ran. Running this suite after deliberately applying W3 (as part of
# building a combined W3+R1 alpha image) silently discarded that W3
# selection back to W0 before the build ever started - the build then
# produced a plain baseline image despite W3 having been correctly applied
# moments earlier. Caught only by inspecting the built artifact's own
# hashes, not by this suite's own exit status (which was, and always had
# been, a clean pass). Fixed: snapshot the DTS's exact real pre-test bytes
# before any mutation, restore exactly those bytes on exit (success,
# failure, or signal) - never assume W0 was the starting state.
#
# Skips (not fails) if vendor/x2000_kernel_6.6 isn't fetched yet.
#
# Usage: sh tests/wifi-sdio-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/wifi-sdio-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS="$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"

if [ ! -f "$DTS" ]; then
	echo "SKIP: $DTS not present - run 00-fetch-vendor-sources.sh first to exercise this suite"
	exit 0
fi

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

# Snapshot the REAL pre-test state (whatever it actually is - W0, W1, W2,
# W3, or anything else) before this suite's first mutation, so cleanup can
# restore exactly that state rather than assuming a fixed baseline.
PRETEST_SNAPSHOT=$(mktemp)
[ -n "${PRETEST_SNAPSHOT:-}" ] && [ -e "$PRETEST_SNAPSHOT" ] || { echo "FATAL: wifi-sdio-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$DTS" "$PRETEST_SNAPSHOT"

cleanup() {
	cp "$PRETEST_SNAPSHOT" "$DTS"
	rm -f "$PRETEST_SNAPSHOT"
}
# EXIT alone runs cleanup on every path (normal completion, `exit` calls
# below, or any other termination) - POSIX shells do NOT terminate a
# process just because it received INT/TERM while a handler is trapped;
# without the process actually exiting afterward, execution would
# otherwise resume with whatever test was next, silently re-mutating the
# just-restored file (confirmed live: a real, distinct bug from the one
# this suite already fixed - a bare `trap cleanup INT TERM` runs cleanup
# but then keeps running the remaining tests, undoing the very restore
# it just performed). `exit` here triggers the EXIT trap on its own; it
# does not call cleanup directly to avoid running it twice.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

msc1_props() {
	sed -n '/^&msc1 {/,/^};/p' "$DTS" | grep -E 'cap-sdio-irq;|cap-sd-highspeed;|cap-mmc-highspeed;'
}

msc0_props() {
	sed -n '/^&msc0 {/,/^};/p' "$DTS" | grep -E 'cap-sdio-irq;|cap-sd-highspeed;|cap-mmc-highspeed;'
}

msc0_baseline=$(msc0_props)

# --- Test 1: W0 leaves the tree git-clean. ---
sh "$VARIANT_SCRIPT" W0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
	pass
else
	fail "W0 did not produce a git-clean tree"
fi

# --- Test 2: W1 adds cap-sdio-irq, keeps cap-mmc-highspeed, no cap-sd-highspeed. ---
sh "$VARIANT_SCRIPT" W1 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sdio-irq;' \
	&& printf '%s' "$props" | grep -q 'cap-mmc-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-sd-highspeed;'; then
	pass
else
	fail "W1 did not produce the expected property set: $props"
fi

# --- Test 3: W2 replaces cap-mmc-highspeed with cap-sd-highspeed, no cap-sdio-irq. ---
sh "$VARIANT_SCRIPT" W2 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sd-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-mmc-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-sdio-irq;'; then
	pass
else
	fail "W2 did not produce the expected property set: $props"
fi

# --- Test 4: W3 has both cap-sdio-irq and cap-sd-highspeed, no cap-mmc-highspeed. ---
sh "$VARIANT_SCRIPT" W3 >/dev/null
props=$(msc1_props)
if printf '%s' "$props" | grep -q 'cap-sdio-irq;' \
	&& printf '%s' "$props" | grep -q 'cap-sd-highspeed;' \
	&& ! printf '%s' "$props" | grep -q 'cap-mmc-highspeed;'; then
	pass
else
	fail "W3 did not produce the expected property set: $props"
fi

# --- Test 5: msc0 (the real eMMC boot storage) is never touched by any
# variant - confirmed unchanged after applying all four in sequence. ---
if [ "$(msc0_props)" = "$msc0_baseline" ]; then
	pass
else
	fail "msc0's cap-* properties changed after applying Wi-Fi SDIO variants (must never happen): before='$msc0_baseline' after='$(msc0_props)'"
fi

# --- Test 6: re-applying the same variant twice is idempotent (no
# duplicate properties, no error). ---
sh "$VARIANT_SCRIPT" W1 >/dev/null
first_count=$(msc1_props | grep -c 'cap-sdio-irq;')
sh "$VARIANT_SCRIPT" W1 >/dev/null
second_count=$(msc1_props | grep -c 'cap-sdio-irq;')
if [ "$first_count" = "1" ] && [ "$second_count" = "1" ]; then
	pass
else
	fail "applying W1 twice did not stay idempotent (counts: $first_count then $second_count)"
fi

# --- Test 7: switching back to W0 after any other variant returns to a
# byte-identical, git-clean baseline. ---
sh "$VARIANT_SCRIPT" W3 >/dev/null
sh "$VARIANT_SCRIPT" W0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain)" ]; then
	pass
else
	fail "switching from W3 back to W0 did not produce a git-clean tree"
fi

# --- Test 8: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" W9 >/dev/null 2>&1; then
	fail "an unknown variant name 'W9' was accepted instead of rejected"
else
	pass
fi

# --- Test 9: composes correctly with display-backlight-diag-variant.sh
# in EITHER order - both touch this same shared DTS file (&msc1 vs &pwm +
# a new top-level node). A real bug (found 2026-08-02): both scripts used
# to do a blanket `git checkout -- "$DTS_REL"` as their own "reset to
# pristine" step, so whichever ran LAST silently discarded the other's
# uncommitted changes - a composed qualification build had a fully
# correct Kconfig selection but a silently-missing backlight DT node
# because of this. Both scripts were fixed to use scoped reverts instead
# (touch only their own owned lines/marked blocks) so they compose safely
# regardless of order - this test proves that directly rather than
# trusting it stays fixed. ---
BACKLIGHT_SCRIPT="$REPO_ROOT/scripts/build/display-backlight-diag-variant.sh"
if [ -f "$BACKLIGHT_SCRIPT" ]; then
	sh "$BACKLIGHT_SCRIPT" DIAG0 >/dev/null 2>&1

	# Order A: W3 then DIAG1 - both must be present afterward.
	sh "$VARIANT_SCRIPT" W3 >/dev/null
	sh "$BACKLIGHT_SCRIPT" DIAG1 >/dev/null
	if msc1_props | grep -q 'cap-sd-highspeed;' && msc1_props | grep -q 'cap-sdio-irq;' \
		&& grep -q 'backlight-probe-diag' "$DTS"; then
		pass
	else
		fail "W3 then DIAG1 did not compose - msc1 props: $(msc1_props | tr '\n' ' '); backlight node present: $(grep -c 'backlight-probe-diag' "$DTS")"
	fi
	sh "$BACKLIGHT_SCRIPT" DIAG0 >/dev/null 2>&1
	sh "$VARIANT_SCRIPT" W0 >/dev/null

	# Order B: DIAG1 then W3 - same requirement, reversed order.
	sh "$BACKLIGHT_SCRIPT" DIAG1 >/dev/null
	sh "$VARIANT_SCRIPT" W3 >/dev/null
	if msc1_props | grep -q 'cap-sd-highspeed;' && msc1_props | grep -q 'cap-sdio-irq;' \
		&& grep -q 'backlight-probe-diag' "$DTS"; then
		pass
	else
		fail "DIAG1 then W3 did not compose - msc1 props: $(msc1_props | tr '\n' ' '); backlight node present: $(grep -c 'backlight-probe-diag' "$DTS")"
	fi
	sh "$VARIANT_SCRIPT" W0 >/dev/null
	sh "$BACKLIGHT_SCRIPT" DIAG0 >/dev/null 2>&1
else
	echo "SKIP: $BACKLIGHT_SCRIPT not present, skipping cross-script composability test"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
