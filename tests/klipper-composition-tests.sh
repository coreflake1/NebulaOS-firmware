#!/bin/sh
#
# Offline, repeatable tests for /etc/nebulaos-klipper-compose.sh (Phase 1
# no-fork migration, Phase F) and /etc/nebulaos-chelper-preflight.sh
# (Phase H).
#
# Same fixture convention as tests/factory-seed-git-tests.sh and
# tests/app-migration-tests.sh: real, locally-built git repositories under a
# temp directory. Never touches GitHub, never touches a real device, never
# touches a canonical checkout.
#
# The fixtures are deliberately Klipper-SHAPED rather than a real Klipper
# clone: klippy/extras/, klippy/chelper/ with real *.c/*.h/__init__.py, a
# real .git, and a manifest of exactly the shipped schema. That keeps the
# suite hermetic and fast while exercising every branch that matters. The
# same library is separately exercised against a genuine pristine
# Klipper3d/klipper checkout composed with the real extension repository -
# see the mission report for that run's output.
#
# Usage: sh tests/klipper-composition-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-klipper-compose.sh"
CHELPER_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-chelper-preflight.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/klipper-composition-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$COMPOSE_LIB"
. "$CHELPER_LIB"

# --- fixtures -------------------------------------------------------------

# A Klipper-shaped git checkout: klippy/extras with a couple of real
# upstream-style modules, klippy/chelper with real sources and a stand-in
# prebuilt library, and upstream's own *.so .gitignore entry (which is what
# lets the prebuilt artifact live in the tree without dirtying it).
make_klipper_fixture() {
	d="$1"
	rm -rf "$d"
	mkdir -p "$d/klippy/extras" "$d/klippy/chelper"
	printf 'out\n*.so\n*.pyc\n' > "$d/.gitignore"
	printf '# klippy\n' > "$d/klippy/klippy.py"
	printf '# extras package\n' > "$d/klippy/extras/__init__.py"
	printf '# upstream heaters\n' > "$d/klippy/extras/heaters.py"
	printf '# upstream fan\n' > "$d/klippy/extras/fan.py"
	printf '# chelper wrapper\n' > "$d/klippy/chelper/__init__.py"
	printf 'int main(void){return 0;}\n' > "$d/klippy/chelper/pyhelper.c"
	printf '#pragma once\n' > "$d/klippy/chelper/pyhelper.h"
	git -C "$d" init -q -b master
	git -C "$d" add -A
	git -C "$d" commit -q -m "klipper fixture"
	# Prebuilt artifact, created after the sources and untracked by design
	# (upstream's own .gitignore covers *.so).
	printf 'ELF-ish\n' > "$d/klippy/chelper/c_helper.so"
}

# An extensions repository with the real manifest shape.
make_extensions_fixture() {
	d="$1"
	rm -rf "$d"
	mkdir -p "$d/extras"
	for m in prtouch_v2 z_compensate nebulaos_compat nebulaos_temperature_mcu; do
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

K="$WORK/klipper"
E="$WORK/extensions"
make_klipper_fixture "$K"
make_extensions_fixture "$E"

# --- 1. basic composition -------------------------------------------------

if compose_ensure "$K" "$E" >"$WORK/log1" 2>&1; then
	pass "compose_ensure succeeds on a clean pair"
else
	fail "compose_ensure failed on a clean pair"; cat "$WORK/log1"
fi

n_links=$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)
if [ "$n_links" -eq 5 ]; then
	pass "all 5 manifest modules composed as symlinks"
else
	fail "expected 5 symlinks in klippy/extras, found $n_links"
fi

if [ -L "$K/klippy/extras/prtouch_v2.py" ] && \
   [ "$(readlink -f "$K/klippy/extras/prtouch_v2.py")" = "$(readlink -f "$E/extras/prtouch_v2.py")" ]; then
	pass "a managed destination resolves to the real file in the extensions tree"
else
	fail "prtouch_v2.py does not resolve into the extensions tree"
fi

# --- 2. both checkouts stay pristine -------------------------------------

kstat=$(git -C "$K" status --porcelain)
estat=$(git -C "$E" status --porcelain)
if [ -z "$kstat" ]; then
	pass "Klipper checkout is pristine after composition (git status --porcelain empty)"
else
	fail "Klipper checkout is dirty after composition:"; printf '%s\n' "$kstat"
