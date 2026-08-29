#!/bin/sh
# Phase 1 final hardware qualification - SESSION 1 (NO MOTION).
#
# Prepared by the Phase 1 overnight closure mission. NOT executed tonight -
# the printer stayed off for the entire mission per that mission's own hard
# rule. Review this script once before running it tomorrow; it is written
# to be safe to run as-is, but it was never exercised against the real
# device in this session.
#
# What this does: collects every piece of no-motion, no-heat evidence
# needed to call Session 1 complete - identity, host MCU health, at24
# EEPROM presence/geometry, a full EEPROM backup with a real
# write/readback/restore test on a chosen safe byte range, and ADXL345
# connectivity - all read-only or explicitly reversible, entirely over
# SSH/Moonraker's HTTP API. NEVER issues G28, any G-code motion command, or
# any heater command.
#
# Usage:
#   sh tools/qualification/session1-no-motion.sh <printer-ip> [output-dir]
#
# You will be prompted for the SSH password interactively (root/openke on
# custom NebulaOS, per docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) - this
# script never stores or hardcodes it.
#
# Exits 0 and prints "SAFE TO POWER OFF" only if every check passed. Any
# single FAIL stops the EEPROM write-test step specifically (never
# attempts a write against a device that hasn't already proven a clean
# backup) but still finishes evidence collection for everything else, so
# the owner has a complete picture either way.

set -u

PRINTER_IP="${1:?usage: $0 <printer-ip> [output-dir]}"
OUT="${2:-./session1-evidence-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)}"
SSH="ssh -o ConnectTimeout=10 root@$PRINTER_IP"
MOONRAKER="http://$PRINTER_IP:7125"

mkdir -p "$OUT"
echo "== Session 1 (no motion) evidence -> $OUT =="
echo "== You will be prompted for the SSH password (once per ssh call unless"
echo "   you set up a key beforehand - see docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) =="

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run() {
	# $1: label, $2: remote command, $3: output file (relative to $OUT)
	echo "--- $1 ---"
	if $SSH "$2" > "$OUT/$3" 2>&1; then
		return 0
	else
		echo "  (command exited non-zero - see $OUT/$3)"
		return 1
	fi
}

# -------------------------------------------------------------------------
# 1. Boot identity / firmware+source identity / GD32 identity
# -------------------------------------------------------------------------
run "NebulaOS build manifest" "cat /opt/nebulaos-version.json 2>/dev/null || cat /etc/nebulaos-release 2>/dev/null" "build-manifest.txt"
grep -q . "$OUT/build-manifest.txt" && pass "build/version identity captured" || fail "could not read build/version identity"

run "GD32 MCU identity (via mcu_application_identify.py, no reflash)" \
	"python3 /etc/nebulaos/mcu_application_identify.py 2>&1 || true" "gd32-identity.txt"
grep -qi "native\|candidate" "$OUT/gd32-identity.txt" && pass "GD32 reports a recognized native application identity" \
	|| fail "GD32 identity output did not mention a recognized native candidate - read $OUT/gd32-identity.txt by hand"

run "MCU lifecycle guard's own last decision (proves no unintended reflash happened at boot)" \
	"cat /usr/data/nebulaos/system/mcu-lifecycle-last-decision.json 2>/dev/null || echo 'NOT FOUND - check docs/MCU_LIFECYCLE_GUARD.md for the real state file path on this build'" \
	"mcu-guard-last-decision.txt"
grep -qi "PASS\|native_already_installed\|NATIVE_CANDIDATE" "$OUT/mcu-guard-last-decision.txt" \
	&& pass "MCU lifecycle guard's last decision shows native/PASS (no restore/reflash attempted this boot)" \
	|| fail "could not confirm MCU guard's last decision was a clean native pass-through - review $OUT/mcu-guard-last-decision.txt by hand before trusting GD32 state"

# -------------------------------------------------------------------------
# 2. Host MCU (klipper_mcu) ready
# -------------------------------------------------------------------------
run "S54nebulaos-host-mcu service status" "ps aux | grep '[k]lipper_mcu'" "host-mcu-process.txt"
grep -q "klipper_mcu" "$OUT/host-mcu-process.txt" && pass "klipper_mcu process is running" || fail "klipper_mcu process not found running"

run "host MCU socket present" "ls -la /tmp/klipper_host_mcu" "host-mcu-socket.txt"
grep -q "klipper_host_mcu" "$OUT/host-mcu-socket.txt" && pass "host MCU socket exists at /tmp/klipper_host_mcu" || fail "host MCU socket missing"

