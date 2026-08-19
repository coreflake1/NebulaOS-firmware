# NebulaOS persistent namespace and slot-owned configuration

Phase 1.5 persistent-namespace mission (2026-08-18). Defines where NebulaOS-specific state is
allowed to live, why machine/platform configuration is image-owned rather than persistent, and how
Wi-Fi credentials safely moved without ever risking the device's own SSH access path.

## The three ownership classes

**CLASS 1 — NEBULAOS_OWNED.** Persistent data created and owned specifically by NebulaOS. Canonical
root: `/usr/data/nebulaos/`. Nothing NebulaOS-specific should be written outside this root except
the one documented exception below.

**CLASS 2 — USER_SHARED_WITH_STOCK.** User content intentionally shared between NebulaOS and the
stock Creality environment. The one instance: `/usr/data/printer_data/gcodes/` — the virtual SD
card / G-code storage path. NebulaOS intentionally reads and writes files there because they are
user print content, not NebulaOS system state, and stays at the stock-compatible location instead
of moving into `/usr/data/nebulaos/` for namespace purity.

**CLASS 3 — STOCK_OWNED.** Existing Creality/stock persistent data elsewhere on the shared
`/usr/data` partition (`mmcblk0p10`). NebulaOS does not delete, replace, repurpose, migrate, or
claim ownership of it. Read access is allowed where explicitly needed (GuppyScreen's power-loss
recovery panel reads `/usr/data/creality/userdata/config/print_file_name.json` — stock's own state,
correctly left untouched).

## Why machine/platform configuration is image-owned, not persistent

`/usr/data` is a single ext4 partition (`mmcblk0p10`) shared across both A/B boot slots — it is
**not** duplicated per slot. Anything that must automatically match whichever slot is currently
active therefore cannot live in persistent storage; it has to live on the read-only rootfs each
slot carries, at `/etc/nebulaos/`:

```
/etc/nebulaos/
├── klipper/
│   ├── machine.cfg     physical Ender-3 V3 KE hardware definition
│   ├── prtouch.cfg     load-cell touch-probe configuration
│   └── platform.cfg    NebulaOS <-> Klipper integration (nebulaos_compat, tmcstatus, nebulaos_version)
└── moonraker/
    └── klipper-pin.conf   qualified Klipper + extensions update-manager pins
```

Slot A carries its own machine definition, platform integration, PRTouch configuration, and
qualified Klipper/extensions pins. Slot B carries its matching versions. Switching or rolling back
A/B therefore automatically restores the matching configuration and pins, with zero persistent-state
migration or sync step — the rootfs change *is* the mechanism. This was not true before this
mission: the qualified pins used to live at `printer_data/config/nebulaos/klipper-pin.conf`, inside
the shared, persistent tree, kept in sync by a firmware migration script that only ever ran
forward. A device rolled back to an older slot would still read the newer slot's persistent copy of
the pin — correctness depended on migration direction, which defeats the point of A/B. Moving the
pins onto the rootfs closes that gap by construction.

Both include mechanisms were verified against the real pinned upstream source before relying on
them, not assumed:

- Klipper (`configfile.py`, pinned `fe4eb8650`): `include_glob = os.path.join(dirname,
  include_spec)` — Python's `os.path.join` returns the second argument unchanged when it is
  absolute, so `[include /etc/nebulaos/klipper/machine.cfg]` resolves correctly regardless of which
  file it appears in.
- Moonraker (`confighelper.py`, pinned `d5ee17128`): `if inc_path[0] == "/": new_path =
  pathlib.Path(inc_path).resolve()` — an explicit, intentional absolute-path branch, not a
  workaround.

## printer.cfg: split, not rewritten

The former monolithic `printer.cfg` (mcu/steppers/extruder/heater/BLTouch/PRTouch/platform sections
all inline) is now a small, persistent, user-owned entrypoint:

```
[include /etc/nebulaos/klipper/platform.cfg]
[include /etc/nebulaos/klipper/machine.cfg]
[include /etc/nebulaos/klipper/prtouch.cfg]

[include GuppyScreen/guppy_cmd.cfg]
[include camera-quality.cfg]

[include simpleaf/homing.cfg]
... (remaining SimpleAF includes, unchanged)

# user includes/macros, then Klipper's own SAVE_CONFIG block
```

