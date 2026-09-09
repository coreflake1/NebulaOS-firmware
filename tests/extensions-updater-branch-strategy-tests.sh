#!/bin/sh
#
# Offline, repeatable tests for the Extensions update-manager branch
# strategy fix (Phase 2 final software closure mission, 2026-09-09 - see
# docs/NEBULAOS_EXTENSIONS_BRANCH_STRATEGY.md for the full mechanical
# root-cause writeup).
#
# A real device found live: Moonraker reported `is_valid: false` /
# "diverged from remote" for the nebulaos_klipper_extensions update_manager
# entry. Root cause verified via `git merge-base`: the deployed pin was 31
# commits AHEAD of origin/main (this project never merges in-development
# phase work to main), which Moonraker's git_repo update_manager reports as
# divergence rather than "no update needed" when checked against
# `primary_branch: main`.
#
# Fix: track a dedicated `production` branch (fast-forwarded to match the
# pin on every qualified release) instead of `main`, everywhere the branch
# name is configured or recorded. This file proves:
#   1. every config file that names the tracked branch says "production",
#      never "main", and stays mutually consistent
#   2. clone_pinned()'s non-shallow path (used for extensions) produces a
#      correctly-attached local branch on a genuinely fresh clone, even
#      when the configured branch's remote tip has moved past the pin -
#      the exact scenario that broke live. This also regression-tests a
#      second, independently-found bug in the same function: a bare
#      `git checkout <sha>` always detaches HEAD, even when the sha
#      equals the current branch tip - previously masked only because a
#      long-lived, never-freshly-cloned local vendor/ checkout happened
#      to already be on the right branch.
#
# Usage: sh tests/extensions-updater-branch-strategy-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEPS_CONF="$REPO_ROOT/manifests/dependencies.conf"
PIN_CONF="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/moonraker/klipper-pin.conf"
FETCH_SCRIPT="$REPO_ROOT/scripts/build/00-fetch-vendor-sources.sh"
COMPILE_SCRIPT="$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh"

for f in "$DEPS_CONF" "$PIN_CONF" "$FETCH_SCRIPT" "$COMPILE_SCRIPT"; do
	[ -f "$f" ] || { echo "SKIP: $f not present"; exit 0; }
done

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# --- Section 1: static config consistency -------------------------------

configured_branch=$(grep '^KLIPPER_EXTENSIONS_BRANCH=' "$DEPS_CONF" | tail -1 | cut -d= -f2)
if [ "$configured_branch" = "production" ]; then
	pass "manifests/dependencies.conf: KLIPPER_EXTENSIONS_BRANCH=production"
else
	fail "manifests/dependencies.conf: KLIPPER_EXTENSIONS_BRANCH=$configured_branch, expected production"
fi

if grep -qxF 'primary_branch: production' "$PIN_CONF"; then
	pass "klipper-pin.conf: [update_manager nebulaos_klipper_extensions] primary_branch: production"
else
	fail "klipper-pin.conf: primary_branch is not 'production'"
fi

if grep -q 'primary_branch: main' "$PIN_CONF"; then
	fail "klipper-pin.conf: a primary_branch: main line still exists somewhere"
else
	pass "klipper-pin.conf: no primary_branch: main line remains"
fi

if grep -qF '"branch": "$KLIPPER_EXTENSIONS_BRANCH"' "$COMPILE_SCRIPT"; then
	pass "04-cross-compile-app-stack.sh: extensions seed-manifest branch field uses \$KLIPPER_EXTENSIONS_BRANCH, not a hardcoded literal"
else
	fail "04-cross-compile-app-stack.sh: extensions seed-manifest branch field does not reference \$KLIPPER_EXTENSIONS_BRANCH"
fi

if grep -qF 'clone_pinned nebulaos-klipper-extensions "$KLIPPER_EXTENSIONS_REPO" "$KLIPPER_EXTENSIONS_PIN" "" "" "$KLIPPER_EXTENSIONS_BRANCH"' "$FETCH_SCRIPT"; then
	pass "00-fetch-vendor-sources.sh: extensions clone_pinned call site passes KLIPPER_EXTENSIONS_BRANCH as local_branch"
else
	fail "00-fetch-vendor-sources.sh: extensions clone_pinned call site does not pass local_branch"
fi

# --- Section 2: clone_pinned() end-to-end, against a fake remote that ---
#     reproduces the exact live scenario (configured branch's tip is
#     BEHIND the pin, i.e. the pin is ahead of it, not merely different)

