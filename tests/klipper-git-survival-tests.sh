#!/bin/sh
#
# Git-operation survival matrix for the composed Klipper checkout.
# Phase 1 no-fork migration, Phase K (2026-08-17).
#
# WHY THIS EXISTS
# ---------------
# The no-fork architecture rests on one empirical claim: NebulaOS's symlinks
# in klippy/extras, plus per-clone .git/info/exclude entries, survive every
# git operation Moonraker's update manager (and a developer over SSH) can
# perform, leaving `git status` empty throughout - so official Klipper's
# checkout stays genuinely pristine and Moonraker reports no anomalies.
#
# The analysis mission tested that by hand (section 8.2 of
# _project/missions/2026-08-phase1-klipper-no-fork-analysis.md) and section
# 26.1 tests 9 and 11 asked for it as a standing pre-hardware check. Nothing
# in this repository asserted it until now: the composition suite covers the
# composer's own behaviour, but never puts a real `git pull` through it.
#
# A hand-run experiment proves a fact once. This is the regression test, so
# the fact stays true after the next change to the composer, the exclude
# handling, or the module list.
#
# THE ONE OPERATION THAT DOES NOT SURVIVE, AND WHY THAT IS CORRECT
# ----------------------------------------------------------------
# `git clean -d -f -x` removes IGNORED files too, which is exactly what the
# managed symlinks are. That is not a defect to be worked around - it is a
# destructive operation the user explicitly asked for, and the honest
# response is to recover from it on the next activation rather than to hide
# it. The test below asserts the destruction AND the recovery, because a
# suite that quietly omitted the case would be claiming a robustness the
# system does not have.
#
# Likewise, an upstream commit that adds a real tracked file at a managed
# path DOES silently replace the symlink at exit code 0 (analysis section
# 8.3). That is the whole reason the collision guard exists. The test asserts
# the hazard is real and that the guard catches it - not that git behaves
# differently than it does.
#
# Same fixture convention as tests/klipper-composition-tests.sh: real,
# locally-built git repositories under a temp directory, with a real bare
# "upstream" remote so fetch/pull are genuine network-shaped operations
# rather than simulations. Never touches GitHub, a real device, or a
# canonical checkout.
#
# Usage: sh tests/klipper-git-survival-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-klipper-compose.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/klipper-git-survival-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$COMPOSE_LIB"

MANAGED="prtouch_v2 z_compensate nebulaos_compat nebulaos_temperature_mcu"
MANAGED_COUNT=5   # the four runtime modules above plus one test module

# --- fixtures -------------------------------------------------------------

# A bare "upstream Klipper" the device clones from, so fetch and pull are
# real operations against a real remote.
make_upstream() {
	seed="$WORK/upstream-seed"
	rm -rf "$seed" "$1"
	mkdir -p "$seed/klippy/extras" "$seed/klippy/chelper"
	printf 'out\n*.so\n*.pyc\n' > "$seed/.gitignore"
	printf '# klippy\n' > "$seed/klippy/klippy.py"
	printf '# extras package\n' > "$seed/klippy/extras/__init__.py"
	printf '# upstream heaters\n' > "$seed/klippy/extras/heaters.py"
	printf '# upstream fan\n' > "$seed/klippy/extras/fan.py"
	printf '# chelper wrapper\n' > "$seed/klippy/chelper/__init__.py"
	printf 'int main(void){return 0;}\n' > "$seed/klippy/chelper/pyhelper.c"
	printf '#pragma once\n' > "$seed/klippy/chelper/pyhelper.h"
	git -C "$seed" init -q -b master
	git -C "$seed" add -A
	git -C "$seed" commit -q -m "klipper upstream base"
	git clone -q --bare "$seed" "$1"
}

