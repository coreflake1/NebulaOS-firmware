# WORKSPACE_RULES.md

The operational contract for this workspace. `AGENTS.md` is the short form; this is the detail.

---

## 1. Active repositories

Exactly five NebulaOS development repositories are active here. All canonical remotes are under
`https://github.com/coreflake1/`.

| Path | Canonical remote | Active branch | Role |
|---|---|---|---|
| `NebulaOS-firmware/` | `coreflake1/NebulaOS-firmware` | `main` | Integration & build authority; owns every dependency pin |
| `NebulaOS-klipper-extensions/` | `coreflake1/NebulaOS-klipper-extensions` | `main` | NebulaOS-owned host Klipper functionality |
| `NebulaOS-klipper-mcu/` | `coreflake1/NebulaOS-klipper-mcu` | `main` | GD32F303 application firmware development |
| `NebulaOS-kernel/` | `coreflake1/NebulaOS-kernel` | `openke` | X2000 Linux kernel development |
| `NebulaOS-guppyscreen/` | `coreflake1/NebulaOS-guppyscreen` | `main` | Touchscreen frontend |

Nothing else in this workspace is a source repository. The workspace root is deliberately
**not** a git repository.

## 2. Allowed paths

Active root contains only: the five repositories above, the five root authority files
(`AGENTS.md`, `CLAUDE.md`, `README.md`, `CURRENT_STATE.md`, `WORKSPACE_RULES.md`), and
`docs/`, `tools/`, `evidence/`.

Do **not** recreate any of these in the active root:

```
_worktrees/   _scratch/   _project/   _evidence/   roadmap/
NebulaOS-klipper/   NebulaOS/
RC2-MANIFEST.txt   FINAL-PREHW-RC-MANIFEST.txt   PROJECT_CONTEXT.md
```

They existed in the previous workspace generation and are preserved in the archive. Their
presence in an active root is precisely what let agents audit the wrong generation.

Long-lived parallel checkouts (`git worktree`) of the active repositories are not permitted in
this root. If you need one, create it outside the workspace and remove it when done.

## 3. Authority hierarchy

Highest wins. Never resolve a conflict in the other direction.

1. **Canonical GitHub remote** — for repository branch identity. Establish it with real git
   mechanics (`git ls-remote`, `rev-parse`, `merge-base`, `log`). A local checkout's
   remote-tracking refs may be arbitrarily stale; do not trust them.
2. **`NebulaOS-firmware/manifests/dependencies.conf`** plus the build/integration scripts —
   for what NebulaOS actually ships.
3. **Current source and current integration behavior** — for architecture.
4. **`CURRENT_STATE.md`** — local human-readable summary, *and only when the identity gate passes*.
5. **Historical reports and README prose** — may explain *why* something exists. They may
   **never** override current source identity.

If `CURRENT_STATE.md` disagrees with the canonical remote or the firmware manifest, then
`CURRENT_STATE_STALE=YES` and `WORKSPACE_IDENTITY_VALID=NO`. Correct the authority layer.
Do not rationalize the contradiction.

## 4. Development HEAD vs shipping pin

```
REPOSITORY_HEAD != SHIPPING_PIN
```

A repository's latest `main` is **not** automatically the version NebulaOS ships. The firmware
manifest decides. A shipping pin that trails its repository HEAD is normal and is not a defect;
report the two as separate facts and never silently promote one to the other.

## 5. Extensions `main` vs `production`

- `main` — development/integration branch. This is what the active clone checks out.
- `production` — the exact runtime/release branch followed by Moonraker on the printer.

The firmware manifest declares the runtime branch (`KLIPPER_EXTENSIONS_BRANCH=production`) and
pins the exact commit (`KLIPPER_EXTENSIONS_PIN`). The identity gate requires the pin to equal
the **remote `production` tip**. It deliberately does **not** require `main == production`:
that equality is true today but may legitimately stop being true during future development.

## 6. Retired repositories

- **`NebulaOS-klipper`** — the retired historical host-Klipper fork. It is **not** the host
  runtime source and must not be cloned here.
- **Host Klipper** is official upstream `Klipper3d/klipper`, pinned by the firmware manifest and
  checked out by the build into its own (gitignored) `NebulaOS-firmware/vendor/` tree. It must
  remain pristine — no NebulaOS patches. There is no permanent top-level Klipper clone.
- **`NebulaOS`** (release front door) and **`NebulaOS-workspace`** are not part of the everyday
  coding workspace. Add one back only for a concrete, current development reason.

## 7. Archive prohibition

The previous workspace generation is preserved wholesale as a sibling `NebulaOS-archive-*`
directory. It is evidence, not authority.

- Do not read it to determine current source identity.
- Do not import material from it into the active workspace.
- Use it only when the user explicitly asks for historical investigation.
- Never nest an archive inside the active workspace.

If you need a historical fact, verify it independently against current sources and write the
verified fact into the authority layer. Do not transplant historical narrative.

## 8. Identity-gate semantics

`tools/verify-workspace-identity.sh` is executable enforcement, not documentation. Run it before
any broad investigation, audit, or edit.