fi
if [ -z "$estat" ]; then
	pass "extensions checkout is pristine after composition"
else
	fail "extensions checkout is dirty after composition:"; printf '%s\n' "$estat"
fi

# --- 3. idempotency -------------------------------------------------------

sig_before=$(compose_marker_signature "$K/.nebulaos-composed")
excl_before=$(wc -l < "$K/.git/info/exclude")
compose_ensure "$K" "$E" >"$WORK/log2" 2>&1
compose_ensure "$K" "$E" >>"$WORK/log2" 2>&1
sig_after=$(compose_marker_signature "$K/.nebulaos-composed")
excl_after=$(wc -l < "$K/.git/info/exclude")
n_links2=$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)

if [ "$excl_before" = "$excl_after" ]; then
	pass "repeated compose_ensure does not grow .git/info/exclude ($excl_after lines both times)"
else
	fail "exclude file grew from $excl_before to $excl_after lines over repeated runs"
fi
if [ "$n_links2" -eq 5 ] && [ "$sig_before" = "$sig_after" ]; then
	pass "repeated compose_ensure is idempotent (same link count, same generation signature)"
else
	fail "repeated compose_ensure changed state: links=$n_links2 sig='$sig_after'"
fi
if grep -q "already current and verified" "$WORK/log2"; then
	pass "an unchanged pair short-circuits the rebuild but is still verified"
else
	fail "expected the second run to report the composition as already current"
fi
if [ -z "$(git -C "$K" status --porcelain)" ]; then
	pass "Klipper checkout still pristine after repeated composition"
else
	fail "Klipper checkout dirty after repeated composition"
fi

# grep-before-append, directly
dupes=$(sort "$K/.git/info/exclude" | uniq -d)
if [ -z "$dupes" ]; then
	pass ".git/info/exclude contains no duplicate lines"
else
	fail ".git/info/exclude contains duplicates:"; printf '%s\n' "$dupes"
fi

# --- 4. teardown ----------------------------------------------------------

compose_teardown "$K" "$E" >"$WORK/log3" 2>&1
if [ "$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)" -eq 0 ] && \
   [ ! -e "$K/.nebulaos-composed" ]; then
	pass "teardown removes every managed symlink and the generation marker"
else
	fail "teardown left managed state behind"
fi
if ! grep -q "nebulaos-klipper-extensions" "$K/.git/info/exclude" 2>/dev/null; then
	pass "teardown removes the managed exclude block"
else
	fail "teardown left the managed exclude block in place"
fi
if [ -f "$K/klippy/extras/heaters.py" ] && [ -f "$K/klippy/extras/fan.py" ]; then
	pass "teardown does not touch upstream's own files"
else
	fail "teardown removed upstream files"
fi
if [ -z "$(git -C "$K" status --porcelain)" ]; then
	pass "Klipper checkout pristine after teardown"
else
	fail "Klipper checkout dirty after teardown"
fi

# --- 5. rebuild after teardown -------------------------------------------

if compose_ensure "$K" "$E" >"$WORK/log4" 2>&1 && \
   [ "$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)" -eq 5 ]; then
	pass "compose_ensure rebuilds from scratch after a full teardown"
else
	fail "rebuild after teardown failed"; cat "$WORK/log4"
fi

# --- 6. collision guard ---------------------------------------------------
#
# The scenario: upstream Klipper adds a file at a path this extension set
# manages. git silently replaces the symlink with upstream's regular file,
# exit 0, no warning - so the platform has to be the thing that notices.

compose_teardown "$K" "$E" >/dev/null 2>&1
printf '# upstream now ships this\n' > "$K/klippy/extras/z_compensate.py"
git -C "$K" add klippy/extras/z_compensate.py
git -C "$K" commit -q -m "upstream adopts z_compensate"

if compose_ensure "$K" "$E" >"$WORK/log5" 2>&1; then
	fail "compose_ensure accepted a regular-file collision"
else
	pass "compose_ensure REFUSES when upstream ships a regular file at a managed path"
fi
if grep -q "COLLISION" "$WORK/log5"; then
	pass "the collision is reported with a specific, named error"
else
	fail "collision error message was not specific"; cat "$WORK/log5"