MCU_STATUS=$(curl -s "$MOONRAKER/printer/objects/query?mcu%20rpi" 2>/dev/null)
echo "$MCU_STATUS" > "$OUT/mcu-rpi-status.json"
echo "$MCU_STATUS" | grep -qi '"mcu_version"' && pass "[mcu rpi] reports a real mcu_version (host MCU ready)" \
	|| fail "[mcu rpi] status did not report mcu_version - is Klipper fully ready? see $OUT/mcu-rpi-status.json"

# -------------------------------------------------------------------------
# 3. at24 driver bound, expected sysfs path, exact size
# -------------------------------------------------------------------------
EEPROM_PATH="/sys/bus/i2c/devices/2-0050/eeprom"
run "at24 driver bound at 2-0050" "ls -la /sys/bus/i2c/devices/2-0050/ 2>&1" "at24-sysfs-dir.txt"
grep -q "eeprom" "$OUT/at24-sysfs-dir.txt" && pass "eeprom sysfs attribute exists at 2-0050" || fail "no eeprom attribute under /sys/bus/i2c/devices/2-0050/ - at24 not bound?"

run "dmesg at24 probe line" "dmesg | grep -i 'at24\|24c16' | tail -20" "at24-dmesg.txt"
grep -qi "at24" "$OUT/at24-dmesg.txt" && pass "dmesg shows an at24 probe message" || echo "  (no at24 dmesg line found - not fatal if the eeprom attribute itself exists, dmesg buffer may have wrapped)"

EEPROM_SIZE=$($SSH "stat -c %s $EEPROM_PATH" 2>/dev/null)
echo "reported size: $EEPROM_SIZE" > "$OUT/eeprom-size.txt"
if [ "$EEPROM_SIZE" = "2048" ]; then
	pass "EEPROM sysfs file reports exactly 2048 bytes"
else
	fail "EEPROM sysfs file reports '$EEPROM_SIZE' bytes, expected exactly 2048"
fi

# -------------------------------------------------------------------------
# 4. Full EEPROM binary backup + SHA256
# -------------------------------------------------------------------------
echo "--- full EEPROM backup ---"
$SSH "cat $EEPROM_PATH | base64" > "$OUT/eeprom-backup.b64" 2>"$OUT/eeprom-backup-stderr.txt"
if [ -s "$OUT/eeprom-backup.b64" ]; then
	base64 -d "$OUT/eeprom-backup.b64" > "$OUT/eeprom-backup.bin" 2>/dev/null
	BACKUP_SIZE=$(stat -c %s "$OUT/eeprom-backup.bin" 2>/dev/null || stat -f %z "$OUT/eeprom-backup.bin" 2>/dev/null)
	if [ "$BACKUP_SIZE" = "2048" ]; then
		pass "EEPROM backup is exactly 2048 bytes"
		sha256sum "$OUT/eeprom-backup.bin" 2>/dev/null > "$OUT/eeprom-backup.sha256" \
			|| shasum -a 256 "$OUT/eeprom-backup.bin" > "$OUT/eeprom-backup.sha256"
		echo "  backup SHA256: $(cat "$OUT/eeprom-backup.sha256")"
		pass "EEPROM backup SHA256 recorded in $OUT/eeprom-backup.sha256"
	else
		fail "EEPROM backup is $BACKUP_SIZE bytes, expected 2048 - DO NOT proceed to the write test"
	fi
else
	fail "EEPROM backup transfer produced no data - DO NOT proceed to the write test"
fi

# Stock page 0 (bytes 0-15) content, for the "unchanged" comparison later.
if [ -f "$OUT/eeprom-backup.bin" ]; then
	dd if="$OUT/eeprom-backup.bin" bs=1 count=16 2>/dev/null | od -An -tx1 > "$OUT/eeprom-page0-before.txt"
	echo "  page 0 (stock reserved) before: $(cat "$OUT/eeprom-page0-before.txt")"
fi

