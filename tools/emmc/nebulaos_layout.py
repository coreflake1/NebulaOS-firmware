"""The Ender-3 V3 KE eMMC layout, with per-fact provenance, plus a GPT builder.

READ THIS BEFORE USING IT TO WRITE ANYTHING

This module exists because of a gap that must not be papered over. NebulaOS
knows a great deal about this device's partitions and almost nothing about
their absolute positions.

VERIFIED FROM REAL HARDWARE (captured evidence in this repository):

  * there are exactly ten partitions, p1..p10
  * their labels are ota, sn_mac, rtos, rtos2, kernel, kernel2, rootfs,
    rootfs2, rootfs_data, userdata
        artifacts/parity/{stock,custom}/12-dev-tree.txt
  * kernel/kernel2 are 8388608 bytes and rootfs/rootfs2 are 524288000 bytes
        scripts/flash-spare-slot.sh, enforced against real hardware
  * the full index-to-role map: p1=ota, p2=sn_mac, p3/p4=rtos/rtos2,
    p5/p6=kernel/kernel2, p7/p8=rootfs/rootfs2, p9=rootfs_data, p10=userdata
        docs/NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md, recorded during a live
        read-only session, corroborated by artifacts/parity/*/12-dev-tree.txt
        (by-path part1..part10) and by flash-spare-slot.sh's device paths
  * p2 = sn_mac is 1024 bytes and holds the PER-UNIT FACTORY IDENTITY
        docs/NEBULAOS_WIFI_CAMERA_RT_LIVE_QUALIFICATION_REPORT.md: a bounded
        read returned
            26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1;;;;;
        - a serial number and the factory MAC fc:ee:11:00:4c:14, confirmed to be
        the address stock's wlan0 actually uses. This data is programmed per
        unit, exists nowhere else on the device, and cannot be regenerated.
  * the factory alternate GPT is invalid; the primary is authoritative
        artifacts/parity/stock/11-dmesg.txt

NOT VERIFIED - NO EVIDENCE EXISTS IN THIS WORKSPACE:

  * the absolute start LBA of ANY partition
  * the total capacity of the eMMC
  * whether p3 is rtos and p4 rtos2, or the reverse (the capture records the
    pair, not the order - harmless, since nothing here ever addresses either)
  * the sizes of rtos, rtos2, rootfs_data and userdata as exact byte counts
    (docs give "300 MB" and "~6 GB" in prose, which is not a number)
  * every partition type GUID, and the mapping of the ten recorded PARTUUIDs
    (artifacts/parity/custom/12-dev-tree.txt) to partitions

WHAT THAT MEANS FOR A DISK IMAGE

A full-disk .img carries a partition table and, written raw, replaces the whole
device. Three separate things make that unsafe here, and only the first is about
the missing offsets:

  1. if any start offset is wrong the write does not fail cleanly, it relocates
     p9 and p10 - the user's printer.cfg, calibration, macros, uploads and Wi-Fi
     credentials - and may disturb the bootloader region below first_usable_lba.

  2. a whole-disk write zeroes p2/sn_mac, destroying the per-unit factory MAC and
     serial number recorded above. That is irreversible and unrecoverable: the
     value is not derivable from anything else on the device, and NebulaOS is
     separately scheduled to START reading it rather than deriving its own MAC.

  3. a whole-disk write also zeroes p5/p7, the stock slot, which
     docs/A_B_SLOT_MODEL.md and docs/DEVELOPER_RECOVERY.md designate as THE
     fallback path. We do not have Creality's stock kernel and rootfs and could
     not redistribute them, so an image we build cannot restore what it removes.

Points 2 and 3 are not fixed by capturing the GPT. They are properties of raw
whole-disk writing, and they are why build-img.py gates the whole-disk path
behind require_whole_disk_preconditions() and emits a slot-scoped image instead.

To close point 1, a human with the device runs, on the printer:

    sgdisk --print /dev/mmcblk0          # or: gdisk -l /dev/mmcblk0
    cat /proc/partitions
    blkid

and records the result here. Points 2 and 3 additionally require a per-unit
sn_mac preservation step and a redistributable stock slot before a whole-disk
image is a defensible artifact at all.
"""

import binascii
import struct
import uuid

SECTOR = 512

VERIFIED = "VERIFIED_FROM_HARDWARE"
DECLARED = "DECLARED_UNVERIFIED"

# Sizes that real hardware has enforced.
KERNEL_PART_BYTES = 8388608
ROOTFS_PART_BYTES = 524288000


class LayoutFact:
    """One statement about the layout, carrying how we know it."""

    __slots__ = ("name", "value", "provenance", "source")

    def __init__(self, name, value, provenance, source):
        self.name = name
        self.value = value
        self.provenance = provenance
        self.source = source

    def __repr__(self):
        return "LayoutFact(%s=%r %s)" % (self.name, self.value, self.provenance)


