#!/bin/sh
# Applies the host-MCU accelerometer/EEPROM bus enablement fix (Phase 1.9A
# Host MCU + ADXL345 + BL24C16F Hardware Restoration, the follow-on
# Phase 1.9A SPI Polarity Fix Investigation, and Phase 1.9B's at24/nvmem
# production EEPROM ownership change) to the vendor kernel checkout and its
# Kconfig fragment.
#
# No new kernel driver source is involved here (CONFIG_SPI_GPIO and
# CONFIG_EEPROM_AT24 are existing upstream options, not NebulaOS code), so
# unlike backlight-final-controller-variant.sh/pwm-state-readback-variant.sh
# there is no scripts/build/patches/*.patch for this variant - the DTS and
# Kconfig fragment content are appended directly by this script, using the
# exact same marker-wrapped, append-only discipline those two scripts use
# for the pieces they own.
#
# THIS IS THE ONLY SCRIPT ALLOWED TO ADD/REMOVE THE
#   NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_DTS_BEGIN/END
# block in kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts, and
# the matching NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_BEGIN/END
# block in halley5-nebulaos-fragment.config.
#
# IMPORTANT - the DTS is shared with wifi-sdio-variant.sh, display-vsync-
# variant.sh, backlight-final-controller-variant.sh, pwm-state-readback-
# variant.sh, and touch-final-qualification-variant.sh. Deliberately NOT a
# blanket `git checkout -- <dts>` here - see those scripts' own headers for
# the real, confirmed bug this causes (a composed qualification build
# silently losing one script's DT node because another script's blanket
# checkout wiped it after the fact). This script's own DTS edit is two
# wholly self-contained, marker-wrapped top-level fragments appended at the
# end of the file (a `&i2c2 { ... }` merge fragment and a new
# `/ { aliases {...}; spi_gpio_adxl345 {...}; }` merge fragment) - it never
# edits any EXISTING line any other variant script owns, so switching this
# script back and forth can never wipe out a sibling script's edits
# regardless of run order, and vice versa. Node-reference fragments
# (`&label { ... }`) merge into the referenced node wherever they appear in
# the file, so appending at EOF rather than near the original &i2c2/&spi0
# nodes is semantically identical to dtc.
#
# Background: our board's own DTS never enabled a usable bus for either
# chip. Pulled and decoded the real stock device's own live
# /sys/firmware/fdt as ground truth for both:
#   - ADXL345 (spi_bus: spidev2.0 in printer.cfg) is not on a real
#     hardware SPI controller at all - stock reaches it via the mainline
#     spi-gpio bitbang driver at gpe16/17/18/21, aliased spi2, with a
#     generic spidev placeholder child. Requires CONFIG_SPI_GPIO=y.
#     Deliberately named spi_gpio_adxl345, NOT spi_gpio: this base board
#     file already has an unrelated, pre-existing, disabled "/spi_gpio"
#     node elsewhere (gpb 28-31, spidev1@0 - the FACTORY_TEST_DEVICE
#     placeholder) that a node declared here with that same bare name
#     would silently merge with instead of creating a separate node
#     (found live: our first attempt at this had its pin numbers and
#     status overwritten by that node).
#   - The physical BL24C16F EEPROM needs &i2c2 enabled with the
#     already-defined-but-unused i2c2_pb pinmux group (mirroring the
#     existing i2c4/i2c4_pc touch fix already in this same file). Phase
#     1.9A originally reached this chip via [bl24c16f] (a NebulaOS Klipper
#     extra running on klipper_mcu's virtual "rpi" MCU, needing
#     CONFIG_I2C_CHARDEV=y so its own i2c.c could open /dev/i2c-<bus>
#     directly). Phase 1.9B retires that production ownership in favor of
#     the generic in-tree at24/nvmem driver (CONFIG_EEPROM_AT24=y) binding
#     directly to a real eeprom@50 child node below - see that node's own
#     comment for the full driver-compatibility rationale. CONFIG_I2C_
#     CHARDEV is dropped accordingly (see the Kconfig fragment append
#     below) - nothing else on this board needs a userspace i2c-chardev
#     consumer.
#
# Polarity fix (Phase 1.9A SPI Polarity Fix Investigation): the first
# working revision of this variant copied stock's raw flags=0x01
# (GPIO_ACTIVE_LOW) verbatim onto all four spi-gpio lines. That got the
# bus probing (spidev2.0 existed, transactions happened) but produced
# corrupt reads (ACCELEROMETER_QUERY: wrong DEVID, value changing with
# spi_speed - evidence of electrical inversion, not a clean failure).
# Source-verified root cause: this kernel's spi-gpio.c (the modern
# gpiod-based rewrite) applies gpiod_set_value_cansleep()/
# gpiod_get_value_cansleep() active-low inversion to sck/mosi/miso
# exactly the same as it does to cs - stock's raw value was almost
# certainly meaningful only for cs under an older, non-gpiod
# implementation. Fix: sck-gpios/mosi-gpios/miso-gpios all
# GPIO_ACTIVE_HIGH (no inversion); cs-gpios stays GPIO_ACTIVE_LOW (matches
# stock's raw value AND genuine chip-select-active-low hardware
# semantics). Modern <name>-gpios property names used throughout (not the
# legacy gpio-<name> form), matching what drivers/spi/spi-gpio.c's own
# probe actually resolves via devm_gpiod_get(). Live-verified on real
# hardware: ACCELEROMETER_QUERY CHIP=adxl345 now returns real motion data
# with no DEVID mismatch.
#
#   FIX0 (default/pristine): baseline halley5_v30.dts and Kconfig fragment,
#       unmodified - no spi2/i2c2 bus for either chip, matching the
#       original Phase 1.9A hardware-qualification failure (mcu.error:
#       Unable to open spi device).
#   FIX1: appends the DTS fragments above (including the at24 eeprom@50
#       child node) plus CONFIG_SPI_GPIO=y/CONFIG_EEPROM_AT24=y to the
#       Kconfig fragment (the corrected, GPIO_ACTIVE_HIGH-on-clock/data-
#       lines, at24-owned-EEPROM revision).
#
# Same "always reset to the real git-committed baseline first" pattern as
# the sibling variant scripts for the files each one exclusively owns.
#
# IMPORTANT: never run this script while any build against this same
# vendor kernel checkout is in flight - see the equivalent warning in the
# other *-variant.sh scripts.
#
# Usage: sh scripts/build/accelerometer-eeprom-bus-enable-variant.sh <FIX0|FIX1>

