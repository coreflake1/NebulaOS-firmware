# Deferred post-release work

Work that is understood, scoped, and deliberately **not** being done in the
current release cycle. Each entry says why it was deferred and what it needs
before it can start — a deferral without a reason is just a forgotten task.

---

## 1. Identity-gate fast-path consolidation

**Status:** deferred to post-release.
**Requires:** Architecture Guardian (`nebula-architect`) review **before**
implementation.

### What

Consolidate the offline fast path of `tools/verify-workspace-identity.sh`
(`--hook` / `--local`) so that it runs as a single process instead of ~88
forked commands.

### Why it is worth doing

The PreToolUse hook runs this gate before **every** `Bash`, `Edit`, `Write` and
`NotebookEdit`. Measured on this host:

| | before | after the batching fix | remaining |
|---|---|---|---|
| gate `--hook` | 195 ms | 137 ms | ~88 forks |
| PreToolUse, no-op `Bash` | 250 ms | 190 ms | |
| PreToolUse, `Edit` | 249 ms | 189 ms | |

The batching fix already landed: the control-file loop forked `sha256sum`+`awk`
twice per manifest line (60 processes for 15 files) and now issues two
`sha256sum` calls over the same files, comparing the same SHA-256 values —
62 ms → 2 ms in isolation.

What remains is diffuse. Every fork costs ~1.5 ms because the gate runs inside
bubblewrap, and the cost is spread over ~36 `git` invocations plus ~52
`grep`/`sed`/`cut`/`wc` calls with no single hot spot left. Consolidating the
whole offline path into one process is estimated at ~30–40 ms, but it means
rewriting a 640-line security-critical script.

### Why it was deferred

Two reasons, both structural rather than about effort:

1. **It is architecture-sensitive work.** `AGENTS.md` requires
   `nebula-architect` review *before* implementation for changes to the
   workspace authority layer. How the identity gate is evaluated is exactly
   that.
2. **It sits immediately before hardware qualification.** The gate is what
   makes every other guarantee in this workspace checkable. Rewriting it in the
   same cycle that freezes a release candidate trades a bounded, measured
   annoyance for an unbounded correctness risk.

### Constraints any implementation must keep

Non-negotiable, and the reason this cannot be a casual refactor:

- **Fail closed.** Every error path denies. A gate that cannot prove the
  workspace is sound must refuse, including "the gate itself is broken".
- **No weakening of** archive isolation, agent privilege binding, launcher
  content binding, or release identity checks.
- **Keep the mode split.** The fast local gate is for per-tool-call use; the
  full online gate (`--full`) stays mandatory at commit/push/build/flash/release
  boundaries. These must not converge.
- **Hashing stays hashing.** An mtime/size fingerprint cache was considered and
  rejected: it is cheaper but strictly weaker than comparing content, and this
  is a security boundary, not a build system.
- The existing fail-closed behaviours must keep their tests — drift detected on
  a tampered file, and a short read (an unreadable file) refusing the *whole*
  control layer rather than silently checking fewer files than the manifest
  lists.

---

## 2. Release artifact packaging formats

**Status:** deferred. Explicitly out of scope for the current cycle.

- Creality `.img` packaging
- Ingenic `.ingenic` packaging
- DarKE port
- OpenKlipperEdition Recovery port

### Why deferred

These are valuable, but introducing new release artifact formats immediately
before hardware qualification would mean qualifying bytes that no prior cycle
has produced. The artifacts being frozen for this qualification remain the
existing canonical core set (`xImage`, `rootfs.squashfs`).

`tools/maintenance/build-cache-gc.sh` already refuses to collect `.img` and
`.ingenic` files should they appear, so the GC tool does not need revisiting
when this work starts.

---

## 3. `build-manifest.txt` does not record `source_date_epoch`

**Status:** deferred. Worked around correctly; the manifest gap itself remains.

`scripts/build/05-final-build.sh` writes `build-manifest.txt` with `built_at`,
every component commit and every artifact hash — but never the reproducibility
epoch, even though `build.sh` computes it, exports it, refuses to build without
it, and prints it.

This was found when the build launcher's attestation read the epoch with
`grep '^source_date_epoch='` and silently wrote a blank: through `grep`, a
missing key and an empty value are indistinguishable, so the attestation
recorded nothing while still claiming to be complete.

**Already fixed, in the launcher:** the attestation now derives the epoch from
the committer date of the firmware commit being built — the same derivation
`build.sh` uses, from the same commit, so it is authoritative by construction
rather than dependent on a key that does not exist. The attestation is now also
withheld outright if the epoch (or any other promised field) is blank, because
an attestation that is present but hollow reads as evidence.

**Still worth doing:** have stage 05 record `source_date_epoch` in the manifest
directly, so the manifest is self-describing and any future consumer can read
the epoch from the artifact set without re-deriving it from git.

**Why deferred:** `build-manifest.txt` is shipped in the image and is an input
to `06-verify.sh`'s assertions. Changing its content in the same cycle that
freezes a release candidate would mean qualifying a manifest shape no previous
build produced. The launcher-side derivation is contained and changes no build
output at all.

---

## 4. `rootfs.ext2` metadata reproducibility

**Status:** pre-existing, documented follow-up. Unchanged by the current cycle.

`rootfs.ext2` is not yet byte-reproducible due to filesystem metadata
(timestamps and inode ordering) that the current image generation does not
fully pin. `xImage` and `rootfs.squashfs` **are** byte-reproducible and are what
the reproducibility proof asserts.

This remains a separate follow-up. It is in scope for the current cycle only in
the negative sense: if a change here unexpectedly regressed `rootfs.ext2`
*content* equivalence, that would be a defect to fix now.
