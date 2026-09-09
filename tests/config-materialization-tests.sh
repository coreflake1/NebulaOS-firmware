#!/bin/sh
#
# Offline, repeatable tests for the config materialization library
# (scripts/build/overlay/etc/nebulaos/config-materialize.sh, Phase 2 final
# software closure mission, 2026-09-09 - see
# docs/NEBULAOS_CONFIG_MATERIALIZATION.md for the full architecture).
#
# Usage: sh tests/config-materialization-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos/config-materialize.sh"

[ -f "$LIB" ] || { echo "SKIP: $LIB not present"; exit 0; }

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/config-materialization-tests.XXXXXX")
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# make_immutable_source DIR GENERATION_SUFFIX - a small, fake immutable
# tree with its own real .manifest.json, content-varied by suffix so two
# calls with different suffixes produce genuinely different generations.
make_immutable_source() {
	dir="$1"; suffix="$2"
	mkdir -p "$dir"
	echo "# platform $suffix" > "$dir/platform.cfg"
	echo "# machine $suffix" > "$dir/machine.cfg"
	files_json=""
	hash_input=""
	for f in platform.cfg machine.cfg; do
		sha=$(sha256sum "$dir/$f" | cut -d' ' -f1)
		files_json="$files_json    \"$f\": \"$sha\",
"
		hash_input="$hash_input$f:$sha
"
	done
	files_json=$(printf '%s' "$files_json" | sed '$ s/,$//')
	generation=$(printf '%s' "$hash_input" | sha256sum | cut -d' ' -f1)
	cat > "$dir/.manifest.json" <<EOF
{
  "schema_version": 1,
  "generation": "$generation",
  "build_date": "test",
  "files": {
$files_json
  }
}
EOF
	echo "$generation"
}

run_materialize() {
	sandbox="$1"; src="$2"; label="$3"
	env NEBULAOS_KLIPPER_CFG_DIR="$src" \
	    PRINTER_DATA_CONFIG="$sandbox/printer_data/config" \
	    SYSTEM="$sandbox/system" \
	    BACKUP_ROOT="$sandbox/system/migration-backups" \
	    sh -c ". '$LIB'; log() { :; }; materialize_config_tree '$label'; echo RC=\$?"
}

run_needed_check() {
	sandbox="$1"; src="$2"
	env NEBULAOS_KLIPPER_CFG_DIR="$src" \
	    PRINTER_DATA_CONFIG="$sandbox/printer_data/config" \
	    SYSTEM="$sandbox/system" \
	    BACKUP_ROOT="$sandbox/system/migration-backups" \
	    sh -c ". '$LIB'; log() { :; }; config_materialization_needed; echo RC=\$?"
}

# =========================================================================
# Test 1: first materialization (no existing tree, no generation file)
# =========================================================================

t1="$WORK/t1"
src1="$WORK/t1-immutable"
gen1=$(make_immutable_source "$src1" "v1")
needed1=$(run_needed_check "$t1" "$src1" | grep '^RC=' | sed 's/RC=//')
[ "$needed1" = "0" ] && pass "test 1: materialization needed on first boot (no config-generation.json yet)" \
	|| fail "test 1: expected needed=0 on first boot, got $needed1"

result1=$(run_materialize "$t1" "$src1" "boot-materialization")
rc1=$(echo "$result1" | grep '^RC=' | sed 's/RC=//')
[ "$rc1" = "0" ] && pass "test 1: materialize_config_tree succeeds on first boot" \
	|| fail "test 1: materialize_config_tree failed ($result1)"

if [ -f "$t1/printer_data/config/nebulaos/platform.cfg" ] && [ -f "$t1/printer_data/config/nebulaos/machine.cfg" ]; then
	pass "test 1: both files materialized"
else
	fail "test 1: materialized files missing"
fi

recorded_gen1=$(grep -o '"generation"[^,]*' "$t1/system/config-generation.json" 2>/dev/null | sed -E 's/.*"([0-9a-f]+)"/\1/')
[ "$recorded_gen1" = "$gen1" ] && pass "test 1: config-generation.json records the correct generation" \
	|| fail "test 1: config-generation.json has wrong/missing generation ($recorded_gen1 vs $gen1)"

# =========================================================================
# Test 2: same generation on next boot - no materialization needed
# =========================================================================

needed2=$(run_needed_check "$t1" "$src1" | grep '^RC=' | sed 's/RC=//')
[ "$needed2" = "1" ] && pass "test 2: same-generation reboot correctly reports not-needed" \
	|| fail "test 2: expected needed=1 (no-op) on same generation, got $needed2"

# =========================================================================
# Test 3: new generation (image changed) - old tree backed up, new
#     materialized, generation marker updated, nothing else touched
# =========================================================================

t3="$WORK/t3"
src3a="$WORK/t3-immutable-a"
gen3a=$(make_immutable_source "$src3a" "gen-a")
run_materialize "$t3" "$src3a" "boot-materialization" >/dev/null

# simulate a real user config living alongside - must never be touched
mkdir -p "$t3/printer_data/config/macros"
echo "[gcode_macro USER]" > "$t3/printer_data/config/macros/user.cfg"
echo "printer.cfg content" > "$t3/printer_data/config/printer.cfg"
before_user_sum=$(sha256sum "$t3/printer_data/config/macros/user.cfg" "$t3/printer_data/config/printer.cfg" | sort)

src3b="$WORK/t3-immutable-b"
gen3b=$(make_immutable_source "$src3b" "gen-b-different-content")

needed3=$(run_needed_check "$t3" "$src3b" | grep '^RC=' | sed 's/RC=//')
[ "$needed3" = "0" ] && pass "test 3: new/different generation correctly reports needed" \
	|| fail "test 3: expected needed=0 for a new generation, got $needed3"

