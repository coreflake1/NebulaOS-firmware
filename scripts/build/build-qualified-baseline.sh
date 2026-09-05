#!/bin/sh
# Repository + Canonical Baseline Repair mission, Phase 7 (2026-08-07): the
# single documented command that reproduces the current qualified NebulaOS
# production baseline (tag nebulaos-wifi-camera-irq-fix-2026-08-04, plus the
# non-tagged accepted work since it - GuppyScreen/z_compensate, see
# docs/NEBULAOS_QUALIFIED_BASELINE_VARIANT_AUDIT.md) from nothing but this
# checkout, the pinned manifest, and the network.
#
# Deliberately the smallest thing that fits this repo's existing conventions
# - it just sequences the pipeline stages already used individually all
# along, in the order they must run, with the baseline-composition and
# assertion steps at the points that actually matter:
#
#   00-fetch-vendor-sources.sh    fetch every pinned source (fails loudly on
#                                  any unpushed/unresolvable pin - see
#                                  manifests/dependencies.conf)
#   apply-qualified-baseline.sh   compose all 8 accepted kernel variants
#   assert-baseline-config.sh pre-build   fail fast if a variant's source-
#                                  level change didn't actually land, before
#                                  spending build time
#   01 -> 06                      the existing numbered pipeline, unchanged
#   assert-baseline-config.sh post-build  prove the resolved artifact
#                                  actually contains what was composed
#
# This does NOT reuse any existing vendor/, build-work/, or artifacts/
# state - run it against a genuinely fresh clone (a dirty/reused checkout
# defeats the entire point of a clean-room build; 00-fetch-vendor-sources.sh
# will happily reuse an already-present vendor/ directory if one exists,
# which is convenient for iteration but not what this script is for).
#
# Usage: sh scripts/build/build-qualified-baseline.sh
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either assertion fails, or any build stage fails.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

echo "=== build-qualified-baseline: fetching every pinned source ==="
sh "$SCRIPT_DIR/00-fetch-vendor-sources.sh"

echo "=== build-qualified-baseline: composing all 8 accepted kernel variants ==="
sh "$SCRIPT_DIR/apply-qualified-baseline.sh"

echo "=== build-qualified-baseline: pre-build assertions (source-level) ==="
sh "$SCRIPT_DIR/assert-baseline-config.sh" pre-build

echo "=== build-qualified-baseline: running the build pipeline ==="
sh "$SCRIPT_DIR/01-apply-kernel-patches.sh"
sh "$SCRIPT_DIR/02-configure-buildroot.sh"
sh "$SCRIPT_DIR/03-build-kernel-and-rootfs.sh"
sh "$SCRIPT_DIR/04-cross-compile-app-stack.sh"
sh "$SCRIPT_DIR/05-final-build.sh"
sh "$SCRIPT_DIR/06-verify.sh"

echo "=== build-qualified-baseline: post-build assertions (resolved artifacts) ==="
if [ "${NEBULAOS_CANDIDATE_BUILD:-}" = "1" ]; then
	sh "$SCRIPT_DIR/assert-baseline-config.sh" candidate-post-build
else
	sh "$SCRIPT_DIR/assert-baseline-config.sh" post-build
fi

echo "=== build-qualified-baseline: complete and composition-verified ==="
echo "Package it with: sh scripts/build/package-deployment.sh"
