#!/bin/sh
#
# Phase 1.5 closure mission (2026-08-19). Tests scripts/build/lib/
# git-provenance.sh's git_provenance_field() - the function
# 05-final-build.sh uses to write every git_commit_*/git_commit_*_dirty
# line in build-manifest.txt.
#
# Exists because of a real, confirmed-by-timestamp incident: a Phase 1.5
# build ran against the firmware worktree while ten commits' worth of
# source changes were still uncommitted. build-manifest.txt correctly
# recorded git_commit_main=<the last real commit> and
# git_commit_main_dirty=yes - which is NOT a provenance bug (dirty=yes is
# exactly the signal that the recorded commit does not fully describe the
# tree state), but was reported at the time as one. These tests prove the
# function's actual, correct behavior in both shapes a real build sees
# (normal clone and git worktree) and in both tree states (clean and
# dirty), so this cannot be re-litigated without evidence again.
#
# Usage: sh tests/git-provenance-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$REPO_ROOT/scripts/build/lib/git-provenance.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-provenance-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

field_value() { echo "$1" | grep "^${2}=" | sed "s/^${2}=//"; }
dirty_value() { echo "$1" | grep "^${2}_dirty=" | sed "s/^${2}_dirty=//"; }

echo "=== git-provenance tests ==="

# --- fixture: a normal clone with two commits -----------------------------
CLONE="$WORK/normal-clone"
mkdir -p "$CLONE"
git -C "$CLONE" init -q -b main
echo one > "$CLONE/file.txt"
git -C "$CLONE" add -A
git -C "$CLONE" commit -q -m "first"
FIRST_SHA=$(git -C "$CLONE" rev-parse HEAD)
echo two >> "$CLONE/file.txt"
git -C "$CLONE" add -A
git -C "$CLONE" commit -q -m "second"
SECOND_SHA=$(git -C "$CLONE" rev-parse HEAD)

# TEST 1 - normal clone, clean tree: reports the real HEAD, dirty=no
out=$(git_provenance_field test_field "$CLONE")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "$SECOND_SHA" ] && pass "normal clone, clean: reports the real HEAD ($SECOND_SHA)" || fail "normal clone, clean: expected $SECOND_SHA, got $val"
[ "$dirty" = "no" ] && pass "normal clone, clean: dirty=no" || fail "normal clone, clean: expected dirty=no, got $dirty"

# TEST 2 - normal clone, DIRTY tree (uncommitted changes on top of a real
# commit): reports the LAST REAL COMMIT plus dirty=yes - this is the exact
# scenario the real Phase 1.5 build hit, and it is CORRECT provenance, not
# a bug: the commit is real, and dirty=yes is the honest signal that the
# tree has more in it than that commit alone.
echo "uncommitted change" >> "$CLONE/file.txt"
out=$(git_provenance_field test_field "$CLONE")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "$SECOND_SHA" ] && pass "normal clone, dirty: still reports the last real commit ($SECOND_SHA), not a phantom or absent value" || fail "normal clone, dirty: expected $SECOND_SHA, got $val"
[ "$dirty" = "yes" ] && pass "normal clone, dirty: dirty=yes correctly signals uncommitted changes on top of that commit" || fail "normal clone, dirty: expected dirty=yes, got $dirty"
git -C "$CLONE" checkout -q -- file.txt

# TEST 3 - a directory that was never a git repo at all: absent/unknown,
# not a crash and not a false commit.
NOTAREPO="$WORK/not-a-repo"
mkdir -p "$NOTAREPO"
out=$(git_provenance_field test_field "$NOTAREPO")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "absent" ] && pass "non-repo directory: reports absent" || fail "non-repo directory: expected absent, got $val"
[ "$dirty" = "unknown" ] && pass "non-repo directory: reports dirty=unknown" || fail "non-repo directory: expected unknown, got $dirty"

# --- fixture: a real git WORKTREE off the same clone -----------------------
WT="$WORK/worktree-checkout"
# Detached, not by branch name: `main` is already checked out in $CLONE
# itself, and git refuses to have the same branch checked out in two
# worktrees at once - detaching at the same commit still exercises the
# real worktree .git-file shape this function has to handle.
git -C "$CLONE" worktree add -q --detach "$WT" "$SECOND_SHA"
if [ -f "$WT/.git" ]; then
	pass "worktree fixture: .git is a FILE (the real worktree shape being tested), not a directory"
else
	fail "worktree fixture: .git is not a file - fixture setup itself is wrong, results below are not meaningful"
fi

# TEST 4 - worktree, clean: reports the real HEAD, dirty=no. This is the
# exact case that used to silently report "absent" before this mission's
# fix (checking `-d "$fdir/.git"` alone, which is false for a worktree).
out=$(git_provenance_field test_field "$WT")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "$SECOND_SHA" ] && pass "worktree, clean: reports the real HEAD ($SECOND_SHA), not absent" || fail "worktree, clean: expected $SECOND_SHA, got $val"
[ "$dirty" = "no" ] && pass "worktree, clean: dirty=no" || fail "worktree, clean: expected dirty=no, got $dirty"

# TEST 5 - worktree, dirty: same correct commit+dirty=yes behavior as a
# normal clone - the worktree shape must not change this semantic.
echo "uncommitted worktree change" >> "$WT/file.txt"
out=$(git_provenance_field test_field "$WT")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "$SECOND_SHA" ] && pass "worktree, dirty: still reports the last real commit ($SECOND_SHA)" || fail "worktree, dirty: expected $SECOND_SHA, got $val"
[ "$dirty" = "yes" ] && pass "worktree, dirty: dirty=yes" || fail "worktree, dirty: expected dirty=yes, got $dirty"
git -C "$WT" checkout -q -- file.txt

# TEST 6 - a worktree whose gitdir pointer is UNREACHABLE (simulates a
# container where the host's git-common-dir is not mounted): must report
# absent/unknown, never crash, never fabricate a commit.
BROKEN_WT="$WORK/broken-worktree"
cp -r "$WT" "$BROKEN_WT"
rm -rf "$BROKEN_WT/.git"
echo "gitdir: /nonexistent/path/that/does/not/exist/.git/worktrees/x" > "$BROKEN_WT/.git"
out=$(git_provenance_field test_field "$BROKEN_WT")
val=$(field_value "$out" test_field)
dirty=$(dirty_value "$out" test_field)
[ "$val" = "absent" ] && pass "worktree with unreachable gitdir: reports absent, not a crash or a fabricated commit" || fail "worktree with unreachable gitdir: expected absent, got $val"
[ "$dirty" = "unknown" ] && pass "worktree with unreachable gitdir: reports dirty=unknown" || fail "worktree with unreachable gitdir: expected unknown, got $dirty"

git -C "$CLONE" worktree remove -f "$WT" >/dev/null 2>&1

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
