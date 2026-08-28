#!/usr/bin/env python3
"""Offline validator for NebulaOS Phase 1.7 GD32F303 MCU candidates.

Two independent layers of checks, both hard gates (VALIDATOR_PASS=NO implies
FLASHABLE_ARTIFACT=NO - see the Phase 1.7 mission brief, section 27):

  format  - generic Creality MCU image format checks (metadata offset,
            type/separator/reserved bytes, CRC-16/XMODEM, length field,
            65535-byte size ceiling). Applies to ANY Creality mcu0 image,
            including the four known stock fixtures.

  target  - NebulaOS/GD32F303-specific checks: build config values (read
            from the Kconfig .config actually used for the build, not a
            hand-written manifest), vector table contents read directly
            from the packaged binary, and the metadata window's placement
            proven from the ELF section table.

Usage:
    creality_validator.py format <image.bin> [--expect-type mcu0]
    creality_validator.py target <image.bin> <klipper.elf> <.config>
    creality_validator.py selftest <image.bin> <klipper.elf> <.config> <stock_fixture_dir>
"""

import argparse
import re
import struct
import subprocess
import sys

METADATA_OFFSET = 0x200
METADATA_SIZE = 0x10
CRC_FIELD_OFFSET = 0x20C
LENGTH_FIELD_OFFSET = 0x20E
MAX_IMAGE_SIZE = 65535

EXPECTED = {
    "MACH_GD32F303": "y",
    "MACH_GD32F30x": "y",
    "CLOCK_FREQ": "120000000",
    "RAM_SIZE": "0x10000",
    "FLASH_SIZE": "0x80000",
    "FLASH_APPLICATION_ADDRESS": "0x8003000",
    "STM32_FLASH_START_3000": "y",
    "STM32_SERIAL_USART2": "y",
    "SERIAL_BAUD": "230400",
}
RAM_START = 0x20000000
RAM_END = RAM_START + 0x10000
FLASH_APP_START = 0x08003000
FLASH_APP_END = FLASH_APP_START + 0x80000


class ValidationError(Exception):
    pass


def crc16_xmodem(data: bytes) -> int:
    crc = 0x0000
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = (crc << 1) ^ 0x1021
            else:
                crc <<= 1
            crc &= 0xFFFF
    return crc


# ---------------------------------------------------------------------
# Layer 1: generic Creality image format
# ---------------------------------------------------------------------

def validate_format(data: bytes, expect_type: str = None) -> list:
    """Return a list of failure strings; empty list means PASS."""
    fails = []

    if len(data) > MAX_IMAGE_SIZE:
        fails.append(f"size {len(data)} exceeds Creality max {MAX_IMAGE_SIZE}")
        # Still continue other checks where possible, but this alone fails.

    if len(data) < METADATA_OFFSET + METADATA_SIZE:
        fails.append(f"file too short ({len(data)} bytes) to contain metadata window")
        return fails

    header = data[METADATA_OFFSET:METADATA_OFFSET + METADATA_SIZE]
    type_code = header[0:4]
    sep1 = header[4:5]
    version = header[5:8]
    sep2 = header[8:9]
    reserved = header[9:12]
    stored_crc = struct.unpack_from("<H", header, 0x0C)[0]
    stored_len = struct.unpack_from("<H", header, 0x0E)[0]

    try:
        type_str = type_code.decode("ascii")
    except UnicodeDecodeError:
        type_str = None
        fails.append(f"type field is not ASCII: {type_code!r}")
    if type_str is not None and expect_type is not None and type_str != expect_type:
        fails.append(f"type {type_str!r} != expected {expect_type!r}")

    if sep1 != b"_" or sep2 != b"_":
        fails.append(f"malformed separators: {sep1!r} / {sep2!r} (expected b'_')")

    if reserved != b"000":
        fails.append(f"reserved field {reserved!r} != b'000'")

    if not re.match(rb"^[0-9]{3}$", version):
        fails.append(f"version field {version!r} is not 3 ASCII digits")

    if stored_len != len(data):
        fails.append(f"stored length {stored_len} != actual file size {len(data)}")

    masked = bytearray(data)
    masked[CRC_FIELD_OFFSET:CRC_FIELD_OFFSET + 4] = b"\x00\x00\x00\x00"
    computed_crc = crc16_xmodem(bytes(masked))
    if stored_crc != computed_crc:
        fails.append(f"stored CRC 0x{stored_crc:04X} != computed 0x{computed_crc:04X}")

    return fails


# ---------------------------------------------------------------------
# Layer 2: NebulaOS GD32F303 target-specific checks
# ---------------------------------------------------------------------