result3=$(run_materialize "$t3" "$src3b" "boot-materialization")
rc3=$(echo "$result3" | grep '^RC=' | sed 's/RC=//')
[ "$rc3" = "0" ] && pass "test 3: materialize_config_tree succeeds on generation change" \
	|| fail "test 3: materialize_config_tree failed on generation change ($result3)"

new_content=$(cat "$t3/printer_data/config/nebulaos/platform.cfg" 2>/dev/null)
[ "$new_content" = "# platform gen-b-different-content" ] && pass "test 3: the newly materialized tree has the new generation's real content" \
	|| fail "test 3: materialized content is not the new generation's ($new_content)"

backup_found=$(find "$t3/system/migration-backups/config-materialization" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$backup_found" -ge 1 ] && pass "test 3: the old tree was backed up before replacement" \
	|| fail "test 3: no backup of the old tree was found"

old_content_in_backup=$(find "$t3/system/migration-backups/config-materialization" -name "platform.cfg" -exec cat {} \; 2>/dev/null)
[ "$old_content_in_backup" = "# platform gen-a" ] && pass "test 3: the backup contains the OLD generation's real content" \
	|| fail "test 3: backup does not contain the expected old content ($old_content_in_backup)"

recorded_gen3=$(grep -o '"generation"[^,]*' "$t3/system/config-generation.json" 2>/dev/null | sed -E 's/.*"([0-9a-f]+)"/\1/')
[ "$recorded_gen3" = "$gen3b" ] && pass "test 3: config-generation.json updated to the new generation" \
	|| fail "test 3: config-generation.json not updated correctly"

after_user_sum=$(sha256sum "$t3/printer_data/config/macros/user.cfg" "$t3/printer_data/config/printer.cfg" | sort)
[ "$before_user_sum" = "$after_user_sum" ] && pass "test 3: printer.cfg and user macros are byte-identical after materialization" \
	|| fail "test 3: an unrelated user-owned file was modified during materialization"

# =========================================================================
# Test 4: A/B rollback - booting an OLDER generation than currently
#     materialized rematerializes to match it (same mechanism, no
#     special-casing - proves generality, not just forward progress)
# =========================================================================

t4="$WORK/t4"
src4new="$WORK/t4-immutable-new"
gen4new=$(make_immutable_source "$src4new" "newer")
run_materialize "$t4" "$src4new" "boot-materialization" >/dev/null

src4old="$WORK/t4-immutable-old"
gen4old=$(make_immutable_source "$src4old" "older-rollback-target")

result4=$(run_materialize "$t4" "$src4old" "boot-materialization")
rc4=$(echo "$result4" | grep '^RC=' | sed 's/RC=//')
[ "$rc4" = "0" ] && pass "test 4 (A/B rollback simulation): materialization to an older generation succeeds" \
	|| fail "test 4: materialization to an older generation failed ($result4)"

rolled_back_content=$(cat "$t4/printer_data/config/nebulaos/platform.cfg" 2>/dev/null)
[ "$rolled_back_content" = "# platform older-rollback-target" ] && pass "test 4: materialized tree now matches the older (rolled-back-to) generation exactly" \
	|| fail "test 4: materialized tree does not match the rollback target ($rolled_back_content)"

# =========================================================================
# Test 5: missing/corrupt manifest - refuses safely, leaves existing tree
# =========================================================================

t5="$WORK/t5"
src5="$WORK/t5-immutable"
make_immutable_source "$src5" "v1" >/dev/null
run_materialize "$t5" "$src5" "boot-materialization" >/dev/null
before_5=$(find "$t5/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)

src5_broken="$WORK/t5-immutable-broken"
mkdir -p "$src5_broken"
echo "# platform broken" > "$src5_broken/platform.cfg"
# no .manifest.json at all

result5=$(run_materialize "$t5" "$src5_broken" "boot-materialization")
rc5=$(echo "$result5" | grep '^RC=' | sed 's/RC=//')
[ "$rc5" = "1" ] && pass "test 5: missing manifest is refused (rc=1), not silently accepted" \
	|| fail "test 5: expected failure for a missing manifest, got rc=$rc5"

after_5=$(find "$t5/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)
[ "$before_5" = "$after_5" ] && pass "test 5: existing materialized tree is untouched after a refused attempt" \
	|| fail "test 5: existing tree was modified despite the refusal"

# =========================================================================
# Test 6: a manifest that claims a hash not matching the real file content
#     is refused, nothing promoted
# =========================================================================

t6="$WORK/t6"
src6="$WORK/t6-immutable"
make_immutable_source "$src6" "v1" >/dev/null
run_materialize "$t6" "$src6" "boot-materialization" >/dev/null
before_6=$(find "$t6/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)

src6_tampered="$WORK/t6-immutable-tampered"
make_immutable_source "$src6_tampered" "tampered-generation" >/dev/null
# tamper with the file AFTER its manifest was written, so the manifest's
# recorded hash no longer matches the real file content
echo "# TAMPERED, does not match manifest hash" > "$src6_tampered/platform.cfg"

result6=$(run_materialize "$t6" "$src6_tampered" "boot-materialization")
rc6=$(echo "$result6" | grep '^RC=' | sed 's/RC=//')
[ "$rc6" = "1" ] && pass "test 6: a hash mismatch against the manifest is refused (rc=1)" \
	|| fail "test 6: expected failure for a hash mismatch, got rc=$rc6"

after_6=$(find "$t6/printer_data/config/nebulaos" -type f -exec sha256sum {} \; | sort)
[ "$before_6" = "$after_6" ] && pass "test 6: existing materialized tree is untouched after a hash-mismatch refusal" \
	|| fail "test 6: existing tree was modified despite the hash-mismatch refusal"

echo ""
echo "config-materialization-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
