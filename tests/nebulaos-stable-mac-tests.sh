#!/bin/sh
#
# Offline, repeatable tests for scripts/build/overlay/etc/nebulaos-stable-
# mac.sh's MAC-derivation logic (pre-qualification mission Phase A3,
# 2026-07-31). Sources the actual production library - there is
# deliberately no second/parallel copy of the derivation logic here to
# drift out of sync with it.
#
# Known, honest coverage gap: nebulaos_read_hardware_identifier() reads
# real sysfs paths (/sys/class/mmc_host/.../cid, /sys/block/mmcblk0/
# device/cid) that only exist on real hardware with a real eMMC attached -
# this suite tests it purely via its documented failure path (no such
# sysfs file exists on the host running these tests, so it always falls
# through to "unavailable", which is itself real, valid coverage of that
# path) and tests the derivation/fallback/orchestration logic against
# directly-supplied identifiers instead. Whether the real sysfs CID read
# succeeds and yields a plausible, actually-unique value on the real
# device remains hardware-only and is tracked as a required later test,
# not something this offline suite can prove.
#
# Usage: sh tests/nebulaos-stable-mac-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LIB="$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-stable-mac.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-stable-mac-tests.XXXXXX")
[ -n "${WORK:-}" ] && [ -e "$WORK" ] || { echo "FATAL: nebulaos-stable-mac-tests.sh: mktemp did not produce a usable path (fixture creation must fail closed - an empty path variable silently retargets later commands at the caller's own directory)" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

pass() {
	PASS=$((PASS + 1))
}

[ -f "$LIB" ] || { echo "FATAL: $LIB not found"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

# --- Test 1: derivation is deterministic for the same identifier. ---
mac_a=$(nebulaos_derive_mac_from_identifier "0011223344556677889900112233445566")
mac_b=$(nebulaos_derive_mac_from_identifier "0011223344556677889900112233445566")
if [ "$mac_a" = "$mac_b" ] && [ -n "$mac_a" ]; then
	pass
else
	fail "same identifier produced different MACs ($mac_a vs $mac_b)"
fi

# --- Test 2: different identifiers produce different MACs. ---
mac_c=$(nebulaos_derive_mac_from_identifier "ffeeddccbbaa99887766554433221100ff")
if [ "$mac_a" != "$mac_c" ]; then
	pass
else
	fail "different identifiers produced the same MAC ($mac_a)"
fi

# --- Test 3: a handful of varied identifiers never collide with each other. ---
collision=0
prev_macs=""
i=0
while [ "$i" -lt 20 ]; do
	ident=$(printf 'test-identifier-%d-%s' "$i" "$(printf '%040d' "$i")")
	m=$(nebulaos_derive_mac_from_identifier "$ident")
	case " $prev_macs " in
		*" $m "*) collision=1 ;;
	esac
	prev_macs="$prev_macs $m"
	i=$((i + 1))
done
if [ "$collision" -eq 0 ]; then
	pass
else
	fail "a collision occurred across 20 varied test identifiers"
fi

# --- Test 4: multicast bit is always clear across many derived MACs. ---
bad=0
for ident in "id-one" "id-two" "id-three" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "0"; do
	m=$(nebulaos_derive_mac_from_identifier "$ident")
	first_byte=${m%%:*}
	dec=$((0x$first_byte))
	if [ $((dec & 1)) -ne 0 ]; then
		bad=1
	fi
done
if [ "$bad" -eq 0 ]; then
	pass
else
	fail "multicast bit (bit 0) was set on at least one derived MAC's first byte"
fi

# --- Test 5: locally-administered bit is always set across many derived MACs. ---
bad=0
for ident in "id-one" "id-two" "id-three" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "0"; do
	m=$(nebulaos_derive_mac_from_identifier "$ident")
	first_byte=${m%%:*}
	dec=$((0x$first_byte))
	if [ $((dec & 2)) -ne 2 ]; then
		bad=1
	fi
done
if [ "$bad" -eq 0 ]; then
	pass
else
	fail "locally-administered bit (bit 1) was not set on at least one derived MAC's first byte"
fi

# --- Test 6: output format is always exactly 6 colon-separated hex octets. ---
bad=0
for ident in "id-one" "x" "0000000000000000" "ffffffffffffffffffffffffffffffff"; do
	m=$(nebulaos_derive_mac_from_identifier "$ident")
	echo "$m" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || bad=1
done
if [ "$bad" -eq 0 ]; then
	pass
else
	fail "at least one derived MAC did not match the expected AA:BB:CC:DD:EE:FF format"
fi

# --- Test 7: an empty identifier is rejected, not silently accepted. ---
if empty_mac=$(nebulaos_derive_mac_from_identifier ""); then
	fail "derivation succeeded for an empty identifier (got '$empty_mac')"
else
	pass
fi

# --- Test 8: hardware identifier read fails safely when no real eMMC CID
# sysfs path exists (true in this offline test environment - real
# coverage of the documented fallback trigger, not a skip). ---
if hw_id=$(nebulaos_read_hardware_identifier 2>/dev/null); then
	fail "nebulaos_read_hardware_identifier unexpectedly succeeded in a non-hardware test environment (got '$hw_id')"
else
	pass
fi

# --- Test 9: fallback identifier is generated once and persisted, then
# reused verbatim on a second call (never regenerated per-boot). ---
SEED_FILE="$WORK/wifi-mac-seed"
fb1=$(nebulaos_read_or_create_fallback_identifier "$SEED_FILE")
fb2=$(nebulaos_read_or_create_fallback_identifier "$SEED_FILE")
if [ -n "$fb1" ] && [ "$fb1" = "$fb2" ] && [ -f "$SEED_FILE" ]; then
	pass
else
	fail "fallback identifier was not stable across two calls (fb1='$fb1' fb2='$fb2')"
fi

# --- Test 10: two independent seed files produce different fallback
# identifiers (never a single hardcoded fallback shared across installs). ---
SEED_FILE_2="$WORK/wifi-mac-seed-2"
fb3=$(nebulaos_read_or_create_fallback_identifier "$SEED_FILE_2")
if [ -n "$fb3" ] && [ "$fb3" != "$fb1" ]; then
	pass
else
	fail "two independent seed files produced the same fallback identifier ('$fb1' vs '$fb3')"
fi

# --- Test 11: a corrupt/non-hex seed file is not trusted verbatim - a
# fresh, valid fallback is generated and persisted instead. ---
SEED_FILE_3="$WORK/wifi-mac-seed-corrupt"
printf 'not-valid-hex!!\n' > "$SEED_FILE_3"
fb4=$(nebulaos_read_or_create_fallback_identifier "$SEED_FILE_3")
case "$fb4" in
	''|*[!0-9a-fA-F]*) fail "corrupt seed file was not replaced with a valid hex fallback (got '$fb4')" ;;
	*) pass ;;