fi
if [ -f "$K/klippy/extras/z_compensate.py" ] && [ ! -L "$K/klippy/extras/z_compensate.py" ] && \
   [ "$(cat "$K/klippy/extras/z_compensate.py")" = "# upstream now ships this" ]; then
	pass "upstream's colliding file is left untouched, never silently overwritten"
else
	fail "upstream's colliding file was modified or replaced"
fi
if [ -z "$(git -C "$K" status --porcelain)" ]; then
	pass "Klipper checkout still pristine after a refused collision"
else
	fail "Klipper checkout dirty after a refused collision"
fi
if [ "$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)" -eq 0 ]; then
	pass "a refused collision leaves NO half-composed link set behind"
else
	fail "a refused collision left partial symlinks in place"
fi

# undo the collision (upstream drops the file again)
git -C "$K" rm -q --cached klippy/extras/z_compensate.py >/dev/null
rm -f "$K/klippy/extras/z_compensate.py"
git -C "$K" commit -q -m "upstream drops z_compensate again"
if compose_ensure "$K" "$E" >/dev/null 2>&1; then
	pass "composition recovers once the upstream collision is gone"
else
	fail "composition did not recover after the collision was removed"
fi

# --- 7. path traversal / improper target ---------------------------------

BADE="$WORK/extensions-bad"
make_extensions_fixture "$BADE"
sed -i 's|"extras/prtouch_v2.py"|"extras/../../../etc/passwd"|' "$BADE/nebulaos-extensions.json"
git -C "$BADE" add -A && git -C "$BADE" commit -q -m "hostile path"
BADK="$WORK/klipper-bad"; make_klipper_fixture "$BADK"
if compose_ensure "$BADK" "$BADE" >"$WORK/log6" 2>&1; then
	fail "compose_ensure accepted a traversing module path"
else
	pass "compose_ensure REFUSES a traversing module path"
fi
if [ "$(find "$BADK/klippy/extras" -maxdepth 1 -type l | wc -l)" -eq 0 ]; then
	pass "a rejected traversing path leaves nothing composed"
else
	fail "a rejected traversing path still created symlinks"
fi

# An improper symlink target planted by hand must fail verification even
# though the marker says the composition is current.
compose_ensure "$K" "$E" >/dev/null 2>&1
ln -sfn /etc/hostname "$K/klippy/extras/prtouch_v2.py"
if compose_verify "$K" "$E" >"$WORK/log7" 2>&1; then
	fail "compose_verify accepted a symlink pointing outside the extensions tree"
else
	pass "compose_verify REFUSES a symlink resolving outside the extensions tree"
fi
if grep -q "OUTSIDE the extensions source tree" "$WORK/log7"; then
	pass "the improper-target failure names the resolved path and the expected root"
else
	fail "improper-target error was not specific"; cat "$WORK/log7"
fi
# compose_ensure must self-heal it: the marker still matches, but
# verification does not, so a rebuild is forced.
if compose_ensure "$K" "$E" >"$WORK/log8" 2>&1 && compose_verify "$K" "$E" >/dev/null 2>&1; then
	pass "compose_ensure self-heals a tampered link even when the marker still matches"
else
	fail "compose_ensure did not self-heal a tampered link"; cat "$WORK/log8"
fi
if grep -q "verification failed - forcing a full rebuild" "$WORK/log8"; then
	pass "the forced rebuild is reported, not silent"
else
	fail "the forced rebuild was not reported"
fi

# --- 8. dangling symlink (extensions tree replaced) ----------------------

compose_ensure "$K" "$E" >/dev/null 2>&1
mv "$E/extras/prtouch_v2.py" "$WORK/stashed.py"
if compose_verify "$K" "$E" >"$WORK/log9" 2>&1; then
	fail "compose_verify accepted a dangling symlink"
else
	pass "compose_verify REFUSES a dangling symlink"
fi
mv "$WORK/stashed.py" "$E/extras/prtouch_v2.py"

# --- 9. half-completed prior run -----------------------------------------
#
# Simulates a process killed mid-loop, in both possible orders, plus a
# missing marker and a corrupt one. Every case must recover to a fully
# verified composition on the next run - that is the whole point of
# rebuilding from a full teardown rather than incrementally.

