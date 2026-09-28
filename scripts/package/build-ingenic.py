#!/usr/bin/env python3
"""Package the canonical NebulaOS core into a .ingenic recovery package.

READ THE COMPATIBILITY SECTION BEFORE USING THIS FOR ANYTHING

WHAT WAS INVESTIGATED

The mission that produced this file required the .ingenic format to be verified
mechanically rather than assumed. It was investigated and it could not be:

  * Creality's own recovery tooling for this printer is
    "cloner-2.5.18-windows_alpha.zip" in CrealityOfficial/Ender-3_V3_KE_Annex,
    under "firmware recovery tool". It is a closed Windows binary. The same
    directory holds two PDF walkthroughs and nothing else.
  * that repository contains NO sample .ingenic package, no format
    documentation, and no packer or unpacker.
  * no public specification of the container was found.

So there is no reference artifact to parse, no spec to implement against, and
no device on which to test the result. Implementing "the Creality format" from a
one-line description of what it probably contains, and then shipping an artifact
that claims to be one, would be inventing a compatibility claim. This file does
not do that.

WHAT THIS ACTUALLY PRODUCES

A fully specified, self-describing NebulaOS recovery container. Everything about
it is defined here, parseable by scripts/package/validate-ingenic.py, and
verified against the canonical core it was built from.

It deliberately begins with a distinctive magic string:

    NEBULAOS-RECOVERY

That choice is a safety measure, not branding. The file is named .ingenic
because that is the extension the recovery workflow uses, and a user could
reasonably try to feed it to Creality's cloner. A tool that does not recognise
this magic will reject the file outright instead of interpreting the first few
kilobytes as some other header and beginning a partial flash of a printer. Fail
fast beats fail halfway, and a half-flashed printer is the exact outcome the
whole project is arranged to avoid.

    CREALITY_CLONER_COMPATIBLE=UNVERIFIED

is written into the header and the manifest, because that is the true state of
knowledge. It is not "NO" - nobody has tested it and found it incompatible -
and it is emphatically not "YES".

THIS IS NOT A HARDWARE AGENT TRANSPORT

.ingenic is end-user and factory recovery media. It is whole-device packaging
with none of the narrow safety semantics the Hardware Agent has: no slot-2-only
ownership, no live-target collision refusal, no armed/disarm state machine, no
way-out proof. The burn map below says plainly which partitions it describes
writing. Do not wire this into an autonomous agent path merely because the
package now exists.

CONTAINER FORMAT v1

    [0 .. 17)        the literal ASCII bytes "NEBULAOS-RECOVERY", then "\n"
    [18 .. 4096)     header, UTF-8 KEY=VALUE lines, NUL-padded
    [4096 .. )       members, each starting on a 4096-byte boundary,
                     zero-padded to the next boundary

Every member is declared in the header with its name, offset, size, SHA-256 and
burn target. The header is fixed-size so that a reader can parse it with one
read of a known length before trusting any offset in it.

DETERMINISM

No timestamp, path, hostname, UID or counter enters the container. Members are
emitted in a fixed declared order, padding is zero, and the only time-like value
is SOURCE_DATE_EPOCH, which is a property of the source commit. Two runs over
the same canonical core produce byte-identical output, and the release pipeline
checks exactly that.
"""

import argparse
import hashlib
import os
import sys
import time

MAGIC = "NEBULAOS-RECOVERY"
FORMAT_VERSION = "1"
HEADER_BYTES = 4096
ALIGN = 4096
MARKER_KERNEL2 = b"ota:kernel2"


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


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


def normalise_build_manifest(raw, source_date_epoch):
    """Return the build manifest with its one nondeterministic line pinned.

    build-manifest.txt records `built_at=<wall clock>`. Everything else in it -
    every component commit, every artifact hash, the builder digest - is a
    property of the source generation and is identical across independent builds
    of the same commit. `built_at` is not: two byte-identical builds of the same
    commit differ in that single line, and embedding it raw made this container
    differ too, purely because of when the compiler happened to run.

    That is packaging nondeterminism imported from an input, and the fix belongs
    here rather than in a looser comparison later. The line is rewritten to the
    build's own SOURCE_DATE_EPOCH, which is derived from the commit and is
    therefore the same for every build of it.

    Nothing else is touched, the transformation is announced in the container
    header (BUILD_MANIFEST_NORMALISED=built_at), and the sidecar manifest records
    the ORIGINAL file's sha256 so the specific build run is still traceable.

    See docs/DEFERRED_POST_RELEASE_WORK.md item 3: build-manifest.txt not
    recording source_date_epoch is a known gap. When that is fixed upstream this
    normalisation becomes a no-op rather than wrong.
    """
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(source_date_epoch)))
    out, replaced = [], False
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if line.startswith("built_at="):
            out.append("built_at=%s" % stamp)
            replaced = True
        else:
            out.append(line)
    if not replaced:
        # Nothing to pin - either the key is gone (the upstream fix landed) or
        # this is not a build manifest. Either way, pass it through untouched
        # rather than inventing a line.
        return raw, False
    return ("\n".join(out) + "\n").encode("utf-8"), True


