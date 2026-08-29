#!/bin/sh
#
# Offline tests for Phase 1.9A (host MCU / ADXL345 / BL24C16F restoration).
#
# Validates the klipper_mcu (MACH_LINUX) build step, the S54nebulaos-host-mcu
# service, and the new machine.cfg config sections - all static analysis of
# script/config text and repo state. Does NOT require the Buildroot
# toolchain, a real build, or hardware - see 06-verify.sh for the
# rootfs-content checks that do need a real built image, and
# tests/recovery-safety-tests.sh for the "zero core patches" collision
# guard this phase extends with bl24c16f.py.
#
# Usage: sh tests/host-mcu-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BUILD_SCRIPT="$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh"
HOST_MCU_SERVICE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S54nebulaos-host-mcu"
KLIPPER_SERVICE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S55klipper"
MACHINE_CFG="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/machine.cfg"
EXT_BL24C16F="$REPO_ROOT/vendor/nebulaos-klipper-extensions/extras/bl24c16f.py"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# =========================================================================
# 1. File existence and permissions
# =========================================================================

echo "--- File existence and permissions ---"

if [ -x "$HOST_MCU_SERVICE" ]; then
    pass "S54nebulaos-host-mcu exists and is executable"
else
    fail "S54nebulaos-host-mcu missing or not executable at $HOST_MCU_SERVICE"
fi

if [ -f "$MACHINE_CFG" ]; then
    pass "machine.cfg exists"
else
    fail "machine.cfg does not exist at $MACHINE_CFG"
fi

# =========================================================================
# 2. klipper_mcu build step: correct toolchain, clean out/, real failure
#    handling - not the bare host gcc, not the GD32 ARM cross-compiler,
#    and never silently continuing on a failed build.
# =========================================================================

echo "--- klipper_mcu (MACH_LINUX) build step ---"

if [ -f "$BUILD_SCRIPT" ]; then
    BUILD_BLOCK=$(awk '/cross-compiling Klipper.s host MCU/,/^\) \|\| exit 1$/' "$BUILD_SCRIPT")

    if [ -n "$BUILD_BLOCK" ]; then
        pass "klipper_mcu build block found in 04-cross-compile-app-stack.sh"

        case "$BUILD_BLOCK" in
            *"CROSS_PREFIX=mipsel-buildroot-linux-gnu-"*)
                pass "build uses the project's mipsel-buildroot-linux-gnu- MIPS toolchain" ;;
            *)
                fail "build block does not reference CROSS_PREFIX=mipsel-buildroot-linux-gnu-" ;;
        esac

        case "$BUILD_BLOCK" in
            *"arm-none-eabi-"*)
                fail "build block references arm-none-eabi- (the GD32F303 stepper-MCU toolchain) - wrong target entirely" ;;
            *)
                pass "build block does not reference the GD32F303 (arm-none-eabi-) toolchain" ;;
        esac

        case "$BUILD_BLOCK" in
            *"rm -rf out .config"*)
                pass "build removes out/.config before building - the proven fix for Make's stale-toolchain-state hazard (see phase1.9-host-mcu-accelerometer-plr-analysis.md section 3)" ;;
            *)
                fail "build block does not clean out/.config before building - vulnerable to the demonstrated stale-toolchain-state hazard" ;;
        esac

        case "$BUILD_BLOCK" in
            *"test/configs/linuxprocess.config"*)
                pass "build uses upstream's own MACH_LINUX reference config" ;;
            *)
                fail "build does not reference test/configs/linuxprocess.config" ;;
        esac

        case "$BUILD_BLOCK" in
            *"FATAL: cross-compiling klipper_mcu"*"exit 1"*)
                pass "a failed klipper_mcu build is FATAL, not silently ignored" ;;
            *)
                fail "no FATAL/exit-1 handling found for a failed klipper_mcu build" ;;
        esac

        case "$BUILD_BLOCK" in
            *"out/klipper.elf"*)
                pass "build verifies out/klipper.elf was actually produced before proceeding" ;;
            *)
                fail "build does not verify out/klipper.elf exists before proceeding" ;;
        esac
    else
        fail "no klipper_mcu build block found in 04-cross-compile-app-stack.sh"
    fi

    case "$(cat "$BUILD_SCRIPT")" in
        *'"$OVERLAY/usr/bin/klipper_mcu"'*)
            pass "build installs the result to \$OVERLAY/usr/bin/klipper_mcu" ;;
        *)
            fail "build does not install to \$OVERLAY/usr/bin/klipper_mcu" ;;
    esac