# Index -> label. p1 and p5..p10 are verified; p2..p4 are a declared guess at
# the ORDER of three labels we know exist but never touch.
PARTITION_ORDER = (
    LayoutFact("p1", "ota", VERIFIED, "docs/A_B_SLOT_MODEL.md + flash-spare-slot.sh"),
    LayoutFact("p2", "sn_mac", VERIFIED, "docs/NEBULAOS_DISPLAY_LIVE_READ_ONLY_REPORT.md live read"),
    LayoutFact("p3", "rtos", DECLARED, "live read records the p3/p4 pair, not which is which"),
    LayoutFact("p4", "rtos2", DECLARED, "live read records the p3/p4 pair, not which is which"),
    LayoutFact("p5", "kernel", VERIFIED, "artifacts/parity/*/12-dev-tree.txt + flash-spare-slot.sh"),
    LayoutFact("p6", "kernel2", VERIFIED, "artifacts/parity/*/12-dev-tree.txt + flash-spare-slot.sh"),
    LayoutFact("p7", "rootfs", VERIFIED, "artifacts/parity/*/12-dev-tree.txt + flash-spare-slot.sh"),
    LayoutFact("p8", "rootfs2", VERIFIED, "artifacts/parity/*/12-dev-tree.txt + flash-spare-slot.sh"),
    LayoutFact("p9", "rootfs_data", VERIFIED, "docs/A_B_SLOT_MODEL.md + dmesg EXT4 mount"),
    LayoutFact("p10", "userdata", VERIFIED, "docs/A_B_SLOT_MODEL.md + dmesg EXT4 mount"),
)

# Sizes in bytes. Only the four slot partitions are verified numbers.
PARTITION_SIZES = (
    LayoutFact("ota", 1024 * 1024, DECLARED, "docs say '1 MB'; exact bytes unproven"),
    LayoutFact("sn_mac", 1024, VERIFIED,
               "docs/NEBULAOS_WIFI_CAMERA_RT_LIVE_QUALIFICATION_REPORT.md: 1024 bytes"),
    LayoutFact("rtos", 8 * 1024 * 1024, DECLARED, "no evidence of size"),
    LayoutFact("rtos2", 8 * 1024 * 1024, DECLARED, "no evidence of size"),
    LayoutFact("kernel", KERNEL_PART_BYTES, VERIFIED, "scripts/flash-spare-slot.sh"),
    LayoutFact("kernel2", KERNEL_PART_BYTES, VERIFIED, "scripts/flash-spare-slot.sh"),
    LayoutFact("rootfs", ROOTFS_PART_BYTES, VERIFIED, "scripts/flash-spare-slot.sh"),
    LayoutFact("rootfs2", ROOTFS_PART_BYTES, VERIFIED, "scripts/flash-spare-slot.sh"),
    LayoutFact("rootfs_data", 300 * 1024 * 1024, DECLARED, "docs say '300 MB'; exact bytes unproven"),
    LayoutFact("userdata", 6 * 1024 * 1024 * 1024, DECLARED, "docs say '~6 GB'; exact bytes unproven"),
)

# There is no evidence for any start LBA at all.
GEOMETRY_FACTS = (
    LayoutFact("first_partition_lba", 2048, DECLARED, "conventional 1 MiB alignment; unproven"),
    LayoutFact("disk_total_bytes", None, DECLARED, "eMMC capacity never captured"),
    LayoutFact("partition_type_guids", None, DECLARED, "never captured"),
    LayoutFact("partition_uuids", None, DECLARED, "per-device; never captured"),
)


# Partitions whose contents are per-unit and cannot be regenerated or obtained.
# Overwriting one is not a recoverable mistake, so every write path names this
# set explicitly rather than relying on it merely being absent from an allowlist.
IRREPLACEABLE_LABELS = frozenset({"sn_mac"})

# Partitions we do not have contents for and could not redistribute if we did.
UNOBTAINABLE_LABELS = frozenset({"kernel", "rootfs", "rtos", "rtos2"})

# Partitions holding the user's own data.
USER_DATA_LABELS = frozenset({"rootfs_data", "userdata"})


