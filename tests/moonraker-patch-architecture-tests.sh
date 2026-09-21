#!/usr/bin/env bash
#
# Adversarial tests for the Moonraker architecture invariant
# (tools/verify-architecture.sh section 6,
#  canonical: tools/workspace-control/scripts/verify-architecture.sh).
#
# Background - the defect these tests exist to prevent recurring. The
# invariant used to be called "moonraker-unmodified" and reported PASS on
# every run while the build was, in fact, patching Moonraker on every build.
# It was blind three independent ways:
#
#   1. the regex was `patch +-p[0-9]`, requiring `-p<digit>` IMMEDIATELY
#      after `patch`. The real call site is `patch -N -p1`, so `-N`
#      intervened and the pattern could never match.
#   2. the glob was `scripts/build/*.sh` - non-recursive, so a patch step in
#      scripts/build/lib/ would never have been scanned at all.
#   3. the `grep -vE '^\s*#'` comment filter was inoperative: `grep -rn`
#      prefixes every output line with `file:lineno:`, so `^\s*#` could
#      never match, and a commented-out patch command would still be counted.
#
# Each test below drives the REAL invariant script against a synthetic
# workspace root, so these are tests of the shipped checker, not of a
# reimplementation of it.
#
# Usage: sh tests/moonraker-patch-architecture-tests.sh

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CHECKER=$REPO_ROOT/tools/workspace-control/scripts/verify-architecture.sh
REAL_PATCH=$REPO_ROOT/scripts/build/patches/moonraker-sqlite-nolock.patch
INV_NAME=moonraker-official-upstream-allowlisted-patches-only

for f in "$CHECKER" "$REAL_PATCH"; do
	[ -f "$f" ] || { echo "SKIP: $f not present"; exit 0; }
done

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/moonraker-invariant-tests.XXXXXX") || {
	echo "FAIL: could not create a temporary directory"; exit 1; }
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Build a synthetic workspace root the real checker can run against. Only the
# Moonraker section's inputs are realistic; every other invariant is expected
# to fail in here and is deliberately ignored - we grep for one line.
new_fixture() {
	root=$WORK/$1
	rm -rf "$root"
	mkdir -p "$root/tools" "$root/NebulaOS-firmware/manifests" \
	         "$root/NebulaOS-firmware/scripts/build/patches" \
	         "$root/NebulaOS-firmware/scripts/build/lib"
	cp "$CHECKER" "$root/tools/verify-architecture.sh"
	chmod 755 "$root/tools/verify-architecture.sh"
	cat > "$root/NebulaOS-firmware/manifests/dependencies.conf" <<'CONF'
MOONRAKER_REPO=https://github.com/Arksine/moonraker.git
MOONRAKER_PIN=d5ee17128bb8f0d2c4d3e2b1a0987654321fedcb
CONF
	cp "$REAL_PATCH" "$root/NebulaOS-firmware/scripts/build/patches/"
	echo "$root"
}

# Returns the invariant's verdict word (PASS / FAIL) for a fixture.
verdict() {
	"$1/tools/verify-architecture.sh" --quick 2>/dev/null \
		| awk -v n="$INV_NAME" '$1=="INV" && $2==n { print $3; exit }'
}

# Returns the whole invariant line (for the step-count assertions).
verdict_line() {
	"$1/tools/verify-architecture.sh" --quick 2>/dev/null \
		| awk -v n="$INV_NAME" '$1=="INV" && $2==n { print; exit }'
}

# --- 1. the real, current call shape: `patch -N -p1` --------------------
# This is the exact shape the OLD regex could not see. It must now be both
# SEEN (step count 1) and ACCEPTED (it names the allowlisted patch).
r=$(new_fixture real_shape)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
line=$(verdict_line "$r")
case "$line" in
	*PASS*) pass "real shape 'patch -N -p1' is accepted (allowlisted)" ;;
	*) fail "real shape 'patch -N -p1': expected PASS, got: $line" ;;
esac
case "$line" in
	*"+ 1 allowlisted build-time patch"*)
		pass "real shape 'patch -N -p1' is actually SEEN (step count 1, not a vacuous pass)" ;;
	*) fail "real shape 'patch -N -p1' was not counted as a patch step: $line" ;;
esac

# --- 2. plain `patch -p1` ------------------------------------------------
r=$(new_fixture plain_p1)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
line=$(verdict_line "$r")
case "$line" in
	*PASS*"+ 1 allowlisted"*) pass "plain 'patch -p1' is seen and accepted" ;;
	*) fail "plain 'patch -p1': expected PASS with step count 1, got: $line" ;;
esac

# --- 3. a different legal option ordering --------------------------------
r=$(new_fixture reordered)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch --forward --directory="$OVERLAY/opt/moonraker" -p1 < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
line=$(verdict_line "$r")
case "$line" in
	*PASS*"+ 1 allowlisted"*) pass "reordered options are seen and accepted (flag-order-proof)" ;;
	*) fail "reordered options: expected PASS with step count 1, got: $line" ;;
esac

