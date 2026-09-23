#!/bin/sh
#
# The shipped init scripts are the highest-consequence shell in this repo: a
# parse error in one of them means the device never boots that stage again.
# This suite exists because that safety net proved able to vanish SILENTLY.
#
# A prose comment introduced in D-01 began with the literal "# shellcheck".
# ShellCheck parses that as a directive, fails on it (SC1073/SC1072), and
# ABORTS analysis of the entire file - so S04nebulaos-migrate, the most
# safety-critical init script here, went unanalysed while every other check
# still passed. `bash -n` was happy, the suites were green, and nothing said
# otherwise. One word of prose disabled static analysis of 1500 lines.
#
# It also partially covers a concern that cannot be tested on this host at
# all: the device runs BusyBox ash, and neither busybox nor dash is installed
# here, so `bash -n` is the only parse check available. `shellcheck -s sh`
# applies POSIX sh rules and is the closest available proxy.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
INITD="$REPO_ROOT/scripts/build/overlay/etc/init.d"

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "SKIP: shellcheck is not installed - cannot lint the shipped init scripts"
	echo ""
	echo "overlay-shell-lint-tests: 0 passed, 0 failed, 1 skipped"
	exit 0
fi

# 1. Every shipped init script must PARSE. A parse abort (SC1009/SC1072/
#    SC1073) is always fatal here - it means the file was not analysed at all,
#    which is indistinguishable from "analysed and clean" in any output that
#    only greps for warnings.
for f in "$INITD"/S*; do
	[ -f "$f" ] || continue
	n=$(basename "$f")
	out=$(shellcheck -s sh "$f" 2>&1)
	if echo "$out" | grep -qE 'SC1009|SC1072|SC1073'; then
		fail "$n: ShellCheck could not parse it - analysis ABORTED, so this file is effectively unchecked: $(echo "$out" | grep -m1 -E 'SC1073|SC1072')"
	else
		pass "$n parses; ShellCheck analysed the whole file"
	fi
	if ! bash -n "$f" 2>/dev/null; then
		fail "$n fails bash -n"
	fi
done

# 2. The specific trap that caused this: a comment whose first word is
#    "shellcheck" but which is not a valid directive.
for f in "$INITD"/S* "$REPO_ROOT"/scripts/build/overlay/etc/*.sh; do
	[ -f "$f" ] || continue
	n=$(basename "$f")
	bad=$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck([^[:alnum:]-]|$)' "$f" \
		| grep -vE '#[[:space:]]*shellcheck[[:space:]]+(disable|source|shell|enable)=?' || true)
	if [ -n "$bad" ]; then
		fail "$n has a comment starting with '# shellcheck' that is not a valid directive - this silently aborts analysis of the whole file: $bad"
	fi
done
pass "no prose comment masquerades as a ShellCheck directive in the shipped shell"

echo ""
echo "overlay-shell-lint-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
