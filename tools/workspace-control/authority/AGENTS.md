# AGENTS.md

Read this before doing anything else in this workspace.

1. **Read [`WORKSPACE_RULES.md`](WORKSPACE_RULES.md) first.** It is the operational contract.

2. **Run `tools/verify-workspace-identity.sh` before any broad investigation, audit, or edit.**
   If it prints `WORKSPACE_IDENTITY_VALID=NO`, **STOP**. Do not audit, do not conclude, do not
   switch to some other local checkout, and do not rationalize the contradiction.

3. **`CURRENT_STATE.md` is valid only when the identity gate passes.** If the gate fails,
   treat `CURRENT_STATE.md` as stale until it is regenerated from verified evidence.

4. **Shipping dependency authority is `NebulaOS-firmware/manifests/dependencies.conf`.**
   A repository's latest `main` is *not* automatically what NebulaOS ships.
   `REPOSITORY_HEAD != SHIPPING_PIN`.

5. **Do not infer current architecture from historical reports or README prose.**
   Current source and current integration behavior outrank any narrative document,
   in this workspace or inside the repositories themselves.

6. **Never read or use `../NebulaOS-archive-*` unless the user explicitly asks for
   historical investigation.** It is preserved evidence, not authority. Archive access is
   also blocked mechanically; a denial is the guardrail working, not a bug to route around.

7. **The retired `NebulaOS-klipper` fork is not the host runtime source.** It is archived.
   Do not clone it into this workspace.

8. **Host Klipper is official upstream `Klipper3d/klipper` and must remain pristine.**
   The firmware build owns its exact dependency checkout; there is no top-level Klipper clone.

Additional hard rules: never operate the printer (no SSH, flashing, reboots, OTA markers,
MCU serial, motion, or heaters) unless the user explicitly asks for a hardware task.

---

## Architecture is not memory

Automatic project memory is **disabled** for this workspace. Current architecture must be
derived from: a passing identity gate, `CURRENT_STATE.md`, the firmware integration manifest
and executable source, and `tools/verify-architecture.sh`. Never from recollection or prose.

## Documentation is not architecture authority

```
README prose is informative.
Executable source and machine-readable integration state outrank it.
```

Known-stale documents exist today in `NebulaOS-firmware/README.md` and
`NebulaOS-klipper-extensions/README.md` (they still describe the retired Klipper fork and the
removed PRTouch stack). They are scheduled for a separate documentation mission. Until then,
do not treat them as current, and do not "correct" the source to match them.

## Agent-use policy

One main programmer, two independent specialist reviewers. Do not spin up multiple
general-purpose agents to solve the same implementation task, and do not create agent teams.

**Routine work — main Claude works directly.** Local, single-repo, low-risk changes:
typo fixes, comments, documentation wording, a contained bug fix, test tweaks.

**Architecture-sensitive work — run `nebula-architect` BEFORE implementation:**

```
multi-repo changes            boot/update/recovery
dependency changes            power-loss recovery (PLR)
Klipper composition           calibration architecture
kernel architecture           persistent config ownership
MCU lifecycle                 public API changes
                              release candidate composition
```

The architect returns `ARCHITECTURE_REVIEW=PASS|PASS_WITH_NOTES|FAIL`. On `FAIL`, fix the
plan before writing code — do not implement and hope the verifier catches it.

**Substantial implementation — run `nebula-verifier` AFTER the change.** It returns
`VERIFICATION=PASS|FAIL` with evidence. It reports problems; it does not fix them. Fixing is
the main programmer's job.

Do not invoke either agent for trivial typo or wording changes. Both are read-only with
respect to source, by configuration as well as by instruction.

## This authority layer is derived state

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md` and `.claude/` are installed from
`NebulaOS-firmware/tools/workspace-control/`, which is version-controlled. The identity gate
fails on drift. To change them: edit the canonical copy, then run
`tools/sync-workspace-control.sh`. Never hand-edit the root copies.
