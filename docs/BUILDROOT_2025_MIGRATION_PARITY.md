# Buildroot 2025.02.18 migration — old-vs-new parity report

```
OLD  lone0/buildroot-x2000 @ 74d020081096972857acdb9e76c6c5335455d430
     (Buildroot 2023.11.1 + 3 commits), GCC 12.3.0, binutils 2.40, Python 3.11.6
NEW  buildroot/buildroot    @ d030e36bbc9669230c015be971b14b6e062cfdde
     (tag 2025.02.18),                   GCC 13.4.0, binutils 2.43.1, Python 3.12.14
```

Reference artifacts for OLD are the frozen `fd4a365` candidate, Build B, whose
hashes were re-verified against `evidence/frozen-candidate-fd4a365/build-B.attestation`
before any inventory was taken:

```
xImage           46bba13612bfe8af981d88ac486042c5ee36afec7748bf98665f1b62fbdc4512   5509184
rootfs.squashfs  da6ce4bbfe0d388bbdaf780f273bbca81ac0256b2d4d3dc7401bafd4732f9456  99758080
```

The rootfs inventory taken from that image is tracked under `docs/parity-baseline/`
and is reproducible with `scripts/parity/rootfs-inventory.sh`.

**Status vocabulary:** `PRESERVED`, `REPLACED_EQUIVALENT`, `INTENTIONALLY_CHANGED`,
`BLOCKED`, `UNKNOWN`. There are no `UNKNOWN` entries.

---

## 1. Method

Parity was established mechanically, not by reading release notes.

1. Every symbol set in the OLD `buildroot.config` (546 of them) was tested for
   existence in 2025.02.18's Kconfig, with `Config.in.legacy` separated out so a
   deprecated stub could not be mistaken for a live symbol.
2. The OLD `.config` was fed to 2025.02.18's own `make olddefconfig`. What that
   resolver did — and did not — carry forward is the evidence below.
3. The resulting configuration was reduced with `savedefconfig` and then
   **round-tripped** (`defconfig` → `olddefconfig`) and diffed against the
   resolved reference. The only difference is `BR2_DEFCONFIG`, which records the
   defconfig's own path.
4. `tests/buildroot-defconfig-parity-tests.sh` asserts the result by value:
   **239 assertions, 0 failures, 194/194 previously-enabled packages present.**

## 2. Symbol-level result

| Measure | Count |
|---|---|
| Symbols set in OLD config | 546 |
| Absent from 2025.02.18 entirely | **3** |
| Surviving only as `Config.in.legacy` stubs | 13 (12 carry `""` or `0`) |
| Enabled packages (`BR2_PACKAGE_*=y`) in OLD | 264 |
| Of those, still existing upstream | **264** |

### The three symbols that no longer exist

| OLD | NEW | Status | Justification | Validation |
|---|---|---|---|---|
| `BR2_PACKAGE_MIDORI_ARCH_SUPPORTS=y` | — | `OBSOLETE_AND_PROVEN_FUNCTIONALLY_UNNEEDED` | Hidden capability flag meaning "this architecture could build midori". `BR2_PACKAGE_MIDORI` was never set, so nothing was built from it. midori was removed upstream. | `grep BR2_PACKAGE_MIDORI= old.config` → no match |
| `BR2_PACKAGE_MONGREL2_LIBC_SUPPORTS=y` | — | `OBSOLETE_AND_PROVEN_FUNCTIONALLY_UNNEEDED` | Same shape, for mongrel2. Never enabled. | `grep BR2_PACKAGE_MONGREL2= old.config` → no match |
| `BR2_TARGET_ROOTFS_EXT2_REV=1` | `BR2_TARGET_ROOTFS_EXT2_2r1=y` | `REPLACED_EQUIVALENT` | `_REV` was a *derived* value. The **selector** `_2r1` (ext2 revision 1) still exists and is still set, so the filesystem revision is unchanged. | asserted by value in the parity test |

### Legacy-stub symbols

