"""GPT parsing and layout validation for the Ender-3 V3 KE eMMC.

WHY A PARSER RATHER THAN A TABLE OF OFFSETS

Every destructive operation in this project ultimately needs one thing: the
exact byte offset and length of a partition. There are two ways to get that.

Hardcode it, and the numbers are right until they are not - a different eMMC
part, a factory revision, a device that was repartitioned by some other tool -
and when they are wrong the write lands somewhere else on the disk. That failure
mode is silent and unrecoverable.

Parse it, and the numbers come from the device itself. A write is then aimed at
"whatever the device says partition kernel2 is", validated against what we
expect that partition to look like. If the device's table does not match the
expected shape, the right answer is to refuse, which a parser can do and a
hardcoded table cannot.

So this module reads the real GPT and then CHECKS it. Both halves matter:
parsing alone would happily hand back offsets from a table belonging to a
completely different product.

WHAT IT REFUSES

The KE's own alternate (backup) GPT is invalid - the kernel says so on every
boot, in evidence captured from a real device:

    artifacts/parity/stock/11-dmesg.txt
    "Alternate GPT is invalid, using primary GPT."

That is the factory state, not damage, so this parser must not treat a bad
alternate GPT as a reason to refuse. It reads the primary GPT, and reports the
alternate's condition as information rather than as a verdict. Refusing there
would refuse every real device.

It does refuse: a bad primary signature, a header CRC mismatch, a partition
array CRC mismatch, entries that overlap, entries that run past the last usable
LBA, and a layout whose named partitions are not the ones this product has.

This module does no I/O of its own beyond reading a file-like object, and it
never writes. It is used by the .img validator, by the USB recovery backend and
by the on-device probe, so that all three agree on what a partition is.
"""

import binascii
import struct
import uuid

SECTOR = 512

_GPT_SIGNATURE = b"EFI PART"
_HEADER_FMT = "<8sIIIIQQQQ16sQIII"
_HEADER_SIZE = struct.calcsize(_HEADER_FMT)      # 92
_ENTRY_FMT = "<16s16sQQQ72s"
_ENTRY_SIZE = struct.calcsize(_ENTRY_FMT)        # 128

# The ten partitions this product actually has, in device order, as recorded
# from a real Ender-3 V3 KE. Source of truth for the NAMES and their ORDER:
#   artifacts/parity/stock/12-dev-tree.txt
#   artifacts/parity/custom/12-dev-tree.txt
# (/dev/disk/by-partlabel/* plus /dev/disk/by-path/*-part1..10)
#
# Those captures prove which labels exist and that there are exactly ten
# partitions. They do NOT record which of sn_mac/rtos/rtos2 is p2, p3 and p4 -
# a directory listing is unordered. That gap is why partition identity here is
# resolved BY LABEL and never by index: every lookup in this module asks for
# "kernel2", not "partition 6", so an unknown ordering among the three
# partitions we never touch cannot misdirect a write.
EXPECTED_LABELS = frozenset(
    {
        "ota",
        "sn_mac",
        "rtos",
        "rtos2",
        "kernel",
        "kernel2",
        "rootfs",
        "rootfs2",
        "rootfs_data",
        "userdata",
    }
)

# Partitions a NebulaOS install may write, ever, by any transport. Slot 1 is
# Creality's and is not ours to touch; the marker is written by a separate,
# deliberate primitive; the data partitions belong to the user.
WRITABLE_LABELS = frozenset({"kernel2", "rootfs2"})

# Never writable, named explicitly so a refusal can say which rule was hit
# rather than merely "not in the allowlist".
STOCK_LABELS = frozenset({"kernel", "rootfs"})

# Known capacities, from scripts/flash-spare-slot.sh, which has enforced them
# against real hardware since before this module existed.
KERNEL_PART_BYTES = 8388608
ROOTFS_PART_BYTES = 524288000


class GPTError(Exception):
    """The table is not one we are willing to act on."""


