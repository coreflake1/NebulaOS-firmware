# NebulaOS config materialization architecture

Phase 2 final software closure mission, 2026-09-09.

## Before this mission

`printer.cfg` included `/etc/nebulaos/klipper/*.cfg` directly - the
immutable, read-only squashfs tree was also the live include target. This
worked, but meant the active config Klipper actually runs was split across
two storage classes with no single place a user (or Mainsail's Config Files
browser) could see the whole picture, and no way to "reset just the
NebulaOS-managed config" independent of the immutable image itself.

## This mission's change

`/etc/nebulaos/klipper/*.cfg` remains the canonical, immutable, slot/image-
owned SOURCE. It is never included directly by a live printer.cfg any more.
Instead, on boot, it is MATERIALIZED - copied, verified, byte-for-byte -
onto persistent storage at `$PRINTER_DATA_CONFIG/nebulaos/` (bind-mounted
to `/opt/printer_data/config/nebulaos/`), and printer.cfg includes files
from there by relative path instead.

```
[squashfs, immutable]                  [/usr/data, persistent]
/etc/nebulaos/klipper/*.cfg   --copy-->  printer_data/config/nebulaos/*.cfg
  .manifest.json (generation)             <-- included by printer.cfg
                                          system/config-generation.json
                                            (records which generation is
                                             currently materialized)
```

## Why materialize instead of include directly

- **Single storage class for the active config.** Everything Klipper
  actually reads for this printer - printer.cfg, the NebulaOS-managed
  files, macros/, guppyscreen/ - now lives under one directory tree on
  persistent storage, visible through Mainsail's ordinary Config Files
  browser.
- **A real "reset just the managed config" operation becomes possible**
  (`nebulaos-recover config`) - restore the materialized tree from the
  immutable source without touching printer.cfg's own user-owned region,
  macros/, guppyscreen/, or anything else.
- **Generation tracking is explicit**, not implied by which squashfs happens
  to be mounted. A rollback to an older A/B slot correctly rematerializes
  that slot's own config generation, the same mechanism as any other
  generation change - no special-casing.

## Generation identity

A dedicated hash - `/etc/nebulaos/klipper/.manifest.json`'s `generation`
field, generated at build time (see `04-cross-compile-app-stack.sh`) from
the sha256 of each of the ten `.cfg` files' content, sorted by filename and
concatenated. Deliberately NOT the firmware's own git SHA: that changes on
every commit, even ones that never touch these ten files, which would force
an unnecessary backup+rematerialize cycle on every single build. The
manifest's generation hash only changes when the actual config content
changes.

`config_materialization_needed()` compares this manifest's generation
against what is recorded in `$SYSTEM/config-generation.json`. Same
generation: no-op (an ordinary reboot on the same image does nothing).
Different (or absent): `materialize_config_tree()` runs.

## What materialize_config_tree() actually does

1. Reads the manifest, verifies it has a generation and at least one file.
2. Copies each `*.cfg` file from the immutable source into a staging
   directory, verifying each copied file's own sha256 against the
   manifest's per-file hash before trusting it.
3. If an existing materialized tree is present, backs it up to
   `$SYSTEM/migration-backups/config-materialization/<timestamp>/` (never
   deleted by this function - subject to the same age+count pruning policy
   as every other migration backup, see `nebulaos-retention.sh`).
4. Atomically promotes the verified staging directory into place.
5. Records the new generation in `config-generation.json`.

Any failure at any step leaves the existing tree completely untouched and
returns non-zero - never a partial rewrite.

## Shared between two callers

`scripts/build/overlay/etc/nebulaos/config-materialize.sh` is a sourced
library, not a standalone script. Both call it identically:

- **Boot time**: `S04nebulaos-migrate`'s `materialize_active_config()`
  (source: `"boot-materialization"`), gated by
  `config_materialization_needed()` so it is a true no-op on an ordinary
  reboot.
- **Explicit user action**: `nebulaos-recover config` (source:
  `"recover-config"`), unconditional - a technician-invoked reset that
  always rematerializes regardless of whether the generation already
  matches, for recovering from local corruption of the managed tree
  itself.

## printer.cfg's own migration

A separate, one-time, idempotent step -
`migrate_printer_cfg_to_managed_tree()` - rewrites printer.cfg's ten direct
`/etc/nebulaos/klipper/*.cfg` includes to the ten relative `nebulaos/*.cfg`
ones, and adds `[include macros/*.cfg]` for the new permanently user-owned
macros directory. It runs only after `materialize_active_config()` has
successfully materialized the tree this same boot (or an earlier one) -
verified file-by-file before ever touching printer.cfg, so Klipper is never
left pointed at files that do not exist. Deliberately narrow: only
recognizes the file when all ten old includes are present, contiguous, and
in the exact known order; anything else safely refuses (backed up, logged)
rather than guessing.