set -eu

VARIANT="${1:?usage: $0 <FIX0|FIX1>}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
KERNEL_DIR="$REPO_ROOT/vendor/x2000_kernel_6.6"
DTS_REL="kernel/kernel-6.6/module_drivers/dts/x2000/halley5_v30.dts"
DTS="$KERNEL_DIR/$DTS_REL"
FRAGMENT="$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config"
MARKER="$REPO_ROOT/build-work/accelerometer-eeprom-bus-enable-variant-applied.txt"

# Plain alphanumeric+underscore only, same rationale as the sibling
# scripts' DTS_MARK_BEGIN/END - used directly as an unanchored sed
# /pattern/ substring match, avoiding any need to regex-escape the /* */
# C-comment delimiters wrapped around it in the DTS.
DTS_MARK_BEGIN="NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_DTS_BEGIN"
DTS_MARK_END="NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_DTS_END"
BEGIN_MARK="#--- NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_BEGIN ---"
END_MARK="#--- NEBULAOS_ACCELEROMETER_EEPROM_BUS_ENABLE_VARIANT_END ---"

case "$VARIANT" in
	FIX0|FIX1) ;;
	*)
		echo "unknown variant '$VARIANT' - must be one of FIX0 FIX1" >&2
		exit 1
		;;
esac

[ -f "$DTS" ] || {
	echo "FATAL: $DTS not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
}
[ -f "$FRAGMENT" ] || {
	echo "FATAL: $FRAGMENT not found" >&2
	exit 1
}

# Strip any previously-applied blocks first, unconditionally - same
# idempotent pattern as the sibling variant scripts. Scoped sed range
# delete, never a blanket checkout of the shared DTS.
if grep -qF "$DTS_MARK_BEGIN" "$DTS"; then
	sed -i "/${DTS_MARK_BEGIN}/,/${DTS_MARK_END}/d" "$DTS"
fi
if grep -qF "$BEGIN_MARK" "$FRAGMENT"; then
	sed -i "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/d" "$FRAGMENT"
fi

X2000_DTSI="$KERNEL_DIR/kernel/kernel-6.6/module_drivers/dts/x2000/x2000.dtsi"
if ! grep -q 'i2c2: i2c@' "$X2000_DTSI" 2>/dev/null; then
	echo "FATAL: could not find the base i2c2 node in $X2000_DTSI - has the SoC DTSI changed?" >&2
	exit 1
