#!/bin/sh
#
# Phase 1.5 persistent-namespace mission (2026-08). Host-side simulation of
# an A/B slot switch: ONE shared persistent tree (printer.cfg, SAVE_CONFIG,
# macros, moonraker.conf, a fake Moonraker database, a fake Wi-Fi config, a
# fake shared gcode file), and TWO separate "/etc/nebulaos" trees standing
# in for what image A and image B each ship on their own read-only rootfs -
# with genuinely different content (different qualified pins), the same way
# two real qualified images would differ.
#
# Proves the actual property this mission's architecture rests on: which
# machine/platform config and which qualified pins are in effect depends
# ENTIRELY on which /etc/nebulaos tree is active - never on anything in the
# persistent tree - and switching between them changes nothing else.
#
# Reuses the real closure resolver (scripts/build/lib/validate-frontend-
# controls.sh) to compose the persistent printer.cfg with whichever
# /etc/nebulaos tree is "active", exactly the way the real build validates
# it and exactly the way real Klipper resolves absolute includes.
#
# Usage: sh tests/ab-slot-config-simulation-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ab-slot-config-simulation-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

. "$REPO_ROOT/scripts/build/lib/validate-frontend-controls.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

PERSIST="$WORK/persistent"
IMAGE_A="$WORK/image-a-etc-nebulaos"
IMAGE_B="$WORK/image-b-etc-nebulaos"

# Builds one image variant's /etc/nebulaos tree with a distinguishable pin
# value baked into machine.cfg (a fake, easy-to-grep marker standing in for
# "this is genuinely different content, not a copy") and klipper-pin.conf.
build_image_etc_nebulaos() {
	dir="$1"; label="$2"; pin="$3"
	rm -rf "$dir"
	mkdir -p "$dir/klipper" "$dir/moonraker"
	cat > "$dir/klipper/platform.cfg" <<-EOF
	[nebulaos_compat]
	# image: $label
	EOF
	cat > "$dir/klipper/machine.cfg" <<-EOF
	[mcu]
	serial: /dev/ttyS1
	# image: $label
	[stepper_x]
	step_pin: PC2
	EOF
	cat > "$dir/klipper/prtouch.cfg" <<-EOF
	[prtouch_v2]
	# image: $label
	EOF
	cat > "$dir/moonraker/klipper-pin.conf" <<-EOF
	[update_manager klipper]
	channel: dev
	pinned_commit: $pin
	EOF
}

build_persistent_tree() {
	rm -rf "$PERSIST"
	mkdir -p "$PERSIST/config" "$PERSIST/database" "$PERSIST/gcodes" "$PERSIST/network"
	cat > "$PERSIST/config/printer.cfg" <<-'EOF'
	[include /etc/nebulaos/klipper/platform.cfg]
	[include /etc/nebulaos/klipper/machine.cfg]
	[include /etc/nebulaos/klipper/prtouch.cfg]

	#*# <---------------------- SAVE_CONFIG ---------------------->
	#*# [bltouch]
	#*# z_offset = 1.234
	EOF
	cat > "$PERSIST/config/moonraker.conf" <<-'EOF'
	[server]
	host: 0.0.0.0
	[include /etc/nebulaos/moonraker/klipper-pin.conf]
	EOF
	echo "fake-database-content" > "$PERSIST/database/moonraker-sql.db"
	echo "fake-gcode-content" > "$PERSIST/gcodes/test-print.gcode"
	echo "ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
	ssid=\"real-network\"
	psk=\"real-password\"
}" > "$PERSIST/network/wpa_supplicant.conf"
}

# "Boots" the persistent tree against a given image's /etc/nebulaos and
# returns the resolved printer.cfg closure path + the resolved pin value,
# via the exact same absolute-include resolution real Klipper/Moonraker use
# (and this project's own build-time closure validator already proved
# correct against the real pinned Klipper/Moonraker source).
resolve_active_pin() {
	image_etc="$1"
	closure="$WORK/closure.txt"
	overlay_root="$WORK/overlay-root-machine"
	# frontend_controls_resolve_closure expects overlay_root such that
	# overlay_root + "/etc/nebulaos/..." resolves to the real files - build
	# a throwaway overlay root whose etc/nebulaos is a symlink to the image
	# under test, so the SAME closure resolver code path used by the real
	# build is exercised here, not a parallel reimplementation.
	rm -rf "$overlay_root"
	mkdir -p "$overlay_root/etc"
	ln -s "$image_etc" "$overlay_root/etc/nebulaos"
	frontend_controls_resolve_closure "$PERSIST/config" printer.cfg "$closure" "$overlay_root" >/dev/null 2>&1
	grep -o "^# image: .*" "$closure" | head -1
}

