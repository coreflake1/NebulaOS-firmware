# NEBULAOS_BUILDROOT_2025_MIGRATION — final report

> Reproducibility (§27) is filled in from the two clean builds. Until both have
> run on the final candidate SHA, that section reads
> `IMAGE_REPRODUCIBILITY=NOT_YET_PROVEN` and must not be read as anything else.

## MISSION RESULT

```
MISSION=NEBULAOS_BUILDROOT_2025_MIGRATION
BRANCH=buildroot-2025.02-migration
BASE=fd4a365e9cc2b7dd478547bde00a272decee220e
COMMITS=11
```

## PLATFORM

```
BUILDROOT=2025.02.18  (buildroot/buildroot @ d030e36bbc9669230c015be971b14b6e062cfdde)
GCC=13.4.0
BINUTILS=2.43.1
GLIBC=2.41-161-g5dd252cf1d113644b3679f5a158e9ef20217865e  (Buildroot default)
PYTHON=3.12.14
OPTIMIZATION=-Os   (BR2_OPTIMIZE_S=y, plus an independent -Os in the app-stack cross-compile)
ARCH=mipsel / xburst / MIPS32R2 / OABI32 / FPXX / legacy NaN
```

All five toolchain/arch values were read back from the **built artifacts**, not
from the configuration that requested them.

## PARITY

```
OLD_BUILDROOT_CAPABILITIES_INVENTORIED=YES
UNACCOUNTED_CAPABILITIES=0
PARITY_GATE=PASS   (tests/buildroot-defconfig-parity-tests.sh: 240 assertions, 0 failures)
```

Of 546 symbols set in the old configuration, **3** are absent from 2025.02.18:
two are hidden capability flags for packages that were never enabled (midori,
mongrel2), and `BR2_TARGET_ROOTFS_EXT2_REV` is a derived value whose selector
`BR2_TARGET_ROOTFS_EXT2_2r1` still exists and is still set. All **264**
previously-enabled packages still exist; **194** real packages are asserted
enabled by value in the gate (the other 70 are auto-derived capability flags).

Full classification: `docs/BUILDROOT_2025_MIGRATION_PARITY.md`.

### Intentional differences

| Change | Why |
|---|---|
| GCC 12.3.0 → 13.4.0 | mission target; also the 2025.02.18 default |
| binutils 2.40 → 2.43.1 | 2.40 was **removed** upstream; its symbol survives only as a legacy stub that selects `BR2_LEGACY`, and Buildroot refuses to build in that state |
| Python 3.11.6 → 3.12.14 | mission target |
| `BR2_GLOBAL_PATCH_DIR` dropped | its only content was three kernel patches **proven never applied** (`OVERRIDE_SRCDIR` ⇒ rsync, not extract+patch; `.stamp_rsynced` present, `.stamp_patched` absent) |
| `BR2_ROOTFS_POST_IMAGE_SCRIPT` dropped | inherited `board/qemu/post-image.sh` cruft |
| matplotlib 3.4.3 → 3.10.0, numpy from stock | retires a vendored `.mk` overwrite and a cp311 wheel |

Nothing was removed for size or tidiness (§19).

## PYTHON

- **Remaining `python3.11` references: 0 in executable code.** What remains are
  historical mentions inside comments and in `FIRMWARE.md`/`docs/` narrative,
  describing what the old build did.
- Target paths and the CPython ABI tag are **derived**, never written down:
  `sysconfig`/`EXT_SUFFIX` at build time, and 06-verify discovers the
  interpreter from the image.
- **Klipper**: builds and ships; `c_helper.so` present; venv provisioned.
  Python 3.12 runtime behaviour is **NOT TESTED** (needs hardware).
- **Moonraker**: builds and ships. `importlib_metadata` and `zipp` retained —
  `moonraker/utils/source_info.py` imports the **backport**, which stdlib
  `importlib.metadata` does not satisfy.
- **Native extensions**: 128 modules, **all** `cpython-312-mipsel-linux-gnu`,
  gated by 06-verify. `streaming_form_data/_parser` confirmed ELF 32-bit MIPS32
  rel2. Zero x86-64 objects in the target.
- **48/48** Python distributions from the old image are accounted for.

## VENV

Scope corrected mid-mission: NebulaOS is unreleased and `/usr/data/nebulaos` is
NebulaOS-owned, so there is no deployed 3.11 venv to migrate. What ships is
**interruption-safe, idempotent provisioning** of fresh 3.12 venvs.

- **Detection**: `venv_is_usable` requires the interpreter to exist, be
  executable, actually run, have a `pyvenv.cfg`, and satisfy the component's
  import smoke test. It replaces `[ -x bin/python3 ]`, which treated a
  half-created environment as finished.
- **Atomicity**: `swap_venv_into_place` renames the old aside, moves the new in,
  then deletes — removing a window in which the machine had **no** environment
  and a power cut was unrecoverable.