Twelve hold `""` or `0` and configure nothing: `BR2_PACKAGE_QEMU_CUSTOM_TARGETS`,
`BR2_PACKAGE_REFPOLICY_POLICY_VERSION`, `BR2_TARGET_GRUB2_BUILTIN_CONFIG`,
`BR2_TARGET_GRUB2_BUILTIN_MODULES`, `BR2_TARGET_ROOTFS_EXT2_BLOCKS`,
`BR2_TARGET_ROOTFS_EXT2_EXTRA_BLOCKS`, `BR2_TARGET_ROOTFS_EXT2_EXTRA_INODES`,
`BR2_TARGET_ROOTFS_OCI_ENTRYPOINT_ARGS`, `BR2_TARGET_UBOOT_CUSTOM_PATCH_DIR`,
`BR2_TOOLCHAIN_EXTRA_EXTERNAL_LIBS`, `BR2_XTENSA_CUSTOM_NAME`,
`BR2_XTENSA_OVERLAY_DIR`. Status `OBSOLETE_AND_PROVEN_FUNCTIONALLY_UNNEEDED`.

The thirteenth is real and is handled as a toolchain change below.

## 3. Architecture and ABI — all `PRESERVED`

Asserted individually by `tests/buildroot-defconfig-parity-tests.sh`.

| Property | OLD | NEW | Status |
|---|---|---|---|
| Endianness / arch | `BR2_mipsel` | same | `PRESERVED` |
| CPU | `BR2_mips_xburst`, `BR2_MIPS_CPU_MIPS32R2` | same | `PRESERVED` |
| Target arch flag | `BR2_GCC_TARGET_ARCH="mips32r2"` | same | `PRESERVED` |
| ABI | `BR2_MIPS_OABI32`, `BR2_GCC_TARGET_ABI="32"` | same | `PRESERVED` |
| Hard float | `BR2_MIPS_SOFT_FLOAT` not set | same | `PRESERVED` |
| FPXX | `BR2_MIPS_FP32_MODE_XX`, `BR2_GCC_TARGET_FP32_MODE="xx"` | same | `PRESERVED` |
| Legacy NaN | `BR2_MIPS_NAN_LEGACY`, `BR2_GCC_TARGET_NAN="legacy"` | same | `PRESERVED` |
| libc | glibc (`BR2_TOOLCHAIN_BUILDROOT_GLIBC`) | same | `PRESERVED` |
| Kernel headers | `BR2_KERNEL_HEADERS_AS_KERNEL`, at-least 6.6 | same | `PRESERVED` |

`BR2_TOOLCHAIN_HEADERS_LATEST` flipped from `y` to unset. It is a **derived**
flag meaning "these headers are the newest Buildroot knows about"; 2025.02.18
knows about kernels newer than 6.6. `BR2_TOOLCHAIN_HEADERS_AT_LEAST="6.6"`
remains set. Status `PRESERVED` (no functional change).

## 4. Toolchain — `INTENTIONALLY_CHANGED`

| Component | OLD | NEW | Status | Justification |
|---|---|---|---|---|
| GCC | 12.3.0 | **13.4.0** | `INTENTIONALLY_CHANGED` | Mission target; also the 2025.02.18 default |
| binutils | 2.40 | **2.43.1** | `INTENTIONALLY_CHANGED` | 2.40 was **removed** upstream; its symbol survives only as a legacy stub that selects `BR2_LEGACY`, and Buildroot refuses to build in that state. 2.43.1 is the 2025.02.18 default |
| Python | 3.11.6 | **3.12.14** | `INTENTIONALLY_CHANGED` | Mission target; follows from `BR2_PACKAGE_PYTHON3` on 2025.02.18 |
| Optimization | `-Os` (`BR2_OPTIMIZE_S`) | `-Os` | `PRESERVED` | Asserted explicitly. LTO asserted OFF |

`-Os` exists in **two independent places** and both are preserved:
`BR2_OPTIMIZE_S=y` for Buildroot-built packages, and an explicit
`CFLAGS="... -Os -march=mips32r2 ..."` in `scripts/build/04-cross-compile-app-stack.sh`
for the hand-rolled app-stack cross-compile, which Buildroot config cannot
express either way.

## 5. Filesystem and A/B layout — all `PRESERVED`

`BR2_TARGET_ROOTFS_EXT2_{SIZE="400M",INODE_SIZE=256,RESBLKS=5,MKFS_OPTIONS="-O ^64bit",LABEL="rootfs",2r1}`
and `BR2_TARGET_ROOTFS_SQUASHFS_{BS_128K,PAD}` + `SQUASHFS4_ZSTD`.

