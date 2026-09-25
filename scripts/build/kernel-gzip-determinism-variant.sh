#!/bin/sh
# Makes the Ingenic zboot kernel payload byte-reproducible.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO TOUCH
#   kernel/kernel-6.6/arch/mips/boot/zcompressed/Makefile
# - same overlapping-variant-script discipline as the other *-variant.sh
# scripts under this directory.
#
# MEASURED CAUSE. arch/mips/boot/zcompressed/ is an Ingenic addition, not
# upstream, and its rule compresses the kernel payload with:
#
#     gzip -v9f $(obj)/vmlinux.bin
#
# with no -n. gzip invoked on a FILE stores that file's NAME and MTIME in the
# gzip header, so every build embedded a fresh wall-clock timestamp. Two builds
# of the same commit produced xImage headers differing at exactly those bytes:
#
#     1f 8b 08 08 <mtime> 02 03 v m l i n u x . b i n 00
#                 ^^^^^^^ flag 08 = FNAME set
#
#     build A mtime 0x6ab59f92   build B mtime 0x6ab5a258
#
# That single field was the entire xImage difference: 10 bytes differed in the
# file, of which 8 were the uImage header CRC and the image data CRC following
# it. Upstream's own generic rule (scripts/Makefile.lib cmd_gzip) already uses
# `-n`; this Ingenic-local rule simply does not.
#
# The fix adds -n, which suppresses both the stored name and the timestamp. It
# does not change the compressed data itself, only the header, and gzip -n is
# what every other kernel compression rule in this tree already does.
#
# Usage: kernel-gzip-determinism-variant.sh GZIPN1
set -eu

MARKER=${1:-}
[ "$MARKER" = "GZIPN1" ] || {
	echo "FATAL: usage: $(basename "$0") GZIPN1" >&2
	exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
TARGET="$KERNEL_DIR/kernel/kernel-6.6/arch/mips/boot/zcompressed/Makefile"

[ -f "$TARGET" ] || {
	echo "FATAL: $TARGET not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}

WANT='	gzip -nv9f $(obj)/vmlinux.bin'
HAVE='	gzip -v9f $(obj)/vmlinux.bin'

if grep -qxF "$WANT" "$TARGET"; then
	echo "== kernel-gzip-determinism ($MARKER): already applied =="
elif grep -qxF "$HAVE" "$TARGET"; then
	# Anchored to the exact line, and verified afterwards. A silent no-op here
	# would put a wall-clock timestamp back into every image, so it must fail
	# loudly rather than pass on a near-miss.
	sed -i "s|^	gzip -v9f \\\$(obj)/vmlinux\\.bin\$|	gzip -nv9f \$(obj)/vmlinux.bin|" "$TARGET"
	grep -qxF "$WANT" "$TARGET" || {
		echo "FATAL: kernel-gzip-determinism: substitution did not take effect in $TARGET" >&2
		exit 1
	}
	echo "== kernel-gzip-determinism ($MARKER): applied - kernel payload gzip now uses -n =="
else
	echo "FATAL: kernel-gzip-determinism: neither the expected original nor the patched" >&2
	echo "       line was found in $TARGET. The vendor rule changed; re-derive this" >&2
	echo "       variant rather than forcing it." >&2
	exit 1
fi

# The header must carry neither a stored name nor a timestamp. Assert the flag
# byte directly once the payload exists; before that there is nothing to check.
GZ="$KERNEL_DIR/kernel/kernel-6.6/arch/mips/boot/zcompressed/vmlinux.bin.gz"
if [ -f "$GZ" ]; then
	flag=$(od -A n -t u1 -j 3 -N 1 "$GZ" | tr -d ' ')
	if [ "$flag" = "0" ]; then
		echo "PASS: kernel payload gzip header carries no name and no timestamp"
	else
		echo "NOTE: existing $GZ predates this variant (flag byte $flag); it will be rebuilt"
	fi
fi