- **Recovery**: `recover_torn_venv` triggers on ".old exists AND the env is
  unusable", never on the env being absent — `S02nebulaos-namespace` recreates
  it empty before S04 runs, so an absence test could never fire.
- **Tests**: `tests/venv-platform-migration-tests.sh`, 14 cases, sourcing the
  real library. They caught a POSIX shell scoping bug (all three helpers used
  `_envdir`, so the callee clobbered its caller and recovery addressed
  `<env>.old.old`) that would have silently failed to restore the only
  surviving copy of a user's environment.
- **Future**: version-aware migration is a documented requirement for the first
  post-release Python ABI transition — `docs/NEBULAOS_PLATFORM_APP_BOUNDARY.md`.

## APP UPDATE ARCHITECTURE

Documented, not implemented (§16/§17 asked only that this migration not block
it): CI-built ABI-matched wheels, staged and atomically activated per-app venvs,
source and venv rolled back as a pair. Platform stays firmware/A-B-owned; an
update needing a newer platform must fail cleanly rather than mutate the OS.

## BUILD

```
06-verify   264 OK
candidate gate   17 PASS / 0 FAIL
regression suites   67 PASS / 11 FAIL / 2 SKIP   (80 suites)
```

The 11 failures are **pre-existing and environmental** — identical set on a
pristine `fd4a365` clone run under the same conditions (they need `vendor/`
trees a fresh clone lacks; `plr-tombstone-tests` writes to `/tmp`). **Zero
regressions.** The 2 SKIPs are reported as SKIP, never PASS.

### Defects found and fixed during the migration

1. **Stage 04 wrote the app payload to the wrong directory** (mine). Would have
   produced a clean build with **no printer software in the image**.
2. **`contourpy` shipped a host-tagged extension.** Correct MIPS object,
   filename CPython cannot import ⇒ matplotlib broken at runtime from a *green*
   build. Upstream bug; fixed via `local.mk`, no upstream file touched.
3. **Seven test suites regressed** by a hardcoded library path — caught only by
   comparing the full suite against the baseline.
4. **POSIX shell scoping bug** in the venv helpers (above).

## ARTIFACTS

See the reproducibility section — artifact hashes belong to the two clean builds
of the final candidate SHA, not to any intermediate build.

## REPRODUCIBILITY

```
IMAGE_REPRODUCIBILITY=NOT_YET_PROVEN
```

Build A and Build B must run **sequentially** on the same published SHA. They
share the Buildroot download cache at `$HOME/.cache/nebulaos/buildroot-dl`,
which is bind-mounted and deliberately **not** freshened per run — every tarball
is sha256-verified on use, so this is not a correctness risk, but "fresh clone"
does not mean "fresh downloads" and the proof should not claim otherwise.

## PERFORMANCE

**No runtime performance measurement was taken. RAM, CPU, boot time and latency
are NOT TESTED.**

Changes that could plausibly affect runtime, listed without any claim about
direction or magnitude: GCC 12.3.0 → 13.4.0 code generation; Python 3.11 → 3.12
interpreter; matplotlib/numpy version jumps; rootfs 99 758 080 → 129 503 232
bytes (+29.8%).

The size increase is **not** a prediction of higher RAM use: squashfs is
demand-paged, and 46 MB of the growth is `matplotlib/tests`, which is never
imported.

Qualification command (read-only, operates nothing):

```
tools/qualification/nebulaos-qualify.sh > baseline.txt   # current firmware
tools/qualification/nebulaos-qualify.sh > candidate.txt  # candidate
diff -u baseline.txt candidate.txt
```

It distinguishes a real value, `ABSENT`, `UNAVAILABLE` and `FAILED`, and never
reports an untaken reading as 0. Interrupt counters are cumulative counts, not
rates — difference two captures against `UPTIME_SECONDS`.

## DEFERRED CLEANUP (none actioned)

- `matplotlib/tests` — 46 MB uncompressed, never imported. Largest single item.
- `BR2_DOWNLOAD_FORCE_CHECK_HASHES` — blocked only by the kernel's custom-version
  tarball having no hash file; 234 of 236 download artifacts are already hashed.
- `python-wheel-target` — shipped for parity; nothing imports it.
- libqmi, libgudev, strace, rsync, git, usbutils, eudev, libcurl, unused
  `brcmfmac` firmware variants, OpenSSL legacy crypto.
- LTO, GCC 14, USB interrupt optimisation, daemon trimming.

## HARDWARE

```
HARDWARE_QUALIFIED=NO
HARDWARE_TESTING=NOT_ATTEMPTED
```

Nothing contacted the printer. Procedure prepared in
`docs/BUILDROOT_2025_ATTENDED_HARDWARE_TEST_PLAN.md`.
