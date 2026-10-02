# Architecture authority (quick reference)

```
Architecture is not memory.
```

Derive current architecture from current source:

1. `NebulaOS-firmware/manifests/dependencies.conf` and the build scripts
2. `tools/verify-architecture.sh`
3. `CURRENT_STATE.md` as a snapshot, re-derived before relying on it

Workspace mode is DEV unless the human explicitly starts RELEASE work
(WORKSPACE_RULES section 0).

Never from recollection, historical reports, or README prose.

```
REPOSITORY_HEAD != SHIPPING_PIN
README prose is informative; executable source and machine-readable
integration state outrank it.
```

Known-stale today: `NebulaOS-firmware/README.md`, `NebulaOS-klipper-extensions/README.md`.
Scheduled for a separate documentation mission — do not treat as current, and do not
change source to match them.

The archived workspace (sibling `*-archive-*`) is preserved evidence, not authority, and is blocked
mechanically. Historical investigation is a separate, explicitly requested session.