def parse_dotconfig(path: str) -> dict:
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, val = line.split("=", 1)
            key = key.removeprefix("CONFIG_")
            cfg[key] = val
    return cfg


def validate_config(cfg: dict) -> list:
    fails = []
    for key, expected in EXPECTED.items():
        actual = cfg.get(key)
        if actual != expected:
            fails.append(f"config {key}={actual!r} != expected {expected!r}")
    return fails


def validate_vector_table(data: bytes) -> list:
    fails = []
    if len(data) < 8:
        return ["file too short to contain a vector table"]
    initial_sp = struct.unpack_from("<I", data, 0)[0]
    reset_vector = struct.unpack_from("<I", data, 4)[0]

    if not (RAM_START <= initial_sp <= RAM_END):
        fails.append(f"initial SP 0x{initial_sp:08X} outside SRAM "
                      f"[0x{RAM_START:08X}, 0x{RAM_END:08X}]")
    if reset_vector & 1 == 0:
        fails.append(f"reset vector 0x{reset_vector:08X} has Thumb bit clear")
    target = reset_vector & ~1
    if not (FLASH_APP_START <= target < FLASH_APP_END):
        fails.append(f"reset vector target 0x{target:08X} outside app flash "
                      f"[0x{FLASH_APP_START:08X}, 0x{FLASH_APP_END:08X})")
    return fails


def readelf_sections(elf_path: str) -> dict:
    """name -> (addr, size) using readelf -S (no external python ELF lib needed)."""
    out = subprocess.check_output(
        ["arm-none-eabi-readelf", "-S", "--wide", elf_path], text=True)
    sections = {}
    for line in out.splitlines():
        m = re.match(r"\s*\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)", line)
        if m:
            name, addr, size = m.groups()
            sections[name] = (int(addr, 16), int(size, 16))
    return sections


def validate_elf(elf_path: str) -> list:
    fails = []
    try:
        sections = readelf_sections(elf_path)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        return [f"could not read ELF sections: {e}"]

    if ".creality_metadata" not in sections:
        fails.append("ELF has no .creality_metadata section - metadata window not reserved")
        return fails

    addr, size = sections[".creality_metadata"]
    if addr != FLASH_APP_START + METADATA_OFFSET:
        fails.append(f".creality_metadata at 0x{addr:08X}, expected "
                      f"0x{FLASH_APP_START + METADATA_OFFSET:08X}")
    if size != METADATA_SIZE:
        fails.append(f".creality_metadata size {size}, expected {METADATA_SIZE}")

    if ".text_app" in sections:
        app_addr, _ = sections[".text_app"]
        expect = FLASH_APP_START + METADATA_OFFSET + METADATA_SIZE
        if app_addr != expect:
            fails.append(f".text_app at 0x{app_addr:08X}, expected 0x{expect:08X} "
                          "(metadata insertion has shifted code)")

    try:
        out = subprocess.check_output(["arm-none-eabi-readelf", "-A", elf_path], text=True)
        if "v7E-M" not in out and "Cortex-M4" not in out:
            fails.append(f"ARM attributes do not indicate Cortex-M4/v7E-M: {out!r}")
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        fails.append(f"could not read ARM attributes: {e}")

    return fails


def validate_target(image_path: str, elf_path: str, config_path: str) -> list:
    with open(image_path, "rb") as f:
        data = f.read()
    fails = []
    fails += validate_config(parse_dotconfig(config_path))
    fails += validate_vector_table(data)
    fails += validate_elf(elf_path)
    return fails


# ---------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------

def _report(name: str, fails: list) -> bool:
    if fails:
        print(f"{name}: FAIL")
        for f in fails:
            print(f"  - {f}")
        return False
    print(f"{name}: PASS")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_fmt = sub.add_parser("format")
    p_fmt.add_argument("image")
    p_fmt.add_argument("--expect-type", default=None)

    p_tgt = sub.add_parser("target")
    p_tgt.add_argument("image")
    p_tgt.add_argument("elf")
    p_tgt.add_argument("config")

    args = ap.parse_args()

    if args.cmd == "format":
        with open(args.image, "rb") as f:
            data = f.read()
        ok = _report(f"format({args.image})", validate_format(data, args.expect_type))
        sys.exit(0 if ok else 1)

    if args.cmd == "target":
        fails = validate_target(args.image, args.elf, args.config)
        with open(args.image, "rb") as f:
            data = f.read()
        fails = validate_format(data, "mcu0") + fails
        ok = _report(f"target({args.image})", fails)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
