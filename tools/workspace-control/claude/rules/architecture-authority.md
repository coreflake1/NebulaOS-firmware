# Architecture authority (quick reference)

```
Architecture is not memory.
```

Derive current architecture from, in order:

1. a passing `tools/verify-workspace-identity.sh`
2. `CURRENT_STATE.md`
3. `NebulaOS-firmware/manifests/dependencies.conf` and the build scripts
4. `tools/verify-architecture.sh`

Never from recollection, historical reports, or README prose.

```
REPOSITORY_HEAD != SHIPPING_PIN
README prose is informative; executable source and machine-readable
integration state outrank it.
```

Known-stale today: `NebulaOS-firmware/README.md`, `NebulaOS-klipper-extensions/README.md`.
Scheduled for a separate documentation mission — do not treat as current, and do not
change source to match them.

Archive (`../NebulaOS-archive-*`) is preserved evidence, not authority, and is blocked
mechanically. Historical investigation is a separate, explicitly requested session.