These are **absent from the 84-line defconfig** because they currently equal a
2025.02.18 default. That is precisely why the parity gate asserts them by value
rather than diffing the defconfig: if a future Buildroot moves one of those
defaults, the defconfig would not change and the A/B partition layout would
shift silently. The gate fails instead.

## 6. Memory resilience (mission §9) — `PRESERVED`, untouched

No file in this area was modified. Recorded here because it is a parity gate.

| Property | Value | Where |
|---|---|---|
| zram device | `/dev/zram0`, 128 MiB logical, lz4, priority 100 | `etc/init.d/S00zram-swap` |
| Disk swap | 128 MiB at `$NEBULAOS_ROOT/system/swapfile`, priority 10 | `etc/init.d/S03nebulaos-diskswap` |
| `vm.swappiness` | 10 | set by `S00zram-swap`, **not** `/etc/sysctl.conf` |
| `vm.page-cluster` | 0 | same |

Note for anyone writing a check: these sysctls are applied from inside the init
script, so an assertion that greps `/etc/sysctl.conf` will find nothing and must
not conclude they are absent. `tools/qualification/nebulaos-qualify.sh` reads
them from `/proc` instead.

The 128 MiB zram size is a **logical ceiling**, not 128 MiB of permanently
consumed RAM; zram occupies real memory only for the compressed pages actually
stored. This layer exists because the 208 MiB device suffered a real OOM.

## 7. Buildroot tree content — the fork carried almost nothing

`vendor/buildroot-x2000` diverged from upstream Buildroot 2023.11.1 by **three
commits touching four tracked files**: `configs/halley5_x2000_defconfig` and
`board/halley5/patches/linux/010{0,1,2}-*.patch`.

| Item | Status | Justification | Validation |
|---|---|---|---|
| `configs/halley5_x2000_defconfig` | `REPLACED_EQUIVALENT` | Superseded by `br2-external/configs/nebulaos_x2000_defconfig`, derived from the actual qualified `.config` rather than from the fork's starting point | round-trip + 239 assertions |
| `board/halley5/patches/linux/0100,0101,0102` | `OBSOLETE_AND_PROVEN_FUNCTIONALLY_UNNEEDED` | **Never applied.** `local.mk` sets `LINUX_OVERRIDE_SRCDIR`, and a package with an override srcdir is *rsynced*, not extracted-and-patched | `package/pkg-generic.mk` ties `_TARGET_CONFIGURE` to `_TARGET_RSYNC`; the built tree has `.stamp_rsynced` and **no** `.stamp_patched`/`.stamp_extracted`. Re-confirmed in 2025.02.18, not assumed across the version jump |
| `BR2_GLOBAL_PATCH_DIR="board/halley5/patches"` | `INTENTIONALLY_CHANGED` (dropped) | Its only content was those three inert patches | asserted empty by the parity gate |
| `BR2_ROOTFS_POST_IMAGE_SCRIPT="board/qemu/post-image.sh"` | `INTENTIONALLY_CHANGED` (dropped) | Inherited cruft from the seeding defconfig; exits 0 on a non-qemu board. Kept working only by accident and is an upstream path upstream may move | asserted empty by the parity gate |

## 8. Upstream pristineness

Two files under the Buildroot checkout used to be rewritten at configure time.
Both are gone, and the acceptance test is `06-verify.sh`'s `check_vendor_pin`
allowlist, cut from **nine** expected modifications to **one**.