Section content, values and ordering are unchanged from what was already qualified — only the file
boundary is new. `platform.cfg` loads first because `[nebulaos_compat]` must run before any other
NebulaOS-provided section (this was already a load-bearing ordering requirement in the monolithic
file; it is preserved exactly).

**SAVE_CONFIG target, proved from the real pinned Klipper source, not assumed:**
`configfile.py`'s `cmd_SAVE_CONFIG()` reads `cfgname = self.printer.get_start_args()['config_file']`
— the top-level file Klipper was started with, i.e. the persistent entrypoint — and rewrites only
that file (backing up the previous version to `<name>-<timestamp>.cfg` first). It never opens,
reads, or writes any `[include ...]`-referenced file. This means SAVE_CONFIG can never touch
`/etc/nebulaos/klipper/machine.cfg`, `prtouch.cfg`, or `platform.cfg` — not because of a convention,
but because Klipper's own save path is hardcoded to the file named on its command line.

## Moonraker: the same pattern

`moonraker.conf` (persistent, user-owned) carries one stable line:

```
[include /etc/nebulaos/moonraker/klipper-pin.conf]
```

`klipper-pin.conf` (image-owned) carries the reserved `[update_manager klipper]` slot and the
`[update_manager nebulaos_klipper_extensions]` section, both pinned to the qualified commit pair.
Advancing a qualified pin is now an ordinary firmware update — no persistent-tree file to keep in
sync, no risk of a rolled-back slot reading a newer pin.

**Known limitation, stated rather than buried:** a device provisioned before this exact include
line existed keeps working but ignores the managed pins until the line is present. Unlike a
brand-new deployment, an *existing* device's `moonraker.conf` is user-owned and is never rewritten
except by the one bounded, idempotent migration in `NEBULAOS_PRINTER_CFG_MIGRATION.md`, which does
cover this exact line (recognizing the old relative-glob form,
`[include nebulaos/*.conf]`, and rewriting only that one line to the new absolute form).

## Wi-Fi migration — safety-critical, because it is also the SSH path

Canonical path: `/usr/data/nebulaos/network/wpa_supplicant.conf`. Previous path:
`/usr/data/nebulaos/wpa_supplicant.conf`, kept as a compatibility symlink to the canonical file —
both paths are inside `/usr/data/nebulaos`, so the compatibility symlink is a convenience, not a
namespace-ownership exception, and is not removed merely for aesthetic cleanliness.

Wi-Fi is this device's primary (often only) remote-access path, so this is not a plain rename.
`/etc/nebulaos-wifi-migrate.sh`'s `nebulaos_wifi_migrate()`, sourced by `S01wifi`, implements five
cases:

- **A — device already migrated:** the new canonical path exists. Used as-is; never reseeded.
- **B — first migration:** the old path is a real file, the new path is absent. The content is
  copied through a temp file in the new directory, `fsync`'d, atomically renamed into place, then
  verified byte-for-byte against the original — only *then* does the old path become a
  compatibility symlink. The old file is never moved or deleted before that verification succeeds.
- **C — virgin device:** neither path exists. A credential-free skeleton
  (`ctrl_interface=`/`update_config=1`, mode `0600`) is seeded at the new path only.
- **D — migration failure:** the old file is left completely untouched and is used for that boot
  (`wpa_supplicant -i wlan0 -c <old path>`); no blank/default file is ever created at the new path
  as a result of a failed migration.
- **E — unexpected object:** either path is a directory, FIFO, device node, or an unexpected
  symlink target. Neither path is followed, deleted, or replaced; the failure is logged and Wi-Fi
  does not start that boot rather than guessing.

GuppyScreen never reads or writes the credentials file directly — its WiFi panel talks exclusively
through `wpa_supplicant`'s control socket (`/var/run/wpa_supplicant`, confirmed by grepping the
GuppyScreen source for any literal `wpa_supplicant.conf` reference: there is none). `wpa_supplicant`
itself, started by `S01wifi` with whatever path the migration function decided on, is the only
writer. This rules out the specific hazard the governing brief for this mission called out by name
("wpa_supplicant reads NEW while GuppyScreen writes OLD as a separate regular file") by
construction, not by convention.

Test matrix: `tests/nebulaos-wifi-migrate-tests.sh`.

## Complete `/usr/data` ownership audit — summary

Every active reference to `/usr/data` across `NebulaOS-firmware`, `NebulaOS-guppyscreen`, and
`NebulaOS-klipper-extensions` was traced and classified as part of this mission. Full detail lives
in the mission report; the load-bearing findings:

