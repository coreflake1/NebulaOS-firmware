#!/bin/sh
#
# Offline, repeatable tests for
# scripts/build/backlight-final-controller-variant.sh (DISPLAY-B-FINAL
# post-incident backlight controller redesign, 2026-08-02+). Operates
# against the real vendor kernel checkout's tracked source/DTS files and
# the tracked Kconfig fragment.
#
# These tests prove what is provable OFFLINE, by source inspection and
# compile-time structure alone: that the toggle script is idempotent, that
# it NEVER touches the shared &pwm node's own pinctrl-0 (the literal root
# cause of the real incident this driver's file header documents), that
# probe() never acquires GPC0/PC22/PWM0, that the state machine's
# transition-validity rules are enforced in source, and that the watchdog/
# restore discipline matches the same arm-before-apply ordering already
# proven correct for CONFIG_NEBULAOS_BACKLIGHT_PROBE_DIAG. They do NOT and
# CANNOT prove real hardware behavior - see the driver's own file header
# for what remains UNKNOWN_UNTIL_HARDWARE.
#
# IMPORTANT: do not run this suite while any build against the vendor
# kernel checkout is in flight - see the warning in
# scripts/build/backlight-final-controller-variant.sh.
#
# Usage: sh tests/backlight-final-controller-variant-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VARIANT_SCRIPT="$REPO_ROOT/scripts/build/backlight-final-controller-variant.sh"
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
DRIVER_REL="kernel/kernel-6.6/module_drivers/drivers/misc/nebulaos_backlight_final_controller.c"
DRIVER="$KERNEL_DIR/$DRIVER_REL"
AFFECTED_FILES="kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig kernel/kernel-6.6/module_drivers/drivers/misc/Makefile $DTS_REL"

PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { PASS=$((PASS + 1)); }

[ -f "$FRAGMENT" ] || { echo "SKIP: $FRAGMENT not present"; exit 0; }

PRETEST_FRAGMENT=$(mktemp)
[ -n "${PRETEST_FRAGMENT:-}" ] && [ -e "$PRETEST_FRAGMENT" ] || { echo "FATAL: backlight-final-controller-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
cp "$FRAGMENT" "$PRETEST_FRAGMENT"
PRETEST_KERNEL_SNAPSHOT=$(mktemp -d)
[ -n "${PRETEST_KERNEL_SNAPSHOT:-}" ] && [ -e "$PRETEST_KERNEL_SNAPSHOT" ] || { echo "FATAL: backlight-final-controller-variant-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
for f in $AFFECTED_FILES; do
	mkdir -p "$PRETEST_KERNEL_SNAPSHOT/$(dirname "$f")"
	cp "$KERNEL_DIR/$f" "$PRETEST_KERNEL_SNAPSHOT/$f"
done
PRETEST_DRIVER_EXISTED=0
[ -f "$DRIVER" ] && PRETEST_DRIVER_EXISTED=1
PRETEST_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")

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

# --- Test 1: FINAL0 leaves the affected files git-clean, no driver file,
# no fragment block. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "FINAL0 did not produce clean affected files: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "FINAL0 left the controller driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' "$FRAGMENT"; then
	fail "FINAL0 left CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER in the fragment"
else
	pass
fi

# --- Test 2: FINAL1 applies the patch - driver file created, Kconfig
# option added to source, fragment selects it exactly once. ---
sh "$VARIANT_SCRIPT" FINAL1 >/dev/null
if [ -f "$DRIVER" ]; then
	pass
else
	fail "FINAL1 did not create $DRIVER_REL"
fi
if grep -q 'config NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' \
	"$KERNEL_DIR/kernel/kernel-6.6/module_drivers/drivers/misc/Kconfig"; then
	pass
else
	fail "FINAL1 did not add the NEBULAOS_BACKLIGHT_FINAL_CONTROLLER Kconfig option to source"
fi
count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$' "$FRAGMENT")
if [ "$count" = "1" ]; then
	pass
else
	fail "FINAL1 produced $count CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y lines, expected exactly 1"
fi

# --- Test 3: FINAL1 adds exactly one DT node referencing the candidate
# PWM channel 0, GPC0-as-GPIO, and PC22. ---
node_count=$(grep -c 'nebulaos_backlight_final: nebulaos_backlight_final' "$DTS")
if [ "$node_count" = "1" ]; then
	pass
else
	fail "FINAL1 produced $node_count nebulaos_backlight_final nodes, expected exactly 1"
fi
if grep -q 'compatible = "nebulaos,backlight-final-controller"' "$DTS" && \
   grep -q 'pwms = <&pwm 0 20000>;' "$DTS" && \
   grep -q 'backlight-gpios = <&gpc 0 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;' "$DTS" && \
   grep -q 'enable-gpios = <&gpc 22 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;' "$DTS"; then
	pass
else
	fail "FINAL1's DT node does not reference the expected GPC0/PWM0/PC22 candidate properties"
fi

# --- Test 4: THE critical regression test for this whole redesign - the
# shared &pwm controller node's own pinctrl-0 property is BYTE-IDENTICAL
# before and after FINAL1 is applied (and after it is reverted). This is
# the literal root cause of the real incident this driver exists because
# of - see nebulaos_backlight_final_controller.c's file header. ---
POSTAPPLY_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
if [ "$PRETEST_PWM_BLOCK" = "$POSTAPPLY_PWM_BLOCK" ]; then
	pass
else
	fail "the &pwm node's own block changed after FINAL1 was applied - THIS IS THE EXACT BUG CLASS THAT CAUSED THE REAL INCIDENT. before:
$PRETEST_PWM_BLOCK
after:
$POSTAPPLY_PWM_BLOCK"
fi
if grep -q 'pinctrl-0 = <&pwm1_pc>;' "$DTS" && ! grep -q 'pinctrl-0 = <&pwm0_pc &pwm1_pc>;' "$DTS"; then
	pass
else
	fail "&pwm's pinctrl-0 no longer reads <&pwm1_pc> after FINAL1 - it must NEVER be repointed"
fi
# The new DT node's OWN pinctrl-0 (a different property, on a different
# node) is allowed and expected to reference pwm0_pc - that line existing
# somewhere in the file is fine; what must never happen is &pwm's own
# block containing it. Confirm the new node's own state name is NOT
# "default"/"init" (the only two names the device core auto-selects).
if grep -q 'pinctrl-names = "pwm-active";' "$DTS"; then
	pass
else
	fail "the new DT node's pinctrl-names is not the expected non-auto-selected \"pwm-active\""
fi
if sed -n '/nebulaos_backlight_final: nebulaos_backlight_final {/,/^	};/p' "$DTS" | \
   grep -Eq 'pinctrl-names = "(default|init)"'; then
	fail "the new DT node names its pinctrl state \"default\" or \"init\" - the device core's " \
		"automatic pinctrl_bind_pins() would select it at probe time, recreating the incident"
else
	pass
fi

# --- Test 5: source inspection - probe() never acquires GPC0/PC22/PWM0.
# The probe() function body must contain ZERO calls to
# gpiod_get()/devm_gpiod_get()/pwm_get()/devm_pwm_get()/
# pinctrl_get_select()/pinctrl_select_state() for any resource. ---
driver_no_comments=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')
probe_body=$(echo "$driver_no_comments" | awk '/^static int nblc_probe\(/,/^}/')
if [ -n "$probe_body" ]; then
	pass
else
	fail "could not extract nblc_probe() body"
fi
if echo "$probe_body" | grep -Eq 'gpiod_get|devm_gpiod_get|pwm_get|devm_pwm_get|pinctrl_get|pinctrl_select_state'; then
	fail "nblc_probe() acquires a GPIO/PWM/pinctrl resource at bind time - this must NEVER happen"
else
	pass
fi
if echo "$probe_body" | grep -q 'NBLC_STATE_BOOT_PRESERVE'; then
	pass
else
	fail "nblc_probe() does not initialize state to NBLC_STATE_BOOT_PRESERVE"
fi

# --- Test 6: source inspection - the ONLY three functions that may call
# gpiod_get()/pwm_get()/pinctrl_get_select() for GPC0/PC22/PWM0 are the
# explicit transition functions, never probe() and never the command
# dispatcher directly. ---
gpc0_gpiod_get_count=$(echo "$driver_no_comments" | grep -c 'gpiod_get(n->dev, "backlight"')
pc22_gpiod_get_count=$(echo "$driver_no_comments" | grep -c 'gpiod_get(n->dev, "enable"')
pinctrl_select_count=$(echo "$driver_no_comments" | grep -c 'pinctrl_get_select(n->dev, "pwm-active")')
if [ "$gpc0_gpiod_get_count" -ge 1 ] && [ "$pc22_gpiod_get_count" -ge 1 ] && [ "$pinctrl_select_count" -ge 1 ]; then
	pass
else
	fail "expected acquisition call sites for GPC0/PC22/pwm-active pinctrl not found " \
		"(gpc0=$gpc0_gpiod_get_count pc22=$pc22_gpiod_get_count pinctrl=$pinctrl_select_count)"
fi
# None of those calls may appear inside nblc_command_write() itself (the
# dispatcher) - only inside the dedicated per-operation functions it calls.
command_write_body=$(echo "$driver_no_comments" | awk '/^static ssize_t nblc_command_write/,/^}/')
if echo "$command_write_body" | grep -Eq 'gpiod_get\(|pwm_get\(|pinctrl_get_select\('; then
	fail "nblc_command_write() itself acquires a hardware resource - acquisition must be " \
		"confined to the dedicated transition functions"
else
	pass
fi

# --- Test 7: state-machine transition validity - pwm-active is only
# entered from safe-on (never boot-preserve or safe-off-test directly).
# safe-off-test is likewise only entered from safe-on. ---
pwm_active_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_pwm_active/,/^}/')
if echo "$pwm_active_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON' && \
   echo "$pwm_active_cmd_body" | grep -q '\-EPERM'; then
	pass
else
	fail "nblc_cmd_pwm_active() does not reject entry from any state other than safe-on"
fi
safe_off_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_safe_off_test/,/^}/')
if echo "$safe_off_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON' && \
   echo "$safe_off_cmd_body" | grep -q '\-EPERM'; then
	pass
