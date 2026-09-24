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
IMAGE_REPRODUCIBLE (xImage, rootfs.squashfs) NO (measured)
IMAGE_NON_DETERMINISM_ROOT_CAUSE            NOT ESTABLISHED
```

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
explanation, and a header-only fix would not make `xImage` reproducible. The
conclusion (not reproducible) stands; the cause does not.

`UTS_VERSION` build time and host, `__DATE__`/`__TIME__` in kernel sources,
squashfs mtimes and entry ordering are the usual suspects. **They are
hypotheses. Naming them is not a result**, and this file will not record them
as one.

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
