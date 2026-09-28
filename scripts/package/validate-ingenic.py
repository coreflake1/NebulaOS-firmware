#!/usr/bin/env python3
"""Validate a NebulaOS .ingenic package by unpacking it again.

Parses the container independently of the packer - it reads the fixed header,
follows the declared offsets, extracts every member to disk, and hashes what
came out. Nothing is taken from the packer's own manifest until the end, and
then only to check that the manifest agrees with the artifact.

Checks:
  1. the magic and format version are ours
  2. the header parses and declares a coherent member table
  3. every declared member is present, in range, and hashes to its declaration
  4. the xImage and rootfs.squashfs members are byte-identical to the canonical
     core the package claims to carry
  5. the extracted rootfs is a real, readable squashfs (unsquashfs listing)
  6. the burn map is present, parses, and names only partitions this project is
     willing to describe writing - a burn map that named the stock slot or the
     user's data partitions would be a defect, so it is asserted against
  7. padding between members is zero
  8. the packaging manifest agrees with the artifact
  9. the compatibility claim is UNVERIFIED and has not drifted to YES
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

MAGIC = "NEBULAOS-RECOVERY"
HEADER_BYTES = 4096
CHUNK = 1024 * 1024

# Exactly the partitions a recovery flash is allowed to describe writing.
ALLOWED_TARGETS = {"kernel2", "rootfs2", "ota", "none"}
# Naming any of these in a burn map is a defect, not a warning.
FORBIDDEN_TARGETS = {"kernel", "rootfs", "rootfs_data", "userdata", "sn_mac", "rtos", "rtos2"}

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


def manifest_get(path, key):
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return None


def parse_header(blob):
    """Parse the fixed header.

    The first line is a bare magic token, not an assignment, so it is consumed
    before the KEY=VALUE loop. Reported back under the synthetic key MAGIC so
    callers have one place to check it.
    """
    text = blob.split(b"\x00", 1)[0].decode("utf-8")
    lines = text.splitlines()
    header, members = {}, []
    if lines:
        header["MAGIC"] = lines[0].strip()
        lines = lines[1:]
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        if key == "MEMBER":
            fields = {}
            for token in value.split():
                k, _, v = token.partition("=")
                fields[k] = v
            members.append(fields)
        else:
            header[key] = value
    return header, members


def report():
    print()
    print("INGENIC_VALIDATION_PASS=%d" % len(PASS))
    print("INGENIC_VALIDATION_FAIL=%d" % len(FAIL))
    print("INGENIC_VALIDATED=%s" % ("YES" if not FAIL else "NO"))
    return 0 if not FAIL else 1


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a NebulaOS .ingenic package")
    parser.add_argument("--package", required=True)
    parser.add_argument("--ximage", required=True, help="canonical xImage to compare against")
    parser.add_argument("--rootfs", required=True, help="canonical rootfs.squashfs to compare against")
    parser.add_argument("--manifest", help="the package's own manifest (defaults to <package>.manifest.txt)")
    parser.add_argument("--skip-extract", action="store_true")
    args = parser.parse_args(argv)

    pkg_manifest = args.manifest or (args.package + ".manifest.txt")
    canonical_x = sha256_file(args.ximage)
    canonical_r = sha256_file(args.rootfs)
    total_size = os.path.getsize(args.package)

    print("=== .ingenic validation: %s ===" % args.package)
    print("CANONICAL_XIMAGE_SHA256=%s" % canonical_x)
    print("CANONICAL_ROOTFS_SHA256=%s" % canonical_r)
    print()

    with open(args.package, "rb") as fh:
        header_blob = fh.read(HEADER_BYTES)
    if len(header_blob) != HEADER_BYTES:
        bad("the package is large enough to hold its fixed header")
        return report()

    try:
        header, members = parse_header(header_blob)
    except (UnicodeDecodeError, ValueError) as exc:
        bad("the fixed header parses", str(exc))
        return report()

    # Checked against the raw first bytes, not merely against the parsed field:
    # the whole point of the magic is where it sits, so a check that only looks
    # at a parsed dictionary would pass on a file with the token anywhere.
    if header_blob[:len(MAGIC)].decode("ascii", "replace") == MAGIC and header.get("MAGIC") == MAGIC:
        ok("the package begins with the NEBULAOS-RECOVERY magic at byte 0")
    else:
        bad("the package begins with the NEBULAOS-RECOVERY magic at byte 0",
            "first %d bytes are %r" % (len(MAGIC), header_blob[:len(MAGIC)]))
        return report()

    # A foreign flashing tool must not mistake this for a disk image. Assert the
    # two signatures such a tool looks for are absent.
    if header_blob[510:512] != b"\x55\xaa":
        ok("the package carries no MBR boot signature (a disk-image sniffer will reject it)")
    else:
        bad("the package carries no MBR boot signature")
    if header_blob[512:520] != b"EFI PART":
        ok("the package carries no GPT signature at LBA1")
    else:
        bad("the package carries no GPT signature at LBA1")

    if header.get("FORMAT_VERSION") == "1":
        ok("the container format version is 1")
    else:
        bad("the container format version is 1", "got %r" % header.get("FORMAT_VERSION"))

    declared = header.get("MEMBER_COUNT")
    if declared is not None and declared.isdigit() and int(declared) == len(members):
        ok("MEMBER_COUNT (%s) matches the number of declared members" % declared)
    else:
        bad("MEMBER_COUNT matches the number of declared members",
            "declared=%s actual=%d" % (declared, len(members)))

    if header.get("TOTAL_BYTES") == str(total_size):
        ok("TOTAL_BYTES matches the file size (%d)" % total_size)
    else:
        bad("TOTAL_BYTES matches the file size",
            "header=%s actual=%d" % (header.get("TOTAL_BYTES"), total_size))

    # --- members ------------------------------------------------------------
    tmpdir = tempfile.mkdtemp(prefix="nebulaos-ingenic-validate.", dir=os.environ.get("TMPDIR") or None)
    extracted = {}
    try:
        for member in members:
            name = member.get("name")
            try:
                offset = int(member["offset"])
                size = int(member["size"])
            except (KeyError, ValueError):
                bad("member %r declares a numeric offset and size" % name, repr(member))
                continue

            if offset < HEADER_BYTES or offset + size > total_size:
                bad("member %r lies inside the package" % name,
                    "offset=%d size=%d total=%d" % (offset, size, total_size))
                continue

            out = os.path.join(tmpdir, name.replace("/", "_"))
            digest = hashlib.sha256()
            with open(args.package, "rb") as src, open(out, "wb") as dst:
                src.seek(offset)
                remaining = size
                while remaining:
                    data = src.read(min(CHUNK, remaining))
                    if not data:
                        break
                    digest.update(data)
                    dst.write(data)
                    remaining -= len(data)
            got = digest.hexdigest()
            extracted[name] = out

            if got == member.get("sha256"):
                ok("member %r extracts and hashes to its declaration (%d bytes)" % (name, size))
            else:
                bad("member %r extracts and hashes to its declaration" % name,
                    "declared=%s extracted=%s" % (member.get("sha256"), got))

            target = member.get("target_partlabel")
            if target in ALLOWED_TARGETS:
                ok("member %r declares an allowed burn target (%s)" % (name, target))
            else:
                bad("member %r declares an allowed burn target" % name,
                    "target=%r is not one of %s" % (target, sorted(ALLOWED_TARGETS)))

        # --- payload equals the canonical core ------------------------------
        if "xImage" in extracted:
            got = sha256_file(extracted["xImage"])
            if got == canonical_x:
                ok("the xImage member is byte-identical to the canonical xImage")
            else:
                bad("the xImage member is byte-identical to the canonical xImage",
                    "package=%s canonical=%s" % (got, canonical_x))
        else:
            bad("the package carries an xImage member")

        if "rootfs.squashfs" in extracted:
            got = sha256_file(extracted["rootfs.squashfs"])
            if got == canonical_r:
                ok("the rootfs.squashfs member is byte-identical to the canonical rootfs")
            else:
                bad("the rootfs.squashfs member is byte-identical to the canonical rootfs",
                    "package=%s canonical=%s" % (got, canonical_r))
        else:
            bad("the package carries a rootfs.squashfs member")

        # --- the extracted filesystem is real -------------------------------
        if args.skip_extract:
            print("SKIP  unsquashfs listing (--skip-extract)")
        elif "rootfs.squashfs" not in extracted:
            pass
        elif not shutil.which("unsquashfs"):
            bad("the extracted rootfs is a readable squashfs",
                "unsquashfs is not installed; pass --skip-extract to acknowledge this gap explicitly")
        else:
            proc = subprocess.run(["unsquashfs", "-l", extracted["rootfs.squashfs"]],
                                  capture_output=True, text=True, timeout=300)
            if proc.returncode != 0:
                bad("the extracted rootfs is a readable squashfs", proc.stderr.strip()[:400])
            else:
                entries = [l for l in proc.stdout.splitlines() if l.startswith("squashfs-root")]
                if len(entries) >= 100 and "squashfs-root/etc/ota_marker.sh" in proc.stdout:
                    ok("the extracted rootfs is a readable NebulaOS squashfs (%d entries)" % len(entries))
                else:
                    bad("the extracted rootfs is a readable NebulaOS squashfs",
                        "%d entries, ota_marker.sh present=%s"
                        % (len(entries), "squashfs-root/etc/ota_marker.sh" in proc.stdout))

        # --- the marker member ----------------------------------------------
        if "ota-marker.bin" in extracted:
            with open(extracted["ota-marker.bin"], "rb") as fh:
                block = fh.read()
            expected = bytearray(512)
            expected[: len(b"ota:kernel2")] = b"ota:kernel2"
            if block == bytes(expected):
                ok("the ota-marker member is exactly one canonical ota:kernel2 block")
            else:
                bad("the ota-marker member is exactly one canonical ota:kernel2 block",
                    "got %r" % block[:32])
        else:
            bad("the package carries an ota-marker member")

        # --- the burn map ----------------------------------------------------
        if "burn-map.txt" not in extracted:
            bad("the package carries a burn map member")
        else:
            burn_text = open(extracted["burn-map.txt"], "r", encoding="utf-8").read()
            burns, nevers = [], set()
            for line in burn_text.splitlines():
                line = line.strip()
                if line.startswith("BURN="):
                    fields = dict(tok.partition("=")[::2] for tok in line[5:].split())
                    burns.append(fields)
                elif line.startswith("NEVER_WRITE="):
                    nevers.add(line.split("=", 1)[1])

            if burns:
                ok("the burn map declares %d burn target(s)" % len(burns))
            else:
                bad("the burn map declares at least one burn target")

            offenders = [b for b in burns if b.get("target_partlabel") in FORBIDDEN_TARGETS]
            if not offenders:
                ok("the burn map names no forbidden partition (stock slot, data partitions)")
            else:
                bad("the burn map names no forbidden partition",
                    "offending targets: %s" % [b.get("target_partlabel") for b in offenders])

            if FORBIDDEN_TARGETS <= nevers:
                ok("the burn map explicitly lists every forbidden partition as NEVER_WRITE")
            else:
                bad("the burn map explicitly lists every forbidden partition as NEVER_WRITE",
                    "missing: %s" % sorted(FORBIDDEN_TARGETS - nevers))

            # The declared capacities must match what the slot partitions really are.
            caps = {b.get("target_partlabel"): b.get("max_bytes") for b in burns}
            if caps.get("kernel2") == "8388608" and caps.get("rootfs2") == "524288000":
                ok("the burn map's slot capacities match the real partition sizes")
            else:
                bad("the burn map's slot capacities match the real partition sizes", repr(caps))

        # --- padding is zero -------------------------------------------------
        ordered = sorted((m for m in members if "offset" in m and "size" in m),
                         key=lambda m: int(m["offset"]))
        padding_clean = True
        with open(args.package, "rb") as fh:
            for i, member in enumerate(ordered):
                end = int(member["offset"]) + int(member["size"])
                next_start = int(ordered[i + 1]["offset"]) if i + 1 < len(ordered) else total_size
                if next_start > end:
                    fh.seek(end)
                    if fh.read(next_start - end).strip(b"\x00"):
                        padding_clean = False
                        bad("padding after member %r is zero" % member.get("name"))
        if padding_clean:
            ok("all inter-member padding is zero")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- the packaging manifest agrees --------------------------------------
    if not os.path.exists(pkg_manifest):
        bad("the .ingenic manifest exists", pkg_manifest)
    else:
        checks = [
            ("XIMAGE_SHA256", canonical_x),
            ("ROOTFS_SQUASHFS_SHA256", canonical_r),
            ("INGENIC_SHA256", sha256_file(args.package)),
            ("INGENIC_SIZE", str(total_size)),
        ]
        disagreements = [(k, v, manifest_get(pkg_manifest, k)) for k, v in checks
                         if manifest_get(pkg_manifest, k) != v]
        if not disagreements:
            ok("the .ingenic manifest agrees with the artifact and the canonical core")
        else:
            bad("the .ingenic manifest agrees with the artifact and the canonical core",
                "; ".join("%s: manifest=%s actual=%s" % (k, got, want) for k, want, got in disagreements))

    # --- the compatibility claim has not drifted ----------------------------
    # Asserted in both places it is written. If a future change ever flips this
    # to YES without a real reference artifact to test against, this fails.
    claims = [header.get("CREALITY_CLONER_COMPATIBLE"),
              manifest_get(pkg_manifest, "CREALITY_CLONER_COMPATIBLE")]
    if all(c == "UNVERIFIED" for c in claims):
        ok("CREALITY_CLONER_COMPATIBLE is UNVERIFIED in both the header and the manifest")
    else:
        bad("CREALITY_CLONER_COMPATIBLE is UNVERIFIED in both the header and the manifest",
            "header=%r manifest=%r - compatibility must not be claimed without a reference artifact"
            % (claims[0], claims[1]))

    if header.get("HARDWARE_AGENT_TRANSPORT") == "NO":
        ok("the package declares HARDWARE_AGENT_TRANSPORT=NO")
    else:
        bad("the package declares HARDWARE_AGENT_TRANSPORT=NO",
            "got %r" % header.get("HARDWARE_AGENT_TRANSPORT"))

    return report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