esac

# --- Test 12: full orchestration end-to-end via a fake `ip` on PATH -
# proves nebulaos_stabilize_iface_mac derives a MAC and attempts to apply
# it via `ip link set ... address ...`, without needing a real interface. ---
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >> "$FAKE_IP_LOG"
exit 0
EOF
chmod +x "$FAKE_BIN/ip"
FAKE_IP_LOG="$WORK/ip.log"
export FAKE_IP_LOG
: > "$FAKE_IP_LOG"
NEBULAOS_MAC_SEED_FILE="$WORK/wifi-mac-seed-e2e"
export NEBULAOS_MAC_SEED_FILE
if PATH="$FAKE_BIN:$PATH" nebulaos_stabilize_iface_mac testif >/dev/null 2>&1; then
	if grep -q "testif down" "$FAKE_IP_LOG" && grep -q "testif address" "$FAKE_IP_LOG" && grep -q "testif up" "$FAKE_IP_LOG"; then
		pass
	else
		fail "orchestration did not call ip link set down/address/up as expected: $(cat "$FAKE_IP_LOG")"
	fi
else
	fail "nebulaos_stabilize_iface_mac failed end-to-end with a working fake ip and a fresh seed file"
fi

# --- Test 13: the tracked source tree contains no unit-specific MAC or
# seed value baked in - only the mechanism. The real seed file path
# (/usr/data/nebulaos/wifi-mac-seed) lives on the persistent partition,
# never inside anything this build tracks in git. ---
if grep -rEq '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' "$SCRIPT_DIR/../scripts/build/overlay/etc/nebulaos-stable-mac.sh" "$SCRIPT_DIR/../scripts/build/overlay/etc/init.d/S01wifi"; then
	fail "found a literal MAC-address-shaped string committed in the production source"
else
	pass
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
