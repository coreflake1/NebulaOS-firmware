# How the A/B boot slots work

This is the raw partition layout and boot-selection mechanism the KE actually uses. It assumes
you're comfortable with SSH, root, and thinking about block devices — this isn't a consumer install
guide, it's the reference for anyone actually working on this stuff.

## The layout

```
Slot 1 (stock)              Slot 2 (custom / NebulaOS)
  mmcblk0p5  kernel            mmcblk0p6  kernel2
  mmcblk0p7  rootfs             mmcblk0p8  rootfs2
  (8 MiB / 500 MB)              (8 MiB / 500 MB - real, fixed capacities)

              mmcblk0p1  ota marker (1 MB)
                 shared, not per-slot

              mmcblk0p9  rootfs_data (300 MB, ext4, /overlay)
              mmcblk0p10 userdata    (~6 GB, ext4, /usr/data)
                 shared, not duplicated per slot - see below
```

These are two fixed physical slots, not a rotating pair. Slot 1 is Creality's stock kernel and
rootfs. Slot 2 is NebulaOS's permanent home — every time you update NebulaOS, you're overwriting
slot 2 again, not alternating between two custom copies.

The important part: **we never overwrite the slot we're currently booted from.** That's not just a
convention, it's enforced in code (more on that below).

### `/overlay` and `/usr/data` are shared, not duplicated

`mmcblk0p9` (`/overlay`) and `mmcblk0p10` (`/usr/data`) are the same physical partitions no matter
which slot is active — they don't get a separate copy per OS. Stock and NebulaOS just use their own
subdirectories underneath, so switching slots doesn't expose one OS's files to the other, and
doesn't wipe either one out. `docs/DEVELOPER_RECOVERY.md` has the full breakdown of what actually
lives where and what survives a switch.

## What a normal flash actually touches

`scripts/flash-spare-slot.sh` writes exactly two devices: `/dev/mmcblk0p6` (kernel2) and
`/dev/mmcblk0p8` (rootfs2). It only ever targets slot 2, and it will flatly refuse to run if the
slot it's about to write turns out to be the one you're currently booted from. That check happens
in the script itself, not just in a warning somewhere — see `run_preflight()` if you want to read
it.

It never touches:

- `mmcblk0p5`/`p7` (stock's kernel/rootfs) — there's no code path that writes there
- `mmcblk0p1` (the OTA marker) — that's a separate, deliberate step, covered below
- `mmcblk0p9`/`p10` (the persistent data partitions) — not this script's job
- U-Boot, the partition table, or any factory-calibration data — nothing in this repo touches those

Worth knowing why this is so locked down: an earlier version of this script had a broken check for
"what am I currently booted from," and a write ended up landing on the live, running rootfs. That
went about as well as you'd expect — cascading segfaults, needed a manual power cycle to recover.
The current script was rewritten specifically to make that impossible: it reads the real `root=`
value out of `/proc/cmdline` instead of trusting an alias, and refuses outright if the resolved
target matches the resolved active slot. If you're ever modifying this script, know that the
safety check is there because we got burned once, not because it seemed like a good idea in the
abstract.

## The OTA marker

`/dev/mmcblk0p1` is a plain 1 MB partition. Its whole job is holding one of two strings:

```
ota:kernel      (boot slot 1 / stock next)
ota:kernel2     (boot slot 2 / custom next)
```

Two different tools write it, depending which OS you're currently on — and that's intentional, not
an inconsistency:

| From | Tool |
|---|---|
| Custom (NebulaOS) | `/etc/ota_marker.sh`'s `write_ota_marker()` — NebulaOS's own helper, ships as part of the rootfs |
| Stock (Creality) | `/etc/ota_bin/ota_local_method.sh`'s `local_set_next_boot_device()` — Creality's own pre-existing tool, already on stock |

If you're switching over from stock for the first time, you use stock's own tool, since NebulaOS's
helper doesn't exist there yet. Once you're running NebulaOS, its own tool takes over. Both have
been used successfully on real hardware to flip the marker and switch slots.

The part that actually reads the marker at boot time lives in the bootloader, which is vendor code
outside this repo — so we can only describe what we've observed (writing the marker and rebooting
reliably switches the boot target), not the internals of how it's read.

## What happens on first boot

**Updated in Phase 1.8B (`phase1.8b/boot-safety`, commit 86a0c01) — the description below is the
CURRENT behavior. It replaces an earlier design (kept here for history) that automatically flipped
the marker back to stock on any Klipper/Moonraker failure.**

```
reboot
  |
S00revert-safety   -- Phase 1.8B: deliberate NO-OP. Logs that automatic stock
  |                   fallback is disabled and why. Does NOT touch the marker.
init sequence proceeds (S04 factory-seed/migrate, S5x services...)
  |
S99confirm-good    -- polls Moonraker's /server/info for klippy_state=="ready"
  |                   (up to 30 retries, 5s apart = 150s), purely for diagnostic
  |                   logging now
  |
  +-- success --> logs healthy, marker UNCHANGED
  |
  +-- timeout ----> logs a WARNING, marker UNCHANGED (stays on NebulaOS)
```

**Why this changed:** booting the stock Creality slot auto-flashes the GD32F303 MCU with old
Creality firmware, destroying whatever native MCU firmware was qualified and installed. The
original design's automatic stock-fallback-on-failure was worse than the problem it solved — a
transient Klipper/Moonraker failure inside NebulaOS could silently trigger an MCU-destroying
reboot into stock. Phase 1.8B removes every automatic path that can flip the marker: a NebulaOS
boot that crashes, hangs, has Klipper or Moonraker fail to start, or loses MCU connectivity now
simply **stays on NebulaOS** and preserves diagnostics — it does not fall back to stock on its own.
Manual recovery (SSH `write_ota_marker`, Creality's own tools, or USB mask-ROM recovery) is fully
preserved for the cases where a human genuinely needs to switch back — see
`docs/DEVELOPER_RECOVERY.md` and `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`.

`S00revert-safety` and `S99confirm-good` are kept as named, ordered init.d scripts rather than
deleted outright: `S00`'s position (literal first script in boot order) is itself meaningful to
preserve, and `S99`'s health poll remains useful diagnostic signal independent of the marker. Both
carry extensive comments explaining why they're neutered, specifically so a future change doesn't
accidentally reintroduce automatic MCU-destroying fallback.

**One thing to be aware of:** this is all NebulaOS-side software behavior. If the kernel never gets
far enough to even start userspace — or the rootfs fails to mount before `/sbin/init` runs — none
of this repo's init scripts get a chance to run at all, and the marker just stays wherever it
already was. There is no bootloader-level (pre-init) automatic fallback mechanism in this project;
the marker is read by vendor bootloader code outside this repo, and no counter/watchdog-driven
revert exists here. That gap is a known, currently-accepted limitation (see Phase 6/7 of the
vNext roadmap), not something Phase 1.8B attempts to close.

## Related docs

- `docs/DEVELOPER_INSTALL_FROM_STOCK.md` — the full first-install walkthrough
- `docs/DEVELOPER_UPDATE.md` — updating an existing install
- `docs/DEVELOPER_RECOVERY.md` — what to do if something goes wrong, including the edge case above
- `docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md` — the practical, day-to-day version of flipping slots
- `docs/NEBULAOS_OTA_FLOW.md` — the bigger picture this slot model fits into