else
	fail "nblc_cmd_safe_off_test() does not reject entry from any state other than safe-on"
fi

# --- Test 8: single-operation serialization - a second bounded operation
# is rejected with -EBUSY while one is already active, for all three
# bounded-operation entry points. ---
pc22_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_pc22_test/,/^}/')
for body_name in "pwm_active_cmd_body:$pwm_active_cmd_body" "safe_off_cmd_body:$safe_off_cmd_body" "pc22_cmd_body:$pc22_cmd_body"; do
	name=${body_name%%:*}
	body=${body_name#*:}
	if echo "$body" | grep -q 'n->active_op != NBLC_OP_NONE' && echo "$body" | grep -q '\-EBUSY'; then
		pass
	else
		fail "$name does not reject a second concurrent operation with -EBUSY"
	fi
done

# --- Test 9: watchdog-before-mutation ordering (same discipline
# nebulaos_backlight_probe_diag.c already established) - in each of the
# three bounded-operation entry points, schedule_delayed_work() must
# appear BEFORE the corresponding hardware-mutating call. ---
check_arm_before() {
	body="$1"; mutate_pattern="$2"; label="$3"
	arm_line=$(echo "$body" | grep -n 'schedule_delayed_work(&n->restore_work' | head -1 | cut -d: -f1)
	mutate_line=$(echo "$body" | grep -n "$mutate_pattern" | head -1 | cut -d: -f1)
	if [ -n "$arm_line" ] && [ -n "$mutate_line" ] && [ "$arm_line" -lt "$mutate_line" ]; then
		pass
	else
		fail "$label: schedule_delayed_work() does not precede the hardware mutation " \
			"(arm_line=$arm_line mutate_line=$mutate_line)"
	fi
}
check_arm_before "$safe_off_cmd_body" 'gpiod_direction_output(n->gpc0_gpio, 0)' "nblc_cmd_safe_off_test"
check_arm_before "$pwm_active_cmd_body" 'nblc_enter_pwm_active_locked(n, duty_pct)' "nblc_cmd_pwm_active"
check_arm_before "$pc22_cmd_body" 'nblc_pc22_test_locked(n, level)' "nblc_cmd_pc22_test"

# --- Test 10: the 2-second hard watchdog cap is compile-time enforced for
# every operation duration via static_assert. ---
if grep -q '^#define NBLC_WATCHDOG_MAX_MS[[:space:]]*2000U$' "$DRIVER" && \
   grep -q 'static_assert(NBLC_SAFE_OFF_TEST_DEFAULT_MS >= NBLC_SAFE_OFF_TEST_MIN_MS &&' "$DRIVER" && \
   grep -q 'static_assert(NBLC_PC22_TEST_MS <= NBLC_WATCHDOG_MAX_MS' "$DRIVER" && \
   grep -q 'static_assert(NBLC_PWM_TEST_MS <= NBLC_WATCHDOG_MAX_MS' "$DRIVER"; then
	pass
else
	fail "the driver does not compile-time bounds-check every operation duration against " \
		"the 2000ms watchdog ceiling"
fi
# The configurable safe_off_test_ms module param is still hard-clamped at
# every use site, regardless of its runtime value.
if grep -q 'static unsigned int nblc_clamped_safe_off_ms(void)' "$DRIVER" && \
   grep -q 'if (ms > NBLC_WATCHDOG_MAX_MS)' "$DRIVER"; then
	pass
else
	fail "safe_off_test_ms is not hard-clamped to the watchdog ceiling at every use site"
fi

# --- Test 11: every restore path converges on the SAME single routine
# (nblc_converge_gpc0_safe_on_locked) - watchdog timeout, explicit
# restore/disarm, enter-pwm-active failure unwind, and remove() all call
# it, rather than each reimplementing its own restore logic. ---
for site in nblc_restore_work nblc_force_restore_now nblc_cmd_enter_safe_on nblc_enter_pwm_active_locked nblc_remove; do
	site_body=$(echo "$driver_no_comments" | awk "/^static (void|int) $site\(/,/^}/")
	if echo "$site_body" | grep -q 'nblc_converge_gpc0_safe_on_locked('; then
		pass
	else
		fail "$site() does not call the shared nblc_converge_gpc0_safe_on_locked() restore routine"
	fi
done

# --- Test 12: the restore routine re-verifies the readback rather than
# assuming the write succeeded, and surfaces a failed verification as a
# hard-stop (restore_failure_count incremented, safe_on_verified cleared,
# last_restore_reason recorded) rather than silently claiming success. ---
converge_body=$(echo "$driver_no_comments" | awk '/^static void nblc_converge_gpc0_safe_on_locked/,/^}/')
if echo "$converge_body" | grep -q 'gpiod_get_value(n->gpc0_gpio) == 1' && \
   echo "$converge_body" | grep -q 'n->safe_on_verified = true;' && \
   echo "$converge_body" | grep -q 'n->safe_on_verified = false;' && \
   echo "$converge_body" | grep -q 'n->restore_failure_count++;'; then
	pass
else
	fail "nblc_converge_gpc0_safe_on_locked() does not re-verify the GPC0 readback and " \
		"honestly record a failed restoration"
fi
# And it must set the internal fault state on any failure, so no other
# code path can later trust "state == safe-on" while gpc0_gpio is not
# actually held.
if echo "$converge_body" | grep -q 'n->state = NBLC_STATE_FAULT;'; then
	pass
else
	fail "nblc_converge_gpc0_safe_on_locked() does not set NBLC_STATE_FAULT on a failed " \
		"convergence - a caller could wrongly trust state==safe-on with no GPIO held"
fi

# --- Test 13: exiting pwm-active always disables the PWM, releases the
# PWM channel, and releases the pinctrl claim, in that order, before
# re-acquiring GPC0 as GPIO - see the file header items (c)/(d). ---
disable_line=$(echo "$converge_body" | grep -n 'st.enabled = false;' | head -1 | cut -d: -f1)
pwm_put_line=$(echo "$converge_body" | grep -n 'pwm_put(n->pwm);' | head -1 | cut -d: -f1)
pinctrl_put_line=$(echo "$converge_body" | grep -n 'pinctrl_put(n->pwm_pinctrl);' | head -1 | cut -d: -f1)
gpio_reacquire_line=$(echo "$converge_body" | grep -n 'gpiod_get(n->dev, "backlight", GPIOD_OUT_HIGH)' | head -1 | cut -d: -f1)
if [ -n "$disable_line" ] && [ -n "$pwm_put_line" ] && [ -n "$pinctrl_put_line" ] && [ -n "$gpio_reacquire_line" ] && \
   [ "$disable_line" -lt "$pwm_put_line" ] && [ "$pwm_put_line" -lt "$pinctrl_put_line" ] && \
   [ "$pinctrl_put_line" -lt "$gpio_reacquire_line" ]; then
	pass
else
	fail "the exit-pwm-active ordering (disable -> release PWM -> release pinctrl -> " \
		"re-acquire GPIO) is not enforced in source order " \
		"(disable=$disable_line pwm_put=$pwm_put_line pinctrl_put=$pinctrl_put_line gpio=$gpio_reacquire_line)"
fi

# --- Test 14: entering pwm-active releases the GPIO claim BEFORE
# selecting the pwm-active pinctrl state - GPC0 must never be
# simultaneously claimed through both subsystems at once. ---
enter_pwm_body=$(echo "$driver_no_comments" | awk '/^static int nblc_enter_pwm_active_locked/,/^}/')
gpio_put_line=$(echo "$enter_pwm_body" | grep -n 'gpiod_put(n->gpc0_gpio);' | head -1 | cut -d: -f1)
pinctrl_select_line=$(echo "$enter_pwm_body" | grep -n 'pinctrl_get_select(n->dev, "pwm-active")' | head -1 | cut -d: -f1)
if [ -n "$gpio_put_line" ] && [ -n "$pinctrl_select_line" ] && [ "$gpio_put_line" -lt "$pinctrl_select_line" ]; then
	pass
else
	fail "nblc_enter_pwm_active_locked() does not release the GPIO claim before selecting " \
		"the pwm-active pinctrl state"
fi
# Every failure path inside this function must unwind through the shared
# converge routine, not leave GPC0 muxed-to-PWM-but-undriven.
if echo "$enter_pwm_body" | grep -q '^unwind:' && \
   echo "$enter_pwm_body" | grep -A3 '^unwind:' | grep -q 'nblc_converge_gpc0_safe_on_locked'; then
	pass
else
	fail "nblc_enter_pwm_active_locked() does not unwind to safe-on on every failure path"
fi

# --- Test 15: PWM duty is restricted to exactly 25/50/75% - 0% and 100%
# are never reachable through the debugfs command interface. ---
if grep -q '"pwm-active-25"' "$DRIVER" && grep -q '"pwm-active-50"' "$DRIVER" && \
   grep -q '"pwm-active-75"' "$DRIVER"; then
	pass
else
	fail "the driver does not recognize exactly the pwm-active-25/50/75 command literals"
fi
if grep -Eq '"pwm-active-0"|"pwm-active-100"' "$DRIVER"; then
	fail "the driver source contains a pwm-active-0/pwm-active-100 command literal - " \
		"0%/100% must never be reachable"
else
	pass
fi
if grep -q 'duty_pct != 25 && duty_pct != 50 && duty_pct != 75' "$DRIVER"; then
	pass
else
	fail "nblc_cmd_pwm_active() does not defensively reject any duty value outside {25,50,75}"
fi

# --- Test 16: the debugfs command whitelist rejects any trailing
# argument, same discipline as nebulaos_backlight_probe_diag.c's hardening
# pass - no arbitrary GPIO/channel/duty/period/timeout can be smuggled
# through. ---
whitelist_check_line=$(echo "$command_write_body" | grep -n 'if (rest && \*rest)' | head -1 | cut -d: -f1)
dispatch_line=$(echo "$command_write_body" | grep -n 'if (!strcmp(cmd, "status"))' | head -1 | cut -d: -f1)
if [ -n "$whitelist_check_line" ] && [ -n "$dispatch_line" ] && [ "$whitelist_check_line" -lt "$dispatch_line" ]; then
	pass
else
	fail "a trailing argument is not rejected before command dispatch"
fi
if echo "$driver_no_comments" | grep -q 'kstrtouint('; then
	fail "the driver calls kstrtouint() - an arbitrary caller-supplied numeric argument " \
		"could be smuggled through"
else
	pass
fi
for word in status enter-safe-on safe-off-test pc22-test-low pc22-test-high pwm-active-25 pwm-active-50 pwm-active-75 disarm restore; do
	if echo "$command_write_body" | grep -q "!strcmp(cmd, \"$word\")"; then
		pass
	else
		fail "nblc_command_write() does not dispatch the documented command \"$word\""
	fi
done

# --- Test 17: legacy /sys/class/gpio sysfs is never USED anywhere in the
# driver's real code or the toggle script - it IS expected and desired for
# the driver's own file header comments to mention the literal path when
# documenting exactly why it's forbidden (same "explain the incident"
# documentation style this project already uses elsewhere), so this checks
# non-comment code only, plus real shell usage in the toggle script. ---
if echo "$driver_no_comments" | grep -q '/sys/class/gpio'; then
	fail "the driver's real code (not just comments) references /sys/class/gpio - forbidden"
else
	pass
fi
if echo "$driver_no_comments" | grep -Eq '\bexport_store\b|gpio_export\('; then
	fail "the driver references legacy sysfs GPIO export internals - forbidden"
else
	pass
fi
variant_script_no_comments=$(grep -v '^[[:space:]]*#' "$VARIANT_SCRIPT")
if echo "$variant_script_no_comments" | grep -q '/sys/class/gpio'; then
	fail "the toggle script's real code (not just comments) references /sys/class/gpio - forbidden"
else
	pass
fi

# --- Test 18: PC22 already-owned detection - gpiod_get() failure (e.g.
# -EBUSY) is checked and refused with a clear warning, never silently
# ignored or crashed into. ---
pc22_test_locked_body=$(echo "$driver_no_comments" | awk '/^static int nblc_pc22_test_locked/,/^}/')
if echo "$pc22_test_locked_body" | grep -q 'IS_ERR(desc)' && \
   echo "$pc22_test_locked_body" | grep -q '\-EBUSY' && \
   echo "$pc22_test_locked_body" | grep -q 'dev_warn'; then
	pass
else
	fail "nblc_pc22_test_locked() does not detect and clearly report an already-owned PC22 " \
		"(-EBUSY from gpiod_get())"
fi
# The initial level capture is honest about direction being unavailable on
# this platform - never fabricates a value.
if grep -q 'pc22_initial_direction_known = false;' "$DRIVER"; then
	pass
else
	fail "the driver does not honestly record PC22's initial direction as unavailable"
fi

# --- Test 19: PC22 test operations are fixed at 1 second, low/high only -
# nothing else exposed. ---
if grep -q '^#define NBLC_PC22_TEST_MS[[:space:]]*1000U$' "$DRIVER"; then
	pass
else
	fail "NBLC_PC22_TEST_MS is not fixed at exactly 1000ms"
fi

# --- Test 20: status exposes every field the mission's runtime interface
# requires: armed, state, active_op, timeout remaining, GPC0 mode/level,
# PWM owned/enabled/period/duty, PC22 state, restore/watchdog-restore/
# restore-failure counts, last restore reason, and safe-on-verified. ---
status_dump_body=$(echo "$driver_no_comments" | awk '/^static void nblc_status_dump/,/^}/')
for field in 'armed:' 'state:' 'active_op:' 'timeout_remaining_ms:' 'gpc0_mode:' 'gpc0_level:' \
	     'pwm_owned:' 'pwm_enabled:' 'pwm_period_ns:' 'pwm_duty_pct:' 'pc22_active:' \
	     'restore_count:' 'watchdog_restore_count:' 'restore_failure_count:' \
	     'last_restore_reason:' 'safe_on_verified:'; do
	if echo "$status_dump_body" | grep -q "\"$field"; then
		pass
	else
		fail "nblc_status_dump() does not expose the required \"$field\" status field"
	fi
done

# --- Test 21: re-applying FINAL1 twice is idempotent. ---
if sh "$VARIANT_SCRIPT" FINAL1 >/dev/null 2>&1; then
	node_count=$(grep -c 'nebulaos_backlight_final: nebulaos_backlight_final' "$DTS")
	frag_count=$(grep -c '^CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER=y$' "$FRAGMENT")
	pwm_block_now=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
	if [ "$node_count" = "1" ] && [ "$frag_count" = "1" ] && [ "$pwm_block_now" = "$PRETEST_PWM_BLOCK" ]; then
		pass
	else
		fail "re-applying FINAL1 produced $node_count DT nodes / $frag_count fragment " \
			"lines, or changed the &pwm block - expected exactly 1 each and an " \
			"unchanged &pwm block"
	fi
else
	fail "re-applying FINAL1 a second time failed - not idempotent"
fi

# --- Test 22: switching from FINAL1 back to FINAL0 restores clean
# affected files, removes the driver file, empties the fragment block, and
# leaves &pwm's block byte-identical to the pristine baseline. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
if [ -z "$(git -C "$KERNEL_DIR" status --porcelain -- $AFFECTED_FILES)" ]; then
	pass
else
	fail "switching from FINAL1 back to FINAL0 left the affected files modified: $(git -C "$KERNEL_DIR" diff -- $AFFECTED_FILES)"
fi
if [ -f "$DRIVER" ]; then
	fail "switching from FINAL1 back to FINAL0 left the controller driver file present"
else
	pass
fi
if grep -q 'NEBULAOS_BACKLIGHT_FINAL_CONTROLLER' "$FRAGMENT"; then
	fail "switching from FINAL1 back to FINAL0 left CONFIG_NEBULAOS_BACKLIGHT_FINAL_CONTROLLER in the fragment"
else
	pass
fi
POSTREVERT_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
if [ "$POSTREVERT_PWM_BLOCK" = "$PRETEST_PWM_BLOCK" ]; then
	pass
else
	fail "&pwm's block is not byte-identical to the pristine baseline after reverting to FINAL0"
fi

# --- Test 23: an unknown variant name is rejected, not silently applied. ---
if sh "$VARIANT_SCRIPT" FINAL9 >/dev/null 2>&1; then
	fail "an unknown variant name 'FINAL9' was accepted instead of rejected"
else
	pass
fi

# --- Test 24: the toggle script itself refuses to proceed if &pwm's
# pinctrl-0 is not the expected pristine <&pwm1_pc> value (e.g. left
# modified by an older/other script) rather than silently building on top
# of an unexpected value. ---
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null
sed -i 's/pinctrl-0 = <&pwm1_pc>;/pinctrl-0 = <\&pwm0_pc>;/' "$DTS"
if sh "$VARIANT_SCRIPT" FINAL1 >/dev/null 2>&1; then
	fail "the toggle script proceeded despite &pwm's pinctrl-0 already being non-pristine"
else
	pass
fi
# Restore for the rest of the suite / cleanup trap.
sed -i 's/pinctrl-0 = <&pwm0_pc>;/pinctrl-0 = <\&pwm1_pc>;/' "$DTS"
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null

# --- pwm-committed tests (Phase 13: sustained-hold extension). Re-apply
# FINAL1 for source inspection - these tests read the driver like Tests
# 5-21 above, they do not need a build. ---
sh "$VARIANT_SCRIPT" FINAL1 >/dev/null
driver_no_comments=$(grep -v '^[[:space:]]*\*' "$DRIVER" | grep -v '^[[:space:]]*/\*')

# --- Test 25: pwm-committed is a real, distinctly-named state, and the
# commit-pwm command is only reachable while an in-flight pwm-active test
# is genuinely active - state == NBLC_STATE_PWM_ACTIVE *and*
# active_op == NBLC_OP_PWM_ACTIVE - never directly from safe-on or any
# other state. ---
if grep -q 'NBLC_STATE_PWM_COMMITTED,' "$DRIVER"; then
	pass
else
	fail "the driver does not define an NBLC_STATE_PWM_COMMITTED enum value"
fi
if grep -q 'case NBLC_STATE_PWM_COMMITTED: return "pwm-committed";' "$DRIVER"; then
	pass
else
	fail "nblc_state_name() does not report \"pwm-committed\" for NBLC_STATE_PWM_COMMITTED"
fi
commit_pwm_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_commit_pwm/,/^}/')
if [ -n "$commit_pwm_cmd_body" ]; then
	pass
