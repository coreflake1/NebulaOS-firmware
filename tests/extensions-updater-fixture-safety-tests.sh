#!/bin/sh
#
# Adversarial proof that tests/extensions-updater-branch-strategy-tests.sh
# cannot mutate the repository it is invoked from, under any failure path.
#
# This is the regression suite for a defect that already fired. Four empty
# commits authored by nebulaos-test (fa4a58ac, 2579efe7, 8889ca87, 8d9ecad8)
# are in canonical firmware main's ancestry because that harness did an
# unguarded `cd "$WORK/seed"` and, with -u but not -e, carried on in the
# INHERITED working directory when the cd failed. Its `git push origin main
# production` was aimed at canonical GitHub and failed only by luck (the
# fixture's pin.txt was never written, so the local production branch never
# existed and the refspec could not resolve).
#
# Method: run the REAL harness from inside a throwaway caller repository,
# with `git` and `mktemp` shims that force each interesting failure, and
# assert after every run that the caller repository received no commit, no
# branch, no tag, no remote change, and that its upstream bare repository
# received no push.
#
# Usage: sh tests/extensions-updater-fixture-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HARNESS=$SCRIPT_DIR/extensions-updater-branch-strategy-tests.sh

[ -f "$HARNESS" ] || { echo "SKIP: $HARNESS not present"; exit 0; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fixture-safety-tests.XXXXXX") \
	|| { echo "FAIL: could not create a temporary directory"; exit 1; }
cleanup() {
	if [ -n "${ROOT:-}" ] && [ -d "$ROOT" ]; then
		chmod -R u+w "$ROOT" 2>/dev/null
		rm -rf "$ROOT"
	fi
	return 0
}
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=safety-test GIT_AUTHOR_EMAIL=safety@nebulaos.invalid
export GIT_COMMITTER_NAME=safety-test GIT_COMMITTER_EMAIL=safety@nebulaos.invalid

# --- shims --------------------------------------------------------------
# A `git` that fails on a chosen subcommand, and a `mktemp` that can fail,
# vanish, or produce a write-protected directory. Both delegate to the real
# tool otherwise. Placed first on PATH only for the sabotage runs.
SHIMBIN=$ROOT/shimbin
mkdir -p "$SHIMBIN"
REAL_GIT=$(command -v git)
REAL_MKTEMP=$(command -v mktemp)

cat > "$SHIMBIN/git" <<SHIM
#!/bin/sh
if [ -n "\${FAIL_GIT_ON:-}" ]; then
	for a in "\$@"; do
		if [ "\$a" = "\$FAIL_GIT_ON" ]; then
			echo "shim: forced failure of 'git \$FAIL_GIT_ON'" >&2
			exit 1
		fi
	done
fi
exec $REAL_GIT "\$@"
SHIM

cat > "$SHIMBIN/mktemp" <<SHIM
#!/bin/sh
case "\${MKTEMP_MODE:-}" in
	fail)
		echo "shim: forced mktemp failure" >&2
		exit 1
		;;
	vanish)
		d=\$($REAL_MKTEMP "\$@") || exit 1
		rm -rf "\$d"
		printf '%s\n' "\$d"
		;;
	readonly)
		d=\$($REAL_MKTEMP "\$@") || exit 1
		chmod 500 "\$d"
		printf '%s\n' "\$d"
		;;
	*)
		exec $REAL_MKTEMP "\$@"
		;;
esac
SHIM
chmod 755 "$SHIMBIN/git" "$SHIMBIN/mktemp"

# --- caller-repository fixtures -----------------------------------------
# A throwaway repo standing in for the firmware checkout, with an origin
# that is itself a monitored bare repo. Nothing here may ever change.
CALLER=$ROOT/caller
CALLER_ORIGIN=$ROOT/caller-origin.git
git init -q --bare "$CALLER_ORIGIN"
git init -q -b main "$CALLER"
: > "$CALLER/seed.txt"
git -C "$CALLER" add -A
git -C "$CALLER" commit -q -m "caller seed commit"
git -C "$CALLER" tag caller-tag-1
git -C "$CALLER" remote add origin "$CALLER_ORIGIN"
git -C "$CALLER" push -q origin main

# A plain directory that is NOT a git repository.
NOREPO=$ROOT/norepo
mkdir -p "$NOREPO"

