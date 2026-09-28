#!/usr/bin/env python3
"""Validate a NebulaOS .ingenic against its canonical core AND its template.

A packaging command that exits 0 proves only that it did not crash. This opens
the finished archive and proves three separate things:

  1. the NebulaOS payloads that went in are the ones that came out, byte for
     byte, compared by SHA-256 against the canonical xImage and rootfs.squashfs
  2. nothing else changed. Every entry the template carried - SPL/U-Boot, the
     MBR/GPT, the per-SoC firmware and DDR descriptors, the Cloner files, the
     security keys - is compared against the template entry by entry. Vendor
     boot material we did not mean to touch must be bit-identical.
  3. the safety properties hold: the erase policy still leaves sn_mac alone,
     the OTA marker selects the intended slot, and in the default slot-B layout
     the stock slot is genuinely untouched.

(2) is the check that matters most and is the easiest to omit. A package that
embeds the right kernel but silently re-encoded U-Boot is not a package anyone
should put a printer into mask-ROM for.
"""

import argparse
import hashlib
import os
import sys
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools", "emmc"))
import nebulaos_layout as layout  # noqa: E402

STOCK_KERNEL_ENTRY = "images/xImage"
STOCK_ROOTFS_ENTRY = "images/rootfs.squashfs"
STOCK_RTOS_ENTRY = "images/zero.bin"
UBOOT_ENTRY = "images/u-boot-with-spl-mbr-gpt.bin"
CLONER_PROFILE_ENTRY = "configs/x2000/x2000e_mmc0_lpddr2_linux.cfg"
OTA_ENTRY = "images/ota"
KERNEL2_ENTRY = "images/xImage2"
ROOTFS2_ENTRY = "images/rootfs2.squashfs"
RTOS2_ENTRY = "images/zero2.bin"
SLOT2_OTA_MARKER = b"ota:kernel2\n\n"
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


def sha256_entry(archive, name):
    digest = hashlib.sha256()
    with archive.open(name, "r") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ini_value(data, section, key):
    header = ("[%s]" % section).encode()
    prefix = ("%s=" % key).encode()
    current = b""
    for line in data.splitlines():
        content = line.rstrip(b"\r\n")
        if content.startswith(b"[") and content.endswith(b"]"):
            current = content
        elif current == header and content.startswith(prefix):
            return content[len(prefix):].decode("ascii", "replace").strip()
    return None


