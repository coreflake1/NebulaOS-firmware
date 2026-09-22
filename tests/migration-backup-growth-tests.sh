#!/bin/sh
#
# D-01 regression: a persistent deterministic reseed failure must NOT create
# boot-proportional backup growth.
#
# This is the suite that would have caught the amplifier. Before the fix, a
# deterministic failure produced one $BACKUP_ROOT/<UTC timestamp> directory per
# boot, forever, holding a full klipper+moonraker tree each - a real device
# reached ~1.6GB / 95% of a 5.9GB /usr/data. Retention reclaims nothing for
# seven days (nebulaos-retention.sh:279 filters -mtime +7 BEFORE the keep
# count), and emergency_gcode_cleanup deletes the user's print files rather
# than migration backups, so "retention will handle it" was never true.
#
# Every case here drives the REAL S04nebulaos-migrate start() against throwaway
# fixtures. Nothing touches the canonical checkout.
set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIGRATE="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
MANIFEST_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-seed-manifest.sh"
GATE_LIB_SRC="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_SEED="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"

export GIT_AUTHOR_NAME=backup-growth GIT_AUTHOR_EMAIL=bg@nebulaos.invalid
export GIT_COMMITTER_NAME=backup-growth GIT_COMMITTER_EMAIL=bg@nebulaos.invalid

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

W=$(mktemp -d "${TMPDIR:-/tmp}/migration-backup-growth.XXXXXX") || exit 1
[ -n "$W" ] || { echo "FATAL: mktemp gave no path"; exit 1; }
trap 'rm -rf "$W"' EXIT

. "$MAKE_SEED"

KLIPPER_ORIGIN="https://github.com/Klipper3d/klipper.git"
MOONRAKER_ORIGIN="https://github.com/Arksine/moonraker.git"
EXT_ORIGIN="https://github.com/coreflake1/NebulaOS-klipper-extensions.git"

