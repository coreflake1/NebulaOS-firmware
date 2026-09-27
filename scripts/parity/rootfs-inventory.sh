#!/bin/sh
# Inventory a NebulaOS rootfs.squashfs into a stable, diff-friendly form.
# Usage: rootfs-inventory.sh <rootfs.squashfs> <outdir>
# Produces one file per inventory dimension, each sorted, so that OLD vs NEW
# is a plain `diff`. Absent is written as an explicit empty file, never skipped.
set -eu
IMG=${1:?rootfs.squashfs}
OUT=${2:?outdir}
mkdir -p "$OUT"
ROOT="$OUT/.root"
rm -rf "$ROOT"
unsquashfs -no-progress -d "$ROOT" "$IMG" >"$OUT/unsquashfs.log" 2>&1

cd "$ROOT"
# 1. every path, with type and mode - the master list
find . -mindepth 1 -printf '%y %m %10s %p -> %l\n' 2>/dev/null \
  | sed 's/ -> $//' | LC_ALL=C sort > "$OUT/files.txt"
# size-independent path list (churn-resistant comparisons)
find . -mindepth 1 -printf '%y %p\n' | LC_ALL=C sort > "$OUT/paths.txt"
# 2. ELF binaries and their architecture
find . -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null \
  | xargs -0 -r file -N 2>/dev/null | grep ELF \
  | sed 's/^\.\///' | LC_ALL=C sort > "$OUT/elf.txt" || : 
awk -F': ' '{print $2}' "$OUT/elf.txt" | sed 's/, BuildID.*//' | LC_ALL=C sort | uniq -c \
  | sort -rn > "$OUT/elf-arch-summary.txt"
# 3. shared libraries
find . -name '*.so' -o -name '*.so.*' | sed 's|^\./||' | LC_ALL=C sort > "$OUT/libraries.txt"
# 4. firmware
find lib/firmware -type f 2>/dev/null | LC_ALL=C sort > "$OUT/firmware.txt" || : > "$OUT/firmware.txt"
# 5. kernel modules
find . -name '*.ko' | sed 's|^\./||' | LC_ALL=C sort > "$OUT/kernel-modules.txt"
# 6. init scripts / services
find etc/init.d -type f 2>/dev/null | LC_ALL=C sort > "$OUT/init-scripts.txt" || : > "$OUT/init-scripts.txt"
# 7. configuration
find etc -type f 2>/dev/null | LC_ALL=C sort > "$OUT/etc-files.txt" || : > "$OUT/etc-files.txt"
# 8. Python: interpreter version dirs, stdlib presence, site-packages, native ext suffixes
find . -maxdepth 4 -type d -name 'python3.*' | sed 's|^\./||' | LC_ALL=C sort > "$OUT/python-versions.txt"
find . -path '*/site-packages/*' -maxdepth 7 -mindepth 1 -printf '%p\n' 2>/dev/null \
  | sed 's|^\./||' | LC_ALL=C sort > "$OUT/python-site-packages.txt"
find . -name '*.cpython-*.so' | sed 's|^\./||' | LC_ALL=C sort > "$OUT/python-native-ext.txt"
find . -name '*.cpython-*.so' | sed 's/.*\(cpython-[0-9a-z_-]*\)\.so/\1/' | LC_ALL=C sort -u > "$OUT/python-abi-tags.txt"
# 9. application payloads
for d in opt/klipper opt/moonraker opt/nebulaos usr/share/mainsail opt/guppyscreen; do
  n=$(echo "$d" | tr '/' '-')
  if [ -d "$d" ]; then find "$d" -type f | LC_ALL=C sort > "$OUT/app-$n.txt"; else : > "$OUT/app-$n.txt"; fi
done
# 10. counts summary
{
  printf 'INVENTORY_OF=%s\n' "$IMG"
  printf 'IMAGE_SHA256=%s\n' "$(sha256sum "$IMG" | awk '{print $1}')"
  printf 'IMAGE_SIZE=%s\n' "$(stat -c %s "$IMG")"
  for f in files paths elf libraries firmware kernel-modules init-scripts etc-files \
           python-versions python-site-packages python-native-ext; do
    printf '%s=%s\n' "$(echo "$f" | tr 'a-z-' 'A-Z_')_COUNT" "$(wc -l < "$OUT/$f.txt")"
  done
  printf 'PYTHON_ABI_TAGS=%s\n' "$(tr '\n' ',' < "$OUT/python-abi-tags.txt" | sed 's/,$//')"
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