else
	fail "could not find nblc_cmd_commit_pwm() in the driver"
fi
if echo "$commit_pwm_cmd_body" | grep -q 'n->state != NBLC_STATE_PWM_ACTIVE' && \
   echo "$commit_pwm_cmd_body" | grep -q 'n->active_op != NBLC_OP_PWM_ACTIVE' && \
   echo "$commit_pwm_cmd_body" | grep -q -- '-EPERM'; then
	pass
else
	fail "nblc_cmd_commit_pwm() does not require BOTH state==pwm-active AND " \
		"active_op==pwm-active (i.e. a currently in-flight bounded test) before " \
		"committing - this is what forces every commit through the already-tested " \
		"bounded pwm-active entry path"
fi
# Never directly reachable from safe-on: the state check above is
# `!= NBLC_STATE_PWM_ACTIVE`, not `!= NBLC_STATE_SAFE_ON` - confirm the
# safe-on state name literal does not appear as the gating check in this
# function (a copy-paste of the pwm-active/safe-off-test guard would be the
# exact bug this test catches).
if echo "$commit_pwm_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON'; then
	fail "nblc_cmd_commit_pwm() gates on safe-on instead of pwm-active - this would " \
		"allow committing directly from safe-on, bypassing the bounded pwm-active " \
		"acquire/apply/verify path entirely"