# Build one complete, valid fixture: apps at "old", seeds at "new".
# $1 = instance name, $2 = extensions branch to put in the manifest ("" = omit)
build_fixture() {
	# NOTE: use ${2-...} (no colon) so an explicitly EMPTY second argument
	# means "omit the branch key", rather than silently falling back to the
	# default the way ${2:-...} would.
	_n="$1"; _extbranch="${2-production}"
	A="$W/$_n-apps"; S="$W/$_n-sys"; SD="$W/$_n-seeds"
	rm -rf "$A" "$S" "$SD"; mkdir -p "$A" "$S" "$SD"
	for spec in "klipper:master:$KLIPPER_ORIGIN" \
	            "nebulaos-klipper-extensions:production:$EXT_ORIGIN" \
	            "moonraker:master:$MOONRAKER_ORIGIN"; do
		c=${spec%%:*}; rest=${spec#*:}; br=${rest%%:*}; org=${rest#*:}
		git init -q -b "$br" "$A/$c" >/dev/null 2>&1
		printf 'old\n' > "$A/$c/f"
		git -C "$A/$c" add -A; git -C "$A/$c" commit -q -m pre
		git -C "$A/$c" remote add origin "$org" 2>/dev/null || \
			git -C "$A/$c" remote set-url origin "$org"
		src="$W/$_n-src-$c"
		rm -rf "$src"; git init -q -b "$br" "$src"
		printf 'new\n' > "$src/f"
		git -C "$src" add -A; git -C "$src" commit -q -m new
		git -C "$src" remote add origin "$org"
		make_seed_archive "$src" "$br" "$org" "$SD/$c.tar.gz" "" >/dev/null 2>&1
	done
	if [ -n "$_extbranch" ]; then
		_extline='"branch": "'"$_extbranch"'", '
	else
		_extline=''
	fi
	cat > "$SD/seed-manifest.json" <<J
{
  "migration_version": "gen-target",
  "components": {
    "klipper": { "branch": "master", "seed_commit": "a" },
    "nebulaos-klipper-extensions": { ${_extline}"seed_commit": "b" },
    "moonraker": { "branch": "master", "seed_commit": "c" }
  }
}
J
}

# Run one simulated boot against a fixture. $1 = instance, $2 = manifest lib
boot() {
	_n="$1"; _lib="${2:-$MANIFEST_LIB}"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 \
		SEEDS="$W/$_n-seeds" APPS="$W/$_n-apps" SYSTEM="$W/$_n-sys" \
		LOCKDIR="$W/$_n-locks" GATE_LIB="$GATE_LIB_SRC" \
		SEED_MANIFEST_LIB="$_lib" \
		sh -c '. "$0"; start' "$MIGRATE" 2>&1
}

backups() { find "$W/$1-sys/migration-backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l; }

# NOTE on what a pre-fix run looks like: the OLD BACKUP_DIR name had
# per-second UTC granularity, so a fast test loop lands several boots in the
# same second and shares one directory - against pre-fix code this suite sees
# ~3 directories for 20 boots, not 20. That understates the real device, where
# boots are minutes apart and every one gets its own. The assertions therefore
# test PROPORTIONALITY (case 5: does the count change with the boot count?)
# rather than an absolute number, which is the property that actually matters.
N=20

echo "=== Case 1: persistent PRECONDITION failure (no derivable branch) x $N boots ==="
build_fixture c1 ""            # manifest omits the extensions branch
i=0; while [ "$i" -lt "$N" ]; do boot c1 >/dev/null 2>&1; i=$((i+1)); done
n1=$(backups c1)
if [ "$n1" -eq 0 ]; then
	pass "precondition failure x $N boots created ZERO backup directories (storage-neutral)"
else
	fail "precondition failure x $N boots created $n1 backup directories (expected 0)"
fi
if [ ! -f "$W/c1-sys/app-generation.json" ]; then
	pass "precondition failure never records a generation (retries forever, safely)"
else
	fail "precondition failure recorded a generation"
fi
if [ "$(cat "$W/c1-apps/klipper/f" 2>/dev/null)" = "old" ]; then
	pass "precondition failure mutated nothing (klipper still pre-migration)"
else
	fail "precondition failure mutated the klipper tree"
fi

echo ""
echo "=== Case 2: persistent MISSING-LIBRARY failure x $N boots ==="
build_fixture c2 production
i=0; while [ "$i" -lt "$N" ]; do boot c2 "$W/no-such-lib.sh" >/dev/null 2>&1; i=$((i+1)); done
n2=$(backups c2)
if [ "$n2" -eq 0 ]; then
	pass "missing seed-manifest library x $N boots created ZERO backup directories"
else
	fail "missing seed-manifest library x $N boots created $n2 backup directories (expected 0)"
fi

echo ""
echo "=== Case 3: persistent POST-CUTOVER failure x $N boots ==="
# A corrupt moonraker archive passes the zero-write preconditions (the file
# exists) and fails at extraction - AFTER klipper has already been cut over.
# This is the failure class the precondition gate cannot cover, and the one
# the attempt record exists to bound.
build_fixture c3 production
printf 'not a gzip stream\n' > "$W/c3-seeds/moonraker.tar.gz"
i=0; while [ "$i" -lt "$N" ]; do boot c3 >/dev/null 2>&1; i=$((i+1)); done
n3=$(backups c3)
if [ "$n3" -le 1 ]; then
	pass "post-cutover failure x $N boots created $n3 backup director(y/ies) - BOUNDED, not boot-proportional"
else
	fail "post-cutover failure x $N boots created $n3 backup directories - growth is boot-proportional (the amplifier)"
fi
if [ ! -f "$W/c3-sys/app-generation.json" ]; then
	pass "post-cutover failure never records a generation (no silent mixed-generation commit)"
else
	fail "post-cutover failure recorded a generation despite an incomplete stack"
fi
# The genuine pre-migration tree must survive all 20 retries.
if [ "$(cat "$W/c3-sys/migration-backups"/*/klipper/f 2>/dev/null | head -1)" = "old" ]; then
	pass "the FIRST backup still holds the genuine pre-migration klipper tree after $N retries"
else
	fail "the preserved backup no longer holds the pre-migration tree - recovery value was destroyed"
fi

echo ""
echo "=== Case 4: successful migration ==="
build_fixture c4 production
out4=$(boot c4)
n4=$(backups c4)
if [ "$n4" -eq 1 ]; then
	pass "successful migration creates exactly one backup directory"
else
	fail "successful migration created $n4 backup directories (expected 1): $out4"
fi
if [ "$(cat "$W/c4-sys/migration-backups"/*/klipper/f 2>/dev/null)" = "old" ]; then
	pass "the backup holds the pre-migration klipper tree (recovery value preserved)"
else
	fail "the backup does not hold the pre-migration klipper tree"
fi
if [ -f "$W/c4-sys/app-generation.json" ]; then
	pass "successful migration records the generation"
else
	fail "successful migration did not record a generation: $out4"
fi
if [ ! -f "$W/c4-sys/migration-attempt.json" ]; then
	pass "the attempt record is cleared once the generation is recorded"
else
	fail "the attempt record survived a successful migration - the next migration would reuse this backup dir"
fi
# Second boot must be a no-op.
out4b=$(boot c4)
n4b=$(backups c4)
if [ "$n4b" -eq "$n4" ]; then
	pass "a second boot after success creates no additional backup (version-match short-circuit)"
else
	fail "a second boot after success grew backups $n4 -> $n4b"
fi
case "$out4b" in
	*version_match*|*"already matches"*) pass "the second boot reports the version-match short-circuit" ;;
	*) fail "the second boot did not short-circuit: $out4b" ;;
esac

echo ""
echo "=== Case 5: the bound is a CONSTANT, not a function of boot count ==="
# Same deterministic post-cutover failure, half the boots. If growth were
# boot-proportional the two counts would differ.
build_fixture c5 production
printf 'not a gzip stream\n' > "$W/c5-seeds/moonraker.tar.gz"
i=0; while [ "$i" -lt 10 ]; do boot c5 >/dev/null 2>&1; i=$((i+1)); done
n5=$(backups c5)
if [ "$n5" -eq "$n3" ]; then
	pass "10 boots and $N boots of the same failure yield the same backup count ($n5) - constant, not proportional"
else
	fail "10 boots gave $n5 backups but $N boots gave $n3 - growth is boot-proportional"
fi

echo ""
echo "migration-backup-growth-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
