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

# A real device found live: clone_pinned() alone (checked above) was
# correctly fixed and passed every unit test, but a real build still
# shipped a seed archive on branch "main" - make_seed_archive()'s own
# `git checkout -B "$active_branch"` unconditionally re-renames the
# ARCHIVED copy's local branch, and the extensions call site in
# 04-cross-compile-app-stack.sh had a second, completely independent
# hardcoded "main" literal there. This static check exists so that
# specific literal can never silently reappear; section 4 below exercises
# the full chain end to end to prove the actual archived output.
if grep -qF 'make_seed_archive "$VENDOR/nebulaos-klipper-extensions" "$KLIPPER_EXTENSIONS_BRANCH"' "$COMPILE_SCRIPT"; then
	pass "04-cross-compile-app-stack.sh: extensions make_seed_archive call site passes \$KLIPPER_EXTENSIONS_BRANCH, not a hardcoded literal"
else
	fail "04-cross-compile-app-stack.sh: extensions make_seed_archive call site does not pass \$KLIPPER_EXTENSIONS_BRANCH (the exact live bug: a hardcoded branch literal here silently overrides clone_pinned()'s correct local_branch)"
fi

# --- Section 2: clone_pinned() end-to-end, against a fake remote that ---
#     reproduces the exact live scenario (configured branch's tip is
#     BEHIND the pin, i.e. the pin is ahead of it, not merely different)

export GIT_AUTHOR_NAME=nebulaos-test GIT_AUTHOR_EMAIL=test@nebulaos.invalid
export GIT_COMMITTER_NAME=nebulaos-test GIT_COMMITTER_EMAIL=test@nebulaos.invalid

# --- fixture safety ------------------------------------------------------
# This suite creates commits, a branch and a push. Every one of those MUST
# land in a throwaway fixture, and none of them may ever reach the
# repository the script happens to be invoked from.
#
# One of them did, for real. Four empty commits authored by nebulaos-test
# (fa4a58ac, 2579efe7, 8889ca87, 8d9ecad8) sit in canonical firmware main's
# ancestry to this day. The mechanism: a subshell did an UNGUARDED
# `cd "$WORK/seed"` and, because this script sets -u but not -e, execution
# continued in the INHERITED working directory when that cd failed - so
# `git commit --allow-empty` ran against the firmware checkout, and
# `git push origin main production` was aimed at canonical GitHub. The push
# happened to fail only because the fixture's pin.txt was never written, so
# the local production branch was never created and the refspec could not
# resolve. That is luck, not a safeguard.
#
# Those four commits are published history and are deliberately left in
# place - rewriting them would invalidate every existing clone. This is the
# fix for the harness that produced them.
#
# The rules, now enforced rather than assumed:
#   * fixture creation is fail-closed: any failure aborts, loudly;
#   * every mutating git call names its repository with `git -C`, so none of
#     them can inherit a working directory;
#   * the push names the fixture bare remote BY PATH, never by the remote
#     name `origin`, so an inherited production `origin` is not reachable as
#     a fallback even in principle;
#   * fixture_repo() re-derives each repository's own git dir and refuses to
#     touch anything outside $WORK.
#
# `set -e` is deliberately NOT added: sections 3 and 5 exercise commands
# that are EXPECTED to fail - that is precisely what those regression checks
# prove. Safety here comes from explicit targeting, not from abort-on-error.

