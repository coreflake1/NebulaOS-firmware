# Build reproducibility — what is established, what is not

This is the canonical record. Earlier statements about build reproducibility in
this repository were wrong in a specific, repeated way, and several places
restated the error independently. **If you find another copy of a retracted
claim, correct it and point it here.** Do not add a count of how many copies
remain: successive passes each asserted they had found the last one and each
was wrong.

```
GUPPYSCREEN_REPRODUCIBLE_FOR_A_FIXED_PIN    YES (measured, three builds)
FULL_GUPPYSCREEN_BYTE_REPRODUCIBILITY       NOT ESTABLISHED
IMAGE_REPRODUCIBLE (xImage, rootfs.squashfs) NOT YET PROVEN at the fixed HEAD
IMAGE_NON_DETERMINISM_ROOT_CAUSE            ESTABLISHED (measured, 11 causes)
```

The earlier value of `IMAGE_NON_DETERMINISM_ROOT_CAUSE` was `NOT ESTABLISHED`,
and section 3 below said so at length. That is no longer true: every cause has
been read out of the differing bytes and fixed. `IMAGE_REPRODUCIBLE` is
deliberately **not** upgraded here - the causes being found and fixed is not
the same claim as two clean builds of the final HEAD matching. That proof is
recorded in the build-evidence tree kept OUTSIDE this repository (it records
absolute build paths and artifact hashes, which are properties of a machine and
a run, not of the source), so it is deliberately not linked from here - a path
this repository cannot resolve from a fresh clone would be worse than none.

## 1. The retracted claim

Several places asserted, in varying words, that build outputs "are NOT
deterministic across builds (the toolchain embeds a build timestamp), even from
byte-identical source", and used that to justify not comparing binary hashes.

Two things were wrong with it:

- **The cause was a guess presented as fact.** "The toolchain embeds a build
  timestamp" was never measured. For `guppyscreen` the real cause was specific
  and fixable. For `xImage` the guess is refuted below.
- **It was applied to `guppybeep`, where it was never true.** `guppybeep` does
  not link libhv, embeds no date string, and has reproduced byte-for-byte
  throughout. A `guppybeep` hash change is a real finding, not a benign
  rebuild artifact.

The deeper error is the pattern, not the fact: an observation was attributed to
a guessed cause, the guess was promoted to "expected", and the expectation was
then used to justify not checking. That is what to avoid restating.

## 2. GuppyScreen — cause found, fixed, and measured

`libhv` expands the compiler `__DATE__`/`__TIME__` macros:

```
libhv/base/htime.c      hv_compile_datetime()   sscanf(__DATE__, ...) / sscanf(__TIME__, ...)
libhv/base/hversion.c   hv_compile_version()    builds a version string from it
```

`libhv.a` links into `guppyscreen` but not into `guppybeep` — exactly the
observed asymmetry. The 2026-08-28 reference binary contains the literal string
`Aug 28 2026`, its own build date.

`scripts/build/04-cross-compile-app-stack.sh` now pins `SOURCE_DATE_EPOCH` to
the committer date of `GUPPYSCREEN_PIN` (not vendor `HEAD`), refuses to build if
the pin is unset or the checkout is not at the pin, and **asserts after the
build** that the binary embeds the expected date. It also clears
`libhv/build-mips` and `spdlog/build-mips`, without which a stale `libhv.a`
would relink and the fix would be a silent no-op on a persistent checkout.

Measured result — three builds, three different firmware commits, three fresh
clones, one fixed pin and container digest:

```
guppyscreen  1b34e7b72f95c4e98538ca8cc0d8cf0feeac03d092eb96c61effa41f7d0a2e31   (all three)
guppybeep    fe2a7d3b37aadfdb19f8357ca25efb37e776d785ca270f4553800d3002b1702c   (all three)
```

**What this does and does not establish.** It refutes "differs from build to
build despite identical pinned source". It does **not** establish full
byte-reproducibility across differing hosts, toolchain images or pins. The
check is a substring match on one date string; archive member ordering,
embedded build paths and the parallel-object behaviour of `build-mips.sh`
remain untested for byte-stability. `scripts/build/05-final-build.sh` says so
deliberately and should not be "upgraded" to a stronger claim without evidence.

