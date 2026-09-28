#!/usr/bin/env python3
"""Package the canonical NebulaOS core into a full-disk .img, deterministically.

THIS IS PACKAGING, NOT BUILDING

It consumes an already-built canonical core - xImage, rootfs.squashfs and the
build manifest that binds them - and rearranges those exact bytes into a disk
image. It compiles nothing. If the xImage inside the .img is not byte-identical
to the xImage the build produced, that is a bug in this script, and the
validator exists to catch it.

WHAT THIS IMAGE IS FOR - READ THIS BEFORE WRITING IT ANYWHERE

This is a BLANK-MEDIA PROVISIONING IMAGE. It is for bringing up NebulaOS on
storage that carries no factory data: a replacement eMMC, a bench/development
board, or an emulated device.

It is NOT an update path for a printer you own, and writing it to one is
destructive in three distinct ways, two of which no amount of care on our side
can fix:

  1. it zeroes p2/sn_mac, which holds the PER-UNIT factory MAC and serial
     (confirmed on real hardware:
      26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1, the address stock's
      wlan0 actually uses). That value is programmed per unit, exists nowhere
      else, and cannot be regenerated. Destroying it is permanent.

  2. it leaves the stock slot (p5/p7) empty, removing the fallback that
     docs/DEVELOPER_RECOVERY.md designates as the way back. We do not have
     Creality's stock kernel and rootfs and could not redistribute them, so this
     image cannot restore what it removes.

  3. it replaces rootfs_data and userdata - printer.cfg, calibration, macros,
     uploads, Wi-Fi credentials - and its partition table's absolute offsets have
     never been captured from a real KE, so they may not even land where the
     factory put them.

To install or update NebulaOS on a printer that already works, use the narrow
two-partition path instead: scripts/flash-spare-slot.sh, driven by the Hardware
Agent. That writes kernel2 and rootfs2 and touches nothing else.

The manifest states this scope in machine-readable form
(IMG_TARGET=BLANK_MEDIA_ONLY, IMG_WRITE_TO_PROVISIONED_PRINTER=FORBIDDEN) and
lists all three reasons, so a tool consuming the manifest can refuse rather than
relying on someone having read this comment.

GEOMETRY PROVENANCE

The partition table is authored from tools/emmc/nebulaos_layout.py, which records
per fact whether a value came from real hardware or is a declaration with no
evidence behind it. Absolute start offsets have never been captured from a KE, so
they are declared. The manifest carries every unverified fact by name. That is
also why IMG_FACTORY_FLASHABLE stays NO: even on blank media this image's
geometry is our best reconstruction, not a reproduction of the factory layout.

DETERMINISM

Two runs over the same canonical core must produce byte-identical output:

  * every GUID is derived by uuid5 from a seed, never generated randomly
  * the seed is the source commit, so it is a property of the release
  * unused space is zero, not uninitialised
  * no timestamp, hostname, path or build counter reaches the image
  * the manifest inside the image records SOURCE_DATE_EPOCH rather than now()

The packaging reproducibility check re-runs this and compares SHA-256.
"""

import argparse
import hashlib
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))

import nebulaos_gpt as gpt          # noqa: E402
import nebulaos_layout as layout    # noqa: E402

MARKER_KERNEL2 = b"ota:kernel2"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_get(path, key):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return None


def canonical_marker_block():
    """The exact 512 bytes the OTA marker partition should hold for slot 2.

    One canonical representation, NUL-padded. The marker primitive that runs on
    the device uses the same rule, so an image built here and a marker written
    there are indistinguishable.
    """
    block = bytearray(512)
    block[: len(MARKER_KERNEL2)] = MARKER_KERNEL2
    return bytes(block)


