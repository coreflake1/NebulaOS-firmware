# Virgin First-Boot Contract

What NebulaOS guarantees about GuppyScreen configuration and WiFi configuration on a device that
has never run NebulaOS before, and what it guarantees about that state on every boot afterwards.

Scope: the two pieces of first-boot state a user cannot recover from without a screen or a network
— GuppyScreen's `guppyconfig.json` and `wpa_supplicant.conf`. Everything else in
`/usr/data/nebulaos` is covered by `NEBULAOS_MUTABLE_RUNTIME_ARCHITECTURE.md` and
`NEBULAOS_PERSISTENT_LIFECYCLE.md`; this document does not restate them.

Written 2026-08-16 (Phase 0 safety/cleanup closeout); WiFi paths updated 2026-08-18 (Phase 1.5
persistent-namespace mission — see `NEBULAOS_PERSISTENT_NAMESPACE.md`). Every path below was read
out of the overlay/init scripts as they exist at the commit noted, not from memory.

## Ownership

| File | Owned by | Kind |
|---|---|---|
| `/opt/guppyscreen/guppyconfig.json` (in-image) | `scripts/build/overlay/opt/guppyscreen/guppyconfig.json` | immutable factory default, squashfs |
| `/usr/data/nebulaos/guppyscreen/guppyconfig.json` | `S01persistent-datastore` (`seed_once`) | persistent user state, ext4 `mmcblk0p10` |
| `/opt/guppyscreen/guppyconfig.json` (at runtime) | `S01persistent-datastore` (`mount --bind`) | the persistent file, made visible where GuppyScreen looks |
| `/usr/data/nebulaos/network/wpa_supplicant.conf` | `/etc/nebulaos-wifi-migrate.sh` (`nebulaos_wifi_migrate`), sourced by `S01wifi` | canonical persistent user state, ext4 `mmcblk0p10` |
| `/usr/data/nebulaos/wpa_supplicant.conf` | same, as a compatibility symlink to the canonical file above | kept only for anything still expecting the pre-Phase-1.5 path; both paths are inside `/usr/data/nebulaos`, so this is a convenience, not a namespace-ownership exception |
| `/var/run/wpa_supplicant/wlan0` | `wpa_supplicant`, started by `S01wifi` | runtime control socket, tmpfs |

No other script in this image writes any of these files. The GuppyScreen repo's own build tree
ships no config template that reaches a device — `NebulaOS-firmware`'s overlay is the only source
of the factory `guppyconfig.json`.

## Guarantee 1 — a valid factory GuppyScreen config always exists in the image

`scripts/build/overlay/opt/guppyscreen/guppyconfig.json` is baked into the read-only squashfs
rootfs and is part of every build. It is valid JSON, and it names the paths this image actually
provides:

- `log_path` → `/opt/printer_data/logs/guppyscreen.log` — created by `S02nebulaos-namespace`
  (`$NEBULAOS_ROOT/printer_data/logs`) inside the tree `S01persistent-datastore` binds over
  `/opt/printer_data`, so it exists and is writable long before `S58guppyscreen` starts.
- `guppy_init_script` → `/etc/init.d/S58guppyscreen` — this image's real GuppyScreen service
  script, which implements `start|stop|restart`. This is what "Restart Guppy" invokes.
- `wpa_supplicant` → `/var/run/wpa_supplicant` — the control-socket *directory*, matching the
  `ctrl_interface` `S01wifi` writes. GuppyScreen scans that directory for the interface socket
  (`WpaEvent::init_wpa()`, `KUtils::get_wifi_interface()`), so a directory is the correct value here.
- `moonraker_host`/`moonraker_port` → `127.0.0.1:7125`, matching
  `overlay/opt/printer_data/config/moonraker.conf`.
- `default_macros` → `_GUPPY_LOAD_MATERIAL` / `_GUPPY_QUIT_MATERIAL`, both defined in
  `overlay/opt/printer_data/config/GuppyScreen/guppy_cmd.cfg`.

Keys the factory file deliberately omits (`touch_calibrated`, `prompt_emergency_stop`,
`default_extruder_temp`, root-level `display_sleep_sec`, `invert_y_direction`,
`invert_z_direction`) are filled in by `Config::init()` on first run and written back to the same
file. That write only succeeds because of Guarantee 2.

## Guarantee 2 — the factory config is seeded once, then owned by the user