resolve_active_klipper_pin() {
	image_etc="$1"
	overlay_root="$WORK/overlay-root-pin"
	rm -rf "$overlay_root"
	mkdir -p "$overlay_root/etc"
	ln -s "$image_etc" "$overlay_root/etc/nebulaos"
	closure="$WORK/moonraker-closure.txt"
	frontend_controls_resolve_closure "$PERSIST/config" moonraker.conf "$closure" "$overlay_root" >/dev/null 2>&1
	grep "^pinned_commit:" "$closure" | head -1 | sed 's/^pinned_commit: *//'
}

sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

echo "=== A/B slot config simulation ==="

build_image_etc_nebulaos "$IMAGE_A" "A" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
build_image_etc_nebulaos "$IMAGE_B" "B" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
build_persistent_tree

printer_cfg_sha_before=$(sha "$PERSIST/config/printer.cfg")
moonraker_conf_sha_before=$(sha "$PERSIST/config/moonraker.conf")
database_sha_before=$(sha "$PERSIST/database/moonraker-sql.db")
gcode_sha_before=$(sha "$PERSIST/gcodes/test-print.gcode")
wifi_sha_before=$(sha "$PERSIST/network/wpa_supplicant.conf")

active=$(resolve_active_pin "$IMAGE_A")
if [ "$active" = "# image: A" ]; then
	pass "boot as image A: machine.cfg resolves to image A's content"
else
	fail "boot as image A: expected '# image: A', got '$active'"
fi

pin=$(resolve_active_klipper_pin "$IMAGE_A")
if [ "$pin" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; then
	pass "boot as image A: klipper-pin.conf resolves to image A's pin"
else
	fail "boot as image A: expected A's pin, got '$pin'"
fi

# --- A -> B ---
active=$(resolve_active_pin "$IMAGE_B")
if [ "$active" = "# image: B" ]; then
	pass "switch A -> B: machine.cfg resolves to image B's content"
else
	fail "switch A -> B: expected '# image: B', got '$active'"
fi

pin=$(resolve_active_klipper_pin "$IMAGE_B")
if [ "$pin" = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]; then
	pass "switch A -> B: klipper-pin.conf resolves to image B's pin"
else
	fail "switch A -> B: expected B's pin, got '$pin'"
fi

if [ "$(sha "$PERSIST/config/printer.cfg")" = "$printer_cfg_sha_before" ]; then
	pass "switch A -> B: persistent printer.cfg unchanged (no rewrite needed for the slot switch)"
else
	fail "switch A -> B: persistent printer.cfg was modified - it should never need rewriting for a slot switch"
fi
if [ "$(sha "$PERSIST/config/moonraker.conf")" = "$moonraker_conf_sha_before" ]; then
	pass "switch A -> B: persistent moonraker.conf unchanged"
else
	fail "switch A -> B: persistent moonraker.conf was modified"
fi
if [ "$(sha "$PERSIST/database/moonraker-sql.db")" = "$database_sha_before" ]; then
	pass "switch A -> B: database unchanged"
else
	fail "switch A -> B: database was modified"
fi
if [ "$(sha "$PERSIST/gcodes/test-print.gcode")" = "$gcode_sha_before" ]; then
	pass "switch A -> B: shared gcode file unchanged and still present"
else
	fail "switch A -> B: shared gcode file was modified or lost"
fi
if [ "$(sha "$PERSIST/network/wpa_supplicant.conf")" = "$wifi_sha_before" ]; then
	pass "switch A -> B: Wi-Fi config unchanged"
else
	fail "switch A -> B: Wi-Fi config was modified"
fi
if grep -q "z_offset = 1.234" "$PERSIST/config/printer.cfg"; then
	pass "switch A -> B: SAVE_CONFIG block still present, unchanged"
else
	fail "switch A -> B: SAVE_CONFIG block missing or altered"
fi

# --- B -> A (rollback) ---
active=$(resolve_active_pin "$IMAGE_A")
if [ "$active" = "# image: A" ]; then
	pass "rollback B -> A: machine.cfg resolves back to image A's content"
else
	fail "rollback B -> A: expected '# image: A', got '$active'"
fi
pin=$(resolve_active_klipper_pin "$IMAGE_A")
if [ "$pin" = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]; then
	pass "rollback B -> A: klipper-pin.conf resolves back to image A's pin (this is the exact property the pre-Phase-1.5 persistent-tree pin design got wrong)"
else
	fail "rollback B -> A: expected A's pin, got '$pin'"
fi
if [ "$(sha "$PERSIST/config/printer.cfg")" = "$printer_cfg_sha_before" ] && [ "$(sha "$PERSIST/network/wpa_supplicant.conf")" = "$wifi_sha_before" ]; then
	pass "rollback B -> A: persistent state still unchanged after two switches"
else
	fail "rollback B -> A: persistent state drifted across the round trip"
fi

# --- A -> B again, confirming repeatability ---
active=$(resolve_active_pin "$IMAGE_B")
if [ "$active" = "# image: B" ]; then
	pass "switch A -> B again: still resolves correctly (repeatable, not a one-shot artifact)"
else
	fail "switch A -> B again: expected '# image: B', got '$active'"
fi

echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