else
	pass
fi

# --- Test 26: the in-flight bounded test's fixed ~2s auto-revert timer is
# genuinely disarmed on commit - cancel_delayed_work() is called, and it
# precedes both the active_op clear and the state transition to
# pwm-committed (so no window exists where the timer could still be
# considered live against the new state). No hardware is touched (no
# gpiod_*/pwm_*/pinctrl_* call anywhere in this function) - committing must
# never itself cause a visible flicker. ---
cancel_line=$(echo "$commit_pwm_cmd_body" | grep -n 'cancel_delayed_work(&n->restore_work);' | head -1 | cut -d: -f1)
op_clear_line=$(echo "$commit_pwm_cmd_body" | grep -n 'n->active_op = NBLC_OP_NONE;' | head -1 | cut -d: -f1)
state_line=$(echo "$commit_pwm_cmd_body" | grep -n 'n->state = NBLC_STATE_PWM_COMMITTED;' | head -1 | cut -d: -f1)
if [ -n "$cancel_line" ] && [ -n "$op_clear_line" ] && [ -n "$state_line" ] && \
   [ "$cancel_line" -lt "$op_clear_line" ] && [ "$op_clear_line" -lt "$state_line" ]; then
	pass
else
	fail "nblc_cmd_commit_pwm() does not cancel the pending watchdog work before " \
		"clearing active_op and transitioning to pwm-committed, in that order " \
		"(cancel=$cancel_line active_op_clear=$op_clear_line state=$state_line)"