| OLD edit | NEW | Status | Validation |
|---|---|---|---|
| `package/python-matplotlib/python-matplotlib.mk` overwritten (pinned 3.4.3 + local wheel dir) | stock `python-matplotlib` 3.10.0 + `python-numpy` 1.25.0 | `REPLACED_EQUIVALENT` | The workaround existed because matplotlib 3.4.3 built via `setup.py`, whose `setup_requires`/`fetch_build_eggs` path ran a nested pip inheriting `_PYTHON_HOST_PLATFORM=linux-mipsel`. 3.10.0 builds through meson-python; that mechanism does not exist there |
| `package/squashfs/squashfs.{mk,hash}` sed-patched | untouched | `OBSOLETE_AND_PROVEN_FUNCTIONALLY_UNNEEDED` | It backported an upstream fix. 2025.02.18 already sets `SQUASHFS_SITE` to `releases/download/...` and already hashes `squashfs-tools-4.6.1.tar.gz`, so the sed's `call github,plougher` precondition is false and the block was a no-op |
| `scripts/build/vendor-wheels/numpy-2.4.6-cp311-cp311-linux_mipsel.whl` | deleted | `REPLACED_EQUIVALENT` | Unusable under Python 3.12 by construction (cp311 ABI tag). Replaced by Buildroot's `python-numpy` |
| `local.mk` | retained | `PRESERVED` | Carries `LINUX_OVERRIDE_SRCDIR`, which Buildroot reads only from `$(TOPDIR)/local.mk` — structurally cannot move |

## 9. Python userspace — 48/48 distributions accounted for

The OLD image's target `site-packages` held 48 distributions. Every one is
provided in NEW:

- **40 from upstream Buildroot 2025.02.18**, including `python-serial` (= pyserial 3.5),
  `python-can`, `python-dateutil`, `python-periphery`, `python-numpy`,
  `python-matplotlib`, `tornado`, `pillow`, `zeroconf`, `dbus-fast`, `paho-mqtt`.
- **8 from `br2-external/package/`**, because upstream does not package them:
  `apprise`, `importlib-metadata`, `inotify-simple`, `ldap3`, `libnacl`,
  `preprocess-cancellation`, `streaming-form-data`, `zipp`.
- **1 additional**, `python-wheel-target`: upstream packages `wheel` as
  **host-only** (`host-python-package`, empty `Config.in`), so there is no
  upstream route onto the target. The OLD image had it only as a side effect of
  the removed `pip3 download`. Re-provided for parity; nothing shipped imports
  it. **Deferred-cleanup candidate.**

