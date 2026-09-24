#!/usr/bin/env bash
#
# Source-level regression assertions for image reproducibility.
#
# These do not build. They assert that the *inputs* found to be
# nondeterministic stay fixed, so a regression surfaces in seconds rather than
# as a hash mismatch two builds later.
#
# The measured causes are recorded in docs/REPRODUCIBILITY.md.
#
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd -P)
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
have() { grep -qF "$2" "$ROOT/$1" 2>/dev/null; }

S04=scripts/build/04-cross-compile-app-stack.sh
BRC=artifacts/buildroot-halley5-v30-image/buildroot.config
CH=scripts/build/overlay/etc/nebulaos-chelper-preflight.sh

echo "REPRODUCIBILITY SOURCE ASSERTIONS"
echo
echo "[ SOURCE_DATE_EPOCH ]"
if grep -q 'SOURCE_DATE_EPOCH=$(git -C "$SCRIPT_DIR" show -s --format=%ct HEAD' "$ROOT/build.sh"; then
  ok "build.sh derives SOURCE_DATE_EPOCH from the firmware commit"
else
  bad "build.sh no longer derives SOURCE_DATE_EPOCH from the commit"
fi

if grep -q 'FATAL: cannot derive SOURCE_DATE_EPOCH' "$ROOT/build.sh"; then
  ok "build.sh fails closed when the epoch cannot be derived"
else
  bad "build.sh no longer fails closed on an underivable epoch"
fi

if have build.sh '-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"'; then
  ok "SOURCE_DATE_EPOCH is propagated into the build container"
else
  bad "SOURCE_DATE_EPOCH is NOT propagated into the container"
fi

echo
echo "[ Buildroot ]"
if have "$BRC" 'BR2_REPRODUCIBLE=y'; then
  ok "BR2_REPRODUCIBLE=y (normalises mtimes, bytecode and archive metadata)"
else
  bad "BR2_REPRODUCIBLE is not enabled"
fi

# Buildroot salts a PLAINTEXT root password randomly at build time, which
# rewrote /etc/shadow on every build. A pre-computed hash fixes the salt. That
# the hash is for the same password is not checkable here, only that it is a
# hash; changing it is a deliberate act.
if grep -qE '^BR2_TARGET_GENERIC_ROOT_PASSWD="\$[0-9]\$' "$ROOT/$BRC"; then
  ok "root password is a pre-computed hash (deterministic /etc/shadow)"
else
  bad "root password is plaintext - Buildroot will salt it randomly per build"
fi

echo
echo "[ generated metadata ]"
if grep -q 'build_date=$(date -u -d "@${SOURCE_DATE_EPOCH' "$ROOT/$S04"; then
  ok "build_date is derived from SOURCE_DATE_EPOCH"
else
  bad "build_date is not epoch-derived"
fi

if grep -qE '^build_date=\$\(date -u \+' "$ROOT/$S04"; then
  bad "a bare wall-clock build_date assignment is back in stage 04"
else
  ok "no bare wall-clock build_date assignment in stage 04"
fi

if have "$CH" 'if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then'; then
  ok "chelper preflight uses the epoch at build time, the wall clock at boot"
else
  bad "chelper preflight writes a wall-clock checked_at into the image"
fi

echo
echo "[ GuppyScreen (closed previously, must stay closed) ]"
if grep -q 'GUPPY_EPOCH=$(git -C "$GUPPYSCREEN_SRC" show -s --format=%ct "$GUPPY_REF"' "$ROOT/$S04"; then
  ok "GuppyScreen epoch is still anchored to GUPPYSCREEN_PIN, not vendor HEAD"
else
  bad "GuppyScreen epoch anchoring regressed"
fi

if have "$S04" 'FATAL: GUPPYSCREEN_PIN is unset or empty'; then
  ok "an unset GUPPYSCREEN_PIN is still fatal"
else
  bad "an unset GUPPYSCREEN_PIN no longer fails the build"
fi

if have "$S04" 'rm -rf "$GUPPYSCREEN_SRC/build" "$GUPPYSCREEN_SRC/libhv/build-mips" "$GUPPYSCREEN_SRC/spdlog/build-mips"'; then
  ok "libhv/spdlog cross-build trees are still cleared"
else
  bad "the libhv/spdlog cross-build clean regressed - the epoch would be a no-op"
fi

echo
echo "TESTS_PASS=$PASS"
echo "TESTS_FAIL=$FAIL"
if [ "$FAIL" -ne 0 ]; then echo "REPRODUCIBILITY_ASSERTIONS=FAIL"; exit 1; fi
echo "REPRODUCIBILITY_ASSERTIONS=PASS"
exit 0
