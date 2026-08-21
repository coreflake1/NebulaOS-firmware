# Shared by S00revert-safety and S99confirm-good (FIRMWARE.md sec 21/23) -
# writes the ota partition marker in the exact byte format both Creality's
# own stock ota_utils.sh (mmc_write_str: `echo $str > $dev`) and
# ballaswag/ingenic-usbboot's swap_ota_partition() (writes "ota:kernel\n\n"
# into a zeroed 512-byte buffer) use. Verified byte-for-byte via a local
# regular-file simulation before ever being trusted on real hardware -
# tested output was an exact match for the live device's own raw partition
# dump: "6f 74 61 3a 6b 65 72 6e 65 6c 0a 0a 00 00 ...".
#
# A bare `echo -n "ota:kernel"` (10 bytes, no trailing newline) would NOT
# match usbboot's own read-check (`strncmp(ota, "ota:kernel\n", 11)`) and
# would fall into its "unexpected value" branch unless --force-swap-ota is
# used - this exists specifically to avoid that mismatch.

write_ota_marker() {
	# $1: "ota:kernel" or "ota:kernel2"
	# This write is what the entire A/B automatic-rollback safety net
	# depends on, so it must hit physical storage - not just the page
	# cache - before this function returns. `dd conv=fsync` is a
	# durability mechanism already confirmed working in this exact
	# BusyBox build by ndq_atomic_write() in
	# nebulaos-display-qualified.sh, which uses it for a lower-stakes
	# config write. That's a different dd feature from the block-padding
	# `conv=sync` flag this function historically avoided (support for
	# THAT one was never confirmed) - fsync-on-write and pad-to-blocksize
	# are unrelated dd behaviors despite the similar flag names. Length
	# computed via ${#1} (shell parameter expansion), not command
	# substitution - $(...) strips trailing newlines, which would
	# silently defeat the padding math.
	printf '%s\n\n' "$1" | dd of=/dev/mmcblk0p1 conv=fsync 2>/dev/null
	marker_len=$((${#1} + 2))
	remaining=$((512 - marker_len))
	if [ "$remaining" -gt 0 ]; then
		dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek="$marker_len" count="$remaining" conv=fsync 2>/dev/null
	fi
	# Trailing global sync as belt-and-suspenders, matching the same
	# pattern ndq_atomic_write() uses after its own durable write.
	sync
}