fi
if ! grep -q '^&i2c4 {' "$DTS"; then
	echo "FATAL: could not find the &i2c4 node in $DTS - has the board DTS changed?" >&2
	exit 1
fi
if grep -q '^	spi_gpio_adxl345 {' "$DTS"; then
	echo "FATAL: a spi_gpio_adxl345 node already exists in $DTS outside this script's own marker block - refusing to risk a duplicate/collision." >&2
	exit 1
fi

if [ "$VARIANT" = "FIX1" ]; then
	# Append-only: two new top-level merge fragments (&i2c2 override,
	# and a new aliases+spi_gpio_adxl345 node). Neither touches any
	# EXISTING line in the file - see the file header above.
	{
		echo "/* $DTS_MARK_BEGIN */"
		echo "&i2c2 {"
		echo "	/* Phase 1.9A host-MCU accelerometer/EEPROM bus enablement:"
		echo "	 * the physical BL24C16F EEPROM is wired here on the real Ender 3 V3"
		echo "	 * KE, physically identical hardware to i2c4/touch above. Pulled and"
		echo "	 * decoded the real stock device's own live /sys/firmware/fdt -"
		echo "	 * stock's own i2c2 node is disabled with no pinctrl (it evidently"
		echo "	 * reaches this bus through a different, proprietary path, not this"
		echo "	 * standard in-tree driver), but the i2c2-pb pinmux group already"
		echo "	 * exists unused in our own x2000-pinctrl.dtsi, exactly mirroring the"
		echo "	 * i2c4-pc fix below."
		echo "	 *"
		echo "	 * Phase 1.9B production EEPROM owner change: the eeprom@50 child"
		echo "	 * node below is the Linux 6.6 in-tree at24/nvmem driver, NOT"
		echo "	 * [bl24c16f] (which owned this same chip directly over"
		echo "	 * i2c_mcu:rpi/i2c-chardev in Phase 1.9A and is retired from"
		echo "	 * production use as of Phase 1.9B - see machine.cfg and"
		echo "	 * nebulaos_power_loss_recovery.py). The BL24C16F is electrically"
		echo "	 * and functionally an Atmel 24C16 - same 2048 bytes, same 16-byte"
		echo "	 * write page, same 8-bit internal address split across 8 I2C slave"
		echo "	 * addresses (0x50..0x57) - so the exact, unmodified upstream"
		echo "	 * \"atmel,24c16\" compatible string and binding apply verbatim; no"
		echo "	 * newer \"belling,bl24c16f\" compatible name or kernel upgrade is"
		echo "	 * needed. Source-verified against this exact kernel's own"
		echo "	 * drivers/misc/eeprom/at24.c: CONFIG_EEPROM_AT24 depends on I2C &&"
		echo "	 * SYSFS (both already satisfied) and selects NVMEM/NVMEM_SYSFS/"
		echo "	 * REGMAP/REGMAP_I2C automatically; \"pagesize\"/\"address-width\"/"
		echo "	 * \"size\"/\"num-addresses\" are exactly the device_property_read_u32()"
		echo "	 * names this driver's own at24_probe() parses. Resulting userspace"
		echo "	 * interface: /sys/bus/i2c/devices/2-0050/eeprom (the reg = <0x50>"
		echo "	 * address below, on i2c bus 2). CONFIG_I2C_CHARDEV is dropped from"
		echo "	 * the Kconfig fragment below in this same Phase 1.9B change - at24"
		echo "	 * is a real kernel driver (binds to the i2c_client directly, no"
		echo "	 * /dev/i2c-* character device involved), and with [bl24c16f]"
		echo "	 * retired, nothing else on this board's i2c_mcu:rpi bus needs"
		echo "	 * /dev/i2c-* chardev access any more (ADXL345 is SPI, not I2C). */"
		echo "	status = \"okay\";"
		echo "	pinctrl-names = \"default\";"
		echo "	pinctrl-0 = <&i2c2_pb>;"
		echo ""
		echo "	eeprom@50 {"
		echo "		/* Physical page 0 (bytes 0..15) is reserved for stock"
		echo "		 * Creality's own PLR checkpoint-slot-pointer/enabled-state"
		echo "		 * bytes - nebulaos_plr_journal.py (NebulaOS-klipper-extensions)"
		echo "		 * never reads or writes that page, only pages 1..127. */"
		echo "		compatible = \"atmel,24c16\";"
		echo "		reg = <0x50>;"
		echo "		pagesize = <16>;"
		echo "		size = <2048>;"
		echo "		address-width = <8>;"
		echo "		num-addresses = <8>;"
		echo "		label = \"nebulaos-plr\";"
		echo "	};"
		echo "};"
		echo
		echo "/* Phase 1.9A host-MCU accelerometer/EEPROM bus enablement:"
		echo " * ADXL345 (spi_bus: spidev2.0 in printer.cfg) is NOT wired to a real"
		echo " * Ingenic hardware SPI controller on this board at all - pulled and"
		echo " * decoded the real stock device's own live /sys/firmware/fdt and found"
		echo " * stock reaches it through the standard mainline spi-gpio bitbang"
		echo " * driver instead, with a generic spidev placeholder child exposing it"
		echo " * as a plain character device (exactly what Klipper's own MCU SPI"
		echo " * backend expects - it talks to the sensor directly, no in-kernel"
		echo " * ADXL345 driver needed). GPIO pin assignments (gpe16/17/18/21) and the"
		echo " * \"rohm,dh2228fv\" placeholder compatible string are copied verbatim"
		echo " * from that same live dump, not guessed. Requires CONFIG_SPI_GPIO=y. */"
		echo "/ {"
		echo "	aliases {"
		echo "		/* Pins this bit-banged bus to bus number 2, exactly matching"
		echo "		 * stock's own \"spi2 = /spi_gpio\" alias - without this, Linux"
		echo "		 * would assign whatever bus number registration order happens"
		echo "		 * to produce, and Klipper's spi_bus: spidev2.0 (hardcoded to"
		echo "		 * this exact path) would not find the device."
		echo "		 *"
		echo "		 * Deliberately named spi_gpio_adxl345, NOT spi_gpio: this base"
		echo "		 * board file already has an unrelated, pre-existing, disabled"
		echo "		 * \"/spi_gpio\" node further down (gpb 28-31, spidev1@0 - the"
		echo "		 * already-documented FACTORY_TEST_DEVICE placeholder). A node"
		echo "		 * declared here with that same bare name would silently merge"
		echo "		 * with it instead of creating a separate node (found live: our"
		echo "		 * first attempt at this had its pin numbers and status"
		echo "		 * overwritten by that later block). The alias only cares where"
		echo "		 * it points, not what the node is named, so giving this one"
		echo "		 * its own distinct name avoids the collision entirely without"
		echo "		 * touching the untouched, already-disabled factory node. */"
		echo "		spi2 = \"/spi_gpio_adxl345\";"
		echo "	};"
		echo
		echo "	spi_gpio_adxl345 {"
		echo "		status = \"okay\";"
		echo "		compatible = \"spi-gpio\";"
		echo "		#address-cells = <1>;"
		echo "		#size-cells = <0>;"
		echo "		/* This SoC's ingenic,pincfg-cells binding is 3 cells after the"
		echo "		 * phandle (pin, flags, pull-config) - found live via a dtc"
		echo "		 * \"property size too small for cell size 3\" warning on an"
		echo "		 * earlier attempt, which only had 2."
		echo "		 *"
		echo "		 * Polarity fix (Phase 1.9A SPI Polarity Fix Investigation):"
		echo "		 * stock's raw live-dumped values used flags=0x01"
		echo "		 * (GPIO_ACTIVE_LOW) on ALL FOUR lines, copied verbatim into an"
		echo "		 * earlier attempt here - that produced device probe success"
		echo "		 * (spidev2.0 exists, transactions happen) but garbled reads"
		echo "		 * (ACCELEROMETER_QUERY: \"Invalid adxl345 id\", wrong DEVID,"
		echo "		 * changing with speed rather than a clean timeout)."
		echo "		 * Source-verified root cause: this kernel's spi-gpio.c"
		echo "		 * (drivers/spi/spi-gpio.c, the modern Linus Walleij gpiod"
		echo "		 * rewrite) calls gpiod_set_value_cansleep()/"
		echo "		 * gpiod_get_value_cansleep() for sck/mosi/miso exactly the"
		echo "		 * same way it does for cs - meaning ANY of the four declared"
		echo "		 * GPIO_ACTIVE_LOW gets transparently inverted by gpiod before"
		echo "		 * the bitbang core (spi-bitbang-txrx.h) ever sees it. The"
		echo "		 * bitbang core assumes non-inverted 1=high/0=low semantics"
		echo "		 * for the clock and data lines - stock's raw flags value was"
		echo "		 * almost certainly written for an older, non-gpiod (raw"
		echo "		 * gpio_set_value) spi-gpio implementation that likely never"
		echo "		 * consulted the active-low flag for sck/mosi/miso at all,"
		echo "		 * only for cs (the one line every spi-gpio generation has"
		echo "		 * always treated specially, since chip-select genuinely needs"
		echo "		 * \"asserted\" semantics). Fix: sck/mosi/miso are plain,"
		echo "		 * non-inverted output/input lines here - GPIO_ACTIVE_HIGH."
		echo "		 * cs-gpios keeps ACTIVE_LOW, both because that matches stock's"
		echo "		 * raw value AND because the ADXL345 (like the overwhelming"
		echo "		 * majority of SPI slaves) is genuinely chip-select-active-low"
		echo "		 * in hardware. Pull-config (INGENIC_GPIO_NOBIAS) is unchanged"
		echo "		 * on all four - unrelated to this bug."
		echo "		 *"
		echo "		 * Property names: sck-gpios/mosi-gpios/miso-gpios (not the"
		echo "		 * legacy gpio-sck/gpio-mosi/gpio-miso form used by an earlier"
		echo "		 * attempt here) - confirmed from source"
		echo "		 * (drivers/spi/spi-gpio.c's own probe:"
		echo "		 * devm_gpiod_get(dev, \"sck\", ...) etc, which resolves the"
		echo "		 * \"<name>-gpios\" convention). The legacy names still worked"
		echo "		 * (some fallback in the OF GPIO core resolved them), but the"
		echo "		 * modern names are what this driver actually asks for. */"
		echo "		sck-gpios = <&gpe 16 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		miso-gpios = <&gpe 18 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		mosi-gpios = <&gpe 17 GPIO_ACTIVE_HIGH INGENIC_GPIO_NOBIAS>;"
		echo "		cs-gpios = <&gpe 21 GPIO_ACTIVE_LOW INGENIC_GPIO_NOBIAS>;"
		echo "		num-chipselects = <1>;"
		echo
		echo "		spidev2: spidev@0 {"
		echo "			status = \"okay\";"
		echo "			compatible = \"rohm,dh2228fv\";"
		echo "			reg = <0>;"
		echo "			spi-max-frequency = <5000000>;"
		echo "		};"
		echo "	};"
		echo "};"
		echo "/* $DTS_MARK_END */"
	} >> "$DTS"

	{
		echo "$BEGIN_MARK"
		echo "# Phase 1.9A/1.9B host-MCU accelerometer/EEPROM bus enablement"
		echo "# variant. ADXL345 needs a bit-banged SPI bus (spi-gpio, matching"
		echo "# stock's own real wiring) that this kernel never enabled the"
		echo "# driver for. The physical EEPROM (BL24C16F, electrically an Atmel"
		echo "# 24C16) needs the generic in-tree at24/nvmem driver - depends on"
		echo "# I2C && SYSFS only (both already satisfied), and itself selects"
		echo "# NVMEM/NVMEM_SYSFS/REGMAP/REGMAP_I2C automatically."
		echo "CONFIG_SPI_GPIO=y"
		echo "CONFIG_EEPROM_AT24=y"
		echo "# CONFIG_I2C_CHARDEV deliberately NOT selected (Phase 1.9B): it was"
		echo "# needed in Phase 1.9A only for klipper_mcu's own i2c.c to open"
		echo "# /dev/i2c-* directly on behalf of [bl24c16f] (i2c_mcu:rpi). With"
		echo "# [bl24c16f] retired as the production EEPROM owner in favor of the"
		echo "# real kernel at24 driver above (which binds its i2c_client"
		echo "# directly, no /dev/i2c-* chardev involved), nothing else on this"
		echo "# board uses a userspace i2c-chardev consumer any more - confirmed"
		echo "# by inspecting machine.cfg: [adxl345] is SPI, not I2C, and no"
		echo "# other [xxx] section declares an i2c_mcu/i2c_bus option."
		echo "$END_MARK"
	} >> "$FRAGMENT"
fi

mkdir -p "$(dirname "$MARKER")"
printf '%s\n' "$VARIANT" > "$MARKER"
echo "== accelerometer-eeprom-bus-enable-variant: $VARIANT applied =="
