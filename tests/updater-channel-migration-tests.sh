#!/bin/sh
#
# Offline, repeatable tests for migrate_updater_channels() in
# scripts/build/overlay/etc/init.d/S04nebulaos-migrate (Phase 2 overnight
# convergence mission, 2026-09-09): the bounded, value-exact rewrite of
# moonraker.conf's [update_manager moonraker]/[update_manager mainsail]
# channel from this project's own old shipped defaults (dev/beta, pre-
# commit cddf41b) to the final frozen policy (stable/stable - see
# _project/missions/final-core-convergence/DECISIONS.md). Discovered live
# on real hardware during Phase 2 RC4 overnight qualification: a device
# provisioned before cddf41b still reported dev/beta after being flashed
# with a post-cddf41b image, because moonraker.conf is USER OWNED and
# nothing else ever revisits its update_manager sections.
#
# Same seam/sandbox convention as printer-cfg-migration-tests.sh.
#
# Usage: sh tests/updater-channel-migration-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# The S04 scripts source this shared reader (audit F-06). Exported once
# here so every `env ... sh -c ". $SCRIPT"` invocation below inherits it;
# on a device it is /etc/nebulaos-seed-manifest.sh and this is a no-op.
export SEED_MANIFEST_LIB="${SEED_MANIFEST_LIB:-$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-seed-manifest.sh}"
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/updater-channel-migration-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: updater-channel-migration-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }

