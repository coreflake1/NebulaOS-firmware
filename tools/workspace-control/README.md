# workspace-control — canonical source for the NebulaOS Claude guardrails

Developer tooling. **Not shipped.** See "Production exclusion" below for the proof.

The NebulaOS workspace root is deliberately *not* a git repository. Without this directory,
the root `AGENTS.md` / `CLAUDE.md` / `WORKSPACE_RULES.md` / `.claude/` would be an unreviewed,
unversioned authority island — exactly the kind of drift-prone state that let an earlier audit
reason from an obsolete generation. So the canonical copies live here, in version control, and
the root holds only **derived state**.

```
MANIFEST                     canonical -> installed mapping (one source of truth)
authority/                   AGENTS.md, CLAUDE.md, WORKSPACE_RULES.md
claude/
  settings.json              permissions, sandbox, hooks, autoMemoryEnabled=false
  agents/                    nebula-architect.md, nebula-verifier.md
  rules/                     architecture-authority.md
  hooks/                     session-start.sh, pre-tool-use-identity.sh
scripts/
  verify-workspace-identity.sh   identity gate (--full | --local | --hook)
  verify-architecture.sh         architecture invariants
  sync-workspace-control.sh      the one explicit installer
sentinel/settings.local.json machine-local nested-repo launch sentinel
historian/                   documentation only - deliberately NOT a subagent
```

## Install / repair

```bash
tools/sync-workspace-control.sh            # dry run: show what would change
tools/sync-workspace-control.sh --apply    # install canonical -> root
tools/verify-workspace-identity.sh         # confirm
```

Verification **never** repairs drift. Silently healing a modified root would destroy the
evidence that something changed it, so repair is always a deliberate, explicit act.

## Design

```
Human
  |
  v
Main Claude programmer
  |
  +--> nebula-architect   read-only independent review BEFORE implementation
  |
  +--> nebula-verifier    independent verification AFTER implementation

Deterministic enforcement:
  workspace identity gate + control drift detection
  architecture invariants
  SessionStart / SessionStart(compact) / PreToolUse hooks
  archive isolation (permissions + OS sandbox + hook)
  nested-repo launch sentinels
```

One main programmer, two specialist reviewers. Not a team, not multiple general-purpose
programmers. Both reviewers are read-only with respect to source by configuration (no Edit /
Write / NotebookEdit tool), not merely by instruction, and neither has persistent memory.

## Gate modes

| Mode | Network | Clean-tree check | Used by |
|---|---|---|---|
| `--full` (default) | yes | yes | session start, audits, humans |
| `--local` | no | yes | fast local inspection |
| `--hook` | no | **no** | `PreToolUse` |

`--hook` omits the clean-tree check on purpose. Cleanliness is an audit property, not an
identity property: if the gate demanded a clean tree, the first edit would dirty a repo and
block every edit after it. It still enforces launch location, remotes, branches, topology,
forbidden paths, control drift, and sentinels — and it fails closed.

## Production exclusion (proof)

The build copies exactly three trees out of this repository into the image. Enumerated
mechanically over every build script:

```
$ grep -rnE '(cp|rsync|install|tar)[^|;]*\$REPO_ROOT' scripts/build/*.sh scripts/build/lib/*.sh

02-configure-buildroot.sh:112  cp -r $REPO_ROOT/scripts/build/overlay/.        -> buildroot overlay
02-configure-buildroot.sh:143  cp    $REPO_ROOT/scripts/build/vendor-wheels/*  -> buildroot wheels
02-configure-buildroot.sh:144  cp    $REPO_ROOT/scripts/build/vendor-patches/… -> buildroot package
```

Every other `$REPO_ROOT` reference copies *out* to `artifacts/`, not into the image.
`tools/workspace-control/` is under none of the three source roots, and `06-verify.sh`'s image
manifest contains no repo-root `tools/` path. Adding files here therefore cannot change the
rootfs.

Do not confuse repo-root `tools/` (developer tooling, not shipped) with
`scripts/build/overlay/opt/nebulaos/tools/` (shipped to `/opt/nebulaos/tools`).
