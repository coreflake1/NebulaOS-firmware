#!/bin/sh
#
# The Extensions branch contract, tested under DIVERGENCE (audit finding F-06).
#
# THE DEFECT. The build archives the extension set with its local branch
# forced to $KLIPPER_EXTENSIONS_BRANCH ("production" - the deployed-runtime
# branch). Three on-device call sites asserted the literal "main" - the
# DEVELOPMENT branch. seed_git_app()/reseed_git_app()/seed_missing_extensions()
# treat that argument as an ASSERTION on the extracted checkout's branch NAME,
# not as a checkout target, so every production archive was rejected and
# deleted: the extensions app directory was never created, no app generation
# was ever recorded, and every later boot re-ran a full migration.
#
# WHY THIS SUITE EXISTS AND WHY IT FORCES DIVERGENCE. main and production
# currently point at the same commit, so any test run against the real repo
# would pass whether or not the bug were fixed - commit equality is irrelevant
# to a branch-NAME comparison. Every fixture below therefore pins
#   production = commit A   (the shipping pin)
#   main       = commit B   (development, ahead)
# so that a path silently using "main" resolves to different CONTENT and is
# caught, not merely a different string.
#
# Everything runs in temporary bare/working repositories. No canonical
# repository is read for mutation or written to.
#
# Usage: sh tests/extensions-branch-contract-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FACTORY_SEED="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
MIGRATE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
MANIFEST_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh"
GATE_LIB_SRC="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_SEED="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
DEPS="$REPO_ROOT/manifests/dependencies.conf"

for f in "$FACTORY_SEED" "$MIGRATE" "$MANIFEST_LIB" "$MAKE_SEED" "$DEPS"; do
	[ -f "$f" ] || { echo "SKIP: $f not present"; exit 0; }
done

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

W=$(mktemp -d "${TMPDIR:-/tmp}/extensions-branch-contract.XXXXXX") \
	|| { echo "FAIL: could not create a temporary directory"; exit 1; }