cleanup() {
	chmod -R u+rwx "$WORK" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[ -f "$MIGRATE_SCRIPT" ] || { echo "SKIP: $MIGRATE_SCRIPT not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

run_fn() {
	pdc="$1"; log="$2"
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 PRINTER_DATA_CONFIG="$pdc" SYSTEM="$WORK/system" SEEDS="$WORK/seeds" \
		sh -c ". '$MIGRATE_SCRIPT'; rc=0; migrate_updater_channels || rc=\$?; echo \"RC=\$rc\"" \
		> "$log" 2>&1
}
rc_of() { grep '^RC=' "$1" | tail -1 | sed 's/^RC=//'; }
channel_of() {
	# $1=section (e.g. "update_manager moonraker"), $2=file
	awk -v want="[$1]" '
		/^\[.*\]$/ { in_sec = ($0 == want); next }
		in_sec && $0 ~ /^[ \t]*channel[ \t]*:/ {
			sub(/^[ \t]*channel[ \t]*:[ \t]*/, ""); gsub(/[ \t]+$/, ""); print; exit
		}
	' "$2"
}

# --- Case 1: real live shape - moonraker=dev, mainsail=beta, both narrow ---

t1="$WORK/case1"; mkdir -p "$t1"; f1="$t1/moonraker.conf"
cat > "$f1" <<'EOF'
[server]
host: 0.0.0.0
port: 7125

[include /etc/nebulaos/moonraker/klipper-pin.conf]

[update_manager moonraker]
channel: dev

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail

[authorization]
trusted_clients:
 127.0.0.1
EOF
cp "$f1" "$f1.orig"

log1="$WORK/log1"
run_fn "$t1" "$log1"

if [ "$(channel_of 'update_manager moonraker' "$f1")" = "stable" ] \
	&& [ "$(channel_of 'update_manager mainsail' "$f1")" = "stable" ]; then
	pass "case 1: both moonraker and mainsail migrated dev/beta -> stable"
else
	fail "case 1: channels not migrated correctly (moonraker=$(channel_of 'update_manager moonraker' "$f1"), mainsail=$(channel_of 'update_manager mainsail' "$f1"))"
fi
if grep -qF '[server]' "$f1" && grep -qF 'trusted_clients:' "$f1" && grep -qF 'repo: mainsail-crew/mainsail' "$f1" \
	&& grep -qF 'path: /usr/data/nebulaos/apps/mainsail' "$f1"; then
	pass "case 1: unrelated sections/options preserved"
else
	fail "case 1: unrelated content lost or altered"
fi
[ "$(rc_of "$log1")" = "0" ] && pass "case 1: reports success" || fail "case 1: reported failure ($(cat "$log1"))"

# --- Case 2: already final (stable/stable) - true no-op --------------------

t2="$WORK/case2"; mkdir -p "$t2"; f2="$t2/moonraker.conf"
cat > "$f2" <<'EOF'
[update_manager moonraker]
channel: stable

[update_manager mainsail]
type: web
channel: stable
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
EOF
cp "$f2" "$f2.orig"
log2="$WORK/log2"
run_fn "$t2" "$log2"
if cmp -s "$f2" "$f2.orig"; then
	pass "case 2: already-stable file is a true no-op, byte-for-byte unchanged"
else
	fail "case 2: an already-final file was modified"
fi
[ "$(rc_of "$log2")" = "0" ] && pass "case 2: reports success on no-op" || fail "case 2: reported failure on no-op ($(cat "$log2"))"

# --- Case 3: moonraker has an explicit pinned_commit alongside dev - refuse -

t3="$WORK/case3"; mkdir -p "$t3"; f3="$t3/moonraker.conf"
cat > "$f3" <<'EOF'
[update_manager moonraker]
channel: dev
pinned_commit: abc123deadbeef

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
EOF
cp "$f3" "$f3.orig"
log3="$WORK/log3"
run_fn "$t3" "$log3"
if [ "$(channel_of 'update_manager moonraker' "$f3")" = "dev" ]; then
	pass "case 3: moonraker section with an extra pinned_commit option is left untouched (ambiguous, refused)"
else
	fail "case 3: moonraker section with unrecognized content was migrated anyway - should have refused"
fi
if [ "$(channel_of 'update_manager mainsail' "$f3")" = "stable" ]; then
	pass "case 3: the OTHER (narrow, unaffected) section still migrates independently"
else
	fail "case 3: mainsail section should still migrate even though moonraker was refused"
fi

# --- Case 4: user deliberately set a different (non-default) channel -------

t4="$WORK/case4"; mkdir -p "$t4"; f4="$t4/moonraker.conf"
cat > "$f4" <<'EOF'
[update_manager moonraker]
channel: beta

[update_manager mainsail]
type: web
channel: stable
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
EOF
cp "$f4" "$f4.orig"
log4="$WORK/log4"
run_fn "$t4" "$log4"
if cmp -s "$f4" "$f4.orig"; then
	pass "case 4: a channel value that does not exactly match the known old default is left untouched"
else
	fail "case 4: a non-matching channel value was modified"
fi

# --- Case 5: no moonraker.conf at all - safe no-op --------------------------

t5="$WORK/case5"; mkdir -p "$t5"
log5="$WORK/log5"
run_fn "$t5" "$log5"
[ "$(rc_of "$log5")" = "0" ] && pass "case 5: missing moonraker.conf is a safe no-op" || fail "case 5: missing file caused a reported failure ($(cat "$log5"))"
[ ! -e "$t5/moonraker.conf" ] && pass "case 5: no file created where none existed" || fail "case 5: a file was unexpectedly created"

# --- Case 6: idempotent across repeated runs --------------------------------

run_fn "$t1" "$WORK/log6a"
sum_a=$(md5sum "$f1" | cut -d' ' -f1)
run_fn "$t1" "$WORK/log6b"
sum_b=$(md5sum "$f1" | cut -d' ' -f1)
[ "$sum_a" = "$sum_b" ] && pass "case 6: repeated execution is idempotent" || fail "case 6: repeated execution changed the file further"

# --- Case 7: mainsail with an unrecognized extra option - refuse -----------

t7="$WORK/case7"; mkdir -p "$t7"; f7="$t7/moonraker.conf"
cat > "$f7" <<'EOF'
[update_manager moonraker]
channel: dev

[update_manager mainsail]
type: web
channel: beta
repo: mainsail-crew/mainsail
path: /usr/data/nebulaos/apps/mainsail
primary_branch: custom-fork-branch
EOF
cp "$f7" "$f7.orig"
log7="$WORK/log7"
run_fn "$t7" "$log7"
if [ "$(channel_of 'update_manager mainsail' "$f7")" = "beta" ]; then
	pass "case 7: mainsail section with an unrecognized extra option is left untouched"
else
	fail "case 7: mainsail section with unrecognized content was migrated anyway"
fi
if [ "$(channel_of 'update_manager moonraker' "$f7")" = "stable" ]; then
	pass "case 7: the OTHER (narrow) section still migrates independently"
else
	fail "case 7: moonraker section should still migrate even though mainsail was refused"
fi

echo ""
echo "updater-channel-migration-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