fi
# Must NOT be the _sync variant while n->lock is held (see the file
# header's own documented deadlock rule for this exact pattern).
if echo "$commit_pwm_cmd_body" | grep -q 'cancel_delayed_work_sync'; then
	fail "nblc_cmd_commit_pwm() calls cancel_delayed_work_sync() while holding n->lock - " \
		"this can deadlock against a concurrently-running watchdog callback that " \
		"itself takes n->lock, per this file's own documented ordering rule"
else
	pass
fi
if echo "$commit_pwm_cmd_body" | grep -Eq 'gpiod_get\(|gpiod_put\(|gpiod_direction_output\(|pwm_get\(|pwm_put\(|pwm_apply_state\(|pinctrl_get_select\(|pinctrl_put\('; then
	fail "nblc_cmd_commit_pwm() touches hardware directly - committing must be a pure " \
		"bookkeeping transition (no visible flicker), reusing whatever " \
		"nblc_enter_pwm_active_locked() already applied"
else
	pass
fi

# --- Test 27: every existing convergence/shutdown/error path still
# converges NBLC_STATE_PWM_COMMITTED to safe-on, via the SAME generic
# conditions already exercised for every other non-safe-on state - none of
# them special-case pwm-committed away. commit-pwm clears active_op to
# NBLC_OP_NONE (Test 26), so the generic "active_op idle but state isn't
# safe-on/boot-preserve yet" fallback in nblc_force_restore_now() is what
# must catch it; nblc_cmd_enter_safe_on() must converge unconditionally
# regardless of active_op; nblc_remove() must converge on any non-boot-
# preserve state. ---
force_restore_body=$(echo "$driver_no_comments" | awk '/^static void nblc_force_restore_now/,/^}/')
if echo "$force_restore_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON && n->state != NBLC_STATE_BOOT_PRESERVE' && \
   echo "$force_restore_body" | grep -A2 'n->state != NBLC_STATE_SAFE_ON && n->state != NBLC_STATE_BOOT_PRESERVE' | \
       grep -q 'nblc_converge_gpc0_safe_on_locked('; then
	pass
else
	fail "nblc_force_restore_now()'s generic 'something is active but active_op says " \
		"none' fallback (the path pwm-committed relies on, since commit-pwm clears " \
		"active_op) is missing or no longer calls the shared converge routine"
fi
if echo "$force_restore_body" | grep -q 'NBLC_STATE_PWM_COMMITTED'; then
	fail "nblc_force_restore_now() explicitly mentions NBLC_STATE_PWM_COMMITTED - it " \
		"should rely on the existing generic state!=safe-on/boot-preserve check " \
		"instead of a special case, per this driver's own documented design choice"
else
	pass
fi
enter_safe_on_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_enter_safe_on/,/^}/')
# The unconditional converge call must appear AFTER the shared
# "n->active_op = NBLC_OP_NONE;" line that closes out the active_op-only
# switch block (that assignment is common to every case, sitting just
# inside the closing brace of the `if (active_op != NONE)` block, so a
# converge call after it is provably outside/unconditional on any specific
# case) - so it always runs regardless of active_op, in particular
# regardless of active_op already being NBLC_OP_NONE, which is exactly the
# state commit-pwm leaves things in.
op_clear_line=$(echo "$enter_safe_on_body" | grep -n 'n->active_op = NBLC_OP_NONE;' | head -1 | cut -d: -f1)
converge_call_line=$(echo "$enter_safe_on_body" | grep -n 'nblc_converge_gpc0_safe_on_locked(n, "enter-safe-on");' | head -1 | cut -d: -f1)
if [ -n "$op_clear_line" ] && [ -n "$converge_call_line" ] && [ "$converge_call_line" -gt "$op_clear_line" ]; then
	pass