`S01persistent-datastore` mounts `mmcblk0p10` at `/usr/data`, then:

```sh
seed_once() {
	src="$1"
	dst="$2"
	[ -e "$dst" ] && return 0
	mkdir -p "$(dirname "$dst")"
	cp -a "$src" "$dst"
}

seed_once /opt/guppyscreen/guppyconfig.json "$GUPPY_STATE/guppyconfig.json"
mount --bind "$GUPPY_STATE/guppyconfig.json" /opt/guppyscreen/guppyconfig.json
```

- **Virgin boot:** `/usr/data/nebulaos/guppyscreen/guppyconfig.json` does not exist, so the factory
  file is copied there (mode 644, root-owned, preserved by `cp -a`), then bind-mounted over
  `/opt/guppyscreen/guppyconfig.json`.
- **Every later boot:** the destination exists, so `seed_once` returns immediately. The factory
  defaults never overwrite the user's file.

GuppyScreen resolves its config as `dirname(/proc/self/exe)/guppyconfig.json` (`main.cpp`) — i.e.
`/opt/guppyscreen/guppyconfig.json`, with no override flag. The bind mount is what makes that
hardcoded path resolve to real writable storage. Without it, `Config::init()`'s closing
`std::ofstream o(config_path)` would fail against the read-only squashfs and nothing GuppyScreen
saves — touch calibration, sleep timeout, sensor layout — would persist.

**Phase 1.5 persistent-namespace mission (2026-08-18):** the `/usr/data` top-level compatibility
symlinks this section used to document here (`/usr/data/printer_data -> /opt/printer_data`,
`/usr/data/guppyscreen -> /opt/guppyscreen`) are REMOVED. They existed only because GuppyScreen's
own compiled binary hardcoded a handful of `/usr/data/printer_data/...` and
`/usr/data/guppyscreen/...` paths instead of the already-correct `/opt/...` bind-mount paths this
guarantee documents; that GuppyScreen-side hardcoding is fixed (see `NebulaOS-guppyscreen`'s
`phase1.5/persistent-namespace` branch), so nothing in the shipped image needs the top-level
aliases anymore. The incident this section used to warn about (`ln -sf` silently landing inside a
real pre-existing stock directory and overwriting a real stock binary) is now moot for these two
paths specifically, because nothing creates the symlink at all — see
`NEBULAOS_PERSISTENT_NAMESPACE.md` for the full ownership reasoning and
`S01persistent-datastore`'s own history comments for the forensic incident record.

## Guarantee 3 — a valid, credential-free WiFi config exists if none is saved

`S01wifi` runs before anything that needs the network, and before `wpa_supplicant` starts. As of
Phase 1.5, the config-path decision itself is delegated to `/etc/nebulaos-wifi-migrate.sh`'s
`nebulaos_wifi_migrate()`, which sets `NEBULAOS_WIFI_CONF` to the canonical path — this is a safe
migration, not a plain seed-once, because the same file is also this device's primary SSH access
path (see `NEBULAOS_PERSISTENT_NAMESPACE.md` §"Wi-Fi migration" for the full case-by-case
algorithm and `tests/nebulaos-wifi-migrate-tests.sh` for its test matrix). On a genuinely virgin
device (case C — neither the new canonical path nor the old one exists), the effective behavior is
unchanged from before this mission:

```sh
NEW=/usr/data/nebulaos/network/wpa_supplicant.conf
...
umask 077
cat > "$NEW" <<-EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
EOF
...
```

- **Virgin boot:** the file is created at the new canonical path with exactly those two directives,
  mode `0600`, and zero SSID/PSK/country material. `wpa_supplicant` is then started as
  `wpa_supplicant -i wlan0 -c /usr/data/nebulaos/network/wpa_supplicant.conf`.
- **A device already provisioned before this mission** (old path is a real file, new path absent —
  case B): the credentials are copied to the new canonical path through a verified atomic
  copy-then-rename, the old path becomes a compatibility symlink to the new one only after that
  copy is verified byte-for-byte, and the original is never deleted or modified before that
  verification succeeds. See `NEBULAOS_PERSISTENT_NAMESPACE.md` for why this cannot be a plain
  `mv`.
- **Every later boot** (new path already exists — case A): the migration function returns
  immediately having changed nothing. A saved network is never replaced by the skeleton.

