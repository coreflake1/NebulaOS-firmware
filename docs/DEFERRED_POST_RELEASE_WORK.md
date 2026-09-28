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

**Status:** PARTIALLY UN-DEFERRED (2026-09-28, universal-release mission). Read
the scope limits below before treating either artifact as installable.

- Creality `.img` packaging — **built, blank-media scope only**
- Ingenic `.ingenic` packaging — **built, Creality-cloner compatibility UNVERIFIED**
- DarKE port — still deferred, not started
- OpenKlipperEdition Recovery port — still deferred, not started

### Why it was deferred, and what changed

The original reasoning stands and has not been overturned: introducing new
release artifact formats immediately before hardware qualification would mean
qualifying bytes that no prior cycle has produced. **The artifacts frozen for
hardware qualification remain the canonical core set (`xImage`,
`rootfs.squashfs`) and nothing here changes that.**

What changed is that the packaging was explicitly requested as a deliverable, so
it now exists as *packaging of the same canonical core* rather than as a new
thing to qualify. Both formats consume the already-built `xImage` and
`rootfs.squashfs` byte-for-byte and compile nothing, which is the property that
makes them additive rather than a new qualification surface. Their validators
assert exactly that.

### Hard scope limits, and why they exist

**`.img` is a blank-media provisioning image. It must never be written to a
printer that already carries factory data.** Three reasons, recorded
machine-readably in every generated manifest as
`IMG_NOT_FOR_PROVISIONED_PRINTER_BECAUSE=`:

1. **`sn_mac` is irreplaceable.** `/dev/mmcblk0p2` (1024 bytes) holds the
   per-unit factory MAC and serial —
   `26096911004C14;FCEE11004C14;F005;NEBULA V1.0.0.1` on the reference unit,
   confirmed in `docs/NEBULAOS_WIFI_CAMERA_RT_LIVE_QUALIFICATION_REPORT.md` to
   be the address stock's `wlan0` actually uses. A raw whole-disk write zeroes
   it, permanently. NebulaOS is separately scheduled to *start* reading this
   partition rather than deriving its own MAC, which makes destroying it worse,
   not better.
2. **The stock slot cannot be restored.** A whole-disk image empties p5/p7, the
   fallback `docs/DEVELOPER_RECOVERY.md` designates as the way back. We do not
   have Creality's stock kernel and rootfs and could not redistribute them.
3. **The geometry is unverified.** No `sgdisk --print /dev/mmcblk0` has ever
   been captured, so the absolute start offsets in the authored partition table
   are a reconstruction. `tools/emmc/nebulaos_layout.py` lists every declared
   fact by name.

The update path for a working printer is unchanged and unaffected:
`scripts/flash-spare-slot.sh`, which writes `kernel2` and `rootfs2` and touches
nothing else.

**`.ingenic` carries `CREALITY_CLONER_COMPATIBLE=UNVERIFIED`.** Creality's
recovery tool for this printer is a closed Windows binary
(`cloner-2.5.18-windows_alpha.zip` in `CrealityOfficial/Ender-3_V3_KE_Annex`);
no sample package and no format specification are published. The container is
therefore a NebulaOS format with a `NEBULAOS-RECOVERY` magic at offset 0, chosen
so a foreign tool rejects the file outright rather than misreading its header
and beginning a partial flash. It is end-user/factory recovery media and is
explicitly not a Hardware Agent transport (`HARDWARE_AGENT_TRANSPORT=NO`).

### What would close the remaining gaps

- **`.img` whole-disk to a real printer:** a captured factory GPT, a per-unit
  `sn_mac` preservation step, and a redistributable stock slot. All three, not
  any one. `tools/emmc/nebulaos_layout.py:require_whole_disk_preconditions()`
  enumerates them at runtime.
- **`.ingenic` compatibility:** a reference `.ingenic` package to parse and
  compare against. Until one exists, the claim stays UNVERIFIED — never `YES`,
  and the validator fails if it ever drifts.

`tools/maintenance/build-cache-gc.sh` already refuses to collect `.img` and
`.ingenic` files, so the GC tool still needs no revisiting.

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