# --- 4. `git apply` of an UNKNOWN moonraker patch ------------------------
r=$(new_fixture git_apply_unknown)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
git apply --directory=opt/moonraker "$SCRIPT_DIR/patches/moonraker-extra-hack.patch"
SH
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "'git apply' of a non-allowlisted moonraker patch is rejected" \
	|| fail "'git apply' of a non-allowlisted moonraker patch: expected FAIL, got '$v'"

# --- 5. a SECOND unknown moonraker patch file ----------------------------
r=$(new_fixture second_patch)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
cat > "$r/NebulaOS-firmware/scripts/build/patches/moonraker-second.patch" <<'P'
--- a/moonraker/server.py
+++ b/moonraker/server.py
@@ -1 +1 @@
-x
+y
P
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "a second moonraker-named patch file is rejected (file-set check)" \
	|| fail "a second moonraker patch file: expected FAIL, got '$v'"

# --- 6. a moonraker patch hiding under an innocuous FILENAME -------------
# The whole point of the content sweep: what a diff TOUCHES cannot be
# disguised by naming the file something harmless, nor by applying it
# through a shell variable that never spells "moonraker" on the line.
r=$(new_fixture disguised)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
cat > "$r/NebulaOS-firmware/scripts/build/patches/misc-cleanups.patch" <<'P'
diff --git a/moonraker/components/database.py b/moonraker/components/database.py
--- a/moonraker/components/database.py
+++ b/moonraker/components/database.py
@@ -1 +1 @@
-x
+y
P
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "a moonraker diff under an innocuous filename is rejected (content sweep)" \
	|| fail "disguised moonraker patch: expected FAIL, got '$v'"

# --- 7. commented-out patch commands must NOT be counted -----------------
# The old comment filter was inoperative. A fixture whose ONLY patch-looking
# lines are comments must yield zero steps and still pass.
r=$(new_fixture commented_out)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
# patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-ghost.patch"
	# git apply moonraker-also-a-ghost.patch
echo "no real patch step here"
SH
line=$(verdict_line "$r")
case "$line" in
	*PASS*"+ 0 allowlisted"*)
		pass "commented-out moonraker patch commands are not counted" ;;
	*) fail "commented-out patch commands: expected PASS with step count 0, got: $line" ;;
esac

# --- 8. RECURSION: a patch step in scripts/build/lib/ --------------------
# The old glob was scripts/build/*.sh, so this location was invisible.
r=$(new_fixture recursion)
cat > "$r/NebulaOS-firmware/scripts/build/lib/helpers.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sneaky.patch"
SH
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "a moonraker patch step in scripts/build/lib/ is found (scan is recursive)" \
	|| fail "patch step in scripts/build/lib/: expected FAIL, got '$v'"

# --- 8b. line continuations cannot hide the patch filename ---------------
# A line-at-a-time scan sees only `patch -N -p1 -d ".../moonraker" \\` and
# never the filename on the next line. Found for real: the F-02 fix wrapped
# the real invocation onto two lines and immediately broke this check.
r=$(new_fixture continuation)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" \
	< "$SCRIPT_DIR/patches/moonraker-split-across-lines.patch"
SH
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "a continuation-split moonraker patch step is still seen (not bypassable by line wrapping)" \
	|| fail "continuation-split patch step: expected FAIL, got '$v'"

# --- 8c. the allowlisted step still passes when split across lines -------
r=$(new_fixture continuation_ok)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" \
	< "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch" || true
SH
line=$(verdict_line "$r")
case "$line" in
	*PASS*"+ 1 allowlisted"*) pass "the real (line-wrapped) call shape is seen and accepted" ;;
	*) fail "line-wrapped allowlisted step: expected PASS with step count 1, got: $line" ;;
esac

# --- 9. the allowlisted patch's CONTENT is pinned ------------------------
# Allowlisting by filename alone would let the patch's contents change
# arbitrarily while the invariant still passed.
r=$(new_fixture content_pin)
cat > "$r/NebulaOS-firmware/scripts/build/04-cross-compile-app-stack.sh" <<'SH'
#!/bin/sh
patch -N -p1 -d "$OVERLAY/opt/moonraker" < "$SCRIPT_DIR/patches/moonraker-sqlite-nolock.patch"
SH
printf '\n# smuggled change\n' >> "$r/NebulaOS-firmware/scripts/build/patches/moonraker-sqlite-nolock.patch"
v=$(verdict "$r")
[ "$v" = FAIL ] \
	&& pass "modified content of the allowlisted patch is rejected (sha256 pin)" \
	|| fail "modified allowlisted patch content: expected FAIL, got '$v'"

# --- 10. the real repository passes ---------------------------------------
# Guards against a checker that only ever fails.
real_line=$("$REPO_ROOT/../tools/verify-architecture.sh" --quick 2>/dev/null \
	| awk -v n="$INV_NAME" '$1=="INV" && $2==n { print; exit }')
if [ -z "$real_line" ]; then
	echo "SKIP: real workspace checker not reachable from here"