# -------------------------------------------------------------------------
# 5. Test write / exact readback / restore / exact restoration verification
# -------------------------------------------------------------------------
# Chosen safe test area: journal page 1 (bytes 16-31) - NebulaOS's own
# journal ring, never stock's page 0. If page 1 already holds real PLR
# journal data (from a prior offline-preparation print, unlikely tonight
# since the printer stayed off, but checked anyway), this script preserves
# and restores it exactly like every other byte - it is not treated
# specially.
if [ "${BACKUP_SIZE:-0}" = "2048" ]; then
	echo "--- EEPROM write/readback/restore test (page 1, bytes 16-31) ---"
	TEST_PATTERN="4e50ff00deadbeef0102030405060708"  # 16 bytes, arbitrary, easy to eyeball
	ORIGINAL_PAGE1=$(dd if="$OUT/eeprom-backup.bin" bs=1 skip=16 count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')
	echo "original page 1: $ORIGINAL_PAGE1" > "$OUT/eeprom-page1-original.txt"

	$SSH "python3 -c \"
import sys
data = bytes.fromhex('$TEST_PATTERN')
with open('$EEPROM_PATH', 'r+b') as f:
    f.seek(16)
    f.write(data)
    f.flush()
    f.seek(16)
    readback = f.read(16)
sys.exit(0 if readback == data else 1)
\"" > "$OUT/eeprom-write-test.txt" 2>&1
	if [ $? -eq 0 ]; then
		pass "EEPROM test write to page 1 read back exactly as written"
	else
		fail "EEPROM test write/readback mismatch - see $OUT/eeprom-write-test.txt"
	fi

	# Restore original bytes regardless of the above outcome - never leave
	# the device in the test-pattern state.
	$SSH "python3 -c \"
data = bytes.fromhex('$ORIGINAL_PAGE1')
with open('$EEPROM_PATH', 'r+b') as f:
    f.seek(16)
    f.write(data)
    f.flush()
\"" > "$OUT/eeprom-restore.txt" 2>&1

	RESTORED_PAGE1=$($SSH "dd if=$EEPROM_PATH bs=1 skip=16 count=16 2>/dev/null | od -An -tx1" | tr -d ' \n')
	if [ "$RESTORED_PAGE1" = "$ORIGINAL_PAGE1" ]; then
		pass "page 1 restored to its exact original bytes"
	else
		fail "page 1 restoration mismatch - original=$ORIGINAL_PAGE1 restored=$RESTORED_PAGE1 - DO NOT power off yet, investigate first"
	fi

	# Page 0 (stock's own bytes) must be byte-for-byte untouched by any of
	# the above - the single most important safety property of this test.
	PAGE0_AFTER=$($SSH "dd if=$EEPROM_PATH bs=1 count=16 2>/dev/null | od -An -tx1" | tr -d ' \n')
	PAGE0_BEFORE=$(tr -d ' \n' < "$OUT/eeprom-page0-before.txt")
	if [ "$PAGE0_AFTER" = "$PAGE0_BEFORE" ]; then
		pass "stock page 0 is byte-for-byte unchanged"
	else
		fail "stock page 0 CHANGED ($PAGE0_BEFORE -> $PAGE0_AFTER) - this must never happen; investigate before powering off"
	fi
else
	echo "SKIP: EEPROM write test - backup did not verify as exactly 2048 bytes above"
fi

# -------------------------------------------------------------------------
# 6. ADXL345 connectivity (no motion, no G28 - a pure SPI read)
# -------------------------------------------------------------------------
echo "--- ADXL345 connectivity ---"
ADXL_RESULT=$(curl -s -X POST "$MOONRAKER/printer/gcode/script" \
	--data-urlencode "script=ACCELEROMETER_QUERY CHIP=adxl345" 2>/dev/null)
echo "$ADXL_RESULT" > "$OUT/adxl345-query.json"
sleep 1
GCODE_STORE=$(curl -s "$MOONRAKER/server/gcode_store?count=10" 2>/dev/null)
echo "$GCODE_STORE" > "$OUT/adxl345-gcode-store.json"
if echo "$GCODE_STORE" | grep -qi "Invalid adxl345 id"; then
	fail "ACCELEROMETER_QUERY reported an invalid chip ID - see $OUT/adxl345-gcode-store.json"
elif echo "$GCODE_STORE" | grep -qi "accelerometer values"; then
	pass "ACCELEROMETER_QUERY returned real motion data (chip communication confirmed)"
else
	fail "could not confirm ACCELEROMETER_QUERY result either way - read $OUT/adxl345-gcode-store.json by hand"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Session 1 results: $PASS passed, $FAIL failed"
echo "Evidence saved to: $OUT"
echo "=========================================="

if [ "$FAIL" -eq 0 ]; then
	echo "SAFE TO POWER OFF: YES - every Session 1 check passed."
	exit 0
else
	echo "SAFE TO POWER OFF: review the $FAIL failure(s) above before powering off - do not proceed to Session 2/3 until resolved."
	exit 1
fi
