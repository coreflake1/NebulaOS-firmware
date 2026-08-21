#!/bin/sh
#
# Phase 1.5 closure mission (2026-08-19). Tests
# scripts/build/lib/baseline-config-compare.sh's baseline_config_semantic_diff()
# - the function assert-baseline-config.sh's post-build mode uses to compare
# kernel.config/buildroot.config/halley5_v30.dts against the qualified
# baseline tag.
#
# The whole reason this function exists rather than a plain `git diff
# --quiet` is a real incident: the qualified baseline tag predates the
# unified build image (Final Closure mission, 2026-08-15, one day after the
# 2026-08-14 baseline), so three provenance-only fields (a compiler
# self-identification string, a build-container mount path, and host-gcc-
# version detection flags) permanently differ on every build from the
# current pinned image, with zero effect on anything this project actually
# builds (each individually verified - see that file's own header). These
# tests prove three things with synthetic fixtures, never the real
# multi-hundred-KB config files:
#
#   A. a known non-behavioral provenance-only difference (exactly the kind
#      excluded above) PASSES.
#   B. a real kernel-config-shaped behavioral difference FAILS - the safety
#      gate this function exists to be must still catch real drift.
#   C. a real Buildroot-config-shaped behavioral difference FAILS, same
#      reasoning.
#
# Usage: sh tests/baseline-config-compare-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$REPO_ROOT/scripts/build/lib/baseline-config-compare.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/baseline-config-compare-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

echo "=== baseline-config-compare tests ==="

# --- fixture repo: a fake "baseline tag" with tracked kernel.config/
# buildroot.config/halley5_v30.dts, mirroring the real artifact layout
# closely enough for baseline_config_semantic_diff to read via `git show
# <tag>:artifacts/buildroot-halley5-v30-image/<file>`. -----------------------
FIXTURE="$WORK/fixture-repo"
mkdir -p "$FIXTURE/artifacts/buildroot-halley5-v30-image"
git -C "$FIXTURE" init -q -b main 2>/dev/null || (mkdir -p "$FIXTURE" && git -C "$FIXTURE" init -q -b main)

cat > "$FIXTURE/artifacts/buildroot-halley5-v30-image/kernel.config" <<'EOF'
#
# Automatically generated file; DO NOT EDIT.
# Linux/mips 6.6.18 Kernel Configuration
#
CONFIG_CC_VERSION_TEXT="mipsel-buildroot-linux-gnu-gcc.br_real (Buildroot 2023.11.1) 12.3.0"
CONFIG_CC_IS_GCC=y
CONFIG_PREEMPT_RT=y
CONFIG_HZ=100
CONFIG_EXTRA_FIRMWARE_DIR="/src/board/halley5-nebulaos-overlay/lib/firmware"
CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y
EOF

cat > "$FIXTURE/artifacts/buildroot-halley5-v30-image/buildroot.config" <<'EOF'
#
# Automatically generated file; DO NOT EDIT.
# Buildroot 2023.11.1 Configuration
#
BR2_HAVE_DOT_CONFIG=y
BR2_HOST_GCC_AT_LEAST_9=y
BR2_TOOLCHAIN_BUILDROOT_VENDOR="nebulaos"
EOF

cat > "$FIXTURE/artifacts/buildroot-halley5-v30-image/halley5_v30.dts" <<'EOF'
/dts-v1/;
/ {
	model = "Ender-3 V3 KE Halley5 v30";
};
EOF

git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "fixture baseline"
git -C "$FIXTURE" tag fixture-baseline-tag

# --- TEST A: provenance-only difference (exactly the three excluded
# fields, changed in exactly the ways the real incident changed them) must
# PASS. --------------------------------------------------------------------
CURRENT_A="$WORK/current-kernel-A.config"
sed \
	-e 's#(Buildroot 2023.11.1)#(Buildroot -g74d0200810-dirty)#' \
	-e 's#/src/board/#/workspace/NebulaOS-firmware/vendor/buildroot-x2000/board/#' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/kernel.config" > "$CURRENT_A"
if baseline_config_semantic_diff kernel.config "$CURRENT_A" fixture-baseline-tag "$FIXTURE"; then
	pass "case A: provenance-only kernel.config difference (CC_VERSION_TEXT + EXTRA_FIRMWARE_DIR) passes"