It validates, per repository: canonical path, canonical remote, expected active branch, local
HEAD equal to the current remote branch head, a clean working tree, and a single working tree.
It additionally validates the shipping pins, the MCU integration provenance (including the
vendored binary's sha256 against its sidecar), workspace topology, the absence of forbidden
legacy paths, and the presence of the root authority files.

On any contradiction it prints:

```
WORKSPACE_IDENTITY_VALID=NO
AUDIT_SOURCE_IDENTITY_VALID=NO
AUDIT_VERDICT=INVALID
```

and exits non-zero. That is a **hard stop**. Do not continue an audit against a plausible older
generation, do not silently switch to another checkout, and do not explain the contradiction away.

`--offline` skips remote comparison and therefore can never report a valid identity; it exists
for local inspection only.

## 9. Source / build / hardware qualification are three different things

Keep these strictly separate and never let one imply another:

- **`SOURCE_VERIFIED`** — this workspace matches the canonical remote generation.
- **`BUILD_VERIFIED`** — a specific commit was actually built and passed `06-verify`.
- **`HARDWARE_QUALIFIED`** — a specific build was flashed to real hardware and passed its gates.

A newer source HEAD is **never** automatically build-verified or hardware-qualified. Qualification
is a property of an exact commit, proven by direct evidence — not inferred from commit dates,
prose, or the fact that an earlier commit passed.

## 10. Historical reports are not current state

No report under any `_project/`, `_evidence/`, `roadmap/`, or archived tree may be treated as a
description of current state, however confident its wording. A closure report describes what was
true when it was written. Re-verify before relying on it.

An audit must never report `VERDICT=PRODUCTION_READY` while simultaneously claiming that known
production functionality sits unmerged on an old feature branch. That combination means the audit
source is wrong, not that the project is in that state.

## 11. Printer safety

Host-workspace work never touches the printer. No SSH, flashing, reboots, OTA marker changes, MCU
serial operation, motion, or heaters unless the user explicitly asks for a hardware task.

## 12. The workspace control layer

Root `AGENTS.md`, `CLAUDE.md`, `WORKSPACE_RULES.md`, `.claude/`, and `tools/*.sh` are
**derived state**. Their canonical, version-controlled source is:

```
NebulaOS-firmware/tools/workspace-control/
```

That directory is developer tooling. It is mechanically excluded from the production rootfs:
the build copies exactly three trees out of the repository into the image
(`scripts/build/overlay/`, `scripts/build/vendor-wheels/`, `scripts/build/vendor-patches/`,
per `scripts/build/02-configure-buildroot.sh`), and `tools/` is not among them.

- `tools/workspace-control/MANIFEST` maps every canonical file to its installed location.
  Both the installer and the drift check read that one file, so they cannot disagree.
- The identity gate hashes each installed file against its canonical source. Any difference
  sets `WORKSPACE_CONTROL_VALID=NO` and therefore `WORKSPACE_IDENTITY_VALID=NO`.
- Verification never repairs drift. Repair is a deliberate, explicit act:

```bash
tools/sync-workspace-control.sh          # show what would change
tools/sync-workspace-control.sh --apply  # install canonical -> root
```

To change the authority layer, edit the canonical copy and re-sync. Never hand-edit the root
copies: the next gate run will flag them, and a re-sync will discard the edit.

The workspace root remains **not** a git repository. Derived root state is deliberately not
committed anywhere; it is reproducible from tracked canonical templates.

## 13. Identity gate modes

```
tools/verify-workspace-identity.sh            # full (default)
tools/verify-workspace-identity.sh --full     # explicit; includes network
tools/verify-workspace-identity.sh --local    # fast, no network
```

`--full` compares every local HEAD against the canonical remote via `git ls-remote`. It is the
authoritative check and is what a session start and any audit must use.

`--local` validates paths, remotes, branches, cleanliness, topology, forbidden paths, control
drift, and sentinels — everything that does not need the network. It exists so a `PreToolUse`
hook can gate every edit in milliseconds without a network round trip. It never reports
`WORKSPACE_IDENTITY_VALID=YES` on its own authority for audit purposes; it reports
`LOCAL_IDENTITY_VALID`.

`--offline` remains a synonym for a local-only run that can never validate a full identity.

## 14. Launch location

Development sessions must start from the workspace root:

```
/home/tim/workspace/NebulaOS
```

Project `.claude/settings.json` — and therefore every hook, permission, and subagent — loads
from the primary project directory. Launching Claude with one of the five repositories as the
primary directory would silently bypass all of it.

Each active repository therefore carries a machine-local sentinel at
`<repo>/.claude/settings.local.json`, excluded via `<repo>/.git/info/exclude` so it never
dirties the repository and is never committed. If a session starts inside a repository, the
sentinel reports:

```
NEBULAOS_WORKSPACE_ROOT_VALID=NO
```

blocks source modification, and tells the user to restart from the workspace root. Reading for
diagnosis stays available. The sentinels do not duplicate these rules; they point back here.

Sentinel presence and content are verified by the identity gate and cannot silently drift.

## 15. Architecture invariants

`tools/verify-architecture.sh` answers a different question from the identity gate:

```
identity      -> am I looking at the right source generation?
architecture  -> does this source still satisfy the frozen NebulaOS architecture?
```

Invariants are derived mechanically from current source. An invariant that cannot be checked
honestly is reported as `DOCUMENTED_ONLY` rather than given a misleading test that would pass
for the wrong reason.

## 16. Historical investigation is a separate session

The archive is blocked for normal sessions at several layers at once (permission deny rules,
a sandbox filesystem `denyRead`, and these rules). Subagents inherit those restrictions, and
no project subagent is granted an exception.

Historical investigation is a **separately launched, explicitly user-requested session**. See
`NebulaOS-firmware/tools/workspace-control/historian/README.md`. The normal programming
environment must never consult history automatically.