else
	fail "nblc_cmd_enter_safe_on() does not call nblc_converge_gpc0_safe_on_locked() " \
		"unconditionally after its active_op switch - a pwm-committed caller (whose " \
		"active_op is already NBLC_OP_NONE) could then fail to converge " \
		"(op_clear=$op_clear_line converge_call=$converge_call_line)"
fi
remove_body=$(echo "$driver_no_comments" | awk '/^static int nblc_remove/,/^}/')
if echo "$remove_body" | grep -q 'if (n->state != NBLC_STATE_BOOT_PRESERVE)' && \
   echo "$remove_body" | grep -A1 'if (n->state != NBLC_STATE_BOOT_PRESERVE)' | \
       grep -q 'nblc_converge_gpc0_safe_on_locked('; then
	pass
else
	fail "nblc_remove() no longer unconditionally converges any non-boot-preserve " \
		"state (which pwm-committed is) to safe-on before releasing the GPIO claim"
fi
if echo "$remove_body" | grep -q 'NBLC_STATE_PWM_COMMITTED'; then
	fail "nblc_remove() explicitly mentions NBLC_STATE_PWM_COMMITTED - it should rely " \
		"on the existing generic state!=boot-preserve check instead of a special case"
else
	pass
fi

# --- Test 28: serialization still holds while committed - a second
# commit-pwm, a new safe-off-test, or a new pwm-active test are all
# rejected while state == pwm-committed. safe-off-test/pwm-active already
# gate on state==safe-on (proven generically by Test 7 for "any state other
# than safe-on", which pwm-committed is one of); this test confirms
# commit-pwm's OWN gate is state==pwm-active specifically, so re-issuing it
# from pwm-committed (state is then pwm-committed, not pwm-active) is
# rejected by that same check - no separate "already committed" branch
# exists or is needed. ---
if echo "$commit_pwm_cmd_body" | grep -q 'n->state != NBLC_STATE_PWM_ACTIVE'; then
	pass
else
	fail "nblc_cmd_commit_pwm()'s state gate is not NBLC_STATE_PWM_ACTIVE - a second " \
		"commit-pwm issued while already in pwm-committed would not be correctly " \
		"rejected"
fi

# --- Test 29: status reporting distinguishes pwm-active (bounded, will
# auto-revert) from pwm-committed (sustained, operator-confirmed), and
# exposes how long the current commitment has been held. ---
status_dump_body=$(echo "$driver_no_comments" | awk '/^static void nblc_status_dump/,/^}/')
for field in 'pwm_committed:' 'pwm_committed_duration_ms:'; do
	if echo "$status_dump_body" | grep -q "\"$field"; then
		pass
	else
		fail "nblc_status_dump() does not expose the required \"$field\" status field"
	fi
done
if grep -q 'unsigned long[[:space:]]*committed_since;' "$DRIVER"; then
	pass
else
	fail "struct nblc does not track a committed_since timestamp for the sustained hold"
fi

# --- Test 30: the debugfs command whitelist dispatches "commit-pwm" (same
# whitelist-enforcement discipline verified for every other command by Test
# 16), and it is documented in the file header's command list. ---
command_write_body=$(echo "$driver_no_comments" | awk '/^static ssize_t nblc_command_write/,/^}/')
if echo "$command_write_body" | grep -q '!strcmp(cmd, "commit-pwm")'; then
	pass
else
	fail "nblc_command_write() does not dispatch a \"commit-pwm\" command"
fi
if grep -q '\*   commit-pwm' "$DRIVER"; then
	pass
else
	fail "the file header's command-interface list does not document commit-pwm"
fi

# --- sleep/wake tests (Phase 14: backlight-only sleep extension). Same
# source-inspection style as the pwm-committed tests above - $DRIVER/
# $driver_no_comments are still the FINAL1-applied copies from that block. ---

# --- Test 31: NBLC_STATE_ASLEEP is a real, distinctly-named state, and
# "sleep" is reachable ONLY from safe-on or pwm-committed - never directly
# from boot-preserve, safe-off-test, or a bare in-flight pwm-active test. ---
if grep -q 'NBLC_STATE_ASLEEP,' "$DRIVER"; then
	pass
else
	fail "the driver does not define an NBLC_STATE_ASLEEP enum value"
fi
if grep -q 'case NBLC_STATE_ASLEEP: return "asleep";' "$DRIVER"; then
	pass
else
	fail "nblc_state_name() does not report \"asleep\" for NBLC_STATE_ASLEEP"
fi
sleep_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_sleep\(/,/^}/')
if [ -n "$sleep_cmd_body" ]; then
	pass
else
	fail "could not find nblc_cmd_sleep() in the driver"
fi
if echo "$sleep_cmd_body" | grep -q 'n->state != NBLC_STATE_SAFE_ON && n->state != NBLC_STATE_PWM_COMMITTED' && \
   echo "$sleep_cmd_body" | grep -q -- '-EPERM'; then
	pass
else
	fail "nblc_cmd_sleep() does not gate entry to exactly safe-on or pwm-committed " \
		"(boot-preserve/safe-off-test/bare pwm-active would then be reachable, or " \
		"the rejection is missing)"
fi

# --- Test 32: a second "sleep" while already asleep is rejected - since the
# gate above allows exactly {safe-on, pwm-committed} and NBLC_STATE_ASLEEP is
# neither, this is the same check as Test 31, confirmed here explicitly as
# its own serialization test per the mission's own required-coverage list. ---
if echo "$sleep_cmd_body" | grep -Eq 'n->state != NBLC_STATE_SAFE_ON && n->state != NBLC_STATE_PWM_COMMITTED && n->state != NBLC_STATE_ASLEEP'; then
	fail "nblc_cmd_sleep()'s gate appears to special-case NBLC_STATE_ASLEEP as an " \
		"additional allowed source state - it must remain excluded"
else
	pass
fi
if echo "$sleep_cmd_body" | grep -q -- '-EBUSY'; then
	pass
else
	fail "nblc_cmd_sleep() does not reject a second concurrent operation with -EBUSY"
fi

# --- Test 33: sleep captures the wake target BEFORE any hardware mutation,
# and is watchdog-armed before mutating - same arm-before-apply discipline as
# every other operation (see check_arm_before, already defined above). ---
capture_line=$(echo "$sleep_cmd_body" | grep -n 'from_pwm = (n->state == NBLC_STATE_PWM_COMMITTED);' | head -1 | cut -d: -f1)
arm_line=$(echo "$sleep_cmd_body" | grep -n 'schedule_delayed_work(&n->restore_work' | head -1 | cut -d: -f1)
if [ -n "$capture_line" ] && [ -n "$arm_line" ] && [ "$capture_line" -lt "$arm_line" ]; then
	pass
