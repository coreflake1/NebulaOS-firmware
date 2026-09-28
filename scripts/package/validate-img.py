#!/usr/bin/env python3
"""Validate a NebulaOS .img by taking it apart again.

A packaging command that exits 0 proves only that it did not crash. This reads
the finished artifact back the way a flasher would, and asserts that what came
out is what went in.

It checks, in order:

  1. the partition table parses as a GPT and passes the Ender-3 V3 KE layout
     validation (ten expected labels, matched A/B slot sizes, no overlap)
  2. the bytes occupying kernel2 are EXACTLY the canonical xImage
  3. the bytes occupying rootfs2 are EXACTLY the canonical rootfs.squashfs
  4. the OTA marker partition holds exactly one canonical ota:kernel2 block
  5. the stock slot really is empty, as the manifest claims - because "we left
     slot 1 alone" is a safety claim and safety claims get tested
  6. the embedded squashfs is a real, readable filesystem, proven by listing it
     with unsquashfs rather than by recognising four magic bytes
  7. the .img manifest agrees with all of the above

Comparison is by SHA-256 over the exact payload length at the partition's
offset, never over the whole partition: the partition is larger than the
payload and the remainder is padding. Hashing the padding too would be
comparing the wrong thing, and loosening the comparison to make it pass would
be worse.
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))

import nebulaos_gpt as gpt  # noqa: E402

MARKER_KERNEL2 = b"ota:kernel2"
CHUNK = 1024 * 1024

PASS, FAIL = [], []


def ok(msg):
    PASS.append(msg)
    print("PASS  %s" % msg)


def bad(msg, detail=""):
    FAIL.append(msg)
    print("FAIL  %s" % msg)
    if detail:
        print("       %s" % detail)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_region(path, offset, length):
    """Hash exactly `length` bytes at `offset` - the payload, not the padding."""
    digest = hashlib.sha256()
    remaining = length
    with open(path, "rb") as fh:
        fh.seek(offset)
        while remaining:
            data = fh.read(min(CHUNK, remaining))
            if not data:
                raise IOError("short read at offset %d" % offset)
            digest.update(data)
            remaining -= len(data)
    return digest.hexdigest()


def region_is_zero(path, offset, length, sample=None):
    """True if the region is entirely zero.

    `sample` caps how much is read, for the multi-hundred-megabyte stock rootfs
    region where reading all of it proves little more than reading a large
    prefix. When capped, the caller says so in its message rather than claiming
    the whole region was checked.
    """
    remaining = length if sample is None else min(sample, length)
    with open(path, "rb") as fh:
        fh.seek(offset)
        while remaining:
            data = fh.read(min(CHUNK, remaining))
            if not data:
                return False
            if data.strip(b"\x00"):
                return False
            remaining -= len(data)
    return True


def manifest_get(path, key):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return None


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a NebulaOS .img against its canonical core")
    parser.add_argument("--img", required=True)
    parser.add_argument("--ximage", required=True, help="canonical xImage to compare against")
    parser.add_argument("--rootfs", required=True, help="canonical rootfs.squashfs to compare against")
    parser.add_argument("--manifest", help="the .img's own manifest (defaults to <img>.manifest.txt)")
    parser.add_argument("--skip-extract", action="store_true",
                        help="skip the unsquashfs listing (for environments without squashfs-tools)")
    args = parser.parse_args(argv)

    img_manifest = args.manifest or (args.img + ".manifest.txt")

    canonical_x = sha256_file(args.ximage)
    canonical_r = sha256_file(args.rootfs)
    x_size = os.path.getsize(args.ximage)
    r_size = os.path.getsize(args.rootfs)

    print("=== .img validation: %s ===" % args.img)
    print("CANONICAL_XIMAGE_SHA256=%s" % canonical_x)
    print("CANONICAL_ROOTFS_SHA256=%s" % canonical_r)
    print()

    # --- 1. partition table ------------------------------------------------
    try:
        with open(args.img, "rb") as fh:
            table = gpt.parse(fh)
        ok("the image's partition table parses as a GPT")
    except (gpt.GPTError, OSError) as exc:
        bad("the image's partition table parses as a GPT", str(exc))
        return report()

    try:
        notes = table.validate_ke_layout()
        ok("the layout validates as an Ender-3 V3 KE layout (10 expected labels, matched slots)")
        for note in notes:
            print("       %s" % note)
    except gpt.GPTError as exc:
        bad("the layout validates as an Ender-3 V3 KE layout", str(exc))
        return report()

    parts = {p.label: p for p in table.partitions}

    # --- 2/3. payloads are byte-exact --------------------------------------
    k2 = parts["kernel2"]
    got = sha256_region(args.img, k2.offset, x_size)
    if got == canonical_x:
        ok("kernel2 holds the canonical xImage byte-for-byte (%d bytes at 0x%x)" % (x_size, k2.offset))
    else:
        bad("kernel2 holds the canonical xImage byte-for-byte", "embedded=%s canonical=%s" % (got, canonical_x))

    r2 = parts["rootfs2"]
    got = sha256_region(args.img, r2.offset, r_size)
    if got == canonical_r:
        ok("rootfs2 holds the canonical rootfs.squashfs byte-for-byte (%d bytes at 0x%x)" % (r_size, r2.offset))
    else:
        bad("rootfs2 holds the canonical rootfs.squashfs byte-for-byte", "embedded=%s canonical=%s" % (got, canonical_r))

    # The payload must FIT, and the remainder of the partition must be padding
    # rather than leftovers from something else.
    if x_size <= k2.size and r_size <= r2.size:
        ok("both payloads fit inside their partitions")
    else:
        bad("both payloads fit inside their partitions",
            "xImage %d/%d  rootfs %d/%d" % (x_size, k2.size, r_size, r2.size))

    if region_is_zero(args.img, k2.offset + x_size, k2.size - x_size):
        ok("kernel2 padding after the payload is zero")
    else:
        bad("kernel2 padding after the payload is zero")

    if region_is_zero(args.img, r2.offset + r_size, r2.size - r_size, sample=32 * CHUNK):
        ok("rootfs2 padding after the payload is zero (first 32 MiB sampled)")
    else:
        bad("rootfs2 padding after the payload is zero (first 32 MiB sampled)")

    # --- 4. the marker -----------------------------------------------------
    ota = parts["ota"]
    with open(args.img, "rb") as fh:
        fh.seek(ota.offset)
        block = fh.read(512)
    expected = bytearray(512)
    expected[: len(MARKER_KERNEL2)] = MARKER_KERNEL2
    if block == bytes(expected):
        ok("the OTA marker partition holds exactly one canonical ota:kernel2 block")
    else:
        bad("the OTA marker partition holds exactly one canonical ota:kernel2 block",
            "got %r" % block[:32])

    if region_is_zero(args.img, ota.offset + 512, ota.size - 512):
        ok("the rest of the OTA partition is zero (no stale second marker)")
    else:
        bad("the rest of the OTA partition is zero (no stale second marker)")

    # --- 5. the stock slot really is untouched -----------------------------
    # The manifest claims IMG_STOCK_SLOT_POPULATED=NO. That is a statement about
    # what a user loses by flashing this image, so it gets verified rather than
    # trusted.
    if region_is_zero(args.img, parts["kernel"].offset, parts["kernel"].size):
        ok("the stock kernel partition is empty, as the manifest states")
    else:
        bad("the stock kernel partition is empty, as the manifest states")

    if region_is_zero(args.img, parts["rootfs"].offset, parts["rootfs"].size, sample=32 * CHUNK):
        ok("the stock rootfs partition is empty, as the manifest states (first 32 MiB sampled)")
    else:
        bad("the stock rootfs partition is empty, as the manifest states (first 32 MiB sampled)")

    # --- 6. the embedded filesystem is real --------------------------------
    if args.skip_extract:
        print("SKIP  unsquashfs listing (--skip-extract)")
    elif not shutil.which("unsquashfs"):
        bad("the embedded rootfs is a readable squashfs (unsquashfs listing)",
            "unsquashfs is not installed; pass --skip-extract to acknowledge this gap explicitly")
    else:
        tmpdir = tempfile.mkdtemp(prefix="nebulaos-img-validate.", dir=os.environ.get("TMPDIR") or None)
        try:
            extracted = os.path.join(tmpdir, "rootfs.squashfs")
            with open(args.img, "rb") as src, open(extracted, "wb") as dst:
                src.seek(r2.offset)
                remaining = r_size
                while remaining:
                    data = src.read(min(CHUNK, remaining))
                    dst.write(data)
                    remaining -= len(data)

            proc = subprocess.run(
                ["unsquashfs", "-l", extracted],
                capture_output=True, text=True, timeout=300,
            )
            if proc.returncode != 0:
                bad("the embedded rootfs is a readable squashfs (unsquashfs listing)",
                    proc.stderr.strip()[:400])
            else:
                listing = proc.stdout
                entries = [l for l in listing.splitlines() if l.startswith("squashfs-root")]
                if len(entries) < 100:
                    bad("the embedded rootfs is a readable squashfs (unsquashfs listing)",
                        "only %d entries listed" % len(entries))
                else:
                    ok("the embedded rootfs is a readable squashfs (%d entries listed by unsquashfs)"
                       % len(entries))

                # Spot-check that it is a NebulaOS rootfs and not merely a valid
                # squashfs. These paths are structural to this product.
                wanted = ["squashfs-root/etc", "squashfs-root/usr", "squashfs-root/sbin"]
                missing = [w for w in wanted if w not in listing]
                if not missing:
                    ok("the embedded filesystem has the expected top-level structure")
                else:
                    bad("the embedded filesystem has the expected top-level structure",
                        "missing: %s" % ", ".join(missing))

                if "squashfs-root/etc/ota_marker.sh" in listing:
                    ok("the embedded filesystem carries NebulaOS's own OTA marker helper")
                else:
                    bad("the embedded filesystem carries NebulaOS's own OTA marker helper",
                        "/etc/ota_marker.sh absent - this may not be a NebulaOS rootfs")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    # --- 7. the manifest agrees -------------------------------------------
    if not os.path.exists(img_manifest):
        bad("the .img manifest exists", img_manifest)
    else:
        checks = [
            ("XIMAGE_SHA256", canonical_x),
            ("ROOTFS_SQUASHFS_SHA256", canonical_r),
            ("IMG_SHA256", sha256_file(args.img)),
            ("IMG_SIZE", str(os.path.getsize(args.img))),
        ]
        disagreements = [(k, v, manifest_get(img_manifest, k)) for k, v in checks
                         if manifest_get(img_manifest, k) != v]
        if not disagreements:
            ok("the .img manifest agrees with the artifact and the canonical core")
        else:
            bad("the .img manifest agrees with the artifact and the canonical core",
                "; ".join("%s: manifest=%s actual=%s" % (k, got, want) for k, want, got in disagreements))

        flashable = manifest_get(img_manifest, "IMG_FACTORY_FLASHABLE")
        verified = manifest_get(img_manifest, "EMMC_LAYOUT_GEOMETRY_VERIFIED")
        if flashable == verified:
            ok("IMG_FACTORY_FLASHABLE tracks EMMC_LAYOUT_GEOMETRY_VERIFIED (=%s)" % flashable)
        else:
            bad("IMG_FACTORY_FLASHABLE tracks EMMC_LAYOUT_GEOMETRY_VERIFIED",
                "flashable=%s verified=%s" % (flashable, verified))

        if flashable == "NO":
            print("       NOTE: this image is deliberately NOT declared factory-flashable.")
            print("       The partition table's absolute offsets have never been captured from")
            print("       real hardware. See tools/emmc/nebulaos_layout.py for the exact gap.")

        # The scope declaration is a safety property, so it is asserted rather
        # than assumed. If a future change ever drops these lines, or widens the
        # target beyond blank media without the preconditions being met, this
        # fails rather than quietly shipping an image that invites a write to a
        # provisioned printer.
        target = manifest_get(img_manifest, "IMG_TARGET")
        if target == "BLANK_MEDIA_ONLY":
            ok("the manifest declares IMG_TARGET=BLANK_MEDIA_ONLY")
        else:
            bad("the manifest declares IMG_TARGET=BLANK_MEDIA_ONLY", "got %r" % target)

        forbidden = manifest_get(img_manifest, "IMG_WRITE_TO_PROVISIONED_PRINTER")
        if forbidden == "FORBIDDEN":
            ok("the manifest forbids writing this image to a provisioned printer")
        else:
            bad("the manifest forbids writing this image to a provisioned printer",
                "got %r" % forbidden)

        destroyed = (manifest_get(img_manifest, "IMG_DESTROYS_PARTITIONS") or "").split(",")
        # sn_mac is the one that cannot be undone. It must be named explicitly.
        if "sn_mac" in destroyed:
            ok("the manifest names sn_mac among the partitions this image destroys")
        else:
            bad("the manifest names sn_mac among the partitions this image destroys",
                "IMG_DESTROYS_PARTITIONS=%r - the per-unit factory MAC/serial loss must be stated"
                % ",".join(destroyed))

        reasons = []
        with open(img_manifest, "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("IMG_NOT_FOR_PROVISIONED_PRINTER_BECAUSE="):
                    reasons.append(line.split("=", 1)[1].strip())
        if len(reasons) >= 3:
            ok("the manifest records all %d reasons this image is not a printer update path" % len(reasons))
            for reason in reasons:
                print("       - %s" % reason[:150])
        else:
            bad("the manifest records the reasons this image is not a printer update path",
                "found %d, expected at least 3 (geometry, sn_mac, stock fallback)" % len(reasons))

    return report()


def report():
    print()
    print("IMG_VALIDATION_PASS=%d" % len(PASS))
    print("IMG_VALIDATION_FAIL=%d" % len(FAIL))
    print("IMG_VALIDATED=%s" % ("YES" if not FAIL else "NO"))
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
