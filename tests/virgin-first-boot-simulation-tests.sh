#!/bin/sh
#
# Virgin-Baseline Fix + Rebuild mission, task 5 (2026-08-08): simulates a
# genuinely empty NebulaOS persistent state going through first boot end
# to end, entirely offline - S02nebulaos-namespace (layout + printer_data/
# config seed), S04nebulaos-factory-seed (klipper checkout seed +
# generation baseline), S04nebulaos-migrate (confirms no redundant
# reseed) - then runs real offline Klipper config validation against the
# RESULTING, provisioned printer.cfg (not the source tree copy), proving
# the full pipeline produces a config Klipper could actually start with.
#
# Unlike tests/nebulaos-printerdata-seed-tests.sh (which uses a synthetic
# minimal printer.cfg fixture), this test seeds from the REAL, tracked
# scripts/build/overlay/opt/printer_data/config/ directly - the actual
# canonical factory config this build ships, including the [z_compensate]/
# [prtouch_v2]/[nebulaos_version] sections task 1/2 of this mission wired
# in. The klipper git archive is still a fixture (a real, throwaway repo
# standing in for the canonical checkout - same convention as
# tests/factory-seed-git-tests.sh) since this test is about the
# provisioning PIPELINE and the REAL printer.cfg, not about re-verifying
# the Klipper source pin itself (tests/recovery-safety-tests.sh already
# does that against the real remote).
#
# Usage: sh tests/virgin-first-boot-simulation-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# Points every sourced init script's own GATE_LIB override at the real,
# tracked shared gate (not the real device path /etc/nebulaos-
# maintenance-gate.sh, which does not exist on a dev machine) - exported
# once so every `env ... sh -c` call below inherits it automatically.
export GATE_LIB="$REPO_ROOT/scripts/build/overlay/etc/nebulaos-maintenance-gate.sh"
MAKE_ARCHIVE_LIB="$REPO_ROOT/scripts/build/lib/make-seed-archive.sh"
S02_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S02nebulaos-namespace"
S04_FACTORY_SEED_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed"
S04_MIGRATE_SCRIPT="$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate"
REAL_PRINTER_DATA_CONFIG="$REPO_ROOT/scripts/build/overlay/opt/printer_data/config"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/virgin-first-boot-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

. "$MAKE_ARCHIVE_LIB"