else
	fail "nblc_cmd_sleep() does not capture the wake target before arming/mutating " \
		"(capture=$capture_line arm=$arm_line)"
fi
check_arm_before "$sleep_cmd_body" 'nblc_drive_gpc0_low_locked(n)' "nblc_cmd_sleep"

# --- Test 34: sleep saves the correct wake target fields only AFTER the
# GPC0-low mutation genuinely succeeds, immediately before transitioning to
# NBLC_STATE_ASLEEP - never speculatively before the mutation is known to
# have worked. ---
mutate_line=$(echo "$sleep_cmd_body" | grep -n 'ret = nblc_drive_gpc0_low_locked(n);' | head -1 | cut -d: -f1)
save_line=$(echo "$sleep_cmd_body" | grep -n 'n->sleep_wake_target_is_pwm = from_pwm;' | head -1 | cut -d: -f1)
state_line=$(echo "$sleep_cmd_body" | grep -n 'n->state = NBLC_STATE_ASLEEP;' | head -1 | cut -d: -f1)
if [ -n "$mutate_line" ] && [ -n "$save_line" ] && [ -n "$state_line" ] && \
   [ "$mutate_line" -lt "$save_line" ] && [ "$save_line" -lt "$state_line" ]; then
	pass
else
	fail "nblc_cmd_sleep() does not save the wake target after a successful GPC0-low " \
		"mutation and before transitioning to asleep, in that order " \
		"(mutate=$mutate_line save=$save_line state=$state_line)"
fi
if echo "$sleep_cmd_body" | grep -q 'n->sleep_wake_target_duty_pct = duty;'; then
	pass
else
	fail "nblc_cmd_sleep() does not save the duty percentage as part of the wake target"
fi

# --- Test 35: sleeping from pwm-committed releases the PWM claim and remuxes
# GPC0 back to GPIO via the SAME nblc_converge_gpc0_safe_on_locked() routine
# every other exit from an active PWM state already uses - never a second,
# parallel "release PWM, remux to GPIO" implementation. ---
if echo "$sleep_cmd_body" | grep -q 'nblc_converge_gpc0_safe_on_locked(n, "sleep-from-pwm-committed");'; then
	pass
else
	fail "nblc_cmd_sleep() does not reuse nblc_converge_gpc0_safe_on_locked() to leave " \
		"pwm-committed - it must not reimplement PWM release/pinctrl remux itself"
fi
if echo "$sleep_cmd_body" | grep -Eq 'pwm_apply_state\(|pwm_put\(|pinctrl_put\(|pinctrl_get_select\(|gpiod_get\('; then
	fail "nblc_cmd_sleep() touches PWM/pinctrl/GPIO-acquisition hardware APIs directly - " \
		"it must only reach hardware through the shared converge routine and " \
		"nblc_drive_gpc0_low_locked()"
else
	pass
fi
# And no direct duplicate of the GPIO-low mechanic either - only through the
# shared helper.
if echo "$sleep_cmd_body" | grep -q 'gpiod_direction_output(n->gpc0_gpio, 0)'; then
	fail "nblc_cmd_sleep() duplicates the GPIO-low mechanic inline instead of calling " \
		"the shared nblc_drive_gpc0_low_locked() helper"
else
	pass
fi

# --- Test 36: "wake" is reachable ONLY from asleep. ---
wake_cmd_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_wake\(/,/^}/')
if [ -n "$wake_cmd_body" ]; then
	pass
else
	fail "could not find nblc_cmd_wake() in the driver"
fi
if echo "$wake_cmd_body" | grep -q 'n->state != NBLC_STATE_ASLEEP' && \
   echo "$wake_cmd_body" | grep -q -- '-EPERM'; then
	pass
else
	fail "nblc_cmd_wake() does not gate entry to exactly asleep"
fi
if echo "$wake_cmd_body" | grep -q -- '-EBUSY'; then
	pass
else
	fail "nblc_cmd_wake() does not reject a second concurrent operation with -EBUSY"
fi
check_arm_before "$wake_cmd_body" 'nblc_converge_gpc0_safe_on_locked(n, "wake")' "nblc_cmd_wake"

# --- Test 37: waking to a plain safe-on target drives GPC0 high (verified)
# and stops there - it must return before ever calling
# nblc_enter_pwm_active_locked(). ---
plain_return_line=$(echo "$wake_cmd_body" | grep -n 'if (!from_pwm) {' | head -1 | cut -d: -f1)
enter_pwm_call_line=$(echo "$wake_cmd_body" | grep -n 'ret = nblc_enter_pwm_active_locked(n, duty);' | head -1 | cut -d: -f1)
if [ -n "$plain_return_line" ] && [ -n "$enter_pwm_call_line" ] && [ "$plain_return_line" -lt "$enter_pwm_call_line" ]; then
	pass
else
	fail "nblc_cmd_wake() does not short-circuit to a plain safe-on restore before " \
		"reaching the pwm-active re-entry step (plain=$plain_return_line " \
		"enter_pwm=$enter_pwm_call_line)"
fi

# --- Test 38: waking to a pwm-committed target goes GPC0-high-verify ->
# re-enter pwm-active (the SAME acquire/apply/verify function pwm-active-X
# itself uses) -> re-commit (the same bookkeeping-only transition
# commit-pwm itself performs), in that order - and never shortcuts by
# calling pwm_apply_state()/gpiod_direction_output()/pinctrl_get_select()
# itself (those must only ever be reached through the shared, already-tested
# functions). ---
converge_call_line=$(echo "$wake_cmd_body" | grep -n 'nblc_converge_gpc0_safe_on_locked(n, "wake");' | head -1 | cut -d: -f1)
commit_state_line=$(echo "$wake_cmd_body" | grep -n 'n->state = NBLC_STATE_PWM_COMMITTED;' | head -1 | cut -d: -f1)
if [ -n "$converge_call_line" ] && [ -n "$enter_pwm_call_line" ] && [ -n "$commit_state_line" ] && \
   [ "$converge_call_line" -lt "$enter_pwm_call_line" ] && [ "$enter_pwm_call_line" -lt "$commit_state_line" ]; then
	pass
else
	fail "nblc_cmd_wake() does not sequence GPC0-high-verify -> re-enter-pwm-active -> " \
		"re-commit in order (converge=$converge_call_line enter_pwm=$enter_pwm_call_line " \
		"commit=$commit_state_line)"
fi
if echo "$wake_cmd_body" | grep -Eq 'pwm_apply_state\(|gpiod_direction_output\(|pinctrl_get_select\(|pwm_get\('; then
	fail "nblc_cmd_wake() calls a hardware-apply API directly - it must go through " \
		"nblc_converge_gpc0_safe_on_locked()/nblc_enter_pwm_active_locked() only, " \
		"never a shortcut around pwm_apply_state()/readback"
else
	pass
fi
if echo "$wake_cmd_body" | grep -q 'n->committed_since = jiffies;'; then
	pass
