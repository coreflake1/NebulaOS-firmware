#!/bin/sh
#
# Static repository-escape safety scan of this directory.
#
# Why this exists. tests/extensions-updater-branch-strategy-tests.sh once
# created four empty commits in the REAL firmware repository and aimed a
# `git push` at canonical GitHub. Nothing about that was exotic: the script
# did an unguarded `cd "$WORK/seed"` inside a subshell, set -u but not -e, so
# when the fixture failed to materialise the `cd` failed, execution carried
# on in the INHERITED working directory, and the fixture's commits landed in
# whatever repository the script had been invoked from. The four commits
# (fa4a58ac, 2579efe7, 8889ca87, 8d9ecad8) are published history and are
# deliberately left in ancestry.
#
# A test fixture must not be able to mutate a real product repository under
# ANY failure path. These are the mechanical properties that make that true,
# checked here so the class of defect cannot quietly return.
#
# Note on scope: absence of `set -e` is deliberately NOT treated as a defect.
# Several suites here exercise commands that are expected to fail, and that
# is the point of those checks. What matters is explicit targeting, not
# abort-on-error.
#
# Usage: sh tests/test-harness-repo-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SELF=$SCRIPT_DIR/$(basename "$0")

# Every tests/*.sh except this scanner itself. Excluding self is not a
# loophole: this file contains the offending patterns only inside its own
# grep patterns and PASS/FAIL message strings, and it makes no git calls at
# all - verified by check 0 below.
SCAN_FILES=$(find "$SCRIPT_DIR" -maxdepth 1 -name '*.sh' -type f ! -path "$SELF" | sort)

# --- 0. this scanner makes no git calls of its own ----------------------
if grep -qE '^[[:space:]]*git[[:space:]]' "$SELF"; then
	echo "FAIL: the safety scanner itself runs git commands - it must be inert"
	exit 1
fi

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- 1. no unguarded `cd` anywhere in tests/ ----------------------------
# A `cd` that starts a command must be guarded (`|| exit`, `|| die`, `&&`
# chain). An unguarded one is the exact mechanism that published those four
# commits. `$(cd ... && pwd)` idioms are already guarded by their own &&.
# A line may be exempted with a SAFETY-SCAN-EXEMPT comment on the two lines
# above it - used by the canary in extensions-updater-fixture-safety-tests.sh,
# which must reproduce the defect inside a disposable repo for its own checks
# not to pass vacuously. Exemptions are printed, never silent.
unguarded=$(echo "$SCAN_FILES" | xargs grep -nE -B2 '^[[:space:]]*cd[[:space:]]' 2>/dev/null \
	| awk '
	    /SAFETY-SCAN-EXEMPT/ { exempt = 3 }
	    /^[^:]*[:-][0-9]+[:-][[:space:]]*cd[[:space:]]/ {
	        if (exempt > 0) { exempt--; next }
	        b = $0; sub(/^[^:]*[:-][0-9]+[:-]/, "", b)
	        if (b ~ /^[[:space:]]*#/) next
	        if (b ~ /\|\|/) next
	        print
	    }
	    { if (exempt > 0) exempt-- }')
exempted=$(echo "$SCAN_FILES" | xargs grep -c 'SAFETY-SCAN-EXEMPT' 2>/dev/null | awk -F: '{t+=$2} END{print t+0}')
if [ -z "$unguarded" ]; then
	pass "no unguarded 'cd' in any tests/*.sh (a failed cd can never fall through into the caller's repository; $exempted audited exemption line(s))"
else
	fail "unguarded 'cd' found - a failure here falls through into the invoking repository:
$unguarded"
fi

# --- 1b. every mktemp result is validated before use --------------------
# The defect that actually escaped during this mission was NOT an unguarded
# `cd`. tests/klipper-git-survival-tests.sh had a plain
# `WORK=$(mktemp -d ...)` with no check; with an unwritable TMPDIR that
# leaves $WORK empty, and `git -C ""` is a NO-OP in git rather than an
# error - so `git -C "$K" checkout -q master` ran against the real firmware
# checkout and switched it to a `master` branch. The same hazard existed in
# scripts/build/lib/make-seed-archive.sh, which the real build uses.
#
# An unvalidated empty path variable is invisible to a `cd`-pattern scan, so
# it gets its own check.
# Coverage extended (audit F-10): the shipped overlay is in scope too. The
# factory-seed script now creates a validated private log directory instead
# of six fixed /tmp paths, and the same empty-path rule applies to it - an
# unvalidated mktemp there would put an empty path into a redirection on a
# real device, not just in a test.
unchecked_tmp=$(echo "$SCAN_FILES" "$SCRIPT_DIR/../scripts/build/lib"/*.sh \
	"$SCRIPT_DIR/../scripts/build/overlay/etc/init.d"/* \
	"$SCRIPT_DIR/../scripts/build/overlay/etc"/*.sh \
	| tr ' ' '\n' | grep -v '^$' | sort -u | while IFS= read -r f; do
		[ -f "$f" ] || continue
		awk -v F="$f" '
		    match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*=\$\(mktemp/) {
		        var = $0
		        sub(/^[ \t]*/, "", var); sub(/=.*$/, "", var)
		        if ($0 ~ /\|\|/) next
		        window = ""
		        for (j = NR; j <= NR + 6; j++) window = window window_lines[j]
		        pending[NR] = var
		    }
		    { window_lines[NR] = $0 "\n" }
		    END {
		        for (n in pending) {
		            v = pending[n]; ok = 0
		            for (j = n; j <= n + 6; j++)
		                if (index(window_lines[j], "-n \"${" v) || index(window_lines[j], "-n \"$" v)) ok = 1
		            if (!ok) print F ":" n " (" v ")"
		        }
		    }' "$f"
	done)