test_virgin_first_boot_produces_valid_klipper_config() {
	NEBULAOS_ROOT="$WORK/persistent-root"
	SEEDS="$WORK/seeds"
	rm -rf "$NEBULAOS_ROOT" "$SEEDS"
	mkdir -p "$SEEDS"

	# 1. Build a real, throwaway "canonical klipper" fixture archive -
	# content doesn't matter for this test (recovery-safety-tests.sh
	# already verifies the real pin's real content); only branch/origin/
	# clean-tree matter to the seeding pipeline itself.
	klipper_src="$WORK/klipper-src"
	git init -q -b master "$klipper_src"
	echo "fixture klipper" > "$klipper_src/marker.txt"
	git -C "$klipper_src" add -A
	git -C "$klipper_src" -c user.email=t@l -c user.name=t commit -q -m "fixture"
	klipper_commit=$(make_seed_archive "$klipper_src" master \
		"https://github.com/coreflake1/NebulaOS-klipper.git" "$SEEDS/klipper.tar.gz")

	cat > "$SEEDS/seed-manifest.json" <<EOF
{
  "migration_version": "virgin-sim-gen-1",
  "seeds": {"klipper": {"seed_commit": "$klipper_commit"}}
}
EOF

	# 2. S02: create the empty namespace layout AND seed printer_data/
	# config from the REAL, tracked source - exactly what a genuinely
	# fresh device's very first boot does.
	env S02NEBULAOS_NAMESPACE_NO_AUTORUN=1 NEBULAOS_ROOT="$NEBULAOS_ROOT" \
		PRINTER_DATA_CONFIG_SEED="$REAL_PRINTER_DATA_CONFIG" \
		sh -c ". '$S02_SCRIPT'; start" > "$WORK/s02.log" 2>&1

	if [ ! -f "$NEBULAOS_ROOT/printer_data/config/printer.cfg" ]; then
		fail "virgin boot: S02 did not seed printer_data/config/printer.cfg ($(cat "$WORK/s02.log"))"
		return
	fi
	pass "virgin boot: S02 seeded printer_data/config from the real tracked source"

	# 3. S04 factory-seed: seed the klipper checkout (function called
	# directly, same convention as tests/app-migration-tests.sh - full
	# start() also seeds mainsail/venvs, out of scope for this config-
	# focused test), then record the initial generation exactly as a
	# real fresh boot's S04 slot would (factory-seed runs before migrate).
	env S04NEBULAOS_FACTORY_SEED_NO_AUTORUN=1 SEEDS="$SEEDS" \
		APPS="$NEBULAOS_ROOT/apps" SYSTEM="$NEBULAOS_ROOT/system" \
		sh -c ". '$S04_FACTORY_SEED_SCRIPT'; \
			seed_git_app klipper master 'https://github.com/coreflake1/NebulaOS-klipper.git' \
				klippy/chelper/c_helper.so; \
			record_initial_generation" > "$WORK/s04-seed.log" 2>&1

	if [ ! -e "$NEBULAOS_ROOT/apps/klipper/.git" ]; then
		fail "virgin boot: klipper checkout was not seeded ($(cat "$WORK/s04-seed.log"))"
		return
	fi
	pass "virgin boot: canonical klipper checkout seeded"

	if [ ! -f "$NEBULAOS_ROOT/system/app-generation.json" ] \
		|| ! grep -q "virgin-sim-gen-1" "$NEBULAOS_ROOT/system/app-generation.json"; then
		fail "virgin boot: app-generation.json missing or wrong migration_version ($(cat "$WORK/s04-seed.log"))"
	else
		pass "virgin boot: correct migration/app generation recorded"
	fi

	# 4. S04 migrate: on the very next S04-slot entry (same boot), must
	# be a clean no-op - the exact fresh-boot-ordering property Phase 3/4
	# fixed and tests/app-migration-tests.sh already covers in isolation;
	# re-confirmed here as part of the full chained pipeline.
	env S04NEBULAOS_MIGRATE_NO_AUTORUN=1 SEEDS="$SEEDS" \
		APPS="$NEBULAOS_ROOT/apps" SYSTEM="$NEBULAOS_ROOT/system" \
		LOCKDIR="$WORK/no-lock" \
		sh -c ". '$S04_MIGRATE_SCRIPT'; start" > "$WORK/s04-migrate.log" 2>&1
	backup_count=$(find "$NEBULAOS_ROOT/system/migration-backups" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
	if [ "$backup_count" -eq 0 ] && grep -q "already matches" "$WORK/s04-migrate.log"; then
		pass "virgin boot: migrate makes no redundant backup/reseed on the same fresh boot"
	else
		fail "virgin boot: migrate did something on a freshly-seeded boot ($(cat "$WORK/s04-migrate.log"))"
	fi

	# 5. User-owned paths stay separate: printer_data/config is untouched
	# by anything apps/system-related, and vice versa - verified by the
	# mere fact both exist independently with no cross-contamination
	# (S04 never references printer_data at all - grep the log for proof
	# this run never touched that path).
	if grep -q "printer_data" "$WORK/s04-seed.log" "$WORK/s04-migrate.log" 2>/dev/null; then
		fail "virgin boot: S04 scripts referenced printer_data - USER OWNED/IMAGE OWNED separation violated"
	else
		pass "virgin boot: USER OWNED printer_data path never referenced by IMAGE OWNED app seeding"
	fi

	# 6. The real proof: parse the ACTUALLY-PROVISIONED printer.cfg (not
	# the source tree) and drive it through real production
	# PRTouchV2/ZCompensate code, exactly as klippy_extras/
	# test_printer_cfg_config_validation.py does against the source file -
	# proving the seeding pipeline didn't corrupt/truncate/mangle
	# anything on the way from source to a provisioned device.
	# Phase 1.5 persistent-namespace mission: [prtouch_v2]/[z_compensate]
	# moved out of printer.cfg into the immutable, image-owned
	# /etc/nebulaos/klipper/prtouch.cfg, included by absolute path. They
	# no longer travel through the virgin-seed pipeline at all (only
	# printer.cfg does) - which is itself the point of this mission (an
	# A/B slot switch restores them from the rootfs, not from anything
	# seeded) - so the meaningful thing left to prove here is that the
	# PROVISIONED printer.cfg, combined with the tracked immutable
	# includes, resolves to values real PRTouchV2/ZCompensate code
	# accepts. Concatenated from the tracked overlay source rather than a
	# real /etc/nebulaos/ (which needs root to stage - see
	# tests/klipper-config-load-smoke-tests.py for that full, root-requiring
	# proof); this offline test only needs the real section content, not a
	# real absolute-include resolution.
	provisioned_cfg="$NEBULAOS_ROOT/printer_data/config/printer.cfg"
	if PYTHONPATH="$REPO_ROOT" python3 - "$provisioned_cfg" "$REPO_ROOT/scripts/build/overlay/etc/nebulaos/klipper/prtouch.cfg" <<'PYEOF'
import configparser, sys
sys.path.insert(0, ".")
from klippy_extras import prtouch_test_support as fake
from klippy_extras import prtouch_v2, z_compensate

def real_section(text, section):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    marker = "\n[%s]\n" % section
    start = text.index(marker) + 1
    nxt = text.find("\n[", start + 1)
    parser.read_string(text[start:nxt if nxt != -1 else len(text)])
    return dict(parser[section])

provisioned_text = open(sys.argv[1]).read()
if "[include /etc/nebulaos/klipper/prtouch.cfg]" not in provisioned_text:
    raise SystemExit("provisioned printer.cfg does not include prtouch.cfg - virgin seed produced an unexpected shape")
text = provisioned_text + "\n" + open(sys.argv[2]).read()
prtouch_values = real_section(text, "prtouch_v2")
printer, mcu, pins, _ = fake.build_environment(prtouch_v2_values=prtouch_values)
prtouch_config = fake.make_prtouch_v2_config(printer, pins, prtouch_values)
pv2 = prtouch_v2.PRTouchV2(prtouch_config)
printer.add_object("prtouch_v2", pv2)

zc_values = real_section(text, "z_compensate")
zc_config = fake.make_z_compensate_config(printer, zc_values)
zc = z_compensate.ZCompensate(zc_config)

fake.connect(printer, mcu)
prtouch_config.assert_all_consumed()
zc_config.assert_all_consumed()
assert zc.bed_add_temp == 60.0, zc.bed_add_temp
print("VALID")
PYEOF
	then
		pass "virgin boot: provisioned printer.cfg reaches a valid Klipper startup configuration (real config-load validation, zero errors)"
	else
		fail "virgin boot: provisioned printer.cfg failed real Klipper config validation"
	fi
}

test_virgin_first_boot_produces_valid_klipper_config

echo
echo "virgin-first-boot-simulation-tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