else
	fail "case A: provenance-only kernel.config difference incorrectly failed"
fi

CURRENT_A_BR="$WORK/current-buildroot-A.config"
sed \
	-e 's#Buildroot 2023.11.1 Configuration#Buildroot -g74d0200810-dirty Configuration#' \
	-e '/^BR2_HOST_GCC_AT_LEAST_9=y$/a BR2_HOST_GCC_AT_LEAST_10=y\nBR2_HOST_GCC_AT_LEAST_11=y' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/buildroot.config" > "$CURRENT_A_BR"
if baseline_config_semantic_diff buildroot.config "$CURRENT_A_BR" fixture-baseline-tag "$FIXTURE"; then
	pass "case A: provenance-only buildroot.config difference (version header + extra host-gcc flags) passes"
else
	fail "case A: provenance-only buildroot.config difference incorrectly failed"
fi

# --- TEST B: a REAL behavioral kernel.config difference must FAIL. This is
# the actual safety property - proving the gate still catches real drift,
# not just that it tolerates the known-safe fields. -------------------------
CURRENT_B="$WORK/current-kernel-B.config"
sed 's/^CONFIG_PREEMPT_RT=y$/# CONFIG_PREEMPT_RT is not set/' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/kernel.config" > "$CURRENT_B"
if baseline_config_semantic_diff kernel.config "$CURRENT_B" fixture-baseline-tag "$FIXTURE"; then
	fail "case B: a real behavioral kernel.config difference (CONFIG_PREEMPT_RT disabled) incorrectly PASSED - the safety gate is not catching real drift"
else
	pass "case B: a real behavioral kernel.config difference (CONFIG_PREEMPT_RT disabled) correctly fails"
fi

CURRENT_B2="$WORK/current-kernel-B2.config"
sed 's/^CONFIG_FB_INGENIC_PAN_VSYNC_GATE=y$/# CONFIG_FB_INGENIC_PAN_VSYNC_GATE is not set/' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/kernel.config" > "$CURRENT_B2"
if baseline_config_semantic_diff kernel.config "$CURRENT_B2" fixture-baseline-tag "$FIXTURE"; then
	fail "case B: a real behavioral kernel.config difference (display vsync gate disabled) incorrectly PASSED"
else
	pass "case B: a real behavioral kernel.config difference (display vsync gate disabled) correctly fails"
fi

# --- TEST C: a REAL Buildroot behavioral config difference must FAIL. -----
CURRENT_C="$WORK/current-buildroot-C.config"
sed 's/^BR2_TOOLCHAIN_BUILDROOT_VENDOR="nebulaos"$/BR2_TOOLCHAIN_BUILDROOT_VENDOR="something-else"/' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/buildroot.config" > "$CURRENT_C"
if baseline_config_semantic_diff buildroot.config "$CURRENT_C" fixture-baseline-tag "$FIXTURE"; then
	fail "case C: a real behavioral buildroot.config difference (toolchain vendor string changed) incorrectly PASSED"
else
	pass "case C: a real behavioral buildroot.config difference (toolchain vendor string changed) correctly fails"
fi

# --- TEST D: halley5_v30.dts gets NO filter at all - any difference,
# provenance-looking or not, must still fail. This file was never found to
# have a provenance-only field, and it must stay strictly byte-identical.
CURRENT_D="$WORK/current.dts"
sed 's/Halley5 v30/Halley5 v30 modified/' \
	"$FIXTURE/artifacts/buildroot-halley5-v30-image/halley5_v30.dts" > "$CURRENT_D"
if baseline_config_semantic_diff halley5_v30.dts "$CURRENT_D" fixture-baseline-tag "$FIXTURE"; then
	fail "case D: halley5_v30.dts must have zero tolerance for any difference - this incorrectly PASSED"
else
	pass "case D: halley5_v30.dts correctly has zero tolerance and fails on any difference"
fi

# --- TEST E: a genuinely identical file (no changes at all) passes. -------
if baseline_config_semantic_diff halley5_v30.dts "$FIXTURE/artifacts/buildroot-halley5-v30-image/halley5_v30.dts" fixture-baseline-tag "$FIXTURE"; then
	pass "case E: a genuinely unchanged file passes"
else
	fail "case E: a genuinely unchanged file incorrectly failed"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