die() { echo "FATAL: $1" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/extensions-branch-strategy-tests.XXXXXX") \
	|| die "could not create a temporary working directory"
[ -n "${WORK:-}" ] || die "mktemp produced an empty path"
[ -d "$WORK" ]     || die "mktemp did not produce a directory ('$WORK')"
case "$WORK" in
	/*) ;;
	*) die "refusing to use a relative fixture root ('$WORK')" ;;
esac
[ -w "$WORK" ] || die "fixture root is not writable ('$WORK')"

# Only ever remove a real directory this run actually created.
cleanup() {
	if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
		rm -rf "$WORK"
	fi
	return 0
}
trap cleanup EXIT INT TERM

# Resolve a repository's own git dir and prove it lives inside the fixture
# root before anything mutates it. This is the last line of defence: if it
# ever fires, the run stops rather than "probably" being fine.
fixture_repo() {
	_fr_dir=$1
	[ -d "$_fr_dir" ] || die "fixture repository '$_fr_dir' does not exist"
	_fr_git=$(git -C "$_fr_dir" rev-parse --absolute-git-dir 2>/dev/null) \
		|| die "'$_fr_dir' is not a git repository"
	case "$_fr_git" in
		"$WORK"/*) ;;
		*) die "REFUSING to mutate '$_fr_git': outside the fixture root $WORK" ;;
	esac
}

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
REMOTE=$WORK/remote.git
SEED=$WORK/seed

mkdir -p "$REMOTE" || die "could not create the fixture remote directory"
git init -q -b main --bare "$REMOTE" || die "could not initialise the fixture bare remote"
fixture_repo "$REMOTE"

git clone -q "$REMOTE" "$SEED" || die "could not clone the fixture remote into a seed checkout"
[ -d "$SEED/.git" ] || die "fixture seed checkout was not created at $SEED"
fixture_repo "$SEED"

# Every call below names $SEED explicitly. There is no `cd`, so there is no
# inherited working directory for any of this to fall through into.
git -C "$SEED" checkout -q -b main 2>/dev/null || true
git -C "$SEED" commit -q --allow-empty -m "c1" \
	|| die "fixture: could not create commit c1"
git -C "$SEED" commit -q --allow-empty -m "c2 (the pin - production points here)" \
	|| die "fixture: could not create commit c2"
git -C "$SEED" rev-parse HEAD > "$WORK/pin.txt" \
	|| die "fixture: could not record the pin commit"
git -C "$SEED" commit -q --allow-empty -m "c3 (main keeps moving, unrelated to the pin)" \
	|| die "fixture: could not create commit c3"
git -C "$SEED" commit -q --allow-empty -m "c4 (main keeps moving, unrelated to the pin)" \
	|| die "fixture: could not create commit c4"

PIN=$(cat "$WORK/pin.txt" 2>/dev/null) || die "fixture: pin.txt could not be read"
[ -n "$PIN" ] || die "fixture: the recorded pin is empty"

git -C "$SEED" branch production "$PIN" \
	|| die "fixture: could not create the production branch at $PIN"
# By PATH, never by the remote name. An inherited `origin` pointing at a real
# product repository must not be reachable from this push even in principle.
git -C "$SEED" push -q "$REMOTE" main production \
	|| die "fixture: could not push main/production to the fixture remote"

rm -rf "$SEED"

(
	cd "$WORK" || exit 1
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
	cd "$WORK" || exit 1
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

# --- Section 4: full chain (clone_pinned + make_seed_archive) - the -----
#     ACTUAL live bug: clone_pinned() alone was fixed and unit-tested
#     correctly (section 2 above), but a real build still shipped a seed
#     archive on branch "main". Root cause: 04-cross-compile-app-stack.sh's
#     extensions call to make_seed_archive() passed a second, completely
#     independent hardcoded "main" literal - that function's own
#     `git checkout -B "$active_branch"` unconditionally force-renames the
#     LOCAL branch in the ARCHIVED copy to whatever it is given, silently
#     undoing clone_pinned()'s already-correct "production" attachment.
#     Neither fix alone is sufficient; this test exercises both functions
#     in the same sequence a real build does, and would have caught this
#     before it reached a real build.

MAKE_SEED_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
if [ -f "$MAKE_SEED_ARCHIVE_LIB" ]; then
	(
		cd "$WORK" || exit 1
		. ./clone_pinned_fn.sh
		clone_pinned chain_target "$WORK/remote.git" "$PIN" "" "" "production" > "$WORK/chain_clone.log" 2>&1
		. "$MAKE_SEED_ARCHIVE_LIB"
		make_seed_archive "$WORK/chain_target" "production" "$WORK/remote.git" "$WORK/chain-seed.tar" "" \
			> "$WORK/chain_archive.log" 2>&1
	)

	if [ -f "$WORK/chain-seed.tar" ]; then
		pass "chain: make_seed_archive produced a seed tar"
	else
		fail "chain: make_seed_archive did not produce a seed tar ($(cat "$WORK/chain_archive.log" 2>/dev/null))"
	fi

	rm -rf "$WORK/chain-extracted"; mkdir -p "$WORK/chain-extracted"
	tar -xf "$WORK/chain-seed.tar" -C "$WORK/chain-extracted" 2>/dev/null

	chain_branch=$(git -C "$WORK/chain-extracted" symbolic-ref --short HEAD 2>/dev/null)
	if [ "$chain_branch" = "production" ]; then
		pass "chain: the ARCHIVED seed tar's local branch is 'production' (the actual live-checked property - clone_pinned() alone is not enough)"
	else
		fail "chain: the archived seed tar is on branch '$chain_branch', expected 'production' - this is the exact live bug (06-verify's check_seed_archive would report MISS)"
	fi

	chain_head=$(git -C "$WORK/chain-extracted" rev-parse HEAD 2>/dev/null)
	if [ "$chain_head" = "$PIN" ]; then
		pass "chain: the archived seed tar's content is still the correct pinned commit"
	else
		fail "chain: the archived seed tar's HEAD is $chain_head, expected the pin $PIN"
	fi
else
	fail "scripts/build/lib/make-seed-archive.sh not found - cannot test the full clone_pinned+make_seed_archive chain"
fi

# Sanity check the other direction: reproduce the exact live bug by
# passing the OLD hardcoded "main" literal to make_seed_archive() even
# though clone_pinned() correctly attached "production" - confirms this
# test suite actually distinguishes the two, not just checking they agree.
if [ -f "$MAKE_SEED_ARCHIVE_LIB" ]; then
	(
		cd "$WORK" || exit 1
		. ./clone_pinned_fn.sh
		clone_pinned chain_target_bug "$WORK/remote.git" "$PIN" "" "" "production" > "$WORK/chain_clone_bug.log" 2>&1
		. "$MAKE_SEED_ARCHIVE_LIB"
		make_seed_archive "$WORK/chain_target_bug" "main" "$WORK/remote.git" "$WORK/chain-seed-bug.tar" "" \
			> "$WORK/chain_archive_bug.log" 2>&1
	)
	rm -rf "$WORK/chain-extracted-bug"; mkdir -p "$WORK/chain-extracted-bug"
	tar -xf "$WORK/chain-seed-bug.tar" -C "$WORK/chain-extracted-bug" 2>/dev/null
	chain_bug_branch=$(git -C "$WORK/chain-extracted-bug" symbolic-ref --short HEAD 2>/dev/null)
	if [ "$chain_bug_branch" = "main" ]; then
		pass "sanity: passing the old hardcoded \"main\" literal to make_seed_archive reproduces the exact live bug, confirming this test suite catches it"
	else
		fail "sanity: passing \"main\" to make_seed_archive did not reproduce the bug (got '$chain_bug_branch') - this test may not be exercising the real issue"
	fi
fi

echo ""
echo "extensions-updater-branch-strategy-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