class Partition:
    __slots__ = ("index", "label", "type_guid", "part_uuid", "first_lba", "last_lba", "attrs")

    def __init__(self, index, label, type_guid, part_uuid, first_lba, last_lba, attrs):
        self.index = index
        self.label = label
        self.type_guid = type_guid
        self.part_uuid = part_uuid
        self.first_lba = first_lba
        self.last_lba = last_lba
        self.attrs = attrs

    @property
    def offset(self):
        """Byte offset of the partition's first sector."""
        return self.first_lba * SECTOR

    @property
    def size(self):
        """Length in bytes. GPT last_lba is INCLUSIVE - the +1 is not an
        off-by-one, its absence would be."""
        return (self.last_lba - self.first_lba + 1) * SECTOR

    def __repr__(self):
        return "Partition(p%d %r off=0x%x size=%d)" % (
            self.index, self.label, self.offset, self.size
        )


def _guid_str(raw):
    """GPT stores GUIDs mixed-endian: first three fields little-endian, last two
    big-endian. uuid.UUID(bytes_le=...) is exactly that convention."""
    return str(uuid.UUID(bytes_le=raw))


def _decode_label(raw):
    """UTF-16LE, NUL-padded to 72 bytes."""
    text = raw.decode("utf-16-le", errors="replace")
    return text.split("\x00", 1)[0]


class GPT:
    """A parsed, validated primary GPT."""

    def __init__(self, header, partitions, alternate_ok, alternate_note):
        self.header = header
        self.partitions = partitions
        self.alternate_ok = alternate_ok
        self.alternate_note = alternate_note

    # -- lookup ------------------------------------------------------------
    def by_label(self, label):
        for part in self.partitions:
            if part.label == label:
                return part
        raise GPTError(
            "no partition labelled %r in this table (present: %s)"
            % (label, ", ".join(sorted(p.label for p in self.partitions)))
        )

    def labels(self):
        return {p.label for p in self.partitions}

    # -- the check that makes a parse usable -------------------------------
    def validate_ke_layout(self):
        """Prove this table belongs to an Ender-3 V3 KE before anything acts on it.

        Returns a list of human-readable notes on success; raises GPTError with
        the first disqualifying fact otherwise. Notes are not warnings to be
        ignored - they are facts the caller should print alongside its own
        verdict.
        """
        notes = []

        found = self.labels()
        if found != EXPECTED_LABELS:
            missing = sorted(EXPECTED_LABELS - found)
            extra = sorted(found - EXPECTED_LABELS)
            raise GPTError(
                "partition labels do not match the Ender-3 V3 KE layout.\n"
                "       missing: %s\n"
                "       unexpected: %s\n"
                "       Refusing: this is either a different product or a repartitioned device."
                % (missing or "(none)", extra or "(none)")
            )

        if len(self.partitions) != 10:
            raise GPTError(
                "expected exactly 10 partitions, found %d" % len(self.partitions)
            )

        # Capacity checks on the two partitions we are ever allowed to write.
        # These are the numbers flash-spare-slot.sh has enforced on real
        # hardware; a device whose slot-2 partitions are a different size is not
        # one this project knows how to install onto.
        for label, expect in (("kernel2", KERNEL_PART_BYTES), ("rootfs2", ROOTFS_PART_BYTES)):
            part = self.by_label(label)
            if part.size != expect:
                raise GPTError(
                    "partition %r is %d bytes, expected %d.\n"
                    "       Refusing rather than writing a payload sized for a different layout."
                    % (label, part.size, expect)
                )
            notes.append("%s: offset=0x%x size=%d OK" % (label, part.offset, part.size))

        # The slot-1 partitions must be the same size as their slot-2 twins.
        # If they are not, the A/B model this project assumes does not hold on
        # this device and no install plan derived from it is safe.
        for a, b in (("kernel", "kernel2"), ("rootfs", "rootfs2")):
            pa, pb = self.by_label(a), self.by_label(b)
            if pa.size != pb.size:
                raise GPTError(
                    "slot asymmetry: %r is %d bytes but %r is %d bytes.\n"
                    "       The A/B slot model assumes matched pairs; refusing."
                    % (a, pa.size, b, pb.size)
                )

        ota = self.by_label("ota")
        if ota.size < SECTOR:
            raise GPTError("the ota marker partition is smaller than one sector")
        notes.append("ota: offset=0x%x size=%d" % (ota.offset, ota.size))

        sn_mac = self.by_label("sn_mac")
        notes.append("sn_mac: offset=0x%x size=%d" % (sn_mac.offset, sn_mac.size))

        if not self.alternate_ok:
            # Expected on this product. Reported, never fatal - see the module
            # docstring and the captured dmesg it cites.
            notes.append(
                "alternate GPT: %s (expected on this product - the factory image "
                "ships an invalid backup GPT; the primary is authoritative)"
                % self.alternate_note
            )
        else:
            notes.append("alternate GPT: valid")

        return notes


