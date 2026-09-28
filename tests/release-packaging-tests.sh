#!/usr/bin/env bash
#
# Offline tests for the release packaging path.
#
# Two delivery formats, both built from an already-built canonical core and
# neither permitted to compile anything:
#
#   .img      the Creality F005 OTA package the STOCK updater consumes
#   .ingenic  the Ingenic Cloner recovery package, built by substituting into
#             the official vendor template
#
# Most of this runs on small synthetic payloads so it is cheap enough to run on
# every change, and it exercises the failure paths a real core cannot easily
# produce: a broken chunk chain, a tampered payload, a manifest that disagrees
# with its own bytes, an oversized image.
#
# The .ingenic cases need the official vendor package, which is 124 MB and is
# deliberately NOT committed here. Point NEBULAOS_INGENIC_TEMPLATE at a local
# copy to run them; without it those cases SKIP loudly rather than passing
# vacuously, because a silent skip is how a format stops being tested.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/.." && pwd)
PKG="$FW/scripts/package"
EMMC="$FW/tools/emmc"

PASS=0; FAIL=0; SKIP=0
ok(){   PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); printf 'FAIL  %s\n       %s\n' "$1" "${2:-}"; }
skip(){ SKIP=$((SKIP+1)); printf 'SKIP  %s\n       %s\n' "$1" "${2:-}"; }

command -v 7z >/dev/null 2>&1 || { echo "FATAL: 7z is required by these tests" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-packaging-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- synthetic canonical core ----------------------------------------------
# Small on purpose. The packagers care about sizes, digests and structure, not
# content, and a 100 MB rootfs would make this suite too slow to run habitually.
# Sized to span several 1 MiB chunks so the chain is genuinely exercised.
XIMAGE="$WORK/xImage"
ROOTFS="$WORK/rootfs.squashfs"
MANIFEST="$WORK/build-manifest.txt"
HEAD_SHA=fd4a365e9cc2b7dd478547bde00a272decee220e

head -c 2621440 /dev/urandom > "$XIMAGE"      # 2.5 MiB -> 3 chunks
head -c 5242880 /dev/urandom > "$ROOTFS"      # 5   MiB -> 5 chunks
X_SHA=$(sha256sum "$XIMAGE" | cut -d' ' -f1)
R_SHA=$(sha256sum "$ROOTFS"  | cut -d' ' -f1)
cat > "$MANIFEST" <<EOF
built_at=2026-09-28T00:00:00Z
git_commit_main=$HEAD_SHA
xImage_sha256=$X_SHA
xImage_size=$(stat -c %s "$XIMAGE")
rootfs_squashfs_sha256=$R_SHA
rootfs_squashfs_size=$(stat -c %s "$ROOTFS")
build_image_digest=sha256:a6ba57c69fa1ea630b037a1d1f55cf0c044a7f5a403bde9b155ea54bca1cceba
EOF

mkimg(){ python3 "$PKG/build-img.py" --ximage "$1" --rootfs "$2" --manifest "$3" --out "$4" \
           --source-head "${5:-$HEAD_SHA}" --source-date-epoch 1790442459 --ota-version "${6:-9.9.9.1}"; }

echo "=== release packaging: offline suite ==="
echo

# --- 1. eMMC layout facts ---------------------------------------------------
# The geometry now comes from the vendor Cloner profile, so it is checked
# against the two constants flash-spare-slot.sh derived independently. Two
# unrelated sources agreeing is what makes it verified rather than plausible.
out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
o = {f.name: f.value for f in L.PARTITION_OFFSETS}
print('kernel_size', o['kernel2'] - o['kernel'])
print('rootfs_size', o['rootfs2'] - o['rootfs'])
print('ota_off', hex(o['ota']))
print('sn_mac_off', hex(o['sn_mac']))
" 2>&1)
if printf '%s' "$out" | grep -q '^kernel_size 8388608$' \
&& printf '%s' "$out" | grep -q '^rootfs_size 524288000$'; then
  ok "vendor cloner offsets reproduce flash-spare-slot.sh's partition capacities exactly"
else
  bad "vendor cloner offsets reproduce flash-spare-slot.sh's partition capacities exactly" "$out"
fi

if printf '%s' "$out" | grep -q '^sn_mac_off 0x200000$'; then
  ok "sn_mac is recorded at its vendor offset 0x200000"
else
  bad "sn_mac is recorded at its vendor offset 0x200000" "$out"
fi

# The single most consequential safety property in the whole packaging path.
out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
print('vendor', L.erase_list_preserves_sn_mac(L.VENDOR_ERASE_LIST))
print('fullwipe', L.erase_list_preserves_sn_mac('0x0,0xffffffff;'))
print('straddle', L.erase_list_preserves_sn_mac('0x0,0x1fffff;0x250000,0xffffffff;'))
print('garbage', L.erase_list_preserves_sn_mac('not,a,range;'))
" 2>&1)
if printf '%s' "$out" | grep -q '^vendor True$' \
&& printf '%s' "$out" | grep -q '^fullwipe False$' \
&& printf '%s' "$out" | grep -q '^straddle False$' \
&& printf '%s' "$out" | grep -q '^garbage False$'; then
  ok "the sn_mac preservation check accepts the vendor erase list and rejects wipes, straddles and garbage"
else
  bad "the sn_mac preservation check behaves correctly" "$out"
fi

# --- 2. .img: the Creality F005 OTA package --------------------------------
IMG="$WORK/test.img"
if mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$IMG" >/dev/null 2>&1; then
  ok ".img packaging succeeds against a synthetic canonical core"
else
  bad ".img packaging succeeds against a synthetic canonical core" "$(mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$IMG" 2>&1 | tail -3 | tr '\n' ' ')"
