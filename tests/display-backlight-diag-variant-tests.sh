#!/bin/sh
#
# Offline, repeatable tests for scripts/build/display-backlight-diag-variant.sh
# (DISPLAY-B0-DIAG prototype, display hardware analysis mission follow-on,
# 2026-08-01+). Operates against the real vendor kernel checkout's tracked
# source/DTS files and the tracked Kconfig fragment.
#
# These tests prove what is provable OFFLINE, by source inspection and
# compile-time structure alone: that the toggle script is idempotent, that
# the patch adds exactly the documented safeguards, and that specific
# dangerous patterns (e.g. calling pwm_apply_state()/gpiod_direction_output()
# from probe()) are absent. They do NOT and CANNOT prove that the safeguards
# behave correctly on real hardware at runtime (e.g. that the workqueue
# timer really fires, that a real PWM/GPIO write really takes effect, that
# a killed shell really cannot block the restore) - see the mission's final
# report for which claims remain SUPPORTED_INFERENCE vs PROVEN_BY_COMPILE_TEST
# vs requiring live hardware.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/display-backlight-diag-variant.sh.
#
# Usage: sh tests/display-backlight-diag-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/display-backlight-diag-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_probe_diag.c"
DRIVER="$KERNEL_DIR/$DRIVER_REL"
AFFECTED_FILES="kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig kernel/kernel-6.6/module_drivers/drivers/misc/Makefile $DTS_REL"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: display-backlight-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: display-backlight-diag-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_KERNEL_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_KERNEL_SNAPSHOT/$f"
done
PRETEST_DRIVER_EXISTED=0
[ -f "$DRIVER" ] && PRETEST_DRIVER_EXISTED=1