def _read_at(stream, offset, length):
    stream.seek(offset)
    data = stream.read(length)
    if len(data) != length:
        raise GPTError(
            "short read at offset 0x%x: wanted %d bytes, got %d" % (offset, length, len(data))
        )
    return data


def parse(stream, check_alternate=True):
    """Parse and validate the PRIMARY GPT from a seekable binary stream.

    `stream` is anything with seek/read - a file, a BytesIO, or the USB
    backend's device shim. Nothing here assumes a real block device, which is
    what lets the whole stack be tested against an image file.
    """
    # LBA0 is the protective MBR. Its only job here is to catch a stream that is
    # not a disk at all; its content is not otherwise used.
    mbr = _read_at(stream, 0, SECTOR)
    if mbr[510:512] != b"\x55\xaa":
        raise GPTError("no MBR boot signature at LBA0 - this is not a partitioned disk image")

    raw = _read_at(stream, SECTOR, SECTOR)
    fields = struct.unpack(_HEADER_FMT, raw[:_HEADER_SIZE])
    (
        signature, revision, header_size, header_crc, _reserved,
        current_lba, backup_lba, first_usable, last_usable,
        disk_guid, entries_lba, entry_count, entry_size, entries_crc,
    ) = fields

    if signature != _GPT_SIGNATURE:
        raise GPTError(
            "primary GPT signature is %r, expected %r - refusing to guess at a layout"
            % (signature, _GPT_SIGNATURE)
        )

    if header_size < _HEADER_SIZE or header_size > SECTOR:
        raise GPTError("implausible GPT header size %d" % header_size)

    # The header CRC is computed with its own field zeroed. Getting this wrong
    # makes every valid table look corrupt, so it is spelled out rather than
    # folded into a helper.
    zeroed = bytearray(raw[:header_size])
    zeroed[16:20] = b"\x00\x00\x00\x00"
    if binascii.crc32(bytes(zeroed)) & 0xFFFFFFFF != header_crc:
        raise GPTError("primary GPT header CRC mismatch - the table is damaged")

    if entry_size < _ENTRY_SIZE or entry_size % 8:
        raise GPTError("implausible GPT entry size %d" % entry_size)
    if entry_count == 0 or entry_count > 512:
        raise GPTError("implausible GPT entry count %d" % entry_count)

    array = _read_at(stream, entries_lba * SECTOR, entry_count * entry_size)
    if binascii.crc32(array) & 0xFFFFFFFF != entries_crc:
        raise GPTError("GPT partition array CRC mismatch - the table is damaged")

    partitions = []
    for i in range(entry_count):
        chunk = array[i * entry_size:(i + 1) * entry_size]
        type_guid, part_guid, first_lba, last_lba, attrs, name = struct.unpack(
            _ENTRY_FMT, chunk[:_ENTRY_SIZE]
        )
        # An all-zero type GUID means "unused slot", not "a partition at LBA 0".
        if type_guid == b"\x00" * 16:
            continue
        if last_lba < first_lba:
            raise GPTError("entry %d ends before it starts" % (i + 1))
        if last_lba > last_usable:
            raise GPTError(
                "entry %d (%r) ends at LBA %d, past the last usable LBA %d"
                % (i + 1, _decode_label(name), last_lba, last_usable)
            )
        if first_lba < first_usable:
            raise GPTError(
                "entry %d (%r) starts at LBA %d, before the first usable LBA %d"
                % (i + 1, _decode_label(name), first_lba, first_usable)
            )
        partitions.append(
            Partition(
                index=i + 1,
                label=_decode_label(name),
                type_guid=_guid_str(type_guid),
                part_uuid=_guid_str(part_guid),
                first_lba=first_lba,
                last_lba=last_lba,
                attrs=attrs,
            )
        )

    if not partitions:
        raise GPTError("the GPT contains no used entries")

    # Overlap is the one structural error that turns a correct-looking write into
    # a write that destroys a neighbour, so it is checked explicitly rather than
    # trusted to the vendor's table.
    ordered = sorted(partitions, key=lambda p: p.first_lba)
    for prev, nxt in zip(ordered, ordered[1:]):
        if nxt.first_lba <= prev.last_lba:
            raise GPTError(
                "partitions %r (p%d) and %r (p%d) overlap - refusing to derive any offset "
                "from this table" % (prev.label, prev.index, nxt.label, nxt.index)
            )

    duplicates = {p.label for p in partitions if sum(1 for q in partitions if q.label == p.label) > 1}
    if duplicates:
        raise GPTError(
            "duplicate partition label(s): %s. A lookup by label would be ambiguous."
            % ", ".join(sorted(duplicates))
        )

    alternate_ok, alternate_note = True, "valid"
    if check_alternate:
        alternate_ok, alternate_note = _check_alternate(stream, backup_lba)

    header = {
        "revision": revision,
        "disk_guid": _guid_str(disk_guid),
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable_lba": first_usable,
        "last_usable_lba": last_usable,
        "entries_lba": entries_lba,
        "entry_count": entry_count,
        "entry_size": entry_size,
    }
    return GPT(header, partitions, alternate_ok, alternate_note)