fi

if python3 "$PKG/validate-img.py" --img "$IMG" --ximage "$XIMAGE" --rootfs "$ROOTFS" >/dev/null 2>&1; then
  ok ".img validation passes, including the reassemble-and-compare gate"
else
  bad ".img validation passes, including the reassemble-and-compare gate" \
      "$(python3 "$PKG/validate-img.py" --img "$IMG" --ximage "$XIMAGE" --rootfs "$ROOTFS" 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
fi

# The envelope secret is derived, not pasted. If the derivation ever changes the
# stock updater cannot open the package, so this is asserted directly.
out=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('m', '$PKG/build-img.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.derive_archive_secret())" 2>&1)
if [ "$out" = '$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0' ]; then
  ok "the OTA envelope secret derives to the known-good MD5-crypt value"
else
  bad "the OTA envelope secret derives to the known-good MD5-crypt value" "got $out"
fi

# The archive must NOT be readable without the derived secret, or it is not the
# vendor envelope at all.
if ! 7z t -p"wrong-secret" "$IMG" >/dev/null 2>&1; then
  ok ".img does not open with a wrong secret (header encryption is on)"
else
  bad ".img does not open with a wrong secret (header encryption is on)"
fi

# The chunk chain is the part that is easy to get plausibly wrong. Break exactly
# one link and require the validator to notice.
BROKEN="$WORK/broken-chain"
mkdir -p "$BROKEN"
7z x -y -p'$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0' -o"$BROKEN" "$IMG" >/dev/null 2>&1
PDIR=$(find "$BROKEN" -type d -name 'ota_v*' | head -1)
SECOND=$(ls "$PDIR" | grep -E '^xImage\.0001\.' | head -1)
if [ -n "$SECOND" ]; then
  mv "$PDIR/$SECOND" "$PDIR/xImage.0001.$(printf 'wrong' | md5sum | cut -d' ' -f1)"
  REPACK="$WORK/broken.img"
  ( cd "$BROKEN" && 7z a -t7z -mhe=on -p'$1$cxswfile$ZFd0RWFYkJQugbtKVGL9y0' "$REPACK" . >/dev/null 2>&1 )
  if ! python3 "$PKG/validate-img.py" --img "$REPACK" --ximage "$XIMAGE" --rootfs "$ROOTFS" >/dev/null 2>&1; then
    ok ".img validation catches a broken link in the chunk chain"
  else
    bad ".img validation catches a broken link in the chunk chain"
  fi
else
  bad ".img validation catches a broken link in the chunk chain" "could not locate chunk 0001"
fi

# A tampered payload must fail the reassemble-and-compare gate even though every
# structural check still passes.
if ! python3 "$PKG/validate-img.py" --img "$IMG" --ximage "$ROOTFS" --rootfs "$XIMAGE" >/dev/null 2>&1; then
  ok ".img validation rejects a package validated against the wrong canonical core"
else
  bad ".img validation rejects a package validated against the wrong canonical core"
fi

# Packaging a core whose manifest disagrees with its bytes must refuse.
BADMAN="$WORK/bad-manifest.txt"
sed "s/^xImage_sha256=.*/xImage_sha256=$(printf 'evil' | sha256sum | cut -d' ' -f1)/" "$MANIFEST" > "$BADMAN"
if ! mkimg "$XIMAGE" "$ROOTFS" "$BADMAN" "$WORK/nope.img" >/dev/null 2>&1; then
  ok ".img packaging refuses a core that disagrees with its own build manifest"
else
  bad ".img packaging refuses a core that disagrees with its own build manifest"
fi

if ! mkimg "$XIMAGE" "$ROOTFS" "$MANIFEST" "$WORK/nope2.img" 0000000000000000000000000000000000000000 >/dev/null 2>&1; then
  ok ".img packaging refuses a source head the build manifest does not name"
else
  bad ".img packaging refuses a source head the build manifest does not name"
fi

# An oversized payload must refuse rather than produce a package the updater
# would accept and then fail to write.
BIGX="$WORK/big-xImage"
head -c $((8388608 + 4096)) /dev/urandom > "$BIGX"
BIGMAN="$WORK/big-manifest.txt"
sed -e "s/^xImage_sha256=.*/xImage_sha256=$(sha256sum "$BIGX" | cut -d' ' -f1)/" \
    -e "s/^xImage_size=.*/xImage_size=$(stat -c %s "$BIGX")/" "$MANIFEST" > "$BIGMAN"
if ! mkimg "$BIGX" "$ROOTFS" "$BIGMAN" "$WORK/nope3.img" >/dev/null 2>&1; then
  ok ".img packaging refuses an xImage larger than the kernel partition"
else
  bad ".img packaging refuses an xImage larger than the kernel partition"
fi

# The manifest must state where this installs, because the answer is surprising:
# applied while NebulaOS is booted, it overwrites the STOCK slot.
if grep -q 'INACTIVE' "$IMG.manifest.txt" && grep -q 'overwrites the STOCK slot' "$IMG.manifest.txt"; then
  ok ".img manifest states that it writes the inactive slot, which may be stock"
else
  bad ".img manifest states that it writes the inactive slot, which may be stock"
fi

if grep -q '^QUALIFIED_INPUT_ARTIFACTS_MODIFIED=NO$' "$IMG.manifest.txt"; then
  ok ".img manifest records that the qualified inputs were not modified"
else
  bad ".img manifest records that the qualified inputs were not modified"
fi

# The canonical inputs must be untouched by packaging.
if [ "$(sha256sum "$XIMAGE" | cut -d' ' -f1)" = "$X_SHA" ] \
&& [ "$(sha256sum "$ROOTFS" | cut -d' ' -f1)" = "$R_SHA" ]; then
  ok "packaging left the canonical xImage and rootfs byte-identical"
else
  bad "packaging left the canonical xImage and rootfs byte-identical"
fi

# --- 3. .ingenic: the Ingenic Cloner recovery package -----------------------
TEMPLATE=${NEBULAOS_INGENIC_TEMPLATE:-}
if [ -z "$TEMPLATE" ] || [ ! -f "$TEMPLATE" ]; then
  skip ".ingenic packaging and validation" \
       "set NEBULAOS_INGENIC_TEMPLATE to the official Ender-3_V3_KE_1.1.0.12.ingenic (124 MB, not committed)"
else
  ING="$WORK/test.ingenic"
  if python3 "$PKG/build-ingenic.py" --template "$TEMPLATE" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --manifest "$MANIFEST" --out "$ING" --source-head "$HEAD_SHA" \
       --source-date-epoch 1790442459 >/dev/null 2>&1; then
    ok ".ingenic packaging succeeds against the vendor template"
  else
    bad ".ingenic packaging succeeds against the vendor template"
  fi

  if python3 "$PKG/validate-ingenic.py" --package "$ING" --template "$TEMPLATE" \
       --ximage "$XIMAGE" --rootfs "$ROOTFS" >/dev/null 2>&1; then
    ok ".ingenic validation passes (payload round-trip + vendor entries unchanged)"
  else
    bad ".ingenic validation passes (payload round-trip + vendor entries unchanged)" \
        "$(python3 "$PKG/validate-ingenic.py" --package "$ING" --template "$TEMPLATE" --ximage "$XIMAGE" --rootfs "$ROOTFS" 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
  fi

  ING2="$WORK/test2.ingenic"
  python3 "$PKG/build-ingenic.py" --template "$TEMPLATE" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
    --manifest "$MANIFEST" --out "$ING2" --source-head "$HEAD_SHA" \
    --source-date-epoch 1790442459 >/dev/null 2>&1
  if cmp -s "$ING" "$ING2"; then
    ok ".ingenic packaging is deterministic (two runs are byte-identical)"
  else
    bad ".ingenic packaging is deterministic (two runs are byte-identical)"
  fi

  # An unpinned template must be refused for a release.
  FAKE="$WORK/fake-template.ingenic"
  cp "$TEMPLATE" "$FAKE"
  printf 'x' >> "$FAKE"
  if ! python3 "$PKG/build-ingenic.py" --template "$FAKE" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
         --manifest "$MANIFEST" --out "$WORK/nope.ingenic" --source-head "$HEAD_SHA" \
         --source-date-epoch 1790442459 >/dev/null 2>&1; then
    ok ".ingenic packaging refuses a template that is not the pinned vendor package"
  else
    bad ".ingenic packaging refuses a template that is not the pinned vendor package"
  fi

  # sn_mac preservation must be asserted in the built artifact, not just intended.
  if grep -q '^INGENIC_SN_MAC_PRESERVED=YES$' "$ING.manifest.txt"; then
    ok ".ingenic manifest records that sn_mac is preserved"
  else
    bad ".ingenic manifest records that sn_mac is preserved"
  fi

  if grep -q '^KEEP_STOCK_SPL_UBOOT_GPT=YES$' "$ING.manifest.txt"; then
    ok ".ingenic manifest records that vendor SPL/U-Boot/GPT is kept"
  else
    bad ".ingenic manifest records that vendor SPL/U-Boot/GPT is kept"
  fi

  # --- both formats carry the SAME canonical core -------------------------
  IMG_X=$(grep '^XIMAGE_SHA256=' "$IMG.manifest.txt" | cut -d= -f2)
  ING_X=$(grep '^XIMAGE_SHA256=' "$ING.manifest.txt" | cut -d= -f2)
  IMG_R=$(grep '^ROOTFS_SQUASHFS_SHA256=' "$IMG.manifest.txt" | cut -d= -f2)
  ING_R=$(grep '^ROOTFS_SQUASHFS_SHA256=' "$ING.manifest.txt" | cut -d= -f2)
  if [ "$IMG_X" = "$X_SHA" ] && [ "$ING_X" = "$X_SHA" ] \
  && [ "$IMG_R" = "$R_SHA" ] && [ "$ING_R" = "$R_SHA" ]; then
    ok "both formats record the identical canonical xImage and rootfs hashes"
  else
    bad "both formats record the identical canonical xImage and rootfs hashes" \
        "img=$IMG_X/$IMG_R ingenic=$ING_X/$ING_R canonical=$X_SHA/$R_SHA"
  fi
fi

echo
printf 'RELEASE_PACKAGING_TESTS_PASS=%d\nRELEASE_PACKAGING_TESTS_FAIL=%d\nRELEASE_PACKAGING_TESTS_SKIP=%d\n' \
  "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