# Add a commit to the bare upstream, as upstream would.
upstream_commit() {
	bare="$1"; path="$2"; content="$3"; msg="$4"
	tmp="$WORK/upstream-work"
	rm -rf "$tmp"
	git clone -q "$bare" "$tmp"
	mkdir -p "$(dirname "$tmp/$path")"
	printf '%s\n' "$content" > "$tmp/$path"
	git -C "$tmp" add -A
	git -C "$tmp" commit -q -m "$msg"
	git -C "$tmp" push -q origin master
	rm -rf "$tmp"
}

make_extensions_fixture() {
	d="$1"
	rm -rf "$d"
	mkdir -p "$d/extras"
	for m in $MANAGED; do
		printf '# %s\n' "$m" > "$d/extras/$m.py"
	done
	printf '# test_prtouch_units\n' > "$d/extras/test_prtouch_units.py"
	cat > "$d/nebulaos-extensions.json" <<'EOF'
{
  "compat_schema_version": 1,
  "extensions_version": "fixture",
  "nebulaos_api_level": 1,
  "klipper": {"qualified_commit": "0000", "allow_unqualified": false},
  "required_klipper_symbols": [],
  "composition": {
    "source_dir": "extras",
    "destination_dir": "klippy/extras",
    "exclude_file": ".git/info/exclude",
    "link_type": "symlink",
    "marker_file": ".nebulaos-composed",
    "require_symlink_resolving_inside_source": true
  },
  "modules": [
    {"path": "extras/prtouch_v2.py", "role": "runtime"},
    {"path": "extras/z_compensate.py", "role": "runtime"},
    {"path": "extras/nebulaos_compat.py", "role": "runtime"},
    {"path": "extras/nebulaos_temperature_mcu.py", "role": "runtime"},
    {"path": "extras/test_prtouch_units.py", "role": "test"}
  ],
  "chelper": {
    "enforced_by": "platform",
    "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources",
    "target": "klippy/chelper/c_helper.so",
    "source_dir": "klippy/chelper",
    "platform_result_file": ".nebulaos-chelper-verdict.json"
  }
}
EOF
	git -C "$d" init -q -b main
	git -C "$d" add -A
	git -C "$d" commit -q -m "extensions fixture"
}

# --- helpers --------------------------------------------------------------

link_count() { find "$1/klippy/extras" -maxdepth 1 -type l 2>/dev/null | wc -l; }
porcelain()  { git -C "$1" status --porcelain 2>/dev/null; }

# The single assertion every surviving operation must satisfy: the checkout
# reports nothing, every managed link is still a link into the extensions
# tree, and the composer's own verification agrees.
assert_survived() {
	op="$1"; kdir="$2"; edir="$3"
	st=$(porcelain "$kdir")
	if [ -n "$st" ]; then
		fail "$op: the Klipper checkout is DIRTY afterwards ($(printf '%s' "$st" | head -3 | tr '\n' ' '))"
		return
	fi
	n=$(link_count "$kdir")
	if [ "$n" -ne "$MANAGED_COUNT" ]; then
		fail "$op: expected $MANAGED_COUNT managed symlinks afterwards, found $n"
		return
	fi
	if ! compose_verify "$kdir" "$edir" >/dev/null 2>&1; then
		fail "$op: compose_verify no longer accepts the composition afterwards"
		return
	fi
	pass "$op: survived - checkout still pristine, all $MANAGED_COUNT links intact and verified"
}

BARE="$WORK/upstream.git"
K="$WORK/klipper"
E="$WORK/extensions"

make_upstream "$BARE"
make_extensions_fixture "$E"
git clone -q "$BARE" "$K"

if compose_ensure "$K" "$E" >/dev/null 2>&1; then
	pass "baseline: the freshly cloned checkout composes cleanly"
else
	fail "baseline: compose_ensure failed on a fresh clone - nothing below is meaningful"
	echo
	echo "klipper-git-survival-tests: $PASS passed, $FAIL failed"
	exit 1
fi
assert_survived "baseline" "$K" "$E"