The daemon is started even with no saved network, deliberately: GuppyScreen's WiFi panel cannot
scan or configure anything unless `wpa_supplicant` is already running, and a virgin device has no
other way in.

## Guarantee 4 — GuppyScreen can actually configure and save WiFi

`wifi_panel.cpp` configures a network entirely through the control socket:

```
ADD_NETWORK → SET_NETWORK <id> ssid "…" → SET_NETWORK <id> psk "…"
→ ENABLE_NETWORK <id> → SELECT_NETWORK <id> → SAVE_CONFIG
```

Two things must hold for that to work, and both are part of the contract:

1. `update_config=1` must already be in the config file. `SAVE_CONFIG` is a silent no-op without
   it — the network would associate once and be gone after a reboot. `seed_default_conf()` writes it.
2. GuppyScreen must find the control socket. `guppyconfig.json`'s `wpa_supplicant` key
   (`/var/run/wpa_supplicant`) is the same directory as `S01wifi`'s `ctrl_interface`;
   `WpaEvent::init_wpa()` scans it and opens the first non-`p2p` socket it finds, so the interface
   name is discovered rather than hardcoded on either side.

`SAVE_CONFIG` makes `wpa_supplicant` rewrite `/usr/data/nebulaos/network/wpa_supplicant.conf` in
place, preserving the file's mode and owner. That is why the seed mode is `0600`: the mode chosen
at creation is the mode the user's plaintext PSK is stored under permanently. `wpa_supplicant`
rewrites the real file at the canonical path; the old-path compatibility symlink (when present)
keeps resolving to it automatically, since a symlink has no content of its own to go stale.

## Guarantee 5 — both survive reboot and whole-image update

Both files live on `mmcblk0p10` (`/usr/data`), which is shared, non-duplicated persistent storage
outside both A/B slots.

- **Reboot:** nothing rewrites either file; both seed functions are existence-guarded no-ops.
- **Whole-image update:** `scripts/flash-spare-slot.sh` writes only the inactive slot's kernel and
  rootfs (`mmcblk0p5`/`mmcblk0p7` or `mmcblk0p6`/`mmcblk0p8`). It never writes `mmcblk0p9` or
  `mmcblk0p10`. A new image therefore boots against the same persistent GuppyScreen config and the
  same saved WiFi network.

The consequence, stated plainly: **changing a factory default in the overlay only reaches devices
that have not been provisioned yet.** A device that has already booted NebulaOS keeps its
persistent copy by design. Correcting a shipped default on an existing device is a manual edit of
`/usr/data/nebulaos/...`, or a deliberate re-seed — not something an image update does on its own.

## Known limitations

- No genuinely virgin (never-written) slot-2 install has been verified on hardware; the guarantees
  above are verified by code reading and by sandbox simulation of the real seed functions, not by a
  first-boot run on a factory-clean device. Tracked in `PROJECT_CONTEXT.md`'s hardware
  qualification status.
- `guppyconfig.json`'s `thumbnail_path` (`/opt/guppyscreen/thumbnails`) names a directory that does
  not exist and could not be written if it did (read-only squashfs). It is unreachable on NebulaOS
  in practice — every caller is behind a `!KUtils::is_running_local()` branch and
  `moonraker_host` is `127.0.0.1` — so it is recorded here rather than changed. Path centralization
  is Phase B work.
- `guppyconfig.json` sets `display_sleep_sec` inside the printer object, but `Config::init()` and
  `sysinfo_panel.cpp` read the root-level key. The nested copy is inert; the root-level key is
  auto-created with the same value (600), so behavior is correct today. Also Phase B.
- An already-provisioned device keeps its `wpa_supplicant.conf` at whatever mode it was created
  with (0644 before the Phase 0 pass that set it to 0600 for new devices). Re-permissioning
  existing user state was deliberately not done.
- The Phase 1.5 old-to-new WiFi path migration (Guarantee 3) has been verified by code reading and
  by sandbox simulation of `nebulaos_wifi_migrate()` (`tests/nebulaos-wifi-migrate-tests.sh`), not
  by a real device carrying genuine prior credentials through an actual boot. Hardware
  verification of exactly this — existing WiFi/SSH surviving a migration boot — is step 8 of
  `_project/missions/2026-08-phase0-phase1-integration-closeout.md`'s morning hardware procedure,
  extended by this mission's own hardware procedure in its mission report.