def _check_alternate(stream, backup_lba):
    """Report on the alternate GPT without ever making it fatal.

    On this product it is expected to be invalid (see module docstring). The
    caller gets a fact, not a verdict.
    """
    try:
        raw = _read_at(stream, backup_lba * SECTOR, SECTOR)
    except GPTError:
        return False, "not present (stream ends before the backup LBA)"
    if raw[:8] != _GPT_SIGNATURE:
        return False, "invalid signature"
    try:
        header_size = struct.unpack("<I", raw[12:16])[0]
        if header_size < _HEADER_SIZE or header_size > SECTOR:
            return False, "implausible header size"
        stored = struct.unpack("<I", raw[16:20])[0]
        zeroed = bytearray(raw[:header_size])
        zeroed[16:20] = b"\x00\x00\x00\x00"
        if binascii.crc32(bytes(zeroed)) & 0xFFFFFFFF != stored:
            return False, "header CRC mismatch"
    except struct.error:
        return False, "unparseable"
    return True, "valid"


def describe(gpt):
    """A stable, greppable rendering used by every caller that reports a layout."""
    lines = [
        "GPT_DISK_GUID=%s" % gpt.header["disk_guid"],
        "GPT_FIRST_USABLE_LBA=%d" % gpt.header["first_usable_lba"],
        "GPT_LAST_USABLE_LBA=%d" % gpt.header["last_usable_lba"],
        "GPT_ENTRY_COUNT=%d" % gpt.header["entry_count"],
        "GPT_ALTERNATE_OK=%s" % ("YES" if gpt.alternate_ok else "NO"),
        "GPT_ALTERNATE_NOTE=%s" % gpt.alternate_note,
        "GPT_PARTITION_COUNT=%d" % len(gpt.partitions),
    ]
    for part in sorted(gpt.partitions, key=lambda p: p.index):
        lines.append(
            "GPT_PART_%d=label=%s offset=0x%x size=%d first_lba=%d last_lba=%d partuuid=%s"
            % (part.index, part.label, part.offset, part.size,
               part.first_lba, part.last_lba, part.part_uuid)
        )
    return "\n".join(lines)