# --- 1. fetch -------------------------------------------------------------

upstream_commit "$BARE" "klippy/extras/probe.py" "# upstream probe" "add probe"
git -C "$K" fetch -q origin
assert_survived "git fetch origin" "$K" "$E"

# --- 2. pull (fast-forward bringing in a new upstream file) ---------------

git -C "$K" pull -q --ff-only origin master
assert_survived "git pull --ff-only (new upstream file)" "$K" "$E"
if [ -f "$K/klippy/extras/probe.py" ] && [ ! -L "$K/klippy/extras/probe.py" ]; then
	pass "the pulled upstream file really did land in the working tree (the pull was a real one, not a no-op)"
else
	fail "the pulled upstream file is missing - the pull did not actually bring anything in"
fi

# --- 3. reset --hard ------------------------------------------------------

git -C "$K" reset -q --hard HEAD
assert_survived "git reset --hard HEAD" "$K" "$E"

git -C "$K" reset -q --hard HEAD~1
assert_survived "git reset --hard HEAD~1 (a real rollback, as the supervisor performs)" "$K" "$E"
git -C "$K" reset -q --hard origin/master

# --- 4. checkout ----------------------------------------------------------

git -C "$K" checkout -q -b sidebranch
assert_survived "git checkout -b (branch switch)" "$K" "$E"
git -C "$K" checkout -q master
assert_survived "git checkout master (switch back)" "$K" "$E"

git -C "$K" checkout -q "$(git -C "$K" rev-parse HEAD)" 2>/dev/null
assert_survived "git checkout <sha> (detached HEAD, as the pin enforcement uses)" "$K" "$E"
git -C "$K" checkout -q master

# --- 5. clean -------------------------------------------------------------

git -C "$K" clean -q -d -f
assert_survived "git clean -d -f" "$K" "$E"

# --- 6. gc / maintenance --------------------------------------------------

git -C "$K" gc -q --prune=now 2>/dev/null
assert_survived "git gc --prune=now" "$K" "$E"

# --- 7. stash -------------------------------------------------------------

git -C "$K" stash -q 2>/dev/null || true
assert_survived "git stash (with nothing to stash - the checkout is pristine)" "$K" "$E"

# --- 8. the destructive case: clean -x ------------------------------------
#
# -x removes ignored files, and the managed symlinks are ignored by design.
# This is asserted rather than avoided: the guarantee NebulaOS makes is that
# activation recovers, not that a deliberate wipe is somehow survived.

git -C "$K" clean -q -d -f -x
n=$(link_count "$K")
if [ "$n" -eq 0 ]; then
	pass "git clean -d -f -x DOES destroy the managed links (asserted, not hidden - -x removes ignored files by definition)"
else
	fail "git clean -d -f -x left $n managed links behind - the exclude mechanism is not doing what this project documents"
fi
if [ -z "$(porcelain "$K")" ]; then
	pass "git clean -d -f -x leaves the checkout pristine (it removed only NebulaOS's own untracked/ignored artifacts)"
else
	fail "git clean -d -f -x left the checkout dirty"
fi
if compose_ensure "$K" "$E" >/dev/null 2>&1; then
	pass "activation recomposes automatically after a clean -x wipe"
else
	fail "compose_ensure could not recover from a clean -x wipe"
fi
assert_survived "recovery after git clean -d -f -x" "$K" "$E"

# --- 9. the silent hazard: upstream adopts a managed module name ----------
#
# Analysis section 8.3. git replaces the managed symlink with upstream's real
# tracked file at exit code 0, with nothing in any status output. The module
# is then shadowed - Klippy would run upstream's code while every version
# report still says NebulaOS. For a load-cell probe that is a physical-safety
# difference, so the guard must refuse rather than warn.

upstream_commit "$BARE" "klippy/extras/z_compensate.py" \
	"# upstream has adopted this name" "upstream adopts z_compensate"
