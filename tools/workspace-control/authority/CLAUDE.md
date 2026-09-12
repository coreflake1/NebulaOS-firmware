@AGENTS.md

# Claude-specific notes

**Architecture is not memory.**

Current architecture must be derived from, in this order:

1. a successful workspace identity gate (`tools/verify-workspace-identity.sh`)
2. `CURRENT_STATE.md`
3. the firmware integration manifest / executable source
   (`NebulaOS-firmware/manifests/dependencies.conf` and the build scripts)
4. architecture invariants (`tools/verify-architecture.sh`)

Never reconstruct current architecture from historical prose, from a previous
session's recollection, or from README narrative.

Automatic project memory is disabled for this workspace on purpose. If you
believe you "remember" a NebulaOS architectural fact, re-derive it from the
four sources above before acting on it.

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md` and `.claude/` are derived
state, installed from `NebulaOS-firmware/tools/workspace-control/`. Edit the
canonical copy there and run `tools/sync-workspace-control.sh`; do not hand-edit
the root copies.