if [ -z "$unchecked_tmp" ]; then
	pass "every mktemp result in tests/ and scripts/build/lib/ is validated before use (an empty path cannot retarget git -C or rm -rf at the caller)"
else
	fail "mktemp result used without validation - an empty path here retargets later commands at the caller's own directory:
$unchecked_tmp"
fi

# --- 2. no UNTARGETED push to a remote by NAME --------------------------
# `git push origin ...` with no `-C` pushes to whatever the INHERITED
# repository's origin happens to be - in the firmware checkout, canonical
# GitHub. That is how the escape nearly published a branch.
#
# `git -C "$fixture" push origin ...` is fine and deliberately allowed: the
# remote name resolves inside the fixture repository, not the caller's.
named_push=$(echo "$SCAN_FILES" | xargs grep -nE '(^|[^-[:alnum:]_])git[[:space:]]+push' 2>/dev/null \
	| awk '{b=$0; sub(/^[^:]*:[0-9]+:/,"",b); sub(/^[0-9]+:/,"",b);
	        if (b ~ /^[[:space:]]*#/) next;
	        if (b ~ /git[[:space:]]+-C[[:space:]]/) next;
	        print}')
if [ -z "$named_push" ]; then
	pass "no tests/*.sh runs an untargeted 'git push' - every push names its repository or its remote by path"
else
	fail "a test runs 'git push' without 'git -C'; an inherited production origin would be the target:
$named_push"
fi

# --- 3. the branch-strategy fixture targets its repository explicitly ---
# This is the script that actually escaped. Every mutating git call in it
# must name its repository with `git -C`, so none of them can inherit a
# working directory. `git init <path>` and `git clone <src> <dst>` are
# exempt: they take their target as an explicit argument.
BS=$SCRIPT_DIR/extensions-updater-branch-strategy-tests.sh
if [ ! -f "$BS" ]; then
	echo "SKIP: $BS not present"
else
	untargeted=$(grep -nE '(^|[^-[:alnum:]_])git[[:space:]]+(commit|push|branch|tag|reset|clean|checkout|switch|remote|add|rebase|merge|cherry-pick)' "$BS" \
		| awk '{b=$0; sub(/^[0-9]+:/,"",b);
		        if (b ~ /^[[:space:]]*#/) next;
		        if (b ~ /git[[:space:]]+-C[[:space:]]/) next;
		        print}')
	if [ -z "$untargeted" ]; then
		pass "extensions-updater-branch-strategy-tests.sh: every mutating git call is explicitly targeted with 'git -C'"
	else
		fail "extensions-updater-branch-strategy-tests.sh has cwd-dependent mutating git calls:
$untargeted"
	fi

	# It must also refuse to run against a fixture root outside its own
	# temporary directory, and fail closed when the fixture cannot be made.
	if grep -q 'REFUSING to mutate' "$BS"; then
		pass "extensions-updater-branch-strategy-tests.sh refuses to mutate a repository outside its fixture root"
	else
		fail "extensions-updater-branch-strategy-tests.sh has no out-of-fixture refusal guard"
	fi
	if grep -q 'could not create a temporary working directory' "$BS"; then
		pass "extensions-updater-branch-strategy-tests.sh fails closed when the fixture cannot be created"
	else
		fail "extensions-updater-branch-strategy-tests.sh does not fail closed on fixture-creation failure"
	fi
fi

echo ""
echo "test-harness-repo-safety-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