def require_whole_disk_preconditions():
    """Return the list of reasons a whole-disk image must not be produced today.

    Empty list means all three preconditions hold. Anything else is a refusal,
    and the strings are meant to be printed verbatim: each one names a concrete
    artifact someone must supply, not a vague concern.
    """
    reasons = []
    if not geometry_is_verified():
        reasons.append(
            "GPT geometry is unverified (%d declared fact(s)): a wrong start offset "
            "relocates rootfs_data/userdata. Capture `sgdisk --print /dev/mmcblk0` "
            "from a real unit." % len(unverified_facts())
        )
    reasons.append(
        "sn_mac (%d bytes) holds the per-unit factory MAC and serial. A raw whole-disk "
        "write zeroes it and the value cannot be recovered. A whole-disk image needs a "
        "per-unit sn_mac preservation step that does not exist."
        % dict((f.name, f.value) for f in PARTITION_SIZES)["sn_mac"]
    )
    reasons.append(
        "the stock slot (kernel, rootfs) is the documented recovery fallback. We do not "
        "have Creality's stock images and could not redistribute them, so a whole-disk "
        "image would remove a fallback it cannot restore."
    )
    return reasons


def all_facts():
    return tuple(PARTITION_ORDER) + tuple(PARTITION_SIZES) + tuple(GEOMETRY_FACTS)


def unverified_facts():
    return tuple(f for f in all_facts() if f.provenance != VERIFIED)


def geometry_is_verified():
    """True only when every fact needed to place bytes on a real disk is proven.

    Deliberately strict: a single DECLARED start offset is enough to make a
    full-disk image unsafe, so there is no partial credit here.
    """
    return not unverified_facts()


def provenance_report():
    lines = ["EMMC_LAYOUT_GEOMETRY_VERIFIED=%s" % ("YES" if geometry_is_verified() else "NO")]
    verified = [f for f in all_facts() if f.provenance == VERIFIED]
    unverified = list(unverified_facts())
    lines.append("EMMC_LAYOUT_FACTS_VERIFIED=%d" % len(verified))
    lines.append("EMMC_LAYOUT_FACTS_UNVERIFIED=%d" % len(unverified))
    for fact in unverified:
        lines.append(
            "EMMC_LAYOUT_UNVERIFIED=%s value=%r reason=%s" % (fact.name, fact.value, fact.source)
        )
    return "\n".join(lines)


# --------------------------------------------------------------------------
# GPT construction
# --------------------------------------------------------------------------
#
# Used for two things and only two things:
#   1. building synthetic devices for the offline test harnesses
#   2. building the partition table inside a full-disk .img
#
# It is fully deterministic: every GUID is derived from a caller-supplied seed
# rather than randomly generated, because a packaging step that produces
# different bytes on every run cannot be checked for reproducibility.

_GPT_SIGNATURE = b"EFI PART"
_ENTRY_SIZE = 128
_ENTRY_COUNT = 128

# Linux filesystem data. Used for every entry: the real device's type GUIDs were
# never captured, and inventing distinct per-role GUIDs would be fabricating
# detail. One honest generic type is better than ten invented specific ones.
LINUX_FS_TYPE_GUID = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")


def derive_guid(seed, tag):
    """A GUID derived deterministically from a seed string.

    uuid5 over a fixed namespace: same seed and tag always give the same GUID,
    different ones essentially never collide, and nothing reads the clock or
    /dev/urandom. That is what makes a packaged image reproducible.
    """
    return uuid.uuid5(uuid.NAMESPACE_URL, "nebulaos:%s:%s" % (seed, tag))


def plan_partitions(partitions, disk_bytes):
    """Place `partitions` on a disk of `disk_bytes`, without allocating anything.

    Split out from the block generation below so that a multi-gigabyte image can
    be written sparsely. An earlier revision built the whole disk as one
    bytearray, which for this product's ~7.5 GB layout meant holding the entire
    image - almost all of it zeroes - in RAM, twice over when comparing two
    packaging runs. Planning and emitting are now separate: the caller learns
    where every partition goes, then writes only the bytes that are not zero.

    Returns (placed, geometry).
    """
    if disk_bytes % SECTOR:
        raise ValueError("disk size must be a whole number of 512-byte sectors")
    total_lba = disk_bytes // SECTOR

    entries_sectors = (_ENTRY_COUNT * _ENTRY_SIZE + SECTOR - 1) // SECTOR  # 32
    first_usable = 2 + entries_sectors                                     # 34
    # The backup header occupies the last LBA and the backup entry array sits
    # immediately below it.
    last_usable = total_lba - 1 - entries_sectors - 1

    placed = []
    cursor = 2048  # 1 MiB alignment, the conventional choice
    if cursor < first_usable:
        cursor = first_usable
    for label, size in partitions:
        if size % SECTOR:
            raise ValueError("partition %r size must be a whole number of sectors" % label)
        sectors = size // SECTOR
        first = cursor
        last = first + sectors - 1
        if last > last_usable:
            raise ValueError(
                "partition %r does not fit: needs up to LBA %d, last usable is %d"
                % (label, last, last_usable)
            )
        placed.append({"label": label, "first_lba": first, "last_lba": last,
                       "offset": first * SECTOR, "size": size})
        cursor = last + 1
        # Re-align the next partition to a 1 MiB boundary, as a real tool would.
        if cursor % 2048:
            cursor += 2048 - (cursor % 2048)

    geometry = {
        "total_lba": total_lba,
        "first_usable": first_usable,
        "last_usable": last_usable,
        "entries_sectors": entries_sectors,
        "disk_bytes": disk_bytes,
    }
    return placed, geometry