| Path | Classification | Notes |
|---|---|---|
| `/usr/data/nebulaos/` (all subtrees) | NEBULAOS_OWNED | apps, envs, printer_data (config/logs/database/certs/comms/timelapse/misc), guppyscreen, network, system, updates, backups, maintenance |
| `/usr/data/printer_data/gcodes/` | USER_SHARED_WITH_STOCK | the one documented exception; virtual_sdcard path (`/opt/printer_data/gcodes`, bind-mounted from here when present, created if genuinely absent) |
| `/usr/data/printer_data` (whole tree, as previously aliased) | **removed** | previously a whole-directory compatibility symlink to `/opt/printer_data` (NebulaOS's own private tree) — this silently claimed the entire stock-shared `printer_data` namespace, not just `gcodes`, and on a device with genuine prior stock content at that path, was skipped entirely, causing NebulaOS-authored files (static IP config, calibration backups) to land inside stock's own directory instead. Removed once GuppyScreen's own hardcoded references to it were fixed to use `/opt/printer_data/...` directly. |
| `/usr/data/guppyscreen` (whole tree, as previously aliased) | **removed** | same mechanism as above, same fix; GuppyScreen's `touch_beep.cpp` and this repo's `guppy_cmd.cfg` now reference `/opt/guppyscreen/...` directly |
| `/usr/data/guppyify-backup` | **moved** | was an unnamespaced, bare top-level backup directory written by GuppyScreen's `klipper_backup_restore.py`; moved to `/usr/data/nebulaos/backups/printer_config` (a directory `S02nebulaos-namespace` already creates) |
| `/usr/data/creality/...` | STOCK_READ_ONLY | GuppyScreen's power-loss recovery panel reads stock's own `print_file_name.json`; correctly unchanged |
| `NebulaOS-guppyscreen`'s `k1/k1_mods/`, `scripts/installer.sh`, `scripts/update.sh`, `scripts/vendor/nginx-src/`, `releases/` | LEGACY_COMPATIBILITY / DEAD_CODE (from NebulaOS's perspective) | GuppyScreen's own separate, standalone K1/stock-firmware installer package for the unrelated OpenKE project — confirmed never invoked by any NebulaOS-firmware build path; out of scope for this audit's remediation, not touched |
| `artifacts/parity/custom/{50-ps.txt,08-mounts.txt}` | stale test fixtures | captured 2026-07-23, predate the real ext4 `/usr/data` mount (2026-07-27) and the WiFi path relocation into `/usr/data/nebulaos/` — recorded here as a known staleness, not corrected by this mission (out of scope; flagged for a future parity-capture refresh) |

`NEBULAOS_SPECIFIC_PERSISTENT_WRITES_OUTSIDE_NAMESPACE = 0` is the target; see the mission report
for how this is checked (`tests/nebulaos-namespace-ownership-tests.sh`) and its actual result.

## Factory-clean scope

NebulaOS's factory-clean tooling (`opt/nebulaos/factory-clean-provision.sh --archive-and-reset`)
archives and recreates exactly three subtrees: `$NEBULAOS_ROOT/apps`, `$NEBULAOS_ROOT/envs`,
`$NEBULAOS_ROOT/system`. It explicitly does not touch `printer_data/config` (its own log message
says so directly: "printer_data/config and your gcodes/logs/database are untouched by this step"),
and — checked directly against this exact mission's own change, not assumed — it does not touch
either Wi-Fi path either. Read literally: **NebulaOS's factory-clean does not clear Wi-Fi
credentials, and did not before this mission.** The `network/` subdirectory move does not change
this in either direction — neither the old `/usr/data/nebulaos/wpa_supplicant.conf` nor the new
`/usr/data/nebulaos/network/wpa_supplicant.conf` is in `archive_and_reset()`'s `apps envs system`
loop, exactly as neither was before. This is stated explicitly here because the mission's own
governing brief requires this to be a documented, deliberate decision rather than something that
falls out unnoticed of where a file happens to live — a factory-clean device retains its saved
network, which is arguably the more useful default for a "clean up the software state, not the
"how do I reach this machine at all" state" operation `--archive-and-reset` otherwise performs, but
it is a real limitation for anyone expecting factory-clean to also wipe credentials (e.g. before
transferring a physical unit to someone else) and is not currently offered as an option at all.
