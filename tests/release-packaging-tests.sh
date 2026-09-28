#!/usr/bin/env bash
#
# Offline tests for the release packaging path: the GPT parser/builder, the
# .img packager and its validator, and the .ingenic packager and its validator.
#
# Runs entirely on small synthetic payloads. It never needs a real build, so it
# is cheap enough to run on every change, and it exercises the failure paths
# that a real canonical core cannot easily produce - a corrupt GPT, a truncated
# package, a tampered payload, a forbidden burn target.
#
# The positive path against the REAL canonical core is a separate, heavier
# check driven by scripts/build/07-package-release.sh; this suite is about the
# logic, not about any particular release.
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/.." && pwd)
PKG="$FW/scripts/package"
EMMC="$FW/tools/emmc"

PASS=0; FAIL=0
ok(){   PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); printf 'FAIL  %s\n       %s\n' "$1" "${2:-}"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/nebulaos-packaging-tests.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- synthetic canonical core ----------------------------------------------
# Deliberately small. The packagers care about sizes and hashes, not content,
# and a 100 MB rootfs would make this suite too slow to run habitually.
XIMAGE="$WORK/xImage"
ROOTFS="$WORK/rootfs.squashfs"
MANIFEST="$WORK/build-manifest.txt"
HEAD_SHA=fd4a365e9cc2b7dd478547bde00a272decee220e

head -c 65536  /dev/urandom > "$XIMAGE"
head -c 262144 /dev/urandom > "$ROOTFS"
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

echo "=== release packaging: offline suite ==="
echo

