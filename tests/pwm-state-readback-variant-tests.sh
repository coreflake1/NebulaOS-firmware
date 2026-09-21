#!/bin/sh
#
# Offline, repeatable tests for scripts/build/pwm-state-readback-variant.sh
# (NebulaOS PWM state readback mission, 2026-08-xx - see
# docs/NEBULAOS_PWM_STATE_READBACK_REPORT.md). Same pattern as
# tests/touch-qualification-variant-tests.sh: toggle-script round trip +
# structural (grep/awk) assertions against the patched source, plus a
# genuine host-executable arithmetic round-trip test
# (pwm-state-readback-roundtrip.c) that this suite compiles and runs
# natively.
#
# HONESTY NOTE: the structural (grep/awk) assertions below prove the
# patched source *contains* the described logic; they do not execute
# kernel code (that requires the mipsel cross-toolchain and can't run on
# this host). The compiled/executed C round-trip test
# (pwm-state-readback-roundtrip.c) genuinely runs the same tick<->ns and
# WCFG encode/decode arithmetic natively and checks real numeric results -
# see that file's own header for exactly what it does and does not prove.
# The real kernel object file compile test (module_drivers/drivers/pwm/
# pwm-ingenic-v2.o, via this project's docker cross-compile pattern, both
# with and without CONFIG_PWM_INGENIC_V2_GET_STATE selected) was performed
# separately and is reported in docs/NEBULAOS_PWM_STATE_READBACK_REPORT.md
# and the commit message - it is not re-run by this script (no docker
# dependency here, matching touch-qualification-variant-tests.sh's own
# convention of keeping the routine test suite docker-free).
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/pwm-state-readback-variant.sh.
#
# Usage: sh tests/pwm-state-readback-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/pwm-state-readback-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
PATCH="$REPO_ROOT/scripts/build/patches/pwm-ingenic-v2-get-state.patch"
AFFECTED_FILES="kernel/kernel-6.6/module_drivers/drivers/pwm/Kconfig kernel/kernel-6.6/module_drivers/drivers/pwm/pwm-ingenic-v2.c"
PWMC="$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/pwm/pwm-ingenic-v2.c"
PWM_KCONFIG="$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/pwm/Kconfig"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: pwm-state-readback-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: pwm-state-readback-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
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

# --- Test 1: GETSTATE0 leaves the affected files git-clean and no
# fragment block/marker. ---
sh "$VARIANT_SCRIPT" GETSTATE0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "GETSTATE0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_PWM_INGENIC_V2_GET_STATE' "$FRAGMENT"; then
	fail "GETSTATE0 left CONFIG_PWM_INGENIC_V2_GET_STATE in the fragment"
else
	pass
fi

# --- Test 2: GETSTATE1 applies the patch and selects the option exactly
# once. ---
sh "$VARIANT_SCRIPT" GETSTATE1 >/dev/null
if grep -q 'config PWM_INGENIC_V2_GET_STATE' "$PWM_KCONFIG"; then
	pass
else
	fail "GETSTATE1 did not add the PWM_INGENIC_V2_GET_STATE Kconfig option to source"
