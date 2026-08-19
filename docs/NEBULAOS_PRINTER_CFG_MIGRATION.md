# printer.cfg / moonraker.conf one-time migration (Phase 1.5)

How an existing device's persistent `printer.cfg` and `moonraker.conf` move from the pre-Phase-1.5
monolithic/relative-include shape to the new split-entrypoint/absolute-include shape, implemented in
`scripts/build/overlay/etc/init.d/S04nebulaos-migrate` (`migrate_printer_cfg()` and
`migrate_moonraker_pin_include()`), run unconditionally on every boot (cheap text-file checks, not
gated behind the app-generation version bump).

There is no public installed user base for NebulaOS — this migration is scoped to the actual
current development baseline, not a general-purpose config-merging framework.

## moonraker.conf

`migrate_moonraker_pin_include()`:

1. If the file already contains `[include /etc/nebulaos/moonraker/klipper-pin.conf]`, no-op
   (already migrated, detectable, idempotent).
2. Else if it contains the exact old line `[include nebulaos/*.conf]`, rewrite **only that line**,
   in place, to the new absolute include. Every other line is untouched byte-for-byte.
3. Else (neither line present — a hand-written or pre-Phase-1 config), no-op. Not an error: a
   device that never had the managed-pin include simply continues without it, exactly as before
   this mission.

Verified with a real `cmp`-equivalent check: the function refuses to declare success unless the
rewritten file actually contains the new line before it replaces the original.

## printer.cfg

`migrate_printer_cfg()` performs a bounded, one-time rewrite from the monolithic shape to the new
small entrypoint. It recognizes the old shape by two signals together — `[nebulaos_compat]` present
as a real (non-included) section, and the anchor line `[include simpleaf/bltouch_macro.cfg]`
(the last of the SimpleAF includes, present in both the old and new file shapes, in the same
relative position) appearing **exactly once**. Anything else is refused, not guessed.

### Case D — already migrated

The file already contains `[include /etc/nebulaos/klipper/platform.cfg]`. No-op, detected before
any of the shape checks below run.

### Cases A/B/C — recognized old shape

1. **Back up first**, to a timestamped, never-overwritten path:
   `$SYSTEM/migration-backups/printer-cfg-migration/printer.cfg.pre-migration.<UTC timestamp>`.
   The backup is verified (`cmp`-equivalent) against the original before migration proceeds. If the
   backup cannot be created or verified, migration is refused and the original is untouched.
2. **Preserve everything after the anchor line, verbatim.** Everything from the line immediately
   following `[include simpleaf/bltouch_macro.cfg]` to end-of-file — a real device's Klipper-written
   `#*# <---------------------- SAVE_CONFIG ---------------------->` block, and/or any additional
   `[include ...]` lines or macros the user added — is captured unchanged and appended, in the same
   position, after the new template's own includes.
3. **Rebuild the rest from the immutable seed** (`/opt/nebulaos-seeds/printer_data-config/printer.cfg`
   — the same tracked source `scripts/build/04-cross-compile-app-stack.sh` already ships as a
   second, never-bind-mounted-over copy for exactly this kind of recovery). This guarantees the
   migrated file's includes are byte-identical to what a virgin device would seed, not a
   hand-reconstructed approximation.
4. **Sanity-check before committing**: the rewritten file must contain
   `[include /etc/nebulaos/klipper/platform.cfg]`. If it doesn't, the original is left untouched
   (backup still exists) and the migration is logged as failed.

Result, for each of the three original required fixtures:

- **Fixture A** (clean known-old factory config, no SAVE_CONFIG, no extra includes): migrates to
  the small entrypoint with no trailing content at all.
- **Fixture B** (old config + real SAVE_CONFIG block): the SAVE_CONFIG block is preserved verbatim
  at the end of the migrated file.
- **Fixture C** (old config + a user-added `[include my_macros.cfg]` line after the anchor):
  preserved verbatim, in the same relative position, ahead of any SAVE_CONFIG block that follows it
  in the original.

### Case E — unexpected structure, refused safely

If `[nebulaos_compat]` is absent, or the anchor line is missing or appears more than once, the
function does **not** guess. It backs the file up to a *different* directory
(`$SYSTEM/migration-backups/printer-cfg-migration-refused/printer.cfg.<UTC timestamp>`) so the
unusual state is preserved for inspection, leaves the live file completely untouched, and logs the
exact reason (whether `nebulaos_compat` was found, and the anchor-line count) rather than a generic
failure message. Manual migration is required in this case.

### Case F — interrupted migration

The rewrite writes to `printer.cfg.migrate-tmp.$$` (PID-suffixed, therefore unique per run) and only
`mv`s it over the real file once every step above has already succeeded. A process killed mid-run
leaves an inert, uniquely-named temp file that nothing else reads — a subsequent boot's migration
attempt is unaffected by it and proceeds normally (the live `printer.cfg` was never in a partial
state, since the `mv` is the last step).

## Virgin devices

A device with no persistent `printer.cfg` at all is not handled by `S04nebulaos-migrate` — it is
seeded directly from `/opt/nebulaos-seeds/printer_data-config/printer.cfg` by
`S02nebulaos-namespace`'s `seed_printer_data_config()`, which already ships the new small-entrypoint
shape (the tracked overlay source was rewritten in place as part of this mission — there is no
separate "old" and "new" seed to choose between). A virgin device therefore boots with only:
immutable `/etc/nebulaos/klipper/{machine,prtouch,platform}.cfg`, the newly-seeded small
`printer.cfg`, and whatever user macro directory it later adds — no prior installation required, no
migration function ever runs for it.

## Test coverage

`tests/printer-cfg-migration-tests.sh` — fixtures A through F above, plus the
`migrate_moonraker_pin_include()` cases, run against the real functions (sourced from the real
`S04nebulaos-migrate` with its path variables overridden into a sandbox), not reimplemented.