def report():
    print()
    print("INGENIC_VALIDATION_PASS=%d" % len(PASS))
    print("INGENIC_VALIDATION_FAIL=%d" % len(FAIL))
    print("INGENIC_VALIDATED=%s" % ("YES" if not FAIL else "NO"))
    return 0 if not FAIL else 1


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a NebulaOS .ingenic package")
    parser.add_argument("--package", required=True)
    parser.add_argument("--template", required=True, help="the official package it was built from")
    parser.add_argument("--ximage", required=True, help="canonical xImage to compare against")
    parser.add_argument("--rootfs", required=True, help="canonical rootfs.squashfs to compare against")
    parser.add_argument("--slot", choices=("a", "b"), default="b")
    args = parser.parse_args(argv)

    slot_b = args.slot == "b"
    canonical_x = sha256_file(args.ximage)
    canonical_r = sha256_file(args.rootfs)

    print("=== .ingenic validation: %s ===" % args.package)
    print("CANONICAL_XIMAGE_SHA256=%s" % canonical_x)
    print("CANONICAL_ROOTFS_SHA256=%s" % canonical_r)
    print("SLOT=%s" % args.slot.upper())
    print()

    try:
        pkg = zipfile.ZipFile(args.package, "r")
        tpl = zipfile.ZipFile(args.template, "r")
    except (zipfile.BadZipFile, OSError) as exc:
        bad("the package and template open as ZIP archives", str(exc))
        return report()
    ok("the package opens as a ZIP archive (the Ingenic Cloner container)")

    pkg_names = [i.filename for i in pkg.infolist()]
    tpl_names = [i.filename for i in tpl.infolist()]

    kernel_entry = KERNEL2_ENTRY if slot_b else STOCK_KERNEL_ENTRY
    rootfs_entry = ROOTFS2_ENTRY if slot_b else STOCK_ROOTFS_ENTRY

    # --- 1. the NebulaOS payloads round-trip --------------------------------
    for entry, canonical, label in ((kernel_entry, canonical_x, "xImage"),
                                    (rootfs_entry, canonical_r, "rootfs.squashfs")):
        if entry not in pkg_names:
            bad("the package carries %s" % entry)
            continue
        got = sha256_entry(pkg, entry)
        if got == canonical:
            ok("%s is byte-identical to the canonical %s" % (entry, label))
        else:
            bad("%s is byte-identical to the canonical %s" % (entry, label),
                "package=%s canonical=%s" % (got, canonical))

    # --- 2. nothing else changed -------------------------------------------
    # The heart of the check. Every template entry must survive untouched
    # except the ones we deliberately substituted or rewrote.
    expected_changed = {kernel_entry, rootfs_entry}
    if slot_b:
        expected_changed |= {CLONER_PROFILE_ENTRY}
    expected_new = {OTA_ENTRY, RTOS2_ENTRY, KERNEL2_ENTRY, ROOTFS2_ENTRY} if slot_b else set()

    missing = [n for n in tpl_names if n not in pkg_names]
    if not missing:
        ok("every one of the template's %d entries is still present" % len(tpl_names))
    else:
        bad("every template entry is still present", "missing: %s" % ", ".join(missing[:5]))

    unexpected = [n for n in pkg_names if n not in tpl_names and n not in expected_new]
    if not unexpected:
        ok("the package adds only the %d intended new entries" % len(expected_new))
    else:
        bad("the package adds only the intended new entries",
            "unexpected: %s" % ", ".join(unexpected[:5]))

    drifted = []
    for name in tpl_names:
        if name in expected_changed or name not in pkg_names:
            continue
        if tpl.getinfo(name).file_size != pkg.getinfo(name).file_size:
            drifted.append(name)
            continue
        if sha256_entry(tpl, name) != sha256_entry(pkg, name):
            drifted.append(name)
    if not drifted:
        ok("all %d carried-through vendor entries are bit-identical to the template"
           % (len(tpl_names) - len(expected_changed)))
    else:
        bad("all carried-through vendor entries are bit-identical to the template",
            "drifted: %s" % ", ".join(drifted[:8]))

    # Called out individually because these are the ones that would matter most.
    for entry, what in ((UBOOT_ENTRY, "SPL/U-Boot + MBR/GPT"),
                        ("security/x2000/key.bin", "X2000 security key"),
                        ("firmwares/x2000/uboot.bin", "X2000 U-Boot firmware"),
                        ("firmwares/x2000/spl.bin", "X2000 SPL firmware")):
        if entry in tpl_names and entry in pkg_names and sha256_entry(tpl, entry) == sha256_entry(pkg, entry):
            ok("%s (%s) is unchanged" % (entry, what))
        else:
            bad("%s (%s) is unchanged" % (entry, what))

    # --- 3. slot A is genuinely stock in the default layout -----------------
    if slot_b:
        for entry, what in ((STOCK_KERNEL_ENTRY, "stock kernel"),
                            (STOCK_ROOTFS_ENTRY, "stock rootfs"),
                            (STOCK_RTOS_ENTRY, "stock RTOS")):
            if sha256_entry(tpl, entry) == sha256_entry(pkg, entry):
                ok("slot A's %s is the untouched stock payload" % what)
            else:
                bad("slot A's %s is the untouched stock payload" % what)

        # The NebulaOS payload must NOT have landed in slot A.
        if sha256_entry(pkg, STOCK_KERNEL_ENTRY) != canonical_x:
            ok("the NebulaOS kernel did not land in slot A")
        else:
            bad("the NebulaOS kernel did not land in slot A",
                "slot A holds the NebulaOS kernel - the stock fallback is gone")

        if RTOS2_ENTRY in pkg_names and sha256_entry(pkg, RTOS2_ENTRY) == sha256_entry(tpl, STOCK_RTOS_ENTRY):
            ok("zero2.bin is a deliberate copy of the stock RTOS")
        else:
            bad("zero2.bin is a deliberate copy of the stock RTOS")

        # --- the OTA marker ---
        if OTA_ENTRY in pkg_names:
            marker = pkg.read(OTA_ENTRY)
            if marker == SLOT2_OTA_MARKER:
                ok("the OTA marker is exactly %r (selects slot B)" % SLOT2_OTA_MARKER)
            else:
                bad("the OTA marker is exactly %r (selects slot B)" % SLOT2_OTA_MARKER,
                    "got %r" % marker)
        else:
            bad("the package carries an OTA marker entry")

        # --- the dual-slot Cloner policy ---
        profile = pkg.read(CLONER_PROFILE_ENTRY)
        enabled = {}
        for policy, label in (("policy1", "ota"), ("policy4", "rtos"), ("policy5", "rtos2"),
                              ("policy6", "kernel"), ("policy7", "kernel2"),
                              ("policy8", "rootfs"), ("policy9", "rootfs2")):
            enabled[label] = ini_value(profile, policy, "enabled")
        if all(v == "1" for v in enabled.values()):
            ok("the Cloner profile enables all 7 dual-slot policies (%s)" % ", ".join(sorted(enabled)))
        else:
            bad("the Cloner profile enables all 7 dual-slot policies",
                "; ".join("%s=%s" % (k, v) for k, v in sorted(enabled.items())))

        for policy, want in (("policy7", KERNEL2_ENTRY), ("policy9", ROOTFS2_ENTRY),
                             ("policy1", OTA_ENTRY), ("policy5", RTOS2_ENTRY)):
            got = ini_value(profile, policy, "attribute")
            if got == want:
                ok("%s points at %s" % (policy, want))
            else:
                bad("%s points at %s" % (policy, want), "got %r" % got)

        # --- sn_mac preservation: the irreversible one --------------------
        erase = ini_value(profile, "mmc", "erase_list")
        if erase and layout.erase_list_preserves_sn_mac(erase):
            ok("the erase policy leaves sn_mac (0x%x..0x%x) untouched: %s"
               % (*layout.SN_MAC_PRESERVED_RANGE, erase))
        else:
            bad("the erase policy leaves sn_mac untouched",
                "erase_list=%r would erase across the per-unit factory MAC/serial" % erase)

        # sn_mac's own policy must stay disabled - it is never programmed.
        if ini_value(profile, "policy2", "enabled") == "0":
            ok("the sn_mac policy remains disabled (never programmed)")
        else:
            bad("the sn_mac policy remains disabled (never programmed)",
                "policy2 enabled=%s" % ini_value(profile, "policy2", "enabled"))

        # The offsets are vendor geometry and must not have moved.
        for policy, label in (("policy1", "ota"), ("policy6", "kernel"), ("policy7", "kernel2"),
                              ("policy8", "rootfs"), ("policy9", "rootfs2"), ("policy2", "sn_mac")):
            got = ini_value(profile, policy, "offset")
            want = layout.partition_offset(label)
            if got is not None and int(got, 0) == want:
                continue
            bad("%s (%s) offset is unchanged at 0x%x" % (policy, label, want), "got %r" % got)
        else:
            ok("every partition offset in the Cloner profile is unchanged vendor geometry")

    pkg.close()
    tpl.close()
    return report()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