half_completed_case() {
	label="$1"
	if compose_ensure "$K" "$E" >"$WORK/half.log" 2>&1 && \
	   compose_verify "$K" "$E" >/dev/null 2>&1 && \
	   [ "$(find "$K/klippy/extras" -maxdepth 1 -type l | wc -l)" -eq 5 ] && \
	   [ -z "$(git -C "$K" status --porcelain)" ] && \
	   [ -z "$(sort "$K/.git/info/exclude" | uniq -d)" ]; then
		pass "recovers from $label"
	else
		fail "did not recover from $label"; cat "$WORK/half.log"
	fi
}

# (a) killed after some links, before the marker
compose_ensure "$K" "$E" >/dev/null 2>&1
rm -f "$K/.nebulaos-composed" "$K/klippy/extras/z_compensate.py" "$K/klippy/extras/nebulaos_compat.py"
half_completed_case "a run killed after partial linking, before the marker was written"

# (b) killed after excludes were written, before any link existed
compose_ensure "$K" "$E" >/dev/null 2>&1
rm -f "$K/.nebulaos-composed"
find "$K/klippy/extras" -maxdepth 1 -type l -delete
half_completed_case "a run killed after the exclude block, before any symlink existed"

# (c) links present, exclude block lost (marker stale)
compose_ensure "$K" "$E" >/dev/null 2>&1
: > "$K/.git/info/exclude"
rm -f "$K/.nebulaos-composed"
half_completed_case "a run that left symlinks with no exclude entries"

# (d) truncated/corrupt marker
compose_ensure "$K" "$E" >/dev/null 2>&1
printf '{\n  "schema": 1,\n  "sign' > "$K/.nebulaos-composed"
half_completed_case "a truncated generation marker"

# (e) stale marker from a different generation
compose_ensure "$K" "$E" >/dev/null 2>&1
sed -i 's/"signature": "[^"]*"/"signature": "deadbeef:deadbeef:deadbeef:\/nowhere"/' "$K/.nebulaos-composed"
compose_ensure "$K" "$E" >"$WORK/log10" 2>&1
if grep -q "generation changed" "$WORK/log10"; then
	pass "a stale generation marker forces a rebuild and says why"
else
	fail "a stale generation marker did not force a rebuild"; cat "$WORK/log10"
fi
half_completed_case "a stale generation marker"

# --- 10. generation tracking ---------------------------------------------

compose_ensure "$K" "$E" >/dev/null 2>&1
sig_a=$(compose_marker_signature "$K/.nebulaos-composed")
printf '# changed\n' >> "$E/extras/prtouch_v2.py"
git -C "$E" commit -qam "extensions move forward"
compose_ensure "$K" "$E" >"$WORK/log11" 2>&1
sig_b=$(compose_marker_signature "$K/.nebulaos-composed")
if [ "$sig_a" != "$sig_b" ] && grep -q "generation changed" "$WORK/log11"; then
	pass "an extensions-repo commit change bumps the recorded generation"
else
	fail "an extensions commit change did not bump the generation"
fi

printf '# upstream moves\n' >> "$K/klippy/extras/fan.py"
git -C "$K" commit -qam "klipper moves forward"
compose_ensure "$K" "$E" >"$WORK/log12" 2>&1
sig_c=$(compose_marker_signature "$K/.nebulaos-composed")
if [ "$sig_b" != "$sig_c" ]; then
	pass "a Klipper commit change also bumps the generation (recompose + re-run the collision guard after any Klipper update)"
else
	fail "a Klipper commit change did not bump the generation"
fi

# The marker itself must not dirty the checkout.
if [ -z "$(git -C "$K" status --porcelain)" ] && \
   grep -qxF "/.nebulaos-composed" "$K/.git/info/exclude"; then
	pass "the generation marker is itself excluded from the Klipper checkout's git status"
else
	fail "the generation marker is visible to git"
fi

# --- 11. chelper mtime invariant: positive -------------------------------

if chelper_check_mtime "$K" >"$WORK/ch1" 2>&1; then
	pass "chelper positive: prebuilt .so newer than every source - invariant holds"
else
	fail "chelper positive case failed"; cat "$WORK/ch1"
fi
if chelper_write_verdict "$K" >"$WORK/ch2" 2>&1 && \
   grep -q '"status": "ok"' "$K/.nebulaos-chelper-verdict.json"; then
	pass "chelper verdict file records status ok at the manifest's platform_result_file path"
else
	fail "chelper verdict was not written as ok"; cat "$WORK/ch2"