else
	case "$real_line" in
		*PASS*) pass "the real NebulaOS workspace satisfies the invariant" ;;
		*) fail "the real NebulaOS workspace does not satisfy the invariant: $real_line" ;;
	esac
fi


# =======================================================================
# Section B: the BUILD-TIME effect gate (F-02)
# =======================================================================
# 04-cross-compile-app-stack.sh applies the patch with `patch -N ... || true`
# and then asserts the EFFECT. The exit status deliberately is not the gate:
# GNU patch -N exits 1 when it skips an already-applied hunk and exits 0 when
# a hunk applies with fuzz, so rc is unreliable in both directions. These
# tests prove the effect assertion's expected counts are correct for the real
# patch, and that they actually discriminate.

BUILD_SCRIPT=$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh
VERIFY_SCRIPT=$REPO_ROOT/scripts/build/06-verify.sh

# B1/B2: both layers of the assertion are present in source.
if grep -q 'FATAL: moonraker-sqlite-nolock.patch did not take effect' "$BUILD_SCRIPT"; then
	pass "04-cross-compile-app-stack.sh fails closed if the patch has no effect"
else
	fail "04-cross-compile-app-stack.sh has no fail-closed effect assertion for the moonraker patch"
fi
if grep -q 'moonraker-sqlite-nolock.patch did NOT reach the shipped database.py' "$VERIFY_SCRIPT"; then
	pass "06-verify.sh re-asserts the patch reached the shipped rootfs (second layer)"
else
	fail "06-verify.sh has no second-layer assertion for the moonraker patch"
fi

# B3..B5: the expected counts, exercised against a real application of the
# real patch. Reconstructs the pre-patch database.py from the diff's own
# context+removed lines, so this test tracks the patch file automatically: if
# MOONRAKER_PIN moves and the patch is re-based, this is what catches a stale
# expected-count in the build gate.
mkdir -p "$WORK/mk/moonraker/components"
python3 - "$REAL_PATCH" "$WORK/mk/moonraker/components/database.py" <<'PYEOF'
import sys
lines = open(sys.argv[1]).read().split("\n")
out, inhunk = [], False
for l in lines:
    if l.startswith("@@"):
        inhunk = True
        out.append("# ---- hunk boundary filler ----")
        continue
    if not inhunk:
        continue
    if l.startswith("+"):
        continue
    if l.startswith("-") or l.startswith(" "):
        out.append(l[1:])
        continue
    if l == "":
        out.append("")
open(sys.argv[2], "w").write("import sqlite3, pathlib\n" + "\n".join(out) + "\n")
PYEOF

# The exact counting the build gate performs, kept in one place.
gate_verdict() {
	f=$1
	[ -f "$f" ] || { echo "NOFILE"; return; }
	code=$(grep -v '^[[:space:]]*#' "$f")
	d=$(grep -c '^def connect_sqlite_nolock(' "$f")
	r=$(echo "$code" | grep -c 'sqlite3\.connect(')
	n=$(echo "$code" | grep -c 'nolock=1')
	h=$(echo "$code" | grep -c 'connect_sqlite_nolock(')
	c=$((h - d))
	if [ "$d" = 1 ] && [ "$r" = 1 ] && [ "$n" = 1 ] && [ "$c" = 4 ]; then
		echo "PASS"
	else
		echo "FAIL(defs=$d raw=$r nolock=$n calls=$c)"
	fi
}

patch -N -p1 -d "$WORK/mk" < "$REAL_PATCH" >/dev/null 2>&1
v=$(gate_verdict "$WORK/mk/moonraker/components/database.py")
[ "$v" = PASS ] \
	&& pass "effect gate accepts a correctly patched database.py" \
	|| fail "effect gate rejected a correctly patched database.py: $v (the build gate's expected counts are wrong - re-derive them)"

# B4: stock, unpatched - the exact silent-divergence case F-02 describes.
rm -rf "$WORK/mk_stock"; cp -r "$WORK/mk" "$WORK/mk_stock"
patch -R -p1 -d "$WORK/mk_stock" < "$REAL_PATCH" >/dev/null 2>&1
v=$(gate_verdict "$WORK/mk_stock/moonraker/components/database.py")
case "$v" in
	FAIL*) pass "effect gate rejects stock, unpatched database.py (the silent-divergence case)" ;;
	*) fail "effect gate accepted stock unpatched database.py: $v" ;;
esac

# B5: partially applied - one call site left raw.
rm -rf "$WORK/mk_part"; cp -r "$WORK/mk" "$WORK/mk_part"
sed -i 's/conn = connect_sqlite_nolock(self\._db_path, timeout=1\.)/conn = sqlite3.connect(str(self._db_path), timeout=1.)/' \
	"$WORK/mk_part/moonraker/components/database.py"
v=$(gate_verdict "$WORK/mk_part/moonraker/components/database.py")
case "$v" in
	FAIL*) pass "effect gate rejects a partially applied patch (3 of 4 call sites)" ;;
	*) fail "effect gate accepted a partially applied patch: $v" ;;
esac

echo ""
echo "moonraker-patch-architecture-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
