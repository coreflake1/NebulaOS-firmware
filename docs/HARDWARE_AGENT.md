# The Hardware Agent

The autonomous developer install: take a printer running NebulaOS, put a new
NebulaOS on it, and prove what landed.

```
NebulaOS running
  ↓  prove printer identity, prove the exact attested candidate
  ↓  prove Stock is reachable and safe to use
  ↓  software reboot to Stock
  ↓  write the NebulaOS slot
  ↓  verify the written bytes
  ↓  select NebulaOS
  ↓  software reboot
  ↓  verify the exact installed build
PART1_INSTALL_VERIFIED=YES
```

## The interface

```sh
run-nebulaos-hardware.sh --device <id> --control <C> inspect
run-nebulaos-hardware.sh --device <id> --control <C> status
run-nebulaos-hardware.sh --device <id> --control <C> verify  <X> <ximage-sha256> <rootfs-sha256>
run-nebulaos-hardware.sh --device <id> --control <C> install <X> <ximage-sha256> <rootfs-sha256>
```

There is no `ssh`, `scp`, `dd`, `marker`, `reboot`, `flash`, raw `usbboot`,
`--host`, `--password` or `--command`. Not filtered — **absent**. `DeviceSession`
defines a closed vocabulary with no method that takes a command, a block device
or an offset, so this is a property of the code rather than a promise about
behaviour.

The target is an **enrolled device id**, never an address. An address is not an
identity: DHCP moves leases and the machine answering at a remembered IP may be
a different printer. Which addresses may be spoken to at all is a property of a
human-created profile.

## C and X

| | |
|---|---|
| **C** — control commit | the reviewed, published source of every privileged helper |
| **X** — product commit | the build being installed. Payload and data only |

Stated separately so that installing an **old** X still uses **current** control
machinery. If helpers came from X, installing a six-month-old build would run
six-month-old flashing code — including whatever bug was fixed since.

Helper bytes are read from C's **git objects** in a protected mirror, never from
the working tree. A working tree is mutable; `tools/` is explicitly unversioned
derived state the sandbox permits writing. Host-side control modules can't be
read from git at import time, so they are **compared** against C and any
difference refuses the operation.

## Capability is not policy

The generic flashing layer can express validated writes to the stock slot, the
NebulaOS slot, either individually, both, and full-device recovery layouts:

```
GENERIC_FLASH_CAPABILITY_STOCK=YES
GENERIC_FLASH_CAPABILITY_NEBULAOS=YES
```

A recovery tool that cannot rewrite Creality's slot is not a recovery tool, and
the device belongs to its owner. The developer `install` operation is separately
narrow:

```
DEV_INSTALL_POLICY=PRESERVE_STOCK
DEV_INSTALL_POLICY_WRITES_STOCK=NO
```

That's the policy of one operation, not a limit of the backend. Safety lives in
validated target selection, vendor-derived bounds, identity, provenance and
read-back — not in an allowlist.