[ -n "${W:-}" ] && [ -d "$W" ] || { echo "FAIL: mktemp produced an unusable path"; exit 1; }
cleanup() { [ -n "${W:-}" ] && [ -d "$W" ] && rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM

export GIT_AUTHOR_NAME=branch-contract GIT_AUTHOR_EMAIL=bc@nebulaos.invalid
export GIT_COMMITTER_NAME=branch-contract GIT_COMMITTER_EMAIL=bc@nebulaos.invalid

EXT_ORIGIN="https://github.com/coreflake1/NebulaOS-klipper-extensions.git"

. "$MANIFEST_LIB"

# ======================================================================
# Section A: the block-scoped manifest reader
# ======================================================================
# The single most likely way to get this change wrong is a FLAT key lookup:
# S04nebulaos-migrate's own json_get() greps the whole file and takes
# `head -1`, which for "branch" returns klipper's "master" no matter which
# component was asked about. Assert the collision directly.

cat > "$W/manifest-real-shape.json" <<'J'
{
  "migration_version": "gen-test",
  "components": {
    "klipper": {
      "format": "git_repo_archive_real_history",
      "branch": "master",
      "seed_commit": "aaaa"
    },
    "nebulaos-klipper-extensions": {
      "format": "git_repo_archive_real_history",
      "branch": "production",
      "seed_commit": "bbbb"
    },
    "moonraker": {
      "branch": "master"
    }
  }
}
J

v=$(seed_manifest_branch "$W/manifest-real-shape.json" nebulaos-klipper-extensions)
if [ "$v" = "production" ]; then
	pass "reader: extensions resolves to 'production', not klipper's 'master' (flat-grep collision avoided)"
else
	fail "reader: extensions resolved to '$v', expected 'production'"
fi
v=$(seed_manifest_branch "$W/manifest-real-shape.json" klipper)
[ "$v" = "master" ] && pass "reader: klipper still resolves to 'master'" \
                    || fail "reader: klipper resolved to '$v', expected 'master'"

printf '{ "components": { "nebulaos-klipper-extensions": { "seed_commit": "x" } } }\n' > "$W/m-nobranch.json"
printf 'this is not json at all\n' > "$W/m-malformed.json"
for case in "absent:$W/does-not-exist.json" "no-branch-field:$W/m-nobranch.json" "malformed:$W/m-malformed.json"; do
	label=${case%%:*}; file=${case#*:}
	out=$(seed_manifest_branch "$file" nebulaos-klipper-extensions); rc=$?
	if [ $rc -ne 0 ] && [ -z "$out" ]; then
		pass "reader fails closed on a $label manifest (no value, non-zero)"
	else
		fail "reader on a $label manifest returned '$out' rc=$rc - must fail closed"
	fi
done

# ======================================================================
# Section B: divergence fixture - production=A, main=B
# ======================================================================
SRC="$W/ext-src"
git init -q -b production "$SRC"
mkdir -p "$SRC/extras"
printf 'A\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "A - the shipping pin, production points here"
COMMIT_A=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q -b main
printf 'B\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "B - development moved on"
COMMIT_B=$(git -C "$SRC" rev-parse HEAD)
git -C "$SRC" checkout -q production
git -C "$SRC" remote add origin "$EXT_ORIGIN"

if [ "$COMMIT_A" != "$COMMIT_B" ]; then
	pass "fixture: production ($(echo "$COMMIT_A" | cut -c1-8)) and main ($(echo "$COMMIT_B" | cut -c1-8)) genuinely diverge"
else
	fail "fixture: production and main are the same commit - the whole suite would be vacuous"
fi

SEEDS="$W/seeds"; mkdir -p "$SEEDS"
. "$MAKE_SEED"
make_seed_archive "$SRC" "production" "$EXT_ORIGIN" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1

mkdir -p "$W/peek"
gzip -dc "$SEEDS/nebulaos-klipper-extensions.tar.gz" | tar -xo -C "$W/peek"
arch_branch=$(git -C "$W/peek" symbolic-ref --short HEAD 2>/dev/null)
arch_head=$(git -C "$W/peek" rev-parse HEAD 2>/dev/null)
[ "$arch_branch" = "production" ] && pass "archive: local branch is 'production' (what the build produces)" \
                                  || fail "archive: local branch is '$arch_branch', expected 'production'"
[ "$arch_head" = "$COMMIT_A" ] && pass "archive: content is commit A (the pin), not main's B" \
                               || fail "archive: HEAD is $arch_head, expected A=$COMMIT_A"

write_manifest() {
	cat > "$SEEDS/seed-manifest.json" <<J
{
  "migration_version": "gen-test",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "aaaa" },
    "nebulaos-klipper-extensions": { "branch": "$1", "seed_commit": "$COMMIT_A" },
    "moonraker": { "branch": "master", "seed_commit": "cccc" }
  }
}
J
}
write_manifest production

# Drive the REAL factory-seed call path, with the real functions.
run_factory_seed() {
	_apps="$1"
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$_apps" \
		SYSTEM="$W/system" GATE_LIB="$GATE_LIB_SRC" \
		SEED_MANIFEST_LIB="$MANIFEST_LIB" \
		sh -c '
			. "$0"
			b=$(seed_manifest_branch "$SEEDS/seed-manifest.json" nebulaos-klipper-extensions)
			[ -n "$b" ] || { echo "NO_BRANCH"; exit 9; }
			seed_git_app nebulaos-klipper-extensions "$b" "$1"
		' "$FACTORY_SEED" "$EXT_ORIGIN" 2>&1
}

A1="$W/apps1"; mkdir -p "$A1"
out=$(run_factory_seed "$A1"); rc=$?
if [ $rc -eq 0 ] && [ -e "$A1/nebulaos-klipper-extensions/.git" ]; then
	pass "factory seed ACCEPTS the production archive (F-06: previously rejected as 'expected main')"