fi
count=$(grep -c '^CONFIG_PWM_INGENIC_V2_GET_STATE=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "GETSTATE1 produced $count CONFIG_PWM_INGENIC_V2_GET_STATE=y lines, expected exactly 1"
fi

# --- Test 3: .get_state is wired into ingenic_pwm_ops, gated behind the
# new Kconfig option (so GETSTATE0 stays byte-for-byte identical). ---
ops_body=$(awk '/^static const struct pwm_ops ingenic_pwm_ops/,/^};/' "$PWMC")
if echo "$ops_body" | grep -q '\.apply = ingenic_pwm_apply' && \
   echo "$ops_body" | grep -q '\.get_state = ingenic_pwm_get_state' && \
   echo "$ops_body" | grep -q '#ifdef CONFIG_PWM_INGENIC_V2_GET_STATE'; then
	pass
else
	fail "ingenic_pwm_ops does not wire .get_state behind CONFIG_PWM_INGENIC_V2_GET_STATE"
fi

# --- Test 4: ingenic_pwm_get_state() reads the three real hardware
# registers the report identifies (PWM_EN via pwm_enable_status(),
# PWM_INITR, PWM_WCFG) - not fabricated/hardcoded values. ---
get_state_body=$(awk '/^static int ingenic_pwm_get_state/,/^}/' "$PWMC")
if [ -z "$get_state_body" ]; then
	fail "could not extract ingenic_pwm_get_state()'s function body"
else
	if echo "$get_state_body" | grep -q 'pwm_enable_status(ingenic_pwm)' && \
	   echo "$get_state_body" | grep -q 'pwm_readl(ingenic_pwm, PWM_INITR)' && \
	   echo "$get_state_body" | grep -q 'PWM_WCFG + channel \* 4'; then
		pass
	else
		fail "ingenic_pwm_get_state() does not read all three expected registers (PWM_EN/PWM_INITR/PWM_WCFG)"
	fi
fi

# --- Test 5: the tick<->ns arithmetic is shared, not duplicated -
# ingenic_pwm_tick_ns() is defined exactly once, and both
# ingenic_pwm_config() (.apply) and ingenic_pwm_get_state() (.get_state)
# call it, so they cannot independently drift on the PRESCALE finding. ---
tick_ns_def_count=$(grep -c '^static unsigned long long ingenic_pwm_tick_ns' "$PWMC")
if [ "$tick_ns_def_count" = "1" ]; then
	pass
else
	fail "expected exactly 1 definition of ingenic_pwm_tick_ns(), found $tick_ns_def_count"
fi
config_body=$(awk '/^static int ingenic_pwm_config/,/^}/' "$PWMC")
if echo "$config_body" | grep -q 'ingenic_pwm_tick_ns(clk_in)' && \
   echo "$get_state_body" | grep -q 'ingenic_pwm_tick_ns('; then
	pass
else
	fail "ingenic_pwm_config() and/or ingenic_pwm_get_state() do not call the shared ingenic_pwm_tick_ns() helper"
fi

# --- Test 6: the PRESCALE finding is documented, not silently
# "corrected" - pwm_get_prescale()'s return value must still be read (for
# behavioral parity with the pristine .apply path) but the tick_ns helper
# must not take a prescale parameter fed from that readback (it uses only
# the compile-time PRESCALE constant, exactly like the pristine driver's
# own dead-code readback already did before this patch). ---
if grep -q 'prescale = pwm_get_prescale(ingenic_pwm, channel);' "$PWMC"; then
	pass
else
	fail "GETSTATE1 removed the pwm_get_prescale() readback - this changes behavior vs. the pristine .apply path"
fi
tick_ns_sig=$(grep '^static unsigned long long ingenic_pwm_tick_ns' "$PWMC")
if echo "$tick_ns_sig" | grep -Eq 'ingenic_pwm_tick_ns\(unsigned int clk_in\)$'; then
	pass
else
	fail "ingenic_pwm_tick_ns() signature changed from (unsigned int clk_in) - expected it to take only clk_in, not a live prescale value, per the documented PRESCALE finding"
fi

# --- Test 7: DMA_MODE handling never fabricates period/duty_cycle -
# the DMA_MODE branch inside ingenic_pwm_get_state() sets both to 0 and
# returns success (0), not an error (an error return would also discard
# the accurate enabled/polarity fields - see the report). ---
dma_branch=$(printf '%s\n' "$get_state_body" | awk '/mode_sel\[channel\] == DMA_MODE/,/^	}/')
if echo "$dma_branch" | grep -q 'state->period = 0;' && \
   echo "$dma_branch" | grep -q 'state->duty_cycle = 0;' && \
   echo "$dma_branch" | grep -q 'return 0;'; then
	pass
else
	fail "the DMA_MODE branch does not zero period/duty_cycle and return 0 (success)"
fi

# --- Test 8: the exactness query exists, is exported, and correctly
# keys off mode_sel[] != DMA_MODE - reused/extended naming convention
# from nebulaos_backlight_probe_diag.c's pwm_restore_is_exact/
# gpio_restore_is_exact fields (see the report). ---
if grep -q 'EXPORT_SYMBOL_GPL(ingenic_pwm_channel_get_state_is_exact)' "$PWMC" && \
   grep -q 'return ingenic_pwm->mode_sel\[channel\] != DMA_MODE;' "$PWMC"; then
	pass
else
	fail "ingenic_pwm_channel_get_state_is_exact() is missing, not exported, or does not key off mode_sel[] != DMA_MODE"
fi
if grep -q '__ATTR(get_state_exact, S_IRUGO, pwm_show_get_state_exact, NULL)' "$PWMC"; then
	pass
else
	fail "the get_state_exact sysfs attribute is not registered in pwm_device_attributes[]"
fi

# --- Test 9: the finish-level bit (PWM_INITR bit[channel+16]) is
# deliberately left unmodeled in get_state, per the report - a comment
# explaining that decision is expected and fine, but the function must
# not actually call pwm_set_finish_level() or otherwise touch that bit as
# code. ---
if echo "$get_state_body" | grep -q 'pwm_set_finish_level('; then
	fail "ingenic_pwm_get_state() calls pwm_set_finish_level() - the report says this bit must stay unmodeled/untouched by get_state"
else
	pass
fi

# --- Test 10: re-applying GETSTATE1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" GETSTATE1 >/dev/null 2>&1; then
	count=$(grep -c '^CONFIG_PWM_INGENIC_V2_GET_STATE=y$' "$FRAGMENT")
	if [ "$count" = "1" ]; then
		pass
	else
		fail "re-applying GETSTATE1 produced $count fragment lines, expected exactly 1 (not idempotent)"
	fi
else
	fail "re-applying GETSTATE1 a second time failed - not idempotent"
fi

# --- Test 11: switching from GETSTATE1 back to GETSTATE0 restores clean
# affected files and an empty fragment block. ---
sh "$VARIANT_SCRIPT" GETSTATE0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from GETSTATE1 back to GETSTATE0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if grep -q 'CONFIG_PWM_INGENIC_V2_GET_STATE' "$FRAGMENT"; then
	fail "switching from GETSTATE1 back to GETSTATE0 left CONFIG_PWM_INGENIC_V2_GET_STATE in the fragment"
else
	pass
fi

# --- Test 12: an unknown variant name is rejected, not silently
# applied. ---
if sh "$VARIANT_SCRIPT" GETSTATE9 >/dev/null 2>&1; then
	fail "an unknown variant name 'GETSTATE9' was accepted instead of rejected"
else
	pass
fi

# --- Test 13: the patch applies cleanly from a pristine checkout (a
# direct git apply --check, independent of the toggle script). ---
git -C "$KERNEL_DIR" checkout -- $AFFECTED_FILES >/dev/null 2>&1
if git -C "$KERNEL_DIR" apply --check "$PATCH" 2>/dev/null; then
	pass
else
	fail "$PATCH does not apply cleanly to a pristine checkout"
fi

# --- Test 14: the host-executable arithmetic round-trip test
# (pwm-state-readback-roundtrip.c) compiles and passes natively - see
# that file's own header for exactly what this does and does not prove. ---
ROUNDTRIP_SRC="$SCRIPT_DIR/pwm-state-readback-roundtrip.c"
ROUNDTRIP_BIN=$(mktemp)
[ -n "${ROUNDTRIP_BIN:-}" ] && [ -e "$ROUNDTRIP_BIN" ] || { echo "FATAL: pwm-state-readback-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
if cc -Wall -Wextra -O2 -o "$ROUNDTRIP_BIN" "$ROUNDTRIP_SRC" 2>/tmp/pwm-roundtrip-cc.log; then
	pass
else
	fail "pwm-state-readback-roundtrip.c failed to compile natively: $(cat /tmp/pwm-roundtrip-cc.log)"
fi
if [ -s /tmp/pwm-roundtrip-cc.log ]; then
	fail "pwm-state-readback-roundtrip.c produced compiler warnings: $(cat /tmp/pwm-roundtrip-cc.log)"
else
	pass
fi
if [ -x "$ROUNDTRIP_BIN" ] && "$ROUNDTRIP_BIN" >/tmp/pwm-roundtrip-run.log 2>&1; then
	pass
else
	fail "pwm-state-readback-roundtrip round-trip assertions failed: $(cat /tmp/pwm-roundtrip-run.log)"
fi
rm -f "$ROUNDTRIP_BIN" /tmp/pwm-roundtrip-cc.log /tmp/pwm-roundtrip-run.log

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