# --- 1. GPT parse/build round trip -----------------------------------------
gpt_case(){
  local name=$1 alternate=$2 expect=$3
  local out
  out=$(cd "$EMMC" && python3 - "$alternate" <<'PY' 2>&1
import io, sys
import nebulaos_layout as L, nebulaos_gpt as G
img, placed = L.build_gpt(L.ke_partition_plan(), 8*1024*1024*1024, "seed", alternate=sys.argv[1])
g = G.parse(io.BytesIO(bytes(img)))
g.validate_ke_layout()
print("OK parts=%d alt_ok=%s" % (len(g.partitions), g.alternate_ok))
PY
)
  if printf '%s' "$out" | grep -q "$expect"; then
    ok "$name"
  else
    bad "$name" "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}

gpt_case "a built GPT with a valid backup parses and validates"    valid   "OK parts=10 alt_ok=True"
# The real KE ships a BROKEN backup GPT. Treating that as fatal would refuse
# every real device, so it must parse and report, not refuse.
gpt_case "a GPT with an invalid backup still parses (the real KE condition)" invalid "OK parts=10 alt_ok=False"
gpt_case "a GPT with an absent backup still parses"                absent  "OK parts=10 alt_ok=False"

# Corruption of the PRIMARY table must be fatal, unlike the backup.
for corrupt in signature header_crc entries_crc overlap; do
  out=$(cd "$EMMC" && python3 - "$corrupt" <<'PY' 2>&1
import io, struct, sys
import nebulaos_layout as L, nebulaos_gpt as G
mode = sys.argv[1]
if mode == "overlap":
    plan = L.ke_partition_plan()
    img, placed = L.build_gpt(plan, 8*1024*1024*1024, "seed")
    img = bytearray(img)
    # Drag entry 2's first LBA back into entry 1, then repair both CRCs so the
    # ONLY remaining defect is the overlap itself. Without the repair this would
    # be caught as a CRC error and the overlap check would never be exercised.
    base = 2*512 + 128
    first = struct.unpack_from("<Q", img, base+32)[0]
    struct.pack_into("<Q", img, base+32, first - 64)
    import binascii
    array = bytes(img[2*512:2*512+128*128])
    crc = binascii.crc32(array) & 0xffffffff
    struct.pack_into("<I", img, 512+88, crc)
    hdr = bytearray(img[512:512+92]); hdr[16:20] = b"\x00\x00\x00\x00"
    struct.pack_into("<I", img, 512+16, binascii.crc32(bytes(hdr)) & 0xffffffff)
else:
    img, placed = L.build_gpt(L.ke_partition_plan(), 8*1024*1024*1024, "seed")
    img = bytearray(img)
    if mode == "signature":
        img[512:520] = b"NOTAGPT!"
    elif mode == "header_crc":
        struct.pack_into("<I", img, 512+16, 0xdeadbeef)
    elif mode == "entries_crc":
        img[2*512] ^= 0xff
try:
    G.parse(io.BytesIO(bytes(img)))
    print("ACCEPTED")
except G.GPTError as e:
    print("REFUSED: %s" % str(e).splitlines()[0])
PY
)
  if printf '%s' "$out" | grep -q '^REFUSED'; then
    ok "a corrupt primary GPT ($corrupt) is refused"
  else
    bad "a corrupt primary GPT ($corrupt) is refused" "$out"
  fi
done

# A table whose labels are not this product's must be refused outright.
out=$(cd "$EMMC" && python3 - <<'PY' 2>&1
import io
import nebulaos_layout as L, nebulaos_gpt as G
plan = [("boot", 8*1024*1024), ("system", 512*1024*1024)]
img, _ = L.build_gpt(plan, 2*1024*1024*1024, "seed")
g = G.parse(io.BytesIO(bytes(img)))
try:
    g.validate_ke_layout(); print("ACCEPTED")
except G.GPTError as e:
    print("REFUSED: %s" % str(e).splitlines()[0])
PY
)
if printf '%s' "$out" | grep -q 'REFUSED'; then
  ok "a GPT from a different product is refused by the KE layout validation"
else
  bad "a GPT from a different product is refused by the KE layout validation" "$out"
fi

# A slot partition of the wrong size means the payload does not belong here.
out=$(cd "$EMMC" && python3 - <<'PY' 2>&1
import io
import nebulaos_layout as L, nebulaos_gpt as G
plan = [(lbl, (sz//2 if lbl == "kernel2" else sz)) for lbl, sz in L.ke_partition_plan()]
img, _ = L.build_gpt(plan, 8*1024*1024*1024, "seed")
g = G.parse(io.BytesIO(bytes(img)))
try:
    g.validate_ke_layout(); print("ACCEPTED")
except G.GPTError as e:
    print("REFUSED: %s" % str(e).splitlines()[0])
PY
)
if printf '%s' "$out" | grep -q 'REFUSED.*kernel2'; then
  ok "a wrongly-sized kernel2 partition is refused"
else
  bad "a wrongly-sized kernel2 partition is refused" "$out"
fi

# --- 2. layout provenance is honest ----------------------------------------
out=$(cd "$EMMC" && python3 -c "import nebulaos_layout as L; print(L.provenance_report())" 2>&1)
if printf '%s' "$out" | grep -q '^EMMC_LAYOUT_GEOMETRY_VERIFIED=NO'; then
  ok "layout geometry reports itself unverified (no GPT dump has ever been captured)"
else
  bad "layout geometry reports itself unverified" "$out"
fi

out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
rs = L.require_whole_disk_preconditions()
print(len(rs))
print('\n'.join(rs))" 2>&1)
if [ "$(printf '%s' "$out" | head -1)" -ge 3 ] 2>/dev/null \
   && printf '%s' "$out" | grep -q 'sn_mac' \
   && printf '%s' "$out" | grep -q 'stock slot'; then
  ok "whole-disk preconditions name sn_mac and the stock fallback, not just geometry"
else
  bad "whole-disk preconditions name sn_mac and the stock fallback, not just geometry" "$out"
fi

# sn_mac's recorded size is the real 1024 bytes, not a guess.
out=$(cd "$EMMC" && python3 -c "
import nebulaos_layout as L
d = {f.name: (f.value, f.provenance) for f in L.PARTITION_SIZES}
print(d['sn_mac'])" 2>&1)
if printf '%s' "$out" | grep -q "1024, 'VERIFIED_FROM_HARDWARE'"; then
  ok "sn_mac's size is recorded as verified-from-hardware (1024 bytes)"
else
  bad "sn_mac's size is recorded as verified-from-hardware (1024 bytes)" "$out"
fi

# --- 3. .img packaging ------------------------------------------------------
IMG="$WORK/test.img"
if python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
     --out "$IMG" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1; then
  ok ".img packaging succeeds against a synthetic canonical core"
else
  bad ".img packaging succeeds against a synthetic canonical core"
fi

if python3 "$PKG/validate-img.py" --img "$IMG" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
     --skip-extract >/dev/null 2>&1; then
  ok ".img validation passes on a freshly packaged image"
else
  bad ".img validation passes on a freshly packaged image" \
      "$(python3 "$PKG/validate-img.py" --img "$IMG" --ximage "$XIMAGE" --rootfs "$ROOTFS" --skip-extract 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
fi

# Determinism: the same core packaged twice must be byte-identical, or the
# reproducibility claim in the release manifest is unfounded.
IMG2="$WORK/test2.img"
python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
  --out "$IMG2" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1
if cmp -s "$IMG" "$IMG2"; then
  ok ".img packaging is deterministic (two runs are byte-identical)"
else
  bad ".img packaging is deterministic (two runs are byte-identical)"
fi

# The scope declarations are safety properties and must be present.
for key in "IMG_TARGET=BLANK_MEDIA_ONLY" "IMG_WRITE_TO_PROVISIONED_PRINTER=FORBIDDEN"; do
  if grep -q "^$key\$" "$IMG.manifest.txt"; then
    ok ".img manifest declares $key"
  else
    bad ".img manifest declares $key"
  fi
done
if grep -q '^IMG_DESTROYS_PARTITIONS=.*sn_mac' "$IMG.manifest.txt"; then
  ok ".img manifest names sn_mac among the partitions it destroys"
else
  bad ".img manifest names sn_mac among the partitions it destroys"
fi

# A tampered payload must be caught by the validator, not slip through.
TAMPER="$WORK/tampered.img"
cp --reflink=auto "$IMG" "$TAMPER" 2>/dev/null || cp "$IMG" "$TAMPER"
K2_OFF=$(grep -o 'IMG_PART=label=kernel2 offset=0x[0-9a-f]*' "$IMG.manifest.txt" | sed 's/.*offset=0x//')
printf '\xff\xff\xff\xff' | dd of="$TAMPER" bs=1 seek=$((0x$K2_OFF)) conv=notrunc status=none
if ! python3 "$PKG/validate-img.py" --img "$TAMPER" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --skip-extract >/dev/null 2>&1; then
  ok ".img validation catches a tampered kernel2 payload"
else
  bad ".img validation catches a tampered kernel2 payload"
fi

# Packaging a core whose manifest disagrees with its bytes must refuse.
BADMAN="$WORK/bad-manifest.txt"
sed "s/^xImage_sha256=.*/xImage_sha256=$(printf 'evil' | sha256sum | cut -d' ' -f1)/" "$MANIFEST" > "$BADMAN"
if ! python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$BADMAN" \
       --out "$WORK/nope.img" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1; then
  ok ".img packaging refuses a core that disagrees with its own build manifest"
else
  bad ".img packaging refuses a core that disagrees with its own build manifest"
fi

# Packaging for the wrong source head must refuse.
if ! python3 "$PKG/build-img.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
       --out "$WORK/nope2.img" --source-head 0000000000000000000000000000000000000000 \
       --source-date-epoch 1790442459 >/dev/null 2>&1; then
  ok ".img packaging refuses a source head the build manifest does not name"
else
  bad ".img packaging refuses a source head the build manifest does not name"
fi

# An oversized payload must refuse rather than truncate into the next partition.
BIGX="$WORK/big-xImage"
head -c $((8388608 + 4096)) /dev/urandom > "$BIGX"
BIGMAN="$WORK/big-manifest.txt"
sed -e "s/^xImage_sha256=.*/xImage_sha256=$(sha256sum "$BIGX" | cut -d' ' -f1)/" \
    -e "s/^xImage_size=.*/xImage_size=$(stat -c %s "$BIGX")/" "$MANIFEST" > "$BIGMAN"
if ! python3 "$PKG/build-img.py" --ximage "$BIGX" --rootfs "$ROOTFS" --manifest "$BIGMAN" \
       --out "$WORK/nope3.img" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1; then
  ok ".img packaging refuses an xImage larger than the kernel2 partition"
else
  bad ".img packaging refuses an xImage larger than the kernel2 partition"
fi

# --- 4. .ingenic packaging --------------------------------------------------
ING="$WORK/test.ingenic"
if python3 "$PKG/build-ingenic.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
     --out "$ING" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1; then
  ok ".ingenic packaging succeeds against a synthetic canonical core"
else
  bad ".ingenic packaging succeeds against a synthetic canonical core"
fi

if python3 "$PKG/validate-ingenic.py" --package "$ING" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
     --skip-extract >/dev/null 2>&1; then
  ok ".ingenic validation passes on a freshly packaged container"
else
  bad ".ingenic validation passes on a freshly packaged container" \
      "$(python3 "$PKG/validate-ingenic.py" --package "$ING" --ximage "$XIMAGE" --rootfs "$ROOTFS" --skip-extract 2>&1 | grep '^FAIL' | head -3 | tr '\n' ' ')"
fi

ING2="$WORK/test2.ingenic"
python3 "$PKG/build-ingenic.py" --ximage "$XIMAGE" --rootfs "$ROOTFS" --manifest "$MANIFEST" \
  --out "$ING2" --source-head "$HEAD_SHA" --source-date-epoch 1790442459 >/dev/null 2>&1
if cmp -s "$ING" "$ING2"; then
  ok ".ingenic packaging is deterministic (two runs are byte-identical)"
else
  bad ".ingenic packaging is deterministic (two runs are byte-identical)"
fi

# The magic exists so a foreign tool rejects the file instead of misreading it.
if [ "$(head -c 17 "$ING")" = "NEBULAOS-RECOVERY" ]; then
  ok ".ingenic begins with the NEBULAOS-RECOVERY magic at offset 0"
else
  bad ".ingenic begins with the NEBULAOS-RECOVERY magic at offset 0"
fi

# The compatibility claim must never drift to YES without a reference artifact.
DRIFT="$WORK/drift.ingenic"
cp "$ING" "$DRIFT"
python3 - "$DRIFT" <<'PY'
import sys
p = sys.argv[1]
with open(p, "r+b") as fh:
    head = fh.read(4096)
    head = head.replace(b"CREALITY_CLONER_COMPATIBLE=UNVERIFIED",
                        b"CREALITY_CLONER_COMPATIBLE=YES\x00\x00\x00\x00\x00\x00\x00")
    fh.seek(0); fh.write(head[:4096])
PY
cp "$ING.manifest.txt" "$DRIFT.manifest.txt"
if ! python3 "$PKG/validate-ingenic.py" --package "$DRIFT" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --skip-extract 2>&1 | grep -q 'INGENIC_VALIDATED=YES'; then
  ok ".ingenic validation fails if the Creality compatibility claim drifts to YES"
else
  bad ".ingenic validation fails if the Creality compatibility claim drifts to YES"
fi

# A tampered member payload must be caught by its declared hash.
TING="$WORK/tampered.ingenic"
cp "$ING" "$TING"
ING_OFF=$(grep -o 'INGENIC_MEMBER=name=xImage offset=[0-9]*' "$ING.manifest.txt" | sed 's/.*offset=//')
printf '\xff\xff\xff\xff' | dd of="$TING" bs=1 seek="$ING_OFF" conv=notrunc status=none
cp "$ING.manifest.txt" "$TING.manifest.txt"
if ! python3 "$PKG/validate-ingenic.py" --package "$TING" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --skip-extract >/dev/null 2>&1; then
  ok ".ingenic validation catches a tampered member payload"
else
  bad ".ingenic validation catches a tampered member payload"
fi

# A truncated package must be caught, not partially accepted.
TRUNC="$WORK/truncated.ingenic"
head -c $(( $(stat -c %s "$ING") / 2 )) "$ING" > "$TRUNC"
cp "$ING.manifest.txt" "$TRUNC.manifest.txt"
if ! python3 "$PKG/validate-ingenic.py" --package "$TRUNC" --ximage "$XIMAGE" --rootfs "$ROOTFS" \
       --skip-extract >/dev/null 2>&1; then
  ok ".ingenic validation catches a truncated package"
else
  bad ".ingenic validation catches a truncated package"
fi

# The burn map must never name a partition this project refuses to write.
if python3 - "$ING" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
forbidden = [b"target_partlabel=kernel ", b"target_partlabel=rootfs ",
             b"target_partlabel=rootfs_data", b"target_partlabel=userdata",
             b"target_partlabel=sn_mac"]
sys.exit(1 if any(f in data for f in forbidden) else 0)
PY
then
  ok ".ingenic never declares a burn target on the stock slot, sn_mac or user data"
else
  bad ".ingenic never declares a burn target on the stock slot, sn_mac or user data"
fi

# --- 5. both formats carry the SAME canonical core -------------------------
# The headline property of the whole release architecture: one build, packaged
# three ways. If the two packagers could disagree about what they embedded,
# nothing downstream could bind them to one source generation.
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

echo
printf 'RELEASE_PACKAGING_TESTS_PASS=%d\nRELEASE_PACKAGING_TESTS_FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
