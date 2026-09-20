# NebulaOS Firmware

This is where NebulaOS actually gets built. NebulaOS is a custom Linux + Klipper stack for the
Creality Ender-3 V3 KE — real mainline-ish kernel, real Klipper, a proper touchscreen UI, none of
the stock firmware's binary blobs where we could avoid them.

If you want to build the whole OS, this is the repo you want. The kernel, Klipper, and GuppyScreen
each live in their own repos, but this one pins the exact commit of each, fetches them fresh, and
puts the whole thing together into something you can flash.

```
NebulaOS-kernel             ─┐
Klipper3d/klipper           ─┤
NebulaOS-klipper-extensions ─┼─►  NebulaOS-firmware  ─►  final rootfs + kernel + firmware image
NebulaOS-guppyscreen        ─┘        (this repo)
```

- [`NebulaOS-kernel`](https://github.com/coreflake1/NebulaOS-kernel) — Linux 6.6 kernel fork (`openke` branch)
- [`Klipper3d/klipper`](https://github.com/Klipper3d/klipper) — the host Klipper runtime. Official
  upstream, pinned to an exact commit, and kept unmodified: NebulaOS patches none of Klipper's own
  files
- [`NebulaOS-klipper-extensions`](https://github.com/coreflake1/NebulaOS-klipper-extensions) —
  NebulaOS's own host-side Klippy extras, composed alongside that unmodified Klipper at boot
  instead of being forked into it
- [`NebulaOS-guppyscreen`](https://github.com/coreflake1/NebulaOS-guppyscreen) — touchscreen UI fork (`main` branch)
- [`NebulaOS`](https://github.com/coreflake1/NebulaOS) — releases live here, not source

`coreflake1/NebulaOS-klipper`, the old host-Klipper fork, is **retired**. It is not a build input,
not a dependency, and not the host runtime source. It is kept only as historical provenance for
the filtered git history that now lives in `NebulaOS-klipper-extensions` (Phase 1 no-fork
migration, 2026-08-17 — see the `KLIPPER_REPO` comment in `manifests/dependencies.conf`).

Every dependency this build pulls in — kernel, Klipper, the Klipper extensions, GuppyScreen,
Buildroot, Moonraker, k1-ustreamer, v4l-utils, Mainsail, WiFi firmware, the build container
itself — is pinned by exact
commit/tag/digest and a SHA256 in `manifests/dependencies.conf`. The build always fetches fresh; it
won't pick up a local checkout of the kernel or Klipper repo sitting next to it, even if you have
one.

## Building it

```sh
git clone https://github.com/coreflake1/NebulaOS-firmware.git
cd NebulaOS-firmware
./build.sh
```

That's genuinely it. `build.sh` pulls one build container
(`ghcr.io/coreflake1/nebulaos-build`, digest-pinned) and runs the whole pipeline inside it —
fetches every dependency, applies the 8 accepted kernel variants, builds the kernel/rootfs/app
stack, and checks the result actually looks right. You need Docker or Podman and not much else —
no `apt-get install` beforehand, no nested containers, nothing weird.

Budget ~15GB of disk and a few hours on a normal machine. It needs the network the whole time,
since everything gets fetched and hash-checked as it goes.

If you want to see what's actually happening under the hood, `build.sh` runs these in order
(details in `scripts/build/README.md`):

```sh
cd scripts/build
./00-fetch-vendor-sources.sh
./01-apply-kernel-patches.sh
./02-configure-buildroot.sh
./03-build-kernel-and-rootfs.sh
./04-cross-compile-app-stack.sh
./05-final-build.sh
./06-verify.sh
```

When it's done, you'll have `xImage`, `rootfs.ext2`, and `rootfs.squashfs` in
`artifacts/buildroot-halley5-v30-image/`, plus `build-manifest.txt` (records exactly what went
into this build) and `kernel.config`. GuppyScreen's compiled binary shows up separately in
`artifacts/guppyscreen-mips/`. The last stage sanity-checks that everything is real, correctly
architected MIPS32 output — it's not claiming byte-for-byte reproducibility between two separate
builds (timestamps and a few build-path strings will differ), just that the same code went in and
came out right.

## Don't build the other repos on their own

Cloning `NebulaOS-kernel`, `NebulaOS-klipper-extensions`, or `NebulaOS-guppyscreen` by itself and
trying to build it won't get you a working printer image — none of them do that alone. This repo
is the one that pulls them, along with pinned upstream Klipper, together into something flashable.

## How reproducible is this, really

Every pin in `manifests/dependencies.conf` is an exact commit/tag/digest plus a SHA256, checked on
every run — that file's comments explain why each one is pinned the way it is, and most of them
have a real story behind them. The 8 kernel variants we build on top of stock upstream (PREEMPT_RT,
a WiFi SDIO IRQ priority fix, VSYNC-gated display panning, a pinctrl ownership fix, the final
backlight controller, PWM state readback, the final touch driver, and disabling WiFi roaming) live
as small, order-independent scripts under `scripts/build/`, applied by
`scripts/build/apply-qualified-baseline.sh`.

## Wait, is this the same thing as OpenKE?

No, and it's a fair question since they're related. [OpenKE](https://github.com/coreflake1/guppyscreen)
is a separate project — its own installer for stock Creality firmware, its own releases — that
shares an author and some history with NebulaOS, but they're not the same project anymore.
`NebulaOS-kernel`'s branch is still called `openke` for historical reasons; that's a leftover name,
not a sign the two projects are still connected.

## If you're setting one of these up yourself

Beyond just building, this repo is also where we keep the docs for installing, updating, and
recovering an actual device — written for developers who already have SSH/root on their printer,
not as a polished installer walkthrough:

- [`docs/A_B_SLOT_MODEL.md`](docs/A_B_SLOT_MODEL.md) — how the stock/custom partition layout works
- [`docs/DEVELOPER_INSTALL_FROM_STOCK.md`](docs/DEVELOPER_INSTALL_FROM_STOCK.md) — putting NebulaOS on a printer for the first time
- [`docs/DEVELOPER_UPDATE.md`](docs/DEVELOPER_UPDATE.md) — updating a printer that's already running NebulaOS
- [`docs/DEVELOPER_RECOVERY.md`](docs/DEVELOPER_RECOVERY.md) — what to do if something goes wrong
- [`docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md`](docs/HOW_TO_SWITCH_STOCK_AND_CUSTOM.md) — flipping between stock and custom day to day
- [`docs/BUILD_PROVENANCE.md`](docs/BUILD_PROVENANCE.md) — figuring out exactly what produced a given build
- [`docs/NEBULAOS_BUILD_ENVIRONMENT.md`](docs/NEBULAOS_BUILD_ENVIRONMENT.md) — what's actually in the build container
- [`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md) — the upstream projects and prior work this stands on

The other repos (kernel, Klipper, GuppyScreen, and the [`NebulaOS`](https://github.com/coreflake1/NebulaOS)
release repo) all link back here instead of keeping their own copies of this stuff — this is the
one place it's kept up to date.

## History

This repo used to be a broader research workspace called `ke-mainline-klipper`. That history —
hardware bring-up notes, root-cause writeups, the mission-by-mission log — is still here, in
[`docs/HISTORY.md`](docs/HISTORY.md) and the rest of `docs/`. `FIRMWARE.md` is the long-form
technical reference for the build internals, if you want the deep version of any of this.

## License

See [`LICENSES/`](LICENSES/) for this project's own code and everything it vendors or fetches.