## 3. The image — not reproducible, and the cause is NOT established

`xImage` and `rootfs.squashfs` differ between builds whose `kernel.config`,
`buildroot.config` and `halley5_v30.dts` are byte-identical, from the same
container digest, with no input change that reaches the image.

Measured on `xImage` (a u-boot legacy uImage, magic `27 05 19 56`):

- the header embeds wall-clock build time at bytes 8-11, big-endian
  (`1790212162` = `2026-09-24T01:09:22Z` vs `1790217506` = `02:38:26Z`, each
  inside its own build window); bytes 4-7 are the header CRC and follow it;
- **skipping the 64-byte header entirely, 1,454,891 bytes of ~5.5 MB still
  differ.** The compressed payload is itself non-deterministic.

So "a kernel build embeds its own build timestamp" is not a sufficient
explanation, and a header-only fix would not make `xImage` reproducible.

**The above was the state of the record until the causes were measured. They
now have been, and the paragraph that used to follow here - listing `UTS_VERSION`,
`__DATE__`/`__TIME__` and squashfs ordering as unverified "usual suspects" - has
been replaced by section 3b rather than deleted, so that the distinction it was
making (hypotheses are not results) is not lost.** None of those suspects turned
out to be the xImage cause.

## 3b. The causes, measured

Each was read out of the differing bytes of two builds whose `kernel.config`,
`buildroot.config` and `halley5_v30.dts` were byte-identical. None was guessed.

| # | Artifact | Producer |
|---|---|---|
| 1 | ~1100 `.pyc` | CPython timestamp-invalidation header carries the source mtime |
| 2 | `opt/nebulaos-seeds/*.tar.gz` | tar member mtimes, readdir order, builder uid/gid |
| 3 | version/seed/config manifest JSON | `build_date=$(date -u …)` in stage 04 |
| 4 | `.nebulaos-chelper-verdict.json` | `now=$(date -u …)` in the chelper preflight |
| 5 | `etc/shadow` | Buildroot salts a plaintext root password randomly per build |
| 6 | `bin/busybox` | build time embedded in the banner |
| 7 | `usr/lib/libcrypto.so.3` | OpenSSL `built on:` string |
| 8 | `usr/lib/libpython3.11.so.1.0` | CPython `getbuildinfo` `__DATE__`/`__TIME__` |
| 9 | `rootfs.squashfs` superblock | mksquashfs creation time |
| 10 | `xImage` | `arch/mips/boot/zcompressed/Makefile` ran `gzip` **without `-n`**, storing the payload's name and mtime in the gzip header |
| 11 | `opt/nebulaos-seeds/*.tar.gz` (again) | the archived `.git/index` (per-file stat data) and `.git/logs/HEAD` (reflog timestamps) |

Cause 10 is the whole of the xImage difference. The 1,454,891 differing bytes
above were measured BEFORE `SOURCE_DATE_EPOCH` existed; once it did, xImage came
down to **10 differing bytes** - one four-byte gzip mtime field plus the header
and data CRCs that follow from it. Upstream's own generic compression rule
already passes `-n`; this Ingenic-local rule did not.

Cause 11 was found only because a *functional* test built the same commit twice
and compared bytes. The grep-level assertion for the tar flags passed the whole
time: the variation was inside the member contents, where deterministic tar
flags cannot reach.

### The fixes

1. `build.sh` derives one `SOURCE_DATE_EPOCH` from the firmware commit's
   committer date and exports it into the container. A non-git or unreadable
   tree fails the build rather than falling back to `date +%s`.
2. `BR2_REPRODUCIBLE=y` (covers 1, 2, 9).
3. `scripts/build/nebulaos-post-build.sh` pins the `/etc/shadow` root hash with
   a fixed salt. **Same password** - only the salt stops being random. It is a
   post-build script because `.config` is included by make, which expands `$5`
   before Buildroot's already-hashed test can match it, and because `/etc/shadow`
   is mode 0600, which git cannot express through the overlay.
