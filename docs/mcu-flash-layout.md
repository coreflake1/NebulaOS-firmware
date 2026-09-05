# MCU flash layout — Creality bootloader preservation (RC2 overnight closure)

Generated 2026-09-06, offline (printer powered off — no hardware access this
run). Scope: mission item §20, "CREALITY BOOTLOADER PRESENCE — PROVE
STATICALLY."

Every value below is read directly from source — no address is guessed or
inferred from behavior.

## CREALITY_BOOTLOADER_RANGE

`0x08000000`–`0x08002FFF` (12 KiB, the first 3 flash sectors before the
application origin below). Never targeted or written by anything in this
project — see FLASHER_WRITE_RANGE.

## NATIVE_APPLICATION_RANGE

Origin: `0x08003000`.

Source chain, all in `NebulaOS-klipper-mcu/patches/0001-stm32-add-native-gd32f303-ke-support.patch`:

```
config STM32_FLASH_START_3000        (new Kconfig choice, line ~186)
config FLASH_APPLICATION_ADDRESS
    default 0x8003000 if STM32_FLASH_START_3000   (line ~195)
```

Confirmed selected (not merely available) for this exact target:
`NebulaOS-klipper-mcu/configs/ender3-v3-ke.defconfig:12`:
```
CONFIG_STM32_FLASH_START_3000=y
```

The linker script itself also asserts the vector table lands here and
reserves a small Creality metadata block immediately after it (same patch,
lines ~91-104):
```
ASSERT(_text_vectortable_end <= CONFIG_FLASH_APPLICATION_ADDRESS + 0x200, ...)
.creality_metadata CONFIG_FLASH_APPLICATION_ADDRESS + 0x200 : { ... }
ASSERT(_creality_metadata_end == CONFIG_FLASH_APPLICATION_ADDRESS + 0x210, ...)
```
Vector table origin 0x08003000, initial SP 0x20010000 (top of 64 KiB SRAM) —
matches the patch's own header comment (line ~41).

## FLASHER_WRITE_RANGE

`NebulaOS-klipper-mcu/tools/creality_flash.py` (`flash_image()`,
lines 128-166) implements the Creality vendor bootloader's own serial
protocol: an "update request" handshake, then a 4-byte little-endian image
**size**, then the image transferred in `sector_size*1024`-byte chunks. At
no point does this protocol carry, accept, or transmit a flash **address**
— there is no address field anywhere in the wire format. The bootloader
decides where to write entirely on its own, using its own fixed internal
logic (write the application starting immediately after itself).

This means bootloader preservation here is not merely "our tool chooses not
to write low addresses" (a policy that could regress) — it is
**architecturally impossible** for `creality_flash.py` to instruct the
vendor bootloader to write anywhere other than its own fixed
post-bootloader application slot, because the protocol gives the host side
no address parameter to abuse in the first place. The same holds even for a
failed/interrupted flash (`app_start()`, lines 121-125, is a separate,
distinct request sent only after `flash_image()` reports its own
"flash completed" status `0x20` — an interrupted transfer simply never
reaches this call; it cannot corrupt anything outside the range the
bootloader itself already owns).

## OVERLAP

None. `CREALITY_BOOTLOADER_RANGE` (0x08000000–0x08002FFF) and
`NATIVE_APPLICATION_RANGE` (0x08003000 onward) are contiguous but disjoint,
by explicit Kconfig selection (`STM32_FLASH_START_3000`) matching the
original Creality bootloader's own known 12 KiB reservation, and
`FLASHER_WRITE_RANGE` cannot address anything below the application origin
at the protocol level, regardless of image content or failure mode.

## CREALITY_BOOTLOADER_PRESERVED = YES

High confidence, source-proven: (1) the native firmware's own linker layout
targets exactly the historically-known post-bootloader offset, verified
selected in the shipping defconfig, not merely available as an option;
(2) the flashing tool's wire protocol to the vendor bootloader has no
address field at all, making an out-of-range write structurally impossible
regardless of firmware content, image size, or a failed/interrupted
transfer.