cleanup() {
	cp "$PRETEST_FRAGMENT" "$FRAGMENT"
	for f in $AFFECTED_FILES; do
		cp "$PRETEST_KERNEL_SNAPSHOT/$f" "$KERNEL_DIR/$f"
	done
	if [ "$PRETEST_DRIVER_EXISTED" = "0" ]; then
		rm -f "$DRIVER"
	fi
	rm -f "$PRETEST_FRAGMENT"
	rm -rf "$PRETEST_KERNEL_SNAPSHOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Test 1: DIAG0 leaves the affected files git-clean, no driver file,
# no fragment block. ---
sh "$VARIANT_SCRIPT" DIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "DIAG0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "DIAG0 left the diagnostic driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_PROBE_DIAG' "$FRAGMENT"; then
	fail "DIAG0 left CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG in the fragment"
else
	pass
fi

# --- Test 2: DIAG1 applies the patch - driver file created, Kconfig
# option added to source, fragment selects it exactly once. ---
sh "$VARIANT_SCRIPT" DIAG1 >/dev/null
if [ -f "$DRIVER" ]; then
	pass
else
	fail "DIAG1 did not create $DRIVER_REL"
fi
if grep -q 'config NEBULAOS_BACKLIGHT_PROBE_DIAG' \
	"$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig"; then
	pass
else
	fail "DIAG1 did not add the NEBULAOS_BACKLIGHT_PROBE_DIAG Kconfig option to source"
fi
count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "DIAG1 produced $count CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y lines, expected exactly 1"
fi

# --- Test 3: DIAG1 adds exactly one DT node referencing the candidate PWM
# channel 0 and repoints &pwm away from the unused channel-1 pin. ---
node_count=$(grep -c 'nebulaos_backlight_diag: nebulaos_backlight_diag' "$DTS")
if [ "$node_count" = "1" ]; then
	pass
else
	fail "DIAG1 produced $node_count nebulaos_backlight_diag nodes, expected exactly 1"
fi
if grep -q 'compatible = "nebulaos,backlight-probe-diag"' "$DTS" && \
   grep -q 'pwms = <&pwm 0 20000>;' "$DTS"; then
	pass
else
	fail "DIAG1's DT node does not reference the candidate PWM channel 0/20000ns period"
fi
if grep -q 'pinctrl-0 = <&pwm0_pc>;' "$DTS" && ! grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS"; then
	pass
else
	fail "DIAG1 did not repoint &pwm to pwm0_pc, or left a stale pwm1_pc reference"
fi

# --- Test 4: source inspection - probe() never applies PWM/GPIO state,
# only reads it. The probe() function body (nebulaos_bl_diag_probe, up to
# its closing brace) must contain pwm_get_state() but must NOT contain
# pwm_apply_state()/gpiod_direction_output()/gpiod_set_raw_value_cansleep(). ---
probe_body=$(awk '/^static int nebulaos_bl_diag_probe/,/^}/' "$DRIVER")
# Strip comment lines first (this check must look only at real code, not
# at comments that happen to mention the very calls they warn against).
probe_code_only=$(echo "$probe_body" | grep -v '^[[:space:]]*\*' | grep -v '/\*')
if echo "$probe_code_only" | grep -q 'pwm_get_state'; then
	pass
else
	fail "nebulaos_bl_diag_probe() does not call pwm_get_state() - cannot confirm it only reads state"
fi
if echo "$probe_code_only" | grep -Eq 'pwm_apply_state|gpiod_direction_output|gpiod_set_raw_value_cansleep'; then
	fail "nebulaos_bl_diag_probe() applies PWM/GPIO state at bind time - this must never happen"
else
	pass
fi

# --- Test 5: source inspection - only 25/50/75 duty values are ever
# accepted; 0 and 100 are never present as accepted command literals.
# UPDATED (command-interface hardening pass, 2026-08-xx): the old
# free-form "probe pwm <value>" grammar (kind/value string pair) was
# replaced by 5 fixed whole-command literals - "probe-pwm-25/50/75" map
# directly to a dispatcher call with a fixed int duty argument, so the
# original !strcmp(value, "25")-style check no longer applies verbatim.
# This is intentional, not a regression - re-verified here against the
# new grammar instead. ---
if grep -q '"probe-pwm-25"' "$DRIVER" && \
   grep -q '"probe-pwm-50"' "$DRIVER" && \
   grep -q '"probe-pwm-75"' "$DRIVER"; then
	pass
else
	fail "the driver does not recognize exactly the probe-pwm-25/50/75 command literals"
fi
if grep -Eq '"probe-pwm-0"|"probe-pwm-100"|"probe-enable-0"|"probe-enable-100"' "$DRIVER"; then
	fail "the driver source contains a probe-pwm-0/probe-pwm-100 command literal - 0%/100% must never be an accepted request"
else
	pass
fi
# The dispatcher must never resolve to a value outside {25,50,75} even
# defensively - nebulaos_bl_diag_cmd_probe()'s own duty-value guard must
# still explicitly exclude everything else.
if grep -q 'value != 25 && value != 50 && value != 75' "$DRIVER"; then
	pass
else
	fail "nebulaos_bl_diag_cmd_probe() does not defensively reject any duty value outside {25,50,75}"
fi

# --- Test 6: source inspection - overlapping probes are rejected before
# any hardware is touched (probe_active checked, -EBUSY returned). ---
if grep -q 'diag->probe_active) {' "$DRIVER" && grep -q '\-EBUSY' "$DRIVER"; then
	pass
else
	fail "the driver does not reject an overlapping probe with -EBUSY"
fi

# --- Test 7: source inspection - the fixed probe duration is bounds-
# checked. UPDATED (command-interface hardening pass, 2026-08-xx): the
# debugfs interface no longer accepts ANY caller-supplied timeout
# argument at all (see the "COMMAND WHITELIST" section - every probe-*
# command takes zero arguments), so there is no longer a runtime
# "timeout_ms < MIN ||" branch to bounds-check a user value against - the
# mission's "no arbitrary timeout" requirement is now satisfied by
# construction (Test 11 below), not by a runtime rejection branch. What
# replaces it: a compile-time static_assert() proving
# NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS (the ONLY duration any probe can
# ever use) is itself within [MIN,MAX] - an equally rigorous guarantee,
# enforced by the compiler instead of a runtime branch no caller can ever
# reach. ---
if grep -q 'NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS' "$DRIVER" && \
   grep -q 'NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS' "$DRIVER" && \
   grep -q 'static_assert(NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS >= NEBULAOS_BL_DIAG_MIN_TIMEOUT_MS &&' "$DRIVER"; then
	pass
else
	fail "the driver does not compile-time bounds-check the fixed probe duration against [MIN,MAX]"
fi

# --- Test 8: source inspection - the auto-restore path is a kernel
# workqueue (delayed_work), armed at probe time, independent of any
# calling process. ---
if grep -q 'INIT_DELAYED_WORK(&diag->restore_work, nebulaos_bl_diag_restore_work)' "$DRIVER" && \
   grep -q 'schedule_delayed_work(&diag->restore_work, msecs_to_jiffies(timeout_ms))' "$DRIVER"; then
	pass
else
	fail "the driver does not arm a kernel-owned delayed_work timer for auto-restore"
fi

# --- Test 9: source inspection - remove() forces a synchronous restore
# if a probe is still active, so unbinding never leaves hardware probed. ---
remove_body=$(awk '/^static int nebulaos_bl_diag_remove/,/^}/' "$DRIVER")
if echo "$remove_body" | grep -q 'cancel_delayed_work_sync' && \
   echo "$remove_body" | grep -q 'nebulaos_bl_diag_do_restore'; then
	pass
else
	fail "nebulaos_bl_diag_remove() does not force a restore of any still-active probe"
fi

# --- Test 10: hardening pass - the mission-mandated bounds are exactly
# default=2000ms, max=3000ms (not the prior revision's 3000/10000). ---
if grep -q '^#define NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS[[:space:]]*2000$' "$DRIVER" && \
   grep -q '^#define NEBULAOS_BL_DIAG_MAX_TIMEOUT_MS[[:space:]]*3000$' "$DRIVER"; then
	pass
else
	fail "the driver does not enforce default=2000ms/max=3000ms exactly"
fi

probe_cmd_body=$(awk '/^static int nebulaos_bl_diag_cmd_probe/,/^}/' "$DRIVER")

# --- Test 11: hardening pass - an arbitrary/unbounded timeout (or any
# other trailing argument - a GPIO/channel number, a duty cycle, a
# period) can never reach the probe logic at all. UPDATED (command-
# interface hardening pass, 2026-08-xx): the old free-form grammar's
# per-request runtime bounds-check ("timeout_ms > MAX ... before
# mutex_lock()") no longer exists because there is no longer any
# caller-supplied timeout to check - proving THAT absence is a stronger
# claim than re-proving a now-nonexistent runtime branch. Source-
# inspection proof: nebulaos_bl_diag_command_write() rejects any command
# write with a trailing token (the "rest && *rest" whitelist-enforcement
# check) BEFORE the if/else-if command-dispatch chain that would call
# nebulaos_bl_diag_cmd_probe() at all - so "probe-pwm-25 9999",
# "probe-pwm-25 <channel>", or any other trailing argument is rejected
# with -EINVAL at the parser level, never reaching probe logic in the
# first place. ---
command_write_body=$(awk '/^static ssize_t nebulaos_bl_diag_command_write/,/^}/' "$DRIVER")
whitelist_check_line=$(echo "$command_write_body" | grep -n 'if (rest && \*rest)' | head -1 | cut -d: -f1)
dispatch_line=$(echo "$command_write_body" | grep -n 'if (!strcmp(cmd, "status"))' | head -1 | cut -d: -f1)
if [ -n "$whitelist_check_line" ] && [ -n "$dispatch_line" ] && [ "$whitelist_check_line" -lt "$dispatch_line" ]; then
	pass
else
	fail "a trailing argument (arbitrary timeout/GPIO/channel/duty/period) is not rejected before command dispatch"
fi
# kstrtouint() - the old free-form timeout parser - must no longer be
# CALLED anywhere in the file (comments are allowed to mention it, e.g.
# to explain that it's gone - only look at real code, same
# comment-stripping convention Test 4 uses).
driver_no_comments=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')
if echo "$driver_no_comments" | grep -q 'kstrtouint('; then
	fail "the driver still calls kstrtouint() - an arbitrary caller-supplied numeric argument could be smuggled through"
else
	pass
fi

# --- Test 12: hardening pass - ARM-BEFORE-APPLY ordering. Within
# nebulaos_bl_diag_cmd_probe(), schedule_delayed_work() (arming the
# kernel-owned watchdog) must appear BEFORE both hardware-apply calls
# (pwm_apply_state()/gpiod_set_raw_value_cansleep() for the candidate
# state - the gpiod_get_raw_value_cansleep() capture call doesn't count,
# only the later *_set_* apply call does). A crash between "apply" and
# "arm" must never be possible - this was a real bug in an earlier
# revision (apply-then-arm) fixed in this hardening pass. ---
arm_line=$(echo "$probe_cmd_body" | grep -n 'schedule_delayed_work(&diag->restore_work' | head -1 | cut -d: -f1)
apply_gpio_line=$(echo "$probe_cmd_body" | grep -n 'gpiod_set_raw_value_cansleep(diag->enable_gpio, gpio_val)' | head -1 | cut -d: -f1)
apply_pwm_line=$(echo "$probe_cmd_body" | grep -n 'pwm_apply_state(diag->pwm, &new_state)' | head -1 | cut -d: -f1)
if [ -n "$arm_line" ] && [ -n "$apply_gpio_line" ] && [ -n "$apply_pwm_line" ] && \
   [ "$arm_line" -lt "$apply_gpio_line" ] && [ "$arm_line" -lt "$apply_pwm_line" ]; then
	pass
else
	fail "schedule_delayed_work() does not precede both hardware-apply calls in nebulaos_bl_diag_cmd_probe() - arm-before-apply ordering is violated"
fi

# --- Test 13: hardening pass - if pwm_apply_state() fails after the
# watchdog was already armed (per Test 12's ordering), the failure branch
# must unwind by canceling that timer. It must use the NON-blocking
# cancel_delayed_work() (not cancel_delayed_work_sync()) while diag->lock
# is still held - calling the blocking _sync() variant under the lock
# risks deadlocking against a concurrently-running watchdog callback
# blocked on the same lock, and calling it AFTER unlocking (an earlier
# revision's approach) reopened a TOCTOU race where a second thread's
# freshly-scheduled probe on the same delayed_work object could be wiped
# out by this cancel instead. Both the correct call and the two
# documented rationales must be present. ---
if echo "$probe_cmd_body" | grep -A2 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -q 'return ret;' && \
   echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -q '^[[:space:]]*cancel_delayed_work(&diag->restore_work);$' && \
   echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | grep -qi 'TOCTOU'; then
	pass
else
	fail "the pwm_apply_state() failure path does not correctly unwind the already-armed watchdog timer with the documented non-blocking cancel + TOCTOU rationale"
fi
# The failure path's actual CODE (not the comments explaining why the
# blocking variant was rejected) must not call cancel_delayed_work_sync().
failure_unwind_code_only=$(echo "$probe_cmd_body" | grep -B40 'dev_err(diag->dev, "probe pwm %d%% failed to apply' | \
	grep -v '^[[:space:]]*\*' | grep -v '^[[:space:]]*/\*')
if echo "$failure_unwind_code_only" | grep -q 'cancel_delayed_work_sync'; then
	fail "the pwm_apply_state() failure path uses the blocking cancel_delayed_work_sync() under the lock - reintroduces a deadlock/TOCTOU risk"
else
	pass
fi

# --- Test 14: hardening pass - no arbitrary PWM channel or GPIO number
# can ever be requested through the debugfs interface. The two hardware
# handles (diag->pwm, diag->enable_gpio) must be acquired exactly once
# each, both inside nebulaos_bl_diag_probe() (module bind), and never
# from the command-write path. ---
driver_code_only=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')
pwm_get_count=$(echo "$driver_code_only" | grep -c 'devm_pwm_get(')
gpio_get_count=$(echo "$driver_code_only" | grep -c 'devm_gpiod_get_optional(')
probe_fn_body=$(awk '/^static int nebulaos_bl_diag_probe\(struct platform_device/,/^}/' "$DRIVER")
if [ "$pwm_get_count" = "1" ] && [ "$gpio_get_count" = "1" ] && \
   echo "$probe_fn_body" | grep -q 'devm_pwm_get(' && \
   echo "$probe_fn_body" | grep -q 'devm_gpiod_get_optional('; then
	pass
else
	fail "the candidate PWM/GPIO handles are not acquired exactly once, at module bind time only"
fi
if echo "$probe_cmd_body" | grep -Eq 'devm_pwm_get|devm_gpiod_get|gpio_to_desc|pwm_request'; then
	fail "nebulaos_bl_diag_cmd_probe() itself acquires a PWM/GPIO handle - this would allow requesting an arbitrary channel/GPIO"
else
	pass
fi

# --- Test 15: hardening pass - honest restoration-exactness reporting.
# UPDATED (PWM state readback cross-module wiring pass, 2026-08-xx): the
# debugfs status output's pwm_restore_is_exact field is no longer a
# hardcoded "0" literal - it is now a live "%d" formatted from a real
# function call (see Test 20/21 below for proof it genuinely branches).
# The old exact-hardcoded-"0" string can no longer appear; what must
# appear instead is the dynamic format plus both exactness sections in
# the file header. ---
if grep -q '"pwm_restore_is_exact: %d\\n"' "$DRIVER" && \
   grep -q 'gpio_restore_is_exact' "$DRIVER" && \
   grep -q 'RESTORATION EXACTNESS' "$DRIVER" && \
   grep -q 'PWM-EXACTNESS GATE' "$DRIVER"; then
	pass
else
	fail "the driver does not expose a live pwm_restore_is_exact/gpio_restore_is_exact status field with a documented rationale"
fi
if grep -q '"pwm_restore_is_exact: 0\\n"' "$DRIVER"; then
	fail "the driver still hardcodes 'pwm_restore_is_exact: 0' as a literal string - it must be a live, computed value now"
else
	pass
fi

# --- Test 16: hardening pass - the file must NOT claim the PWM restore
# path unconditionally reads real hardware state. The known-dishonest
# phrase from an earlier revision ("reads the descriptor's cached/
# hardware state", implying a genuine register read for PWM) must not
# reappear, and the header must instead explain that whether
# pwm_get_state() returns real hardware content depends on
# pwm-ingenic-v2.c's .get_state callback (now real under
# CONFIG_PWM_INGENIC_V2_GET_STATE, per the PWM state readback mission). ---
if grep -q 'reads the descriptor.s cached/hardware state' "$DRIVER"; then
	fail "the driver still contains the overclaiming 'cached/hardware state' phrasing for the PWM restore path"
else
	pass
fi
if grep -q 'apply callback' "$DRIVER" && grep -q 'get_state callback' "$DRIVER"; then
	pass
else
	fail "the driver does not explain pwm-ingenic-v2.c's .apply/.get_state history for the PWM restoration path"
fi

# --- Test 20: command-interface hardening pass - the debugfs command
# parser recognizes EXACTLY the 9 mission-whitelisted literal commands,
# each dispatched by an exact !strcmp() against the fixed string. ---
command_write_body=$(awk '/^static ssize_t nebulaos_bl_diag_command_write/,/^}/' "$DRIVER")
whitelist_ok=1
for word in status arm disarm restore probe-enable-low probe-enable-high probe-pwm-25 probe-pwm-50 probe-pwm-75; do
	if ! echo "$command_write_body" | grep -q "!strcmp(cmd, \"$word\")"; then
		whitelist_ok=0
		fail "nebulaos_bl_diag_command_write() does not dispatch the whitelisted command \"$word\""
	fi
done
[ "$whitelist_ok" = "1" ] && pass

# --- Test 21: command-interface hardening pass - the OLD free-form
# "probe <kind> <value> [timeout]" grammar is completely gone: there is
# no remaining dispatch on a bare "probe" command word, and no remaining
# string comparison against a separately-parsed "kind"/"value" argument
# (the mechanism that used to allow an arbitrary-looking two-token
# request). This is what makes an arbitrary GPIO number, PWM channel,
# duty cycle, or period structurally impossible now, not just
# discouraged. ---
if echo "$command_write_body" | grep -q '!strcmp(cmd, "probe")'; then
	fail "the driver still dispatches the old free-form \"probe\" command word - the whitelist is not exclusive"
else
	pass
fi
if grep -Eq '!strcmp\(kind,|!strcmp\(value,' "$DRIVER"; then
	fail "the driver still parses a separate kind/value argument pair - an arbitrary GPIO/channel/duty/period could be smuggled through"
else
	pass
fi

# --- Test 22: command-interface hardening pass - persistent/unbounded
# probe mode is impossible: nebulaos_bl_diag_cmd_probe() always schedules
# the watchdog for exactly NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS (the only
# value "timeout_ms" can ever hold now - Test 11 already proved no
# caller-supplied value can reach this function at all). ---
if echo "$probe_cmd_body" | grep -q 'unsigned int timeout_ms = NEBULAOS_BL_DIAG_DEFAULT_TIMEOUT_MS;' && \
   echo "$probe_cmd_body" | grep -q 'schedule_delayed_work(&diag->restore_work, msecs_to_jiffies(timeout_ms));'; then
	pass
else
	fail "nebulaos_bl_diag_cmd_probe() does not always use the fixed default timeout - persistent/unbounded probe mode may be reachable"
fi

# --- Test 23: diagnostic-level arm/disarm gate - disarmed by default at
# every boot/bind (zero hardware-state change either way), and a probe is
# rejected with -EPERM while disarmed. ---
probe_fn_body=$(awk '/^static int nebulaos_bl_diag_probe\(struct platform_device/,/^}/' "$DRIVER")
if echo "$probe_fn_body" | grep -q 'diag->diag_armed = false;'; then
	pass
else
	fail "nebulaos_bl_diag_probe() (module bind) does not default diag_armed to false"
fi
if echo "$probe_cmd_body" | grep -q '!diag->diag_armed' && echo "$probe_cmd_body" | grep -q '\-EPERM'; then
	pass
else
	fail "nebulaos_bl_diag_cmd_probe() does not reject a disarmed diagnostic with -EPERM"
fi
# The disarmed-gate check must run before any hardware capture (Step 1) -
# same "reject before touching anything" discipline as every other check
# in this function.
armed_check_line=$(echo "$probe_cmd_body" | grep -n '!diag->diag_armed' | head -1 | cut -d: -f1)
step1_line=$(echo "$probe_cmd_body" | grep -n 'Step 1: capture prior state' | head -1 | cut -d: -f1)
if [ -n "$armed_check_line" ] && [ -n "$step1_line" ] && [ "$armed_check_line" -lt "$step1_line" ]; then
	pass
else
	fail "the disarmed-diagnostic rejection does not run before the probe captures/touches any hardware state"
fi

# --- Test 24: "arm"/"disarm" commands themselves - arm sets diag_armed,
# disarm forces an immediate synchronous restore of any active probe
# (fail-safe) before clearing diag_armed. ---
disarm_body=$(awk '/^static int nebulaos_bl_diag_cmd_disarm/,/^}/' "$DRIVER")
arm_body=$(awk '/^static int nebulaos_bl_diag_cmd_arm/,/^}/' "$DRIVER")
if echo "$arm_body" | grep -q 'diag->diag_armed = true;'; then
	pass
else
	fail "nebulaos_bl_diag_cmd_arm() does not set diag_armed = true"
fi
if echo "$disarm_body" | grep -q 'cancel_delayed_work_sync(&diag->restore_work);' && \
   echo "$disarm_body" | grep -q 'nebulaos_bl_diag_do_restore(diag, false);' && \
   echo "$disarm_body" | grep -q 'diag->diag_armed = false;'; then
	pass
else
	fail "nebulaos_bl_diag_cmd_disarm() does not force-restore any active probe before clearing diag_armed"
fi

# --- Test 25: PWM-exactness gate (closes the TODOs from the PWM state
# readback mission) - nebulaos_bl_diag_pwm_restore_is_exact() genuinely
# calls the real exported ingenic_pwm_channel_get_state_is_exact() when
# CONFIG_PWM_INGENIC_V2_GET_STATE is selected, and returns false (never
# true) in the #else fallback branch when it is not - proving this is a
# real, live branch on the underlying driver's answer, not a hardcoded
# constant either way. ---
pwm_exact_fn_body=$(awk '/^static bool nebulaos_bl_diag_pwm_restore_is_exact/,/^}/' "$DRIVER")
if echo "$pwm_exact_fn_body" | grep -q '#ifdef CONFIG_PWM_INGENIC_V2_GET_STATE' && \
   echo "$pwm_exact_fn_body" | grep -q 'return ingenic_pwm_channel_get_state_is_exact(chip, diag->pwm->hwpwm);' && \
   echo "$pwm_exact_fn_body" | grep -q '#else' && \
   echo "$pwm_exact_fn_body" | grep -q 'return false;'; then
	pass
else
	fail "nebulaos_bl_diag_pwm_restore_is_exact() does not genuinely branch on the real exported capability query"
fi
# The #else (config-not-selected) branch must be the ONLY return in that
# arm, and it must never be "true" - the safe fallback is always "refuse
# to arm", never "assume exact".
else_branch=$(echo "$pwm_exact_fn_body" | awk '/#else/,/#endif/')
if echo "$else_branch" | grep -q 'return true;'; then
	fail "the CONFIG_PWM_INGENIC_V2_GET_STATE-unselected fallback returns true somewhere - must always conservatively return false"
else
	pass
fi

# --- Test 26: the exactness gate is genuinely called - and enforced -
# from nebulaos_bl_diag_cmd_probe(), rejecting with -EOPNOTSUPP BEFORE
# any hardware is captured/touched (Step 1), for both probe types (the
# gate dispatches per-type via nebulaos_bl_diag_probe_type_restore_is_exact()
# rather than only ever checking one resource). ---
if echo "$probe_cmd_body" | grep -q 'nebulaos_bl_diag_probe_type_restore_is_exact(diag, type)' && \
   echo "$probe_cmd_body" | grep -q '\-EOPNOTSUPP'; then
	pass
else
	fail "nebulaos_bl_diag_cmd_probe() does not call the real per-type exactness gate and reject with -EOPNOTSUPP"
fi
gate_check_line=$(echo "$probe_cmd_body" | grep -n 'nebulaos_bl_diag_probe_type_restore_is_exact(diag, type)' | head -1 | cut -d: -f1)
if [ -n "$gate_check_line" ] && [ -n "$step1_line" ] && [ "$gate_check_line" -lt "$step1_line" ]; then
	pass
else
	fail "the PWM-exactness gate does not run before the probe captures/touches any hardware state"
fi
# nebulaos_bl_diag_probe_type_restore_is_exact() itself must dispatch to
# the two distinct real per-resource checks, not a single hardcoded
# answer for every type.
dispatch_fn_body=$(awk '/^static bool nebulaos_bl_diag_probe_type_restore_is_exact/,/^}/' "$DRIVER")
if echo "$dispatch_fn_body" | grep -q 'nebulaos_bl_diag_gpio_restore_is_exact(diag)' && \
   echo "$dispatch_fn_body" | grep -q 'nebulaos_bl_diag_pwm_restore_is_exact(diag)'; then
	pass
else
	fail "nebulaos_bl_diag_probe_type_restore_is_exact() does not dispatch to distinct real per-resource checks"
fi

# --- Test 27: the exported cross-module symbol name/signature this
# driver consumes matches exactly what pwm-ingenic-v2.c actually exports
# (ingenic_pwm_channel_get_state_is_exact(struct pwm_chip *, unsigned
# int)) - guarding against a silently-mismatched extern declaration that
# would still compile (implicit int / mismatched signature warnings
# aside) but call the wrong thing. ---
if grep -q 'extern bool ingenic_pwm_channel_get_state_is_exact(struct pwm_chip \*chip, unsigned int channel);' "$DRIVER"; then
	pass
else
	fail "the driver's extern declaration of ingenic_pwm_channel_get_state_is_exact() does not match pwm-ingenic-v2.c's real signature"
fi

# --- Test 17: re-applying DIAG1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" DIAG1 >/dev/null 2>&1; then
	node_count=$(grep -c 'nebulaos_backlight_diag: nebulaos_backlight_diag' "$DTS")
	frag_count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG=y$' "$FRAGMENT")
	if [ "$node_count" = "1" ] && [ "$frag_count" = "1" ]; then
		pass
	else
		fail "re-applying DIAG1 produced $node_count DT nodes / $frag_count fragment lines, expected exactly 1 each"
	fi
else
	fail "re-applying DIAG1 a second time failed - not idempotent"
fi

# --- Test 18: switching from DIAG1 back to DIAG0 restores clean affected
# files, removes the driver file, and empties the fragment block. ---
sh "$VARIANT_SCRIPT" DIAG0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from DIAG1 back to DIAG0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "switching from DIAG1 back to DIAG0 left the diagnostic driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_PROBE_DIAG' "$FRAGMENT"; then
	fail "switching from DIAG1 back to DIAG0 left CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG in the fragment"
else
	pass
fi

# --- Test 19: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" DIAG9 >/dev/null 2>&1; then
	fail "an unknown variant name 'DIAG9' was accepted instead of rejected"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