4. `build_date` and the preflight's `checked_at` derive from the epoch. The
   preflight still uses the wall clock at boot, because it runs there too.
5. `kernel-gzip-determinism-variant.sh` adds `-n` to the zboot rule.
6. `make_seed_archive()` sorts members, fixes owner/mtime, drops the reflog and
   rebuilds `.git/index` from HEAD with zeroed stat data.

`make_seed_archive()` takes its mtime from the archived tree's **own HEAD commit
date**, not from `SOURCE_DATE_EPOCH`. It is a shared function - the tests and
offline fixtures call it directly - and requiring a build-time variable broke
every caller outside `build.sh`. The commit date is also the more honest value:
the archive *is* that commit.

There are deliberately **two** epochs: the image epoch above, and the GuppyScreen
epoch derived from `GUPPYSCREEN_PIN`, because GuppyScreen should track its pin
rather than the firmware commit.

`tests/reproducibility-assertions-tests.sh` asserts all of it (24 assertions).
Four of them are functional rather than grep-level, and each assertion was
verified to FAIL when its fix is reverted - an assertion that cannot go red
proves nothing.

One of them guards a defect these fixes themselves introduced. The first
version of the sparse skip-worktree step used `read -r -d ''`, a bashism. These
scripts are `#!/bin/sh` and `build.sh` runs the pipeline with `sh`, which is
dash in the container; dash's `read` has no `-d`, so the loop body never ran,
the bits were never re-applied, and the packaging guard correctly refused a
tree it now saw as entirely deleted. It failed closed, but it failed a real
build. The tests did not catch it because they source the library into **bash**,
where `read -d` works, and `bash -n` cannot see this class of defect at all. A
`shellcheck -s sh` gate over every `#!/bin/sh` script under `scripts/build` now
does, and it was verified against the exact construct that broke the build.

## 3a. Corrections to claims made while producing this record

This series exists to stop unverified claims being restated. Two of its own
commit messages contained measurably wrong numbers. Published history is not
rewritten for this; the corrections live here.

- **"all 19 assertions" is wrong. The number is 17.** Stated in the commit
  messages of `36e83c1` and `40762c2`. Measured across all three modes against
  the real repository: pre-build 17, candidate-post-build 17, post-build 17
  (plus 3 baseline comparisons). The count is static in
  `scripts/build/assert-baseline-config.sh` — 15 `check()` sites plus 2 inline
  PASS/FAIL blocks per section — so it does not vary with the build and no real
  build can produce 19. The figure had no source in the repository.

- **"byte-identical to the baseline tag" is wrong. They are SEMANTICALLY
  identical.** Stated in the commit message of `40762c2` about the recorded
  artifacts. Measured by blob SHA against
  `nebulaos-canonical-baseline-2026-08-14-prtouch-qualified`: only
  `halley5_v30.dts` is byte-identical; `kernel.config` and `buildroot.config`
  differ, in exactly the two documented excluded fields
  (`CONFIG_CC_VERSION_TEXT`, `CONFIG_EXTRA_FIRMWARE_DIR`) and nothing else. The
  gate that produced the wording says "semantically" itself. The substantive
  conclusion — that the recorded artifacts are the 2026-08-14 eight-variant
  snapshot and predate the ninth — is unaffected.

Both were caught by independent verification, not by the author. That is the
same failure mode this file documents: a number repeated until it sounds
established.

## 4. Consequence for release qualification

A metadata-only commit followed by a rebuild still yields different flashable
artifacts. Therefore:

```
FINAL_ARTIFACT_EQUALS_HW_QUALIFIED_CANDIDATE = NO   (structurally)
```

Hardware evidence cannot be carried across a rebuild on the strength of
artifact identity, and baseline promotion is not a no-op for the image. The
conservative route — flash the exact artifact that will ship, and qualify that
— is the only available one until image reproducibility is solved. That is its
own scoped piece of work, not something to fold into a release closure.