else
	fail "factory seed rejected the production archive (rc=$rc): $out"
fi
dep_head=$(git -C "$A1/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
dep_branch=$(git -C "$A1/nebulaos-klipper-extensions" symbolic-ref --short HEAD 2>/dev/null)
[ "$dep_head" = "$COMMIT_A" ] && pass "deployed copy resolves to commit A (the pin), not main's B" \
                              || fail "deployed HEAD is $dep_head, expected A=$COMMIT_A"
[ "$dep_branch" = "production" ] && pass "deployed copy is on branch 'production'" \
                                 || fail "deployed copy is on '$dep_branch', expected 'production'"

# Advancing main must not change deployed state.
git -C "$SRC" checkout -q main
printf 'B2\n' > "$SRC/extras/marker.py"
git -C "$SRC" add -A
git -C "$SRC" commit -q -m "main advances again"
git -C "$SRC" checkout -q production
after_head=$(git -C "$A1/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
[ "$after_head" = "$COMMIT_A" ] && pass "advancing main leaves the deployed copy untouched at A" \
                                || fail "deployed copy moved to $after_head after main advanced"

# A genuine branch mismatch must still fail closed.
BAD="$W/bad-src"
git init -q -b somethingelse "$BAD"; printf 'x\n' > "$BAD/f"; git -C "$BAD" add -A
git -C "$BAD" commit -q -m x; git -C "$BAD" remote add origin "$EXT_ORIGIN"
mkdir -p "$W/seeds-bad"
SEEDS_KEEP=$SEEDS; SEEDS="$W/seeds-bad"
make_seed_archive "$BAD" "somethingelse" "$EXT_ORIGIN" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1
write_manifest production
A2="$W/apps2"; mkdir -p "$A2"
out=$(run_factory_seed "$A2"); rc=$?
if [ $rc -ne 0 ] && [ ! -e "$A2/nebulaos-klipper-extensions/.git" ]; then
	pass "a genuine branch mismatch still FAILS CLOSED and leaves no partial checkout"
else
	fail "branch mismatch was accepted (rc=$rc) - the assertion has been weakened"
fi
SEEDS=$SEEDS_KEEP

# A wrong origin must still fail closed (the origin is deliberately NOT derived).
WRONG="$W/wrong-origin-src"
git init -q -b production "$WRONG"; printf 'x\n' > "$WRONG/f"; git -C "$WRONG" add -A
git -C "$WRONG" commit -q -m x
git -C "$WRONG" remote add origin "https://github.com/someone-else/not-our-extensions.git"
mkdir -p "$W/seeds-wrong"
SEEDS_KEEP=$SEEDS; SEEDS="$W/seeds-wrong"
make_seed_archive "$WRONG" "production" \
	"https://github.com/someone-else/not-our-extensions.git" \
	"$SEEDS/nebulaos-klipper-extensions.tar.gz" "" >/dev/null 2>&1
write_manifest production
A3="$W/apps3"; mkdir -p "$A3"
out=$(run_factory_seed "$A3"); rc=$?
if [ $rc -ne 0 ] && [ ! -e "$A3/nebulaos-klipper-extensions/.git" ]; then
	pass "right branch + WRONG ORIGIN still fails closed (origin stays a literal on purpose)"
else
	fail "a wrong-origin archive was accepted (rc=$rc)"
fi
SEEDS=$SEEDS_KEEP

# Manifest fail-closed at the real call site, not just in the reader.
for bad in absent no-branch; do
	case $bad in
		absent)    mv "$SEEDS/seed-manifest.json" "$SEEDS/seed-manifest.json.off" ;;
		no-branch) printf '{ "components": { "nebulaos-klipper-extensions": { "seed_commit": "x" } } }\n' \
		             > "$SEEDS/seed-manifest.json" ;;
	esac
	AX="$W/apps-$bad"; mkdir -p "$AX"
	out=$(run_factory_seed "$AX"); rc=$?
	if [ $rc -ne 0 ] && [ ! -e "$AX/nebulaos-klipper-extensions/.git" ]; then
		pass "call site refuses to seed when the manifest is $bad (no guessed branch, no partial checkout)"
	else
		fail "call site seeded with a $bad manifest (rc=$rc) - it guessed a branch"
	fi
	[ "$bad" = absent ] && mv "$SEEDS/seed-manifest.json.off" "$SEEDS/seed-manifest.json"