else
    fail "04-cross-compile-app-stack.sh not found at $BUILD_SCRIPT"
fi

# =========================================================================
# 3. No post-clone patch targets vendor/klipper for this work - the whole
#    point of Phase 1.9A is compiling an EXISTING upstream build target,
#    never patching upstream source. Deliberately scoped to this phase's
#    own new content, not a repeat of recovery-safety-tests.sh's broader
#    equivalent check.
# =========================================================================

echo "--- No host Klipper core patch ---"

if [ -f "$BUILD_SCRIPT" ]; then
    if grep -A2 -B2 "cross-compiling Klipper.s host MCU" "$BUILD_SCRIPT" \
        | grep -qi "git apply\|patch -"; then
        fail "the klipper_mcu build step contains a patch/git-apply call - Phase 1.9A must not patch upstream Klipper"
    else
        pass "the klipper_mcu build step contains no patch/git-apply call against vendor/klipper"
    fi
else
    fail "cannot check for core patches - build script missing"
fi

# =========================================================================
# 4. No GD32F303 MCU lifecycle files touched by this phase - the host MCU
#    and the stepper-driver MCU are different chips, different buses,
#    different subsystems, and Phase 1.9A must not touch the latter at all.
# =========================================================================

echo "--- GD32F303 MCU lifecycle untouched ---"

GD32_FILES="scripts/build/overlay/etc/nebulaos/mcu_lifecycle.py
scripts/build/overlay/etc/nebulaos/mcu_restore.py
scripts/build/overlay/etc/nebulaos/mcu_restart.py
scripts/build/overlay/etc/nebulaos/mcu_application_identify.py
scripts/build/overlay/etc/nebulaos/mcu_known_identities.py
scripts/build/overlay/etc/init.d/S50nebulaos-mcu-guard
scripts/build/overlay/opt/nebulaos/tools/creality_flash.py
scripts/build/overlay/opt/nebulaos/tools/creality_validator.py"

if command -v git >/dev/null 2>&1 && git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    MERGE_BASE=$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || git -C "$REPO_ROOT" merge-base HEAD main 2>/dev/null)
    if [ -n "$MERGE_BASE" ]; then
        CHANGED=$(git -C "$REPO_ROOT" diff --name-only "$MERGE_BASE" -- $GD32_FILES 2>/dev/null)
        if [ -z "$CHANGED" ]; then
            pass "no GD32F303 MCU lifecycle file changed on this branch (diff against $MERGE_BASE)"
        else
            fail "GD32F303 MCU lifecycle files changed on this branch: $CHANGED"
        fi
    else
        echo "SKIP: could not resolve a merge-base against main - skipping the diff-based GD32 check"
    fi
else
    echo "SKIP: not a git checkout or git unavailable - skipping the diff-based GD32 check"
fi

# =========================================================================
# 5. Config sections - [mcu rpi], [adxl345], [resonance_tester], [bl24c16f]
# =========================================================================

echo "--- machine.cfg config sections ---"

if [ -f "$MACHINE_CFG" ]; then
    for section in "\[mcu rpi\]" "\[adxl345\]" "\[resonance_tester\]" "\[bl24c16f\]"; do
        if grep -q "^${section}$" "$MACHINE_CFG"; then
            pass "machine.cfg declares $section"
        else
            fail "machine.cfg is missing $section"
        fi
    done

    if grep -A3 "^\[mcu rpi\]$" "$MACHINE_CFG" | grep -q "serial: /tmp/klipper_host_mcu"; then
        pass "[mcu rpi] points at /tmp/klipper_host_mcu, matching S54nebulaos-host-mcu's socket"
    else
        fail "[mcu rpi] does not reference /tmp/klipper_host_mcu"
    fi

    if grep -A5 "^\[bl24c16f\]$" "$MACHINE_CFG" | grep -q "i2c_mcu: rpi"; then
        pass "[bl24c16f] is wired through [mcu rpi] (i2c_mcu: rpi), matching stock's real wiring"
    else
        fail "[bl24c16f] does not reference i2c_mcu: rpi"
    fi
