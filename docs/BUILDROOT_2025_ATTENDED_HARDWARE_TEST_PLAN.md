# Attended hardware test plan — Buildroot 2025.02.18 candidate

**Status: PREPARED, NOT EXECUTED.** No step below was performed. Nothing in this
migration contacted the printer: no SSH, no flashing, no partition write, no
slot change, no MCU flash, no motion, no heating, no probing, no extrusion.

`HARDWARE_QUALIFIED=NO` · `HARDWARE_TESTING=NOT_ATTEMPTED`

This is the next session's procedure. It is **attended only** — a human is at the
machine for every step that writes anything.

---

## Before you start

Two independent things must be true, and neither is implied by the other:

1. The candidate is **build-verified** — two clean builds of the same published
   SHA produced identical artifacts. See the reproducibility section of the
   final report.
2. You have a **baseline capture from the current firmware** (Step 1). Without
   it, Step 5 has nothing to compare against and the whole exercise degrades to
   "it seems fine".

Have ready: the candidate `xImage` and `rootfs.squashfs` with their SHA256s, the
source SHA, and physical access to power.

---

## Step 1 — Baseline the CURRENT firmware (read-only, do this first)

Run the qualification tool on the printer **as it is now**, before touching
anything:

```
tools/qualification/nebulaos-qualify.sh > old-baseline.txt
```

It reads `/proc`, `/sys` and loopback HTTP only. It operates nothing — no
motion, no heaters, no configuration change — so it is safe to run on a live
machine. Copy the output off the printer.

Captures: MemTotal/MemAvailable/cached, swap and zram totals and usage, load and
CPU jiffies, context switches, **per-IRQ counters** (including the USB OTG
counter §22 wants tracked), per-process RSS/CPU for Klipper, Moonraker,
GuppyScreen, ustreamer, nginx, Dropbear, wpa_supplicant, udevd, dbus, the
NebulaOS supervisors, Python and venv versions, required imports, nginx /
Mainsail / Moonraker / webcam responses, and filesystem usage.

> Interrupt counters are **cumulative counts, not rates**. For a rate, take two
> captures and difference them against `UPTIME_SECONDS`.

## Step 2 — Candidate integrity (host-side, no device contact)

Verify before writing anything:

- `sha256sum` of `xImage` and `rootfs.squashfs` match the attestation exactly
- the attestation's `SOURCE_HEAD` is the SHA you intend to ship
- confirm which slot is **inactive** — that is the only legal target
- confirm the rollback path: the currently-active slot must remain intact

## Step 3 — Flash the inactive slot (ATTENDED)

Use `scripts/flash-spare-slot.sh`. Do not hand-roll `dd`.

It keeps every on-device guard: slot-label verification, live-target collision
refusal, capacity checks, manifest-vs-bytes verification, a second preflight
immediately before the write to close the time-of-check/time-of-use gap, and
post-write read-back.

Known constraints from the previous hardware session, which still apply:

- The launcher **cannot** drive this install: it has no `ota:kernel` marker
  direction, and the hook's grammar structurally forbids a `VAR=value` prefix,
  so the stock password cannot reach it. The flash is performed **by hand**.
- The stock window must be entered and left by **software reboot only**. A hard
  power cycle while Stock is active lets stock's `S13mcu_update` reflash the
  GD32F303 MCU. Do not power-cycle during that window.
- Verify the write by hashing the partition directly, with exact block maths:
  `dd if=/dev/mmcblkXpN bs=4096 count=<size/4096> | sha256sum`.
  `bs=1M count=96` over-reads and produces a mismatching hash for a correct
  install.

## Step 4 — First candidate boot

Verify, in roughly this order:

| Area | What to confirm |
|---|---|
| Boot | booted the intended slot; `/proc/cmdline` root matches |
| Datastore | `/usr/data` mounted, persistent content intact |
| **Python** | `python3 --version` is **3.12.x** |
| **Venvs** | `envs/klipper` and `envs/moonraker` exist, their `bin/python3` executes, and imports resolve. These are **freshly provisioned**, not migrated — see the scope note below |
| Memory | zram active 128 MiB lz4 priority 100; disk swap 128 MiB priority 10; `vm.swappiness=10`; `vm.page-cluster=0`; **no OOM in dmesg** |
| Network | Wi-Fi associates, MAC unchanged, SSH up |
| Web | nginx serves, Mainsail loads, Moonraker `/server/info` returns, `failed_components` empty |
| Display | GuppyScreen running, backlight and touch behave |
| Camera | ustreamer present; snapshot works if a camera is attached |
| Klipper | reaches `ready`; MCU handshake completes; NebulaOS extensions load; `c_helper` loads |
| Updates | update manager loads with no ConfigError (this is the failure the venv predicate fix targets) |

**Scope note on venvs.** NebulaOS is unreleased and `/usr/data/nebulaos` is
NebulaOS-owned, so there is no deployed Python 3.11 venv to migrate. What ships
is interruption-safe, idempotent **provisioning** of fresh 3.12 venvs. Version
-aware migration is a documented future requirement for the first post-release
Python ABI transition — see `docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md`. Do not
expect a migration to be exercised here; do exercise the recovery paths below.

Worth deliberately testing while attended, since it is cheap and the code is new:
interrupt the first boot during venv provisioning (pull power once, deliberately,
**before** any MCU/stock window work) and confirm the next boot recovers — a
leftover `envs/<name>.old` must be restored or discarded, never left stranded,
and `envs/<name>.partial` must not be mistaken for a finished environment.

## Step 5 — Performance comparison

Run the **same** tool, same way:

```
tools/qualification/nebulaos-qualify.sh > new-candidate.txt
diff -u old-baseline.txt new-candidate.txt
```

To compare only behaviour and ignore legitimately-varying values, drop the
fenced tail first: `sed '/# --- VOLATILE/,$d'`.

Compare specifically: MemAvailable and per-process RSS, zram/swap occupancy,
idle CPU, interrupt counters (USB OTG especially), API latency, and camera
impact when active.

**Read the sentinels precisely.** `ABSENT`, `UNAVAILABLE` and `FAILED` are
distinct and none of them means zero. A metric that changes from a number to
`FAILED` is a regression, not a measurement.

### What is expected to differ, and what is not predicted

The rootfs is **+29.8%** (99 758 080 → 129 503 232 bytes), entirely from the
Python tree: matplotlib 3.4.3 → 3.10.0 (+50 MB uncompressed, 46 MB of which is
its bundled test suite), numpy +12 MB, fontTools +12 MB.

**This is not a prediction of higher RAM use.** squashfs is demand-paged; only
pages actually touched become resident, and `matplotlib/tests` is never
imported. RAM, CPU, boot time and latency are **NOT TESTED** and no claim is
made about them. Measure, then conclude.

## Step 6 — Functional qualification

Only after Steps 4 and 5 are clean:

calibration paths → accelerometer / input shaper → probe → motion → heating →
extrusion → a controlled test print.

`numpy` and `matplotlib` now come from stock Buildroot packages instead of a
vendored wheel and a patched `.mk`, so the calibration and graphing paths
deserve explicit attention here — including anything that plots.

## Step 7 — Recovery and A/B

Verify rollback to the previously-active slot restores a working machine, and
that the persistent datastore survives the round trip.

---

## STOP

Do not continue past Step 7 in the same session. Record results, then decide.