fi
if [ -z "$(git -C "$K" status --porcelain)" ]; then
	pass "the chelper verdict file does not dirty the Klipper checkout"
else
	fail "the chelper verdict file dirtied the Klipper checkout"
fi

# --- 12. chelper mtime invariant: negative -------------------------------

sleep 1
touch "$K/klippy/chelper/stepcompress.c" 2>/dev/null || \
	printf 'int x;\n' > "$K/klippy/chelper/stepcompress.c"
touch "$K/klippy/chelper/stepcompress.c"
if chelper_check_mtime "$K" >"$WORK/ch3" 2>&1; then
	fail "chelper negative: a source newer than the .so was NOT detected"
else
	pass "chelper negative: a source newer than the .so is detected"
fi
if grep -q "stepcompress.c" "$WORK/ch3" && grep -q "gcc rebuild" "$WORK/ch3"; then
	pass "the chelper failure names the offending file and the consequence"
else
	fail "chelper failure message was not specific"; cat "$WORK/ch3"
fi
if chelper_write_verdict "$K" >"$WORK/ch4" 2>&1; then
	fail "chelper_write_verdict returned success on a stale pair"
else
	pass "chelper_write_verdict returns failure on a stale pair"
fi
if grep -q '"status": "stale"' "$K/.nebulaos-chelper-verdict.json"; then
	pass "the verdict file records status 'stale', which nebulaos_compat.py refuses to start on"
else
	fail "verdict file did not record 'stale'"
fi

# The .c file this test created is untracked and would dirty the fixture -
# it is a test artifact, not part of the composition contract.
rm -f "$K/klippy/chelper/stepcompress.c"

# Missing .so is its own distinct verdict.
mv "$K/klippy/chelper/c_helper.so" "$WORK/so.bak"
chelper_write_verdict "$K" >/dev/null 2>&1
if grep -q '"status": "missing"' "$K/.nebulaos-chelper-verdict.json"; then
	pass "an absent c_helper.so produces its own named 'missing' verdict"
else
	fail "an absent c_helper.so did not produce a 'missing' verdict"
fi
mv "$WORK/so.bak" "$K/klippy/chelper/c_helper.so"

# --- 13. chelper enforcement (build-time) --------------------------------

touch "$K/klippy/chelper/pyhelper.c"
if chelper_check_mtime "$K" >/dev/null 2>&1; then
	fail "test setup: expected the invariant to be violated before enforcement"
else
	if chelper_enforce_mtime "$K" >"$WORK/ch5" 2>&1 && chelper_check_mtime "$K" >/dev/null 2>&1; then
		pass "chelper_enforce_mtime deterministically restores the invariant and re-verifies it"
	else
		fail "chelper_enforce_mtime did not restore the invariant"; cat "$WORK/ch5"
	fi
fi

# --- 14. malformed / missing manifest ------------------------------------

EMPTY="$WORK/extensions-empty"
make_extensions_fixture "$EMPTY"
rm -f "$EMPTY/nebulaos-extensions.json"
if compose_ensure "$K" "$EMPTY" >/dev/null 2>&1; then
	fail "compose_ensure accepted an extensions tree with no manifest"
else
	pass "compose_ensure REFUSES an extensions tree with no manifest"
fi

NOMOD="$WORK/extensions-nomod"
make_extensions_fixture "$NOMOD"
sed -i 's/"link_type": "symlink"/"link_type": "hardlink"/' "$NOMOD/nebulaos-extensions.json"
NOMODK="$WORK/klipper-nomod"; make_klipper_fixture "$NOMODK"
if compose_ensure "$NOMODK" "$NOMOD" >"$WORK/log13" 2>&1; then
	fail "compose_ensure accepted an unimplemented link_type"
else
	pass "compose_ensure REFUSES a link_type this platform does not implement"
fi

MISS="$WORK/extensions-missing-file"
make_extensions_fixture "$MISS"
rm -f "$MISS/extras/z_compensate.py"
MISSK="$WORK/klipper-missing"; make_klipper_fixture "$MISSK"
if compose_ensure "$MISSK" "$MISS" >"$WORK/log14" 2>&1; then
	fail "compose_ensure accepted a manifest declaring a module with no source file"
else
	pass "compose_ensure REFUSES a manifest declaring a module with no source file"
fi

# --- summary --------------------------------------------------------------

echo
echo "klipper-composition-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