done
write_manifest production

# ======================================================================
# Section C: seed_missing_extensions, on its REAL trigger
# ======================================================================
# S04nebulaos-migrate:1242 reaches this function only when the extensions
# .git is absent - the pre-no-fork upgrade path. Test it there, not in
# isolation.
A4="$W/apps4"; mkdir -p "$A4/klipper"
out=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$A4" \
	SYSTEM="$W/system4" GATE_LIB="$GATE_LIB_SRC" SEED_MANIFEST_LIB="$MANIFEST_LIB" \
	sh -c '. "$0"; seed_missing_extensions' "$MIGRATE" 2>&1); rc=$?
if [ $rc -eq 0 ] && [ -e "$A4/nebulaos-klipper-extensions/.git" ]; then
	pass "seed_missing_extensions provisions from the production archive"
else
	fail "seed_missing_extensions failed on a valid production archive (rc=$rc): $out"
fi
smx_head=$(git -C "$A4/nebulaos-klipper-extensions" rev-parse HEAD 2>/dev/null)
[ "$smx_head" = "$COMMIT_A" ] && pass "seed_missing_extensions lands on commit A (the pin)" \
                              || fail "seed_missing_extensions HEAD is $smx_head, expected A"

# ======================================================================
# Section D: no unnecessary reseed once a generation is recorded
# ======================================================================
# The F-06 consequence was that a rejected seed meant no app generation was
# ever recorded, so every boot re-ran a full migration - creating a new
# timestamped backup of klipper and moonraker each time. With seeding fixed,
# a matching generation must short-circuit before any backup is created.
A5="$W/apps5"; S5="$W/system5"; mkdir -p "$A5" "$S5"
for c in klipper nebulaos-klipper-extensions moonraker; do
	git init -q -b master "$A5/$c" >/dev/null 2>&1
	printf 'x\n' > "$A5/$c/f"; git -C "$A5/$c" add -A
	git -C "$A5/$c" commit -q -m seed
done
cat > "$S5/app-generation.json" <<J
{ "migration_version": "gen-test", "recorded_at": "now" }
J
out=$(env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS" APPS="$A5" SYSTEM="$S5" \
	LOCKDIR="$W/locks5" GATE_LIB="$GATE_LIB_SRC" SEED_MANIFEST_LIB="$MANIFEST_LIB" \
	sh -c '. "$0"; start' "$MIGRATE" 2>&1)
backups=$(find "$S5/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [ "$backups" -eq 0 ]; then
	pass "a matching generation short-circuits migration: no backup directory created"
else
	fail "migration created $backups backup directory/ies despite a matching generation"
fi
case "$out" in
	*version_match*|*"already matches"*) pass "migration reports the version-match short-circuit" ;;
	*) fail "migration did not take the version-match path: $out" ;;
esac

# KNOWN LIMITATION, deliberately not asserted here. S04nebulaos-migrate:1215
# creates BACKUP_DIR before any component is attempted, and :1288-1290 ends
# without advancing the generation on failure, with no failure counter or
# backoff. So ANY persistent per-boot migration failure - not just this one -
# still produces one backup directory per boot, against
# nebulaos-retention.sh's -mtime +7 floor. Fixing F-06 removes today's
# trigger; it does not remove that amplifier, which needs its own change.

echo ""
echo "extensions-branch-contract-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