snapshot() {
	_repo=$1
	printf 'commits=%s|branches=%s|tags=%s|remotes=%s|dirty=%s|origin_refs=%s' \
		"$(git -C "$_repo" rev-list --count --all 2>/dev/null)" \
		"$(git -C "$_repo" branch --format='%(refname:short)' 2>/dev/null | sort | tr '\n' ',')" \
		"$(git -C "$_repo" tag 2>/dev/null | sort | tr '\n' ',')" \
		"$(git -C "$_repo" remote -v 2>/dev/null | sort | tr '\n' ',')" \
		"$(git -C "$_repo" status --porcelain 2>/dev/null | wc -l)" \
		"$(git -C "$CALLER_ORIGIN" for-each-ref --format='%(refname)=%(objectname)' 2>/dev/null | sort | tr '\n' ',')"
}

# Run the real harness from $1, with the shim PATH and whatever sabotage
# env the caller sets. Returns the harness's exit status.
run_from() {
	_cwd=$1
	( cd "$_cwd" || exit 99
	  PATH="$SHIMBIN:$PATH" sh "$HARNESS" >/dev/null 2>&1 )
}

check_case() {
	_label=$1; _cwd=$2
	_before=$(snapshot "$CALLER")
	run_from "$_cwd"
	_rc=$?
	_after=$(snapshot "$CALLER")
	if [ "$_before" = "$_after" ]; then
		pass "$_label: caller repository untouched (harness rc=$_rc)"
	else
		fail "$_label: CALLER REPOSITORY MUTATED (rc=$_rc)
     before: $_before
     after : $_after"
	fi
}

# --- 0. canary: the detector actually detects ---------------------------
# Reproduces the OLD vulnerable shape in a disposable repo and proves a
# mutation would be caught. Without this, every PASS below could be vacuous.
CANARY=$ROOT/canary
git init -q -b main "$CANARY"
: > "$CANARY/seed.txt"
git -C "$CANARY" add -A
git -C "$CANARY" commit -q -m "canary seed"
canary_before=$(git -C "$CANARY" rev-list --count --all)
( cd "$CANARY" || exit 1
  # the exact pre-fix pattern: unguarded cd, then commit in whatever cwd
  # SAFETY-SCAN-EXEMPT: deliberate reproduction of the defect, inside a
  # disposable canary repo, so the checks below cannot pass vacuously.
  cd "$ROOT/does-not-exist" 2>/dev/null
  git commit -q --allow-empty -m "canary escape" ) >/dev/null 2>&1
canary_after=$(git -C "$CANARY" rev-list --count --all)
if [ "$canary_before" != "$canary_after" ]; then
	pass "canary: the pre-fix unguarded-cd pattern DOES mutate the caller, so these checks are not vacuous"
else
	fail "canary: the pre-fix pattern did not mutate the caller - this suite cannot prove anything"
fi

# --- the failure matrix -------------------------------------------------
MKTEMP_MODE= FAIL_GIT_ON= ; export MKTEMP_MODE FAIL_GIT_ON

MKTEMP_MODE=fail     FAIL_GIT_ON=       check_case "failed temporary-directory creation" "$CALLER"
MKTEMP_MODE=vanish   FAIL_GIT_ON=       check_case "missing fixture directory"           "$CALLER"
MKTEMP_MODE=readonly FAIL_GIT_ON=       check_case "write-protected fixture"             "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=clone  check_case "failed clone"                        "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=init   check_case "failed fixture remote init"          "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=commit check_case "intentional git command failure"     "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=branch check_case "missing local production branch"     "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=push   check_case "failed fixture push"                 "$CALLER"
MKTEMP_MODE=         FAIL_GIT_ON=       check_case "healthy run, invoked from a real git repo with an origin" "$CALLER"

# Invoked from outside any git repository: nothing to mutate, and it must
# not wander upward looking for one.
before_outside=$(snapshot "$CALLER")
MKTEMP_MODE= FAIL_GIT_ON= run_from "$NOREPO"
rc_outside=$?
after_outside=$(snapshot "$CALLER")
if [ "$before_outside" = "$after_outside" ]; then
	pass "invocation outside a git repository: no repository mutated (harness rc=$rc_outside)"
else
	fail "invocation outside a git repository mutated something"
fi
if [ "$(git -C "$NOREPO" rev-parse --git-dir 2>/dev/null)" = "" ]; then
	pass "invocation outside a git repository: the working directory is still not a repository"
else
	fail "invocation outside a git repository CREATED a repository at $NOREPO"
fi

# The harness must still genuinely pass when nothing is sabotaged.
MKTEMP_MODE= FAIL_GIT_ON= run_from "$CALLER"
if [ $? -eq 0 ]; then
	pass "healthy run still passes its own assertions (the fix did not break the test)"
else
	fail "healthy run failed - the safety fix broke the harness's own assertions"
fi

echo ""
echo "extensions-updater-fixture-safety-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