else
	fail "nblc_cmd_wake() does not record committed_since when re-committing, the same " \
		"as nblc_cmd_commit_pwm() itself does"
fi

# --- Test 39: every existing convergence/shutdown/disarm/remove path that
# already handles NBLC_STATE_PWM_COMMITTED (Test 27) also handles
# NBLC_STATE_ASLEEP - either via the SAME generic non-safe-on/boot-preserve
# fallback (settled asleep state, active_op idle, exactly like
# pwm-committed), or via explicit NBLC_OP_SLEEP_TRANSITION/
# NBLC_OP_WAKE_TRANSITION cases in every active_op switch (the transition
# itself, which pwm-committed has no equivalent of since committing touches
# no hardware). ---
restore_work_body=$(echo "$driver_no_comments" | awk '/^static void nblc_restore_work/,/^}/')
force_restore_body=$(echo "$driver_no_comments" | awk '/^static void nblc_force_restore_now/,/^}/')
remove_body=$(echo "$driver_no_comments" | awk '/^static int nblc_remove/,/^}/')
for site_name in "nblc_restore_work:$restore_work_body" "nblc_force_restore_now:$force_restore_body" "nblc_remove:$remove_body"; do
	name=${site_name%%:*}
	body=${site_name#*:}
	if echo "$body" | grep -q 'NBLC_OP_SLEEP_TRANSITION' && echo "$body" | grep -q 'NBLC_OP_WAKE_TRANSITION'; then
		pass
	else
		fail "$name()'s active_op switch does not handle NBLC_OP_SLEEP_TRANSITION/" \
			"NBLC_OP_WAKE_TRANSITION - a crash mid sleep/wake transition would not " \
			"be converged"
	fi
done
# The SETTLED NBLC_STATE_ASLEEP itself must rely on the same generic
# fallback pwm-committed already relies on - no special-casing.
if echo "$force_restore_body" | grep -q 'NBLC_STATE_ASLEEP'; then
	fail "nblc_force_restore_now() explicitly mentions NBLC_STATE_ASLEEP - it should " \
		"rely on the existing generic state!=safe-on/boot-preserve check instead of " \
		"a special case, same design choice already made for pwm-committed"
else
	pass
fi
enter_safe_on_body=$(echo "$driver_no_comments" | awk '/^static int nblc_cmd_enter_safe_on/,/^}/')
if echo "$enter_safe_on_body" | grep -q 'NBLC_STATE_ASLEEP'; then
	fail "nblc_cmd_enter_safe_on() explicitly mentions NBLC_STATE_ASLEEP - it should " \
		"converge unconditionally regardless of active_op, same as for pwm-committed, " \
		"with no special case"
else
	pass
fi
if echo "$remove_body" | grep -q 'NBLC_STATE_ASLEEP'; then
	fail "nblc_remove() explicitly mentions NBLC_STATE_ASLEEP - it should rely on the " \
		"existing generic state!=boot-preserve check instead of a special case"
else
	pass
fi

# --- Test 40: NBLC_STATE_ASLEEP structurally never holds n->pwm/
# n->pwm_pinctrl - neither nblc_cmd_sleep() nor nblc_cmd_wake() ever assigns
# to those fields directly; only the shared converge/enter-pwm-active
# routines do, and both are always called (and always leave the driver
# either fully safe-on or fully back in pwm-active/pwm-committed) before
# NBLC_STATE_ASLEEP is ever set or left. ---
if echo "$sleep_cmd_body" | grep -Eq 'n->pwm[[:space:]]*=|n->pwm_pinctrl[[:space:]]*=' ; then
	fail "nblc_cmd_sleep() assigns n->pwm/n->pwm_pinctrl directly instead of leaving " \
		"that to the shared converge routine"
else
	pass
fi
if echo "$wake_cmd_body" | grep -Eq 'n->pwm[[:space:]]*=|n->pwm_pinctrl[[:space:]]*=' ; then
	fail "nblc_cmd_wake() assigns n->pwm/n->pwm_pinctrl directly instead of leaving " \
		"that to the shared converge/enter-pwm-active routines"
else
	pass
fi

# --- Test 41: status exposes every field the mission's sleep/wake runtime
# interface requires: asleep, wake_target, asleep duration, sleep/wake/
# wake-failure counts. ---
status_dump_body=$(echo "$driver_no_comments" | awk '/^static void nblc_status_dump/,/^}/')
for field in 'asleep:' 'wake_target:' 'asleep_duration_ms:' 'sleep_count:' 'wake_count:' 'wake_failure_count:'; do
	if echo "$status_dump_body" | grep -q "\"$field"; then
		pass
	else
		fail "nblc_status_dump() does not expose the required \"$field\" status field"
	fi
done
if grep -q 'unsigned long[[:space:]]*asleep_since;' "$DRIVER"; then
	pass
else
	fail "struct nblc does not track an asleep_since timestamp for the sleep duration"
fi

# --- Test 42: the debugfs command whitelist dispatches "sleep" and "wake"
# (same whitelist-enforcement discipline verified for every other command by
# Test 16), and both are documented in the file header's command list. ---
command_write_body=$(echo "$driver_no_comments" | awk '/^static ssize_t nblc_command_write/,/^}/')
if echo "$command_write_body" | grep -q '!strcmp(cmd, "sleep")' && \
   echo "$command_write_body" | grep -q '!strcmp(cmd, "wake")'; then
	pass
else
	fail "nblc_command_write() does not dispatch both \"sleep\" and \"wake\" commands"
fi
if grep -q '\*   sleep' "$DRIVER" && grep -q '\*   wake' "$DRIVER"; then
	pass
else
	fail "the file header's command-interface list does not document sleep/wake"
fi

# --- Test 43: sleep/wake never touch framebuffer blanking, panel reset, or
# PC22 in any way - explicit exclusions from the mission spec. ---
if echo "$sleep_cmd_body$wake_cmd_body" | grep -Eiq 'pc22|fbioblank|fb_blank|panel_reset|framebuffer'; then
	fail "nblc_cmd_sleep()/nblc_cmd_wake() reference PC22, framebuffer blanking, or " \
		"panel reset - these are explicitly out of scope for backlight-only sleep"
else
	pass
fi

# --- Test 44: the shared &pwm controller node's own pinctrl-0 remains
# byte-identical to pristine after the sleep/wake extension to this same
# patch - the same dedicated regression check as Test 4/21/22, re-run here
# explicitly per the mission's own required-coverage list. ---
POSTSLEEP_PWM_BLOCK=$(sed -n '/^&pwm {/,/^};/p' "$DTS")
if [ "$PRETEST_PWM_BLOCK" = "$POSTSLEEP_PWM_BLOCK" ]; then
	pass
else
	fail "the &pwm node's own block changed after the sleep/wake extension - before:
$PRETEST_PWM_BLOCK
after:
$POSTSLEEP_PWM_BLOCK"
fi

# Leave the suite in the same FINAL0/clean end-state the rest of the file
# already establishes.
sh "$VARIANT_SCRIPT" FINAL0 >/dev/null

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
