#!/bin/sh
# Applies one of two kernel preemption-model qualification variants
# (R0/R1) to the tracked Kconfig fragment, for the later PREEMPT vs
# PREEMPT_RT A/B (pre-qualification mission Phase A8, 2026-07-31 - see
# docs/NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md sec 12/13/18.15/18.20).
#
#   R0: CONFIG_PREEMPT=y, CONFIG_PREEMPT_RT=n, CONFIG_HZ=100 - today's
#       real, already-shipping baseline. Neither this project's own
#       fragment nor this script needs to add anything for R0 - the base
#       vendor defconfig already sets exactly this (confirmed directly
#       against the last real build's kernel.config), so R0 is simply
#       "no PREEMPT_RT override present in the fragment at all".
#   R1: CONFIG_PREEMPT_RT=y, CONFIG_HZ=100 (unchanged). This kernel is a
#       genuine 6.6-rt23-lineage vendor drop with CONFIG_PREEMPT_RT fully
#       Kconfig-wired and every dependency already satisfied
#       (ARCH_SUPPORTS_RT=y, EXPERT=y, HAVE_POSIX_CPU_TIMERS_TASK_WORK=y -
#       all already true in the base defconfig, confirmed by source
#       reading, not assumed) - enabling it really is just this one
#       Kconfig line, not a backport project.
#
# HZ is never touched by either variant, per the mission's own explicit
# instruction. This script never combines a preemption change with any
# other kernel-config change (SDIO/camera/etc. variants are applied via
# their own separate, independent scripts) - the whole point of an A/B
# is exactly one variable at a time.
#
# Idempotent: always strips any previously-applied R1 block first, then
# adds it back only if R1 was requested - so switching back and forth
# never accumulates duplicate/conflicting lines in the fragment.
#
# Usage: sh scripts/build/preempt-variant.sh <R0|R1>

set -eu

VARIANT="${1:?usage: $0 <R0|R1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# Both overridable, defaulting to the real repo paths so production behaviour
# is bit-identical to before. This exists so the test suite can exercise the
# state machine on a disposable COPY instead of mutating the tracked product
# artifact in place: the suite used to snapshot-and-restore the real fragment,
# which meant a crash, an OOM kill or a SIGKILL mid-run could leave the shipped
# fragment without CONFIG_PREEMPT_RT=y and the next build would silently
# produce a non-RT kernel - exactly the class of bug that suite exists to
# catch. Mirrors the SEEDS/APPS/SYSTEM override convention used by the
# init.d scripts. Changes no configuration.
FRAGMENT="${NEBULAOS_VARIANT_FRAGMENT:-$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config}"
MARKER="${NEBULAOS_VARIANT_MARKER:-$REPO_ROOT/build-work/preempt-variant-applied.txt}"

BEGIN_MARK="#--- NEBULAOS_PREEMPT_RT_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_PREEMPT_RT_VARIANT_END ---"

case "$VARIANT" in
	R0|R1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of R0 R1" >&2
		exit 1
		;;
esac

[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

# Strip any previously-applied R1 block first, unconditionally - the one
# safe way to guarantee idempotence regardless of which variant was
# applied last. The markers are plain text with no regex-special
# characters, so a direct /pattern/,/pattern/d range delete is safe as-is.
if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

if [ "$VARIANT" = "R1" ]; then
	{
		echo "$BEGIN_MARK"
		echo "# Pre-qualification mission Phase A8 (2026-07-31) - PREEMPT_RT"
		echo "# qualification variant. HZ is deliberately left unchanged."
		echo "CONFIG_PREEMPT_RT=y"
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== preempt-variant: $VARIANT applied to $FRAGMENT =="