git -C "$K" fetch -q origin
git -C "$K" merge -q --ff-only origin/master 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
	pass "the colliding upstream commit merged at exit code 0 - the hazard really is silent, exactly as documented"
else
	fail "the colliding merge failed (rc=$rc); this suite can no longer prove the guard catches the silent case"
fi
if [ -f "$K/klippy/extras/z_compensate.py" ] && [ ! -L "$K/klippy/extras/z_compensate.py" ]; then
	pass "the managed symlink was silently replaced by upstream's regular file (the failure mode the guard exists for)"
else
	fail "the managed symlink was not replaced - the fixture no longer reproduces the documented hazard"
fi
if compose_verify "$K" "$E" >/dev/null 2>&1; then
	fail "compose_verify ACCEPTED a shadowed module - this is the silent-shadowing failure the architecture is supposed to make impossible"
else
	pass "compose_verify REFUSES the shadowed composition instead of accepting it"
fi
if compose_ensure "$K" "$E" >/dev/null 2>&1; then
	fail "compose_ensure re-composed over an upstream collision instead of refusing"
else
	pass "compose_ensure REFUSES to activate against an upstream collision - it never silently overwrites upstream's file, and never leaves the module shadowed"
fi
if [ -f "$K/klippy/extras/z_compensate.py" ] && [ ! -L "$K/klippy/extras/z_compensate.py" ]; then
	pass "upstream's colliding file is left untouched by the refusal - resolving it stays a deliberate human decision"
else
	fail "the refusal modified upstream's file"
fi
if [ -z "$(porcelain "$K")" ]; then
	pass "the checkout is still pristine after the refused collision"
else
	fail "the refused collision left the checkout dirty"
fi

# --- 10. hard recovery: destroy the checkout, reclone, recompose ----------
#
# Section 26.1 test 11. The most invasive non-hardware recovery there is:
# the Klipper checkout is gone entirely and has to be rebuilt from origin.

git -C "$K" rev-parse HEAD > "$WORK/pre-reclone-head"
rm -rf "$K"
git clone -q "$BARE" "$K"
git -C "$K" reset -q --hard "$(cat "$WORK/pre-reclone-head")"
# The recloned tree still carries upstream's colliding file, so the guard must
# still refuse - a reclone is not an escape hatch from a real collision.
if compose_ensure "$K" "$E" >/dev/null 2>&1; then
	fail "a reclone silently bypassed the collision guard"
else
	pass "a hard reclone does NOT bypass the collision guard - the collision is a property of upstream's content, not of local state"
fi
# Resolve the collision the way a human would (upstream wins, the NebulaOS
# module is renamed out of the way) and confirm full recovery.
python3 - "$E" <<'EOF'
import json, os, sys
root = sys.argv[1]
path = os.path.join(root, 'nebulaos-extensions.json')
man = json.load(open(path))
man['modules'] = [m for m in man['modules']
                  if m['path'] != 'extras/z_compensate.py']
json.dump(man, open(path, 'w'), indent=2)
EOF
os_rc=$?
if [ "$os_rc" -ne 0 ]; then
	fail "could not rewrite the fixture manifest (python3 missing?) - skipping the recovery assertion"
else
	git -C "$E" add -A
	git -C "$E" commit -q -m "drop the module upstream adopted"
	MANAGED_COUNT=4
	if compose_ensure "$K" "$E" >/dev/null 2>&1; then
		pass "after a hard reclone and a resolved collision, composition rebuilds from scratch"
	else
		fail "composition could not be rebuilt after a hard reclone"
	fi
	assert_survived "hard reclone + recomposition" "$K" "$E"
	if [ -z "$(porcelain "$E")" ]; then
		pass "the extensions checkout is pristine throughout the whole matrix"
	else
		fail "the extensions checkout is dirty at the end of the matrix"
	fi
fi

echo
echo "klipper-git-survival-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