def canonical_marker_block():
    block = bytearray(512)
    block[: len(MARKER_KERNEL2)] = MARKER_KERNEL2
    return bytes(block)


def align_up(value):
    return value if value % ALIGN == 0 else value + (ALIGN - value % ALIGN)


def build(args):
    ximage_sha = sha256_file(args.ximage)
    rootfs_sha = sha256_file(args.rootfs)

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
    build_manifest_raw = open(args.manifest, "rb").read()
    build_manifest, normalised = normalise_build_manifest(
        build_manifest_raw, args.source_date_epoch
    )

    # The burn map is a MEMBER, not merely a comment: it travels with the
    # package, so anything that unpacks it later learns what the package was
    # meant to write without needing this script.
    burn_map = "\n".join([
        "# NebulaOS recovery package burn map",
        "#",
        "# Which partition each payload member describes writing. This is a",
        "# DESCRIPTION carried inside the package, not an instruction any",
        "# NebulaOS tool executes - nothing in this project flashes a printer",
        "# from a .ingenic package.",
        "#",
        "# A recovery flash driven by this map replaces slot 2 and the OTA",
        "# marker. It does NOT describe writing the stock slot (kernel, rootfs),",
        "# and it does NOT describe writing rootfs_data or userdata, so a tool",
        "# that follows it exactly leaves stock and the user's data intact.",
        "BURN_MAP_VERSION=1",
        "BURN=member=xImage target_partlabel=kernel2 max_bytes=8388608",
        "BURN=member=rootfs.squashfs target_partlabel=rootfs2 max_bytes=524288000",
        "BURN=member=ota-marker.bin target_partlabel=ota max_bytes=512",
        "NEVER_WRITE=kernel",
        "NEVER_WRITE=rootfs",
        "NEVER_WRITE=rootfs_data",
        "NEVER_WRITE=userdata",
        "NEVER_WRITE=sn_mac",
        "NEVER_WRITE=rtos",
        "NEVER_WRITE=rtos2",
        "",
    ]).encode("utf-8")

    # Fixed order. A set or dict iteration order here would be a reproducibility
    # bug that only shows up on another Python build.
    members = [
        ("xImage", ximage, "kernel2"),
        ("rootfs.squashfs", rootfs, "rootfs2"),
        ("ota-marker.bin", canonical_marker_block(), "ota"),
        ("build-manifest.txt", build_manifest, "none"),
        ("burn-map.txt", burn_map, "none"),
    ]

    # Two passes: place members to learn their offsets, then render the header
    # that describes them. The header is a fixed 4096 bytes, so placement does
    # not depend on how long the header text turns out to be.
    placed = []
    cursor = HEADER_BYTES
    for name, data, target in members:
        placed.append({
            "name": name, "data": data, "target": target,
            "offset": cursor, "size": len(data), "sha256": sha256_bytes(data),
        })
        cursor = align_up(cursor + len(data))
    total = cursor

    # The magic is a BARE TOKEN on the first line, not a KEY=VALUE pair. An
    # earlier revision wrote "NEBULAOS_RECOVERY_MAGIC=NEBULAOS-RECOVERY", which
    # put the KEY's name at offset 0 and the actual magic 24 bytes in. Anything
    # sniffing the first bytes of the file - which is exactly what a foreign
    # flashing tool does - would have been reading the key name. Byte 0 now is
    # the magic itself.
    header_lines = [
        MAGIC,
        "FORMAT_VERSION=%s" % FORMAT_VERSION,
        "CREALITY_CLONER_COMPATIBLE=UNVERIFIED",
        "PACKAGE_KIND=end-user-and-factory-recovery-media",
        "HARDWARE_AGENT_TRANSPORT=NO",
        "SOURCE_HEAD=%s" % source_head,
        "SOURCE_DATE_EPOCH=%s" % args.source_date_epoch,
        "HEADER_BYTES=%d" % HEADER_BYTES,
        "MEMBER_ALIGN=%d" % ALIGN,
        "MEMBER_COUNT=%d" % len(placed),
        "BUILD_MANIFEST_NORMALISED=%s" % ("built_at" if normalised else "none"),
        "TOTAL_BYTES=%d" % total,
        "XIMAGE_SHA256=%s" % ximage_sha,
        "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
    ]
    for member in placed:
        header_lines.append(
            "MEMBER=name=%s offset=%d size=%d sha256=%s target_partlabel=%s"
            % (member["name"], member["offset"], member["size"], member["sha256"], member["target"])
        )

    header_text = "\n".join(header_lines) + "\n"
    header_blob = header_text.encode("utf-8")
    if len(header_blob) > HEADER_BYTES:
        sys.exit("FATAL: header is %d bytes, exceeds the fixed %d-byte header area"
                 % (len(header_blob), HEADER_BYTES))
    header_blob = header_blob.ljust(HEADER_BYTES, b"\x00")

    with open(args.out, "wb") as fh:
        fh.write(header_blob)
        for member in placed:
            fh.seek(member["offset"])
            fh.write(member["data"])
        # Explicitly extend to the aligned total so the final member's padding
        # exists as real zero bytes rather than as an implicit short file.
        fh.truncate(total)
        fh.flush()
        os.fsync(fh.fileno())

    pkg_sha = sha256_file(args.out)

    lines = [
        "# NebulaOS .ingenic packaging manifest",
        "# Generated by scripts/package/build-ingenic.py from an already-built canonical core.",
        "# Nothing here was compiled by this step.",
        "INGENIC_FORMAT_VERSION=%s" % FORMAT_VERSION,
        "INGENIC_MAGIC=%s" % MAGIC,
        "SOURCE_HEAD=%s" % source_head,
        "SOURCE_DATE_EPOCH=%s" % args.source_date_epoch,
        "XIMAGE_SHA256=%s" % ximage_sha,
        "XIMAGE_SIZE=%d" % len(ximage),
        "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
        "ROOTFS_SQUASHFS_SIZE=%d" % len(rootfs),
        "INGENIC_SHA256=%s" % pkg_sha,
        "INGENIC_SIZE=%d" % total,
        "INGENIC_MEMBER_COUNT=%d" % len(placed),
        # The as-built manifest's own hash, kept OUT of the container so the
        # container stays byte-identical across builds, but recorded here so the
        # specific build run that produced this package is still traceable.
        "BUILD_MANIFEST_ORIGINAL_SHA256=%s" % sha256_bytes(build_manifest_raw),
        "BUILD_MANIFEST_NORMALISED=%s" % ("built_at" if normalised else "none"),
        "CREALITY_CLONER_COMPATIBLE=UNVERIFIED",
        "HARDWARE_AGENT_TRANSPORT=NO",
    ]
    for member in placed:
        lines.append("INGENIC_MEMBER=name=%s offset=%d size=%d sha256=%s target_partlabel=%s"
                     % (member["name"], member["offset"], member["size"],
                        member["sha256"], member["target"]))
    lines += [
        "# COMPATIBILITY. Creality's recovery tool for this printer is a closed",
        "# Windows binary (cloner-2.5.18-windows_alpha.zip in",
        "# CrealityOfficial/Ender-3_V3_KE_Annex). No sample .ingenic package and no",
        "# format specification are published anywhere this project could find, so",
        "# this container's compatibility with that tool has never been tested and",
        "# is recorded as UNVERIFIED rather than claimed.",
        "# The NEBULAOS-RECOVERY magic at offset 0 is deliberate: a tool that does",
        "# not know this format rejects the file rather than misreading it and",
        "# starting a partial flash.",
        "# SCOPE. This is recovery media for a human. It has none of the Hardware",
        "# Agent's safety semantics - no slot-2-only ownership enforcement, no",
        "# live-target collision refusal, no armed/disarm transaction. The burn map",
        "# member records what it describes writing: kernel2, rootfs2 and the OTA",
        "# marker, and explicitly never the stock slot or the data partitions.",
    ]

    with open(args.out + ".manifest.txt", "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(args.out + ".sha256", "w", encoding="utf-8") as fh:
        fh.write("%s  %s\n" % (pkg_sha, os.path.basename(args.out)))

    print("INGENIC_BUILT=%s" % args.out)
    print("INGENIC_SHA256=%s" % pkg_sha)
    print("INGENIC_SIZE=%d" % total)
    print("CREALITY_CLONER_COMPATIBLE=UNVERIFIED")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description="Package the canonical core into a NebulaOS .ingenic")
    parser.add_argument("--ximage", required=True)
    parser.add_argument("--rootfs", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--source-head")
    parser.add_argument("--source-date-epoch", required=True)
    return build(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