**One exception.** `sn_mac` is refused at the *capability* layer, under every
policy including full-device recovery. It holds the per-unit factory MAC and
serial (`26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1` on the reference
unit — the address stock's `wlan0` actually uses). Every other partition can be
restored from an image; this one cannot.

## What `install` proves before it commits

Setting the marker to `ota:kernel` while NebulaOS runs is the point of no easy
return: after the reboot, the only way forward *or back* is through stock. So
everything stock depends on is checked first, while retreat is free.

- the enrolled printer, by eMMC CID and `SHA256(sn_mac)` — not by address, and
  not by `machine-id`, which differs per slot on the same physical printer
- a **v2 attestation** for X that verifies under the attestation key, whose
  digests equal the artifact bytes, whose profile is release or candidate
- X is published
- the printer is idle: not printing, not paused, every heater target zero
- stock is usable: slot present, a root account, dropbear, a Wi-Fi config, a
  pinned host key, a credential, a known address, room to stage
- payload and helpers staged and hashed **on the device**

Then, and only then, the marker moves — through the on-device
`write_ota_marker()`, because that helper is the only thing that fires the PLR
tombstone when switching away from NebulaOS.

## ARMED, and disarming

`ARMED_STOCK` means NebulaOS is still running and the marker says boot stock.

Every failure in that state sets the marker back and **reads the physical bytes
back** to confirm. A resumed transaction that finds the device armed disarms
*first*, before considering anything else — it does not assume it meant to
continue.

Once slot 2 verifies, the marker is the **immediate** next operation. Not log
collection, not a status report.

## The MCU cost, stated up front

Booting Creality's slot lets its updater reflash the GD32 with stock firmware,
destroying the qualified MCU build. That is why Phase 1.8B removed every
*automatic* route into stock. This install goes there deliberately, because
`flash-spare-slot.sh` refuses to write the slot it is booted from — a rule
written after a real incident where a write landed on the live rootfs.

NebulaOS's guard gets **one bounded restore attempt** on the way back.
`PART1_INSTALL_VERIFIED=YES` requires that no restore was needed:
`MCU_RESTORE_RESULT` is *observed*, and any restore fails the check. A pass on a
printer whose MCU is running Creality's firmware would be a false pass.

This project performs software reboots and cannot power-cycle, so the window is
survivable by construction — but `POWER_CYCLE_DANGEROUS=YES` appears in the
journal and the output throughout it, because a human pulling the plug is the
remaining risk.

## Enrolment is a human act

```sh
tools/hardware/enroll-device.sh --device printer-01 --address 192.168.0.98 --os nebulaos
tools/hardware/enroll-device.sh --device printer-01 --address 192.168.0.138 --os stock
```

Both OSes, before any install. Enrolment is the moment someone asserts *this
physical printer is the one called `<id>`*, and everything downstream rests on
that assertion having been made by someone who could see it. An installer that
can enrol can enrol the wrong printer — which is the trust-on-first-use failure
the rest of this design exists to prevent.

`enroll-device.sh` is deliberately **not** a launcher an agent may run, and the
profile store is denied to agents by permission rules and by the sandbox.

Host keys are pinned **per OS** — stock and NebulaOS are different systems on
one printer — and checked with `StrictHostKeyChecking=yes`. No TOFU, no
automatic re-pinning. A changed key is a refusal; a human re-enrols.

## Prerequisites

| | |
|---|---|
| `~/.config/nebulaos-attest/attest.key` | human-created, 0600 in a 0700 dir. Without it nothing can be attested and every install refuses |
| `~/.config/nebulaos-hardware/devices/<id>/` | enrolled profile, both OSes |
| `~/.local/state/nebulaos-hardware/mirror.git` | protected control mirror, created on first use |

All three are denied to agents. That is the control, not an obstacle: an agent
that can read the attestation key can mint an attestation for any bytes.

## What it does not claim

`PART1_INSTALL_VERIFIED` says an exact image is installed and the system came
up. It is **not** `HARDWARE_QUALIFIED`. Motion, heating, extrusion, calibration
and printing are Part 2, and nothing here touches them.

## Testing

`tests/hardware-install-simulation-tests.py` — 89 assertions across 28
scenarios, driving the real state machine against a simulated printer whose
`boot()` derives which slot comes up **from the marker bytes**, exactly as the
bootloader does. An installer that mis-parses the marker boots the wrong thing
there too.

The simulator lives under `tests/`; production has no import path to it. The
seam is `session_factory` — SSH in production, simulator in tests.

## Related

- [`A_B_SLOT_MODEL.md`](A_B_SLOT_MODEL.md) — partitions and the marker
- [`DEVELOPER_RECOVERY.md`](DEVELOPER_RECOVERY.md) — when it will not boot
- [`RELEASE_ARTIFACTS.md`](RELEASE_ARTIFACTS.md) — the three delivery formats
- [`NEBULAOS_OTA_FLOW.md`](NEBULAOS_OTA_FLOW.md) — why automatic stock fallback was removed