- **1 new runtime dependency**, `python-smart-open` 7.5.0 (`br2-external`),
  status `INTENTIONALLY_CHANGED`. The OLD image shipped `streaming-form-data`
  **1.11.0**, copied in as bare `*.py`/`*.so` with no dist-info, and 1.11.0
  imports nothing extra. NEW ships **1.19.1**, which declares
  `smart-open>=7.0.5` and imports it at module load (`targets.py`, the module
  Moonraker's `application.py` imports). Every release from 1.16.0 on declares
  smart-open. The first NEW image shipped without it, and Moonraker died at
  import on the printer. Going back to 1.11.0 is not a fix: its `_parser.c` was
  generated by Cython 0.29.32, which predates Python 3.12. `smart_open`'s one
  hard dependency, `wrapt`, is upstream's `python-wrapt` 1.17.2.
  `06-verify.sh` now has a release-blocking metadata closure gate, so a
  declared runtime dependency missing from the image fails the build.

`msgspec` is deliberately **not** added: it is absent from the OLD image and is
an optional `try/except` import in Klipper's `webhooks.py`. Adding it would be a
behaviour change, not parity.

`importlib_metadata` and `zipp` are **not** redundant on Python 3.12:
`moonraker/utils/source_info.py` does `from importlib_metadata import ...`,
which is the backport distribution, not the stdlib `importlib.metadata` module.

### Supply chain

`pip3 download` is removed from the firmware build. All nine formerly-fetched
distributions are Buildroot packages with recorded sha256 values taken from the
PyPI JSON API `digests` field and independently re-computed against the
downloaded sdist. Build backends were determined by inspecting each sdist, not
inferred.

### Native extensions

OLD carried 106 `*.cpython-311-mipsel-linux-gnu.so` files. The only one built by
NebulaOS rather than Buildroot was `streaming_form_data/_parser`, whose filename
was **hand-written**. It is now built by its Buildroot package, which names it
from the target interpreter's real `EXT_SUFFIX`. Nothing in the pipeline spells
a CPython ABI tag by hand.

## 10. Deliberately NOT removed (mission §19)

Present in OLD, still present in NEW, listed as future cleanup candidates only:
`libqmi`, `ModemManager`-adjacent `libgudev`, `strace`, `rsync`, `git`,
`usbutils`, `eudev`, `libcurl`, generic `brcmfmac` firmware for board variants
this product does not ship, and `python-wheel-target`. **None was removed.**
Proving functional equivalence comes first; a missing feature must not be
confusable with the Buildroot migration itself.

## 11. Known change in build identity

`support/scripts/setlocalversion` produced `-g<sha>` for the fork, which has no
tags anywhere in its history. Official Buildroot **is** tagged, so
`BR2_VERSION_FULL` becomes a clean `2025.02.18` — provided the tree is clean,
which §8's allowlist now enforces. This changes the `# Buildroot <version>
Configuration` header line in `buildroot.config` and the corresponding
`build-manifest.txt` provenance field. Expected, not a defect.

---

## 12. First green build — measured result

`BUILD=PASS` on `8bbe8eb85d560bdbf84dfc0bed9468cf066aa32e`, exit code 0, ~42 min
(33 min of build stages; the Buildroot download cache was warm).

```
GCC 13.4.0 · binutils 2.43.1 · Python 3.12.14 · Buildroot 2025.02.18
xImage           d139733af462d425eccacc22dcd645541058ea528ea4456b7b5cfd82c14813ff    5505088
rootfs.squashfs  a2f819044d907e8fa9076ff15679b17d27cb3d4280e4e8150fb4eb6f1a412d1c  129503232
06-verify        OK=264  MISS=1  FATAL=0
candidate gate   17 PASS / 0 FAIL
```

The single MISS was `vendor/buildroot-x2000/configs/nebulaos_x2000_defconfig`,
an untracked file left by staging the defconfig into the upstream checkout. It
was unnecessary — Buildroot's `%_defconfig` rule already searches every
`BR2_EXTERNAL` tree (Makefile 1056-1060) — and the staging is removed. Verified
against a pristine 2025.02.18 checkout: the defconfig resolves from
`br2-external/configs/` alone, and `git status --porcelain -uall` on the
Buildroot tree stays empty. **Pristineness target met: `local.mk` only.**

### Native extension ABI

```
OK   every CPython extension in the image uses cpython-312-mipsel-linux-gnu (128 modules)
```

### Rootfs size — `INTENTIONALLY_CHANGED`, fully accounted

| | OLD | NEW | Δ |
|---|---|---|---|
| `rootfs.squashfs` | 99 758 080 | 129 503 232 | **+29 745 152 (+29.8 %)** |
| files | 7 476 | 11 809 | +4 333 |
| ELF objects | 394 | 419 | +25 |
| native Python extensions | 106 | 128 | +22 |

Every byte of the growth is in the Python tree (107 MB → 188 MB uncompressed);
`opt/klipper`, `opt/moonraker`, `usr/share/mainsail` and `opt/guppyscreen` are
unchanged at 13/4/10/7 MB.

| Component | OLD | NEW | Note |
|---|---|---|---|
| matplotlib | 19 MB | **69 MB** | 3.4.3 → 3.10.0. **46 MB of it is `matplotlib/tests`** (bundled suite + baseline images) |
| numpy | 26 MB | 38 MB | pip-installed cp311 wheel → Buildroot `python-numpy` 1.25.0 |
| fontTools | — | 12 MB | new hard dependency of matplotlib ≥3.6 |
| mpl_toolkits | — | 7 MB | split out of matplotlib |

This is accepted, not optimised away. Mission §18 is explicit that NumPy and
matplotlib must not be removed for size, and §20 puts rootfs size below
stability, RAM, CPU and latency. It also fits comfortably:

```
rootfs partition 524 288 000 bytes
OLD  19.0 %      NEW  24.7 %      headroom 376.5 MB
```

**Deferred cleanup candidate (do not action during this migration):**
`matplotlib/tests` at 46 MB uncompressed is the single largest removable item
in the image and is never executed on the printer. Removing it belongs to the
cleanup mission, against evidence, not here.

### Not claimed

Nothing above is a runtime measurement. RAM, CPU, boot time and latency are
**NOT TESTED** — they require the printer and
`tools/qualification/nebulaos-qualify.sh`. A larger rootfs does not by itself
imply higher RAM use: squashfs is demand-paged, and only pages actually touched
are resident. `matplotlib/tests` in particular is never imported.