else
    fail "cannot check config sections - machine.cfg missing"
fi

# =========================================================================
# 6. S54nebulaos-host-mcu service: starts klipper_mcu, correct ordering
# =========================================================================

echo "--- S54nebulaos-host-mcu service behavior ---"

if [ -f "$HOST_MCU_SERVICE" ]; then
    if grep -qF -- '--exec "$KLIPPER_HOST_MCU" -- -r' "$HOST_MCU_SERVICE"; then
        pass "S54nebulaos-host-mcu starts /usr/bin/klipper_mcu with -r"
    else
        fail "S54nebulaos-host-mcu does not start klipper_mcu with the expected arguments"
    fi

    if grep -q "FORCE_SHUTDOWN" "$HOST_MCU_SERVICE"; then
        pass "S54nebulaos-host-mcu parks GPIOs via FORCE_SHUTDOWN before killing the process, matching stock's own shutdown handshake"
    else
        fail "S54nebulaos-host-mcu does not send FORCE_SHUTDOWN before stopping"
    fi

    if [ -f "$KLIPPER_SERVICE" ]; then
        # S54 < S55 lexically guarantees ordering - a real assertion, not
        # just a comment, since a future rename could silently break it.
        S54_NAME=$(basename "$HOST_MCU_SERVICE")
        S55_NAME=$(basename "$KLIPPER_SERVICE")
        FIRST=$(printf '%s\n%s\n' "$S54_NAME" "$S55_NAME" | sort | head -1)
        if [ "$FIRST" = "$S54_NAME" ]; then
            pass "S54nebulaos-host-mcu sorts before S55klipper - host MCU is available before Klippy starts"
        else
            fail "S54nebulaos-host-mcu does not sort before S55klipper"
        fi
    else
        fail "S55klipper not found - cannot verify ordering"
    fi
else
    fail "cannot check service behavior - S54nebulaos-host-mcu missing"
fi

# =========================================================================
# 7. bl24c16f.py vendored correctly (extensions repo, when checked out
#    alongside this one - e.g. inside vendor/ after 00-fetch-vendor-
#    sources.sh, or as a sibling worktree during local development)
# =========================================================================

echo "--- bl24c16f.py extension ---"

BL24C16F_CANDIDATE=""
BRANCH_DIR=$(basename "$REPO_ROOT")
for cand in "$EXT_BL24C16F" \
            "$REPO_ROOT/../../NebulaOS-klipper-extensions/$BRANCH_DIR/extras/bl24c16f.py" \
            "$REPO_ROOT/../../../NebulaOS-klipper-extensions/extras/bl24c16f.py"; do
    [ -f "$cand" ] && { BL24C16F_CANDIDATE="$cand"; break; }
done

if [ -n "$BL24C16F_CANDIDATE" ]; then
    if grep -q "from . import bus" "$BL24C16F_CANDIDATE"; then
        pass "bl24c16f.py's only Klipper-internal dependency is the standard bus module - no core patch needed"
    else
        fail "bl24c16f.py does not import bus as expected - has it been modified from upstream?"
    fi

    if grep -q "Eric Callahan" "$BL24C16F_CANDIDATE"; then
        pass "bl24c16f.py preserves its original author's copyright header"
    else
        fail "bl24c16f.py is missing its original copyright header"
    fi

    for cmd in EEPROM_READ EEPROM_WRITE_BYTE EEPROM_WRITE_INT EEPROM_WRITE_FLOAT; do
        if grep -q "\"$cmd\"" "$BL24C16F_CANDIDATE"; then
            pass "bl24c16f.py registers $cmd"
        else
            fail "bl24c16f.py does not register $cmd"
        fi
    done
else
    echo "SKIP: NebulaOS-klipper-extensions not found alongside this checkout - cannot verify bl24c16f.py directly (checked in that repo's own tree, see VENDORED.md)"
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "=========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