def gpt_blocks(placed, geometry, seed, alternate="valid"):
    """Return [(offset, bytes)] for every non-zero region of the GPT container.

    Everything not listed is zero, so a caller can create a sparse file and write
    only these. `alternate` is "valid", "invalid" or "absent" - the KE ships an
    invalid backup GPT, so the test harness must be able to reproduce that exact
    condition and not merely the textbook-correct case.
    """
    total_lba = geometry["total_lba"]
    first_usable = geometry["first_usable"]
    last_usable = geometry["last_usable"]
    entries_sectors = geometry["entries_sectors"]

    blocks = []

    # --- protective MBR ---
    mbr = bytearray(SECTOR)
    mbr[446] = 0x00
    mbr[450] = 0xEE          # GPT protective type
    struct.pack_into("<I", mbr, 454, 1)
    struct.pack_into("<I", mbr, 458, min(total_lba - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    blocks.append((0, bytes(mbr)))

    # --- entry array ---
    array = bytearray(_ENTRY_COUNT * _ENTRY_SIZE)
    for i, part in enumerate(placed):
        name = part["label"].encode("utf-16-le")[:72].ljust(72, b"\x00")
        struct.pack_into(
            "<16s16sQQQ72s", array, i * _ENTRY_SIZE,
            LINUX_FS_TYPE_GUID.bytes_le,
            derive_guid(seed, part["label"]).bytes_le,
            part["first_lba"], part["last_lba"], 0, name,
        )
    entries_crc = binascii.crc32(bytes(array)) & 0xFFFFFFFF

    disk_guid = derive_guid(seed, "__disk__")

    def header(current_lba, backup_lba, entries_lba):
        raw = bytearray(SECTOR)
        struct.pack_into(
            "<8sIIIIQQQQ16sQIII", raw, 0,
            _GPT_SIGNATURE, 0x00010000, 92, 0, 0,
            current_lba, backup_lba, first_usable, last_usable,
            disk_guid.bytes_le, entries_lba, _ENTRY_COUNT, _ENTRY_SIZE, entries_crc,
        )
        crc = binascii.crc32(bytes(raw[:92])) & 0xFFFFFFFF
        struct.pack_into("<I", raw, 16, crc)
        return bytes(raw)

    blocks.append((SECTOR, header(1, total_lba - 1, 2)))
    blocks.append((2 * SECTOR, bytes(array)))

    backup_entries_lba = total_lba - 1 - entries_sectors
    if alternate == "valid":
        blocks.append((backup_entries_lba * SECTOR, bytes(array)))
        blocks.append(((total_lba - 1) * SECTOR, header(total_lba - 1, 1, backup_entries_lba)))
    elif alternate == "invalid":
        # Reproduce the factory condition: a header that is present but does not
        # validate. Corrupting the CRC (not the signature) is the closest match
        # to what the kernel reports on a real KE.
        raw = bytearray(header(total_lba - 1, 1, backup_entries_lba))
        struct.pack_into("<I", raw, 16, 0xDEADBEEF)
        blocks.append(((total_lba - 1) * SECTOR, bytes(raw)))
    elif alternate == "absent":
        pass
    else:
        raise ValueError("alternate must be valid, invalid or absent")

    return blocks


def build_gpt(partitions, disk_bytes, seed, alternate="valid"):
    """Convenience wrapper that materialises a whole small disk in memory.

    For test harnesses only. Real packaging uses plan_partitions + gpt_blocks and
    writes sparsely - see the note on plan_partitions.
    """
    placed, geometry = plan_partitions(partitions, disk_bytes)
    image = bytearray(disk_bytes)
    for offset, data in gpt_blocks(placed, geometry, seed, alternate):
        image[offset:offset + len(data)] = data
    return image, placed


def ke_partition_plan():
    """The ten (label, size) pairs this product is declared to have.

    Callers that intend to WRITE this to hardware must first consult
    geometry_is_verified(); this function will happily return a plan built on
    declared values, because the test harness needs exactly that.
    """
    sizes = {f.name: f.value for f in PARTITION_SIZES}
    return [(f.value, sizes[f.value]) for f in PARTITION_ORDER]
