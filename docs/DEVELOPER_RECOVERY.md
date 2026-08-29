# Recovering a NebulaOS printer

If a development build goes sideways, don't jump straight to USB recovery — there are a few easier
ways back, roughly in order of how bad things have to get before you need them.

## 1. Automatic stock fallback is DISABLED (Phase 1.8B)

**This section describes behavior that has been intentionally removed.** The old automatic stock
fallback (S00revert-safety writing "ota:kernel" on every boot, S99confirm-good flipping it forward
only on success) was removed in Phase 1.8B because booting the stock Creality slot causes it to
auto-flash the MCU with old Creality firmware, destroying the qualified native GD32F303 MCU build.
The risk of silently bricking the MCU outweighs the convenience of automatic rollback.

**Current behavior:** if a NebulaOS boot fails (Klipper doesn't start, Moonraker is unreachable,
etc.), the device stays on NebulaOS. The boot health check (S99confirm-good) still runs and logs
whether Klipper reached "ready" state, but it no longer touches the OTA marker on any code path.
Recovery from a failed boot requires manual intervention — see sections 2 and 3 below.

The `write_ota_marker` function is still available in `/etc/ota_marker.sh` for manual use.

## 2. Switch slots over SSH

If the currently-running OS still has working SSH, this takes about two minutes and no tools.

From custom:
```sh
. /etc/ota_marker.sh
write_ota_marker "ota:kernel"    # or "ota:kernel2" to go the other way
reboot
```

From stock:
```sh
. /etc/ota_bin/ota_local_method.sh
local_set_next_boot_device
reboot
```

This doesn't erase anything on either side — see the persistence table below.

## 3. USB recovery — the panic button

This is what you reach for when networking is dead and you can't get to the custom slot any other
way. It's specifically a way to force the device back to stock, not a general-purpose installer, so
don't expect it to do anything fancier than that.

You'll need:
- A Linux computer (this is the only platform these commands are documented against)
- A USB cable into the Nebula Pad's MicroUSB port
- Possibly opening the case to reach two small buttons next to that port
- `sudo` (plain USB access without it just fails with a permissions error)
- [`ballaswag/ingenic-usbboot`](https://github.com/ballaswag/ingenic-usbboot), built from source — credit to that project for making this recovery path possible at all:
  ```sh
  git clone https://github.com/ballaswag/ingenic-usbboot
  cd ingenic-usbboot
  make
  ```
  The compiled binary ends up named `usbboot`, not `ingenic-usbboot` — that's just the repo's name.
  This is a third-party tool and we don't pin a specific version of it.

Here's the actual procedure, including a couple of gotchas we hit doing this for real:

1. Power off. Hold both buttons for 3 seconds, release the reset button first, then boot. This puts
   the board into mask-ROM USB recovery mode — nothing's running yet, it's just waiting for
   instructions.
2. Optional sanity check: `lsusb`, look for `ID a108:eaef Ingenic Semiconductor Co.,Ltd Ingenic USB
   BOOT DEVICE`.
3. **Load u-boot before you try to swap the marker** — the raw mask-ROM stage doesn't support that
   request at all, and running it first just fails with `Could not open USB device` or a transfer
   error.
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot --swap-ota
   ```
   There's no `--force-swap-ota` flag — `--swap-ota` toggles between the two, it doesn't let you
   pick a side. It prints the state before and after, so read that output.
4. **Don't trust that printed output on its own.** We saw two consecutive runs both print the exact
   same "before/after" text despite actually starting from different states — the raw USB-boot
   session doesn't reliably remember what happened in a previous invocation. Check the real bytes
   instead:
   ```sh
   sudo ./usbboot --uboot
   sudo ./usbboot -o 0x100000 -s 0x1000 --dump-partition ./ota.out
   xxd ./ota.out | head -3
   ```
   You want to see `ota:kernel` (stock) in there. If it still says `ota:kernel2`, run `--swap-ota`
   again and re-check until the actual bytes confirm you're on stock.
5. Power-cycle normally (or hit reset) to leave recovery mode and boot for real. It'll come up on
   stock.

This only touches the OTA marker partition — it doesn't flash a kernel or rootfs, and it doesn't
touch the bootloader or partition table.

## 4. Manual repair over SSH

If you can still SSH into either slot, you've got ordinary root access and normal shell tooling —
but there's no dedicated "repair script" beyond what's already covered above. We haven't built one,
and this doc isn't going to pretend one exists.

## 5. Full factory restore

Creality has its own official recovery images and USB flashing tooling that reinstalls everything —
bootloader, kernel, rootfs, the works — back to a genuinely factory-fresh state, using the same USB
mask-ROM mode as step 3 above. That's Creality's own tooling, though, not something NebulaOS
provides, pins, or has actually run as part of any of our own testing. If you need it, treat it as
Creality's procedure, not a documented NebulaOS recovery path.

## What actually survives a slot switch

| Data | What happens |
|---|---|
| `printer.cfg`, macros, `moonraker.conf` | Survives — lives in a dedicated directory this whole mechanism never touches |
| Z offset / calibration, bed mesh | Survives — saved into `printer.cfg` via `SAVE_CONFIG`, though we haven't specifically re-tested this exact scenario |
| NebulaOS's own WiFi credentials | Survives — confirmed on real hardware during a full persistent-state reset |
| Moonraker config/state | Survives — confirmed on real hardware |
| GuppyScreen config/theme | Survives — confirmed across a real flash during the Final Closure testing |
| G-code uploads | Survives — confirmed as part of a real backup |
| Logs | Don't survive, but that's expected — they rotate out every 7 days anyway |
| Mainsail config | Honestly not sure — haven't specifically checked this one |
| Camera config, timelapses | Same — not verified either way |

Stock keeps its own config in a separate area of the same shared `/usr/data` partition, so switching
to stock never touches NebulaOS's data and vice versa — see `A_B_SLOT_MODEL.md` for how that's
arranged.

## Related docs

- `docs/A_B_SLOT_MODEL.md` — the partition/marker mechanics behind all of this
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — steps 2 and 3 above, written for a less technical reader
- `docs/DEVELOPER_UPDATE.md` — what to do instead if the device is healthy and you just want a newer version