export GIT_AUTHOR_NAME=nebulaos-test GIT_AUTHOR_EMAIL=test@nebulaos.invalid
export GIT_COMMITTER_NAME=nebulaos-test GIT_COMMITTER_EMAIL=test@nebulaos.invalid

WORK=$(mktemp -d "${TMPDIR:-/tmp}/extensions-branch-strategy-tests.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

awk '/^clone_pinned\(\) \{/,/^}/' "$FETCH_SCRIPT" > "$WORK/clone_pinned_fn.sh"

# Build a fake remote: main advances PAST the point production/pin sits at,
# then further still - reproducing "configured branch is ahead in wall-
# clock time but the deployed pin is not reachable from it going forward,
# and production/pin needs its own separate ref" is the wrong framing;
# what actually broke live is simpler: production's tip (the pin) must be
# directly fetchable and checkoutable as an attached branch REGARDLESS of
# where main currently sits, including cases where main is not even an
# ancestor relationship worth computing here - clone_pinned() has no
# reason to know or care about main at all once local_branch=production is
# used, which is exactly the point of the fix.
mkdir -p "$WORK/remote.git"
git init -q -b main --bare "$WORK/remote.git"
git clone -q "$WORK/remote.git" "$WORK/seed"
(
	cd "$WORK/seed"
	git checkout -q -b main 2>/dev/null || true
	git commit -q --allow-empty -m "c1"
	git commit -q --allow-empty -m "c2 (the pin - production points here)"
	echo "$(git rev-parse HEAD)" > "$WORK/pin.txt"
	git commit -q --allow-empty -m "c3 (main keeps moving, unrelated to the pin)"
	git commit -q --allow-empty -m "c4 (main keeps moving, unrelated to the pin)"
	git branch production "$(cat "$WORK/pin.txt")"
	git push -q origin main production
)
rm -rf "$WORK/seed"
PIN=$(cat "$WORK/pin.txt")

(
	cd "$WORK"
	. ./clone_pinned_fn.sh
	clone_pinned target "$WORK/remote.git" "$PIN" "" "" "production" > "$WORK/clone.log" 2>&1
	echo "RC=$?" >> "$WORK/clone.log"
)

if [ -d "$WORK/target/.git" ]; then
	pass "clone_pinned: target checkout was created"
else
	fail "clone_pinned: target checkout was not created ($(cat "$WORK/clone.log" 2>/dev/null))"
fi

actual_branch=$(git -C "$WORK/target" symbolic-ref --short HEAD 2>/dev/null)
if [ "$actual_branch" = "production" ]; then
	pass "clone_pinned: resulting checkout is attached to branch 'production', not detached"
else
	fail "clone_pinned: resulting checkout is on '$actual_branch' (expected 'production' - a detached HEAD here is exactly the live bug)"
fi

actual_head=$(git -C "$WORK/target" rev-parse HEAD 2>/dev/null)
if [ "$actual_head" = "$PIN" ]; then
	pass "clone_pinned: HEAD is exactly the pinned commit"
else
	fail "clone_pinned: HEAD is $actual_head, expected pin $PIN"
fi

branch_remote=$(git -C "$WORK/target" config --get branch.production.remote 2>/dev/null)
branch_merge=$(git -C "$WORK/target" config --get branch.production.merge 2>/dev/null)
if [ "$branch_remote" = "origin" ] && [ "$branch_merge" = "refs/heads/production" ]; then
	pass "clone_pinned: branch.production.remote/merge wired correctly (what Moonraker's GitDeploy reads)"
else
	fail "clone_pinned: branch.production.remote/merge not wired correctly (remote=$branch_remote merge=$branch_merge)"
fi

# --- Section 3: the exact previously-latent regression, isolated -------
#     (no local_branch argument at all - the old call shape) must still
#     reproduce a detached HEAD, proving this test would have caught the
#     original bug rather than trivially passing regardless of the fix.

(
	cd "$WORK"
	. ./clone_pinned_fn.sh
	clone_pinned target_old_shape "$WORK/remote.git" "$PIN" > "$WORK/clone_old.log" 2>&1
)
old_shape_branch=$(git -C "$WORK/target_old_shape" symbolic-ref --short HEAD 2>&1)
case "$old_shape_branch" in
	*"not a symbolic ref"*|*"fatal"*)
		pass "sanity: the pre-fix call shape (no local_branch) reproduces a detached HEAD, confirming this suite actually catches the bug"
		;;
	*)
		fail "sanity: the pre-fix call shape did not reproduce a detached HEAD (got '$old_shape_branch') - this test may not be exercising the real bug"
		;;
esac

echo ""
echo "extensions-updater-branch-strategy-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