def build(args):
    ximage_sha = sha256_file(args.ximage)
    rootfs_sha = sha256_file(args.rootfs)
    manifest_sha = sha256_file(args.manifest)

    # The canonical core must agree with its own manifest before it is packaged.
    # Packaging a set whose manifest disagrees with its bytes would bind the
    # .img to a release generation that never existed.
    man_x = manifest_get(args.manifest, "xImage_sha256")
    man_r = manifest_get(args.manifest, "rootfs_squashfs_sha256")
    man_c = manifest_get(args.manifest, "git_commit_main")
    if man_x != ximage_sha:
        sys.exit("FATAL: xImage sha256 %s does not match build manifest %s" % (ximage_sha, man_x))
    if man_r != rootfs_sha:
        sys.exit("FATAL: rootfs.squashfs sha256 %s does not match build manifest %s" % (rootfs_sha, man_r))
    if args.source_head and man_c != args.source_head:
        sys.exit("FATAL: build manifest records git_commit_main=%s, not %s" % (man_c, args.source_head))

    source_head = args.source_head or man_c
    if not source_head:
        sys.exit("FATAL: no source head given and the build manifest records none")

    ximage = open(args.ximage, "rb").read()
    rootfs = open(args.rootfs, "rb").read()

    plan = layout.ke_partition_plan()
    sizes = dict(plan)
    if len(ximage) > sizes["kernel2"]:
        sys.exit("FATAL: xImage is %d bytes, exceeds the kernel2 partition (%d)"
                 % (len(ximage), sizes["kernel2"]))
    if len(rootfs) > sizes["rootfs2"]:
        sys.exit("FATAL: rootfs.squashfs is %d bytes, exceeds the rootfs2 partition (%d)"
                 % (len(rootfs), sizes["rootfs2"]))

    disk_bytes = sum(size for _, size in plan) + 64 * 1024 * 1024  # headroom for table + alignment
    if disk_bytes % layout.SECTOR:
        disk_bytes += layout.SECTOR - (disk_bytes % layout.SECTOR)

    # The seed is the source commit: same release, same GUIDs, every time.
    placed, geometry = layout.plan_partitions(plan, disk_bytes)
    placed_by_label = {p["label"]: p for p in placed}

    # Written SPARSELY. The logical image is ~7.5 GB and all but ~110 MB of it
    # is zero; ftruncate creates the extent and the filesystem stores the holes,
    # so the artifact costs its payload on disk while still being a complete,
    # dd-able disk image. Building it as one in-memory buffer instead would cost
    # 7.5 GB of RAM per packaging run, and the reproducibility check runs two.
    writes = list(layout.gpt_blocks(placed, geometry, seed=source_head, alternate="valid"))
    for label, payload in (("kernel2", ximage), ("rootfs2", rootfs),
                           ("ota", canonical_marker_block())):
        writes.append((placed_by_label[label]["offset"], payload))

    with open(args.out, "wb") as fh:
        fh.truncate(disk_bytes)
        for offset, payload in writes:
            fh.seek(offset)
            fh.write(payload)
        fh.flush()
        os.fsync(fh.fileno())

    img_sha = sha256_file(args.out)
    img_size = os.path.getsize(args.out)

    verified = layout.geometry_is_verified()
    unverified = layout.unverified_facts()
    refusals = layout.require_whole_disk_preconditions()

    lines = [
        "# NebulaOS .img packaging manifest",
        "# Generated by scripts/package/build-img.py from an already-built canonical core.",
        "# Nothing here was compiled by this step.",
        "IMG_FORMAT_VERSION=1",
        "SOURCE_HEAD=%s" % source_head,
        "SOURCE_DATE_EPOCH=%s" % args.source_date_epoch,
        "XIMAGE_SHA256=%s" % ximage_sha,
        "XIMAGE_SIZE=%d" % len(ximage),
        "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
        "ROOTFS_SQUASHFS_SIZE=%d" % len(rootfs),
        "BUILD_MANIFEST_SHA256=%s" % manifest_sha,
        "IMG_SHA256=%s" % img_sha,
        "IMG_SIZE=%d" % img_size,
        "IMG_NEBULAOS_SLOT=2",
        "IMG_OTA_MARKER=ota:kernel2",
        "IMG_STOCK_SLOT_POPULATED=NO",
        "IMG_FACTORY_FLASHABLE=%s" % ("YES" if verified else "NO"),
        "EMMC_LAYOUT_GEOMETRY_VERIFIED=%s" % ("YES" if verified else "NO"),
        # The scope declaration. Machine-readable on purpose: a consumer can
        # refuse on these two lines without having to parse the prose below.
        "IMG_TARGET=BLANK_MEDIA_ONLY",
        "IMG_WRITE_TO_PROVISIONED_PRINTER=FORBIDDEN",
        "IMG_UPDATE_PATH_FOR_A_WORKING_PRINTER=scripts/flash-spare-slot.sh",
        "IMG_DESTROYS_PARTITIONS=%s" % ",".join(sorted(
            layout.IRREPLACEABLE_LABELS | layout.UNOBTAINABLE_LABELS | layout.USER_DATA_LABELS)),
    ]
    for reason in refusals:
        lines.append("IMG_NOT_FOR_PROVISIONED_PRINTER_BECAUSE=%s" % reason)
    for part in placed:
        lines.append("IMG_PART=label=%s offset=0x%x size=%d" % (part["label"], part["offset"], part["size"]))
    if not verified:
        lines.append("# Refusing to declare this image factory-flashable. Every fact below is a")
        lines.append("# value with no hardware evidence behind it; writing a partition table built")
        lines.append("# on them would relocate rootfs_data/userdata and destroy user data.")
        for fact in unverified:
            lines.append("IMG_UNVERIFIED_LAYOUT_FACT=%s value=%r reason=%s"
                         % (fact.name, fact.value, fact.source))
    lines.append("# SCOPE: blank media only - a replacement eMMC, a bench board, or an")
    lines.append("# emulated device. Writing this to a printer that already carries factory")
    lines.append("# data permanently destroys the per-unit sn_mac identity, removes the stock")
    lines.append("# recovery slot, and replaces the user's persistent partitions. To update a")
    lines.append("# working printer use scripts/flash-spare-slot.sh, which writes kernel2 and")
    lines.append("# rootfs2 and nothing else.")

    with open(args.out + ".manifest.txt", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(args.out + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  %s\n" % (img_sha, os.path.basename(args.out)))

    print("IMG_BUILT=%s" % args.out)
    print("IMG_SHA256=%s" % img_sha)
    print("IMG_SIZE=%d" % img_size)
    print("IMG_FACTORY_FLASHABLE=%s" % ("YES" if verified else "NO"))
    print("IMG_TARGET=BLANK_MEDIA_ONLY")
    print("IMG_WRITE_TO_PROVISIONED_PRINTER=FORBIDDEN")
    for reason in refusals:
        print("  reason: %s" % reason)
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Package the canonical core into a NebulaOS .img")
    parser.add_argument("--ximage", required=True)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True, help="build-manifest.txt from the canonical build")
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-head")
    parser.add_argument("--source-date-epoch", required=True)
    return build(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
