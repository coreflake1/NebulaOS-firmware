# Platform / application boundary, and the future app-dependency model

This document records a **design boundary and a recommended direction**. It is
deliberately not an implementation plan for this release. Mission §16/§17 asked
that the Buildroot 2025.02.18 migration not *block* the model below; it does
not ask for the model to be built now, and building it now would be premature.

---

## 1. The two halves

### Platform — firmware-owned, A/B-updated, immutable at runtime

kernel · glibc · the Python interpreter · OpenSSL · nginx · Dropbear ·
wpa_supplicant · eudev · core system libraries · the Buildroot base system ·
every `BR2_PACKAGE_*` in `br2-external/configs/nebulaos_x2000_defconfig`.

These live in the read-only squashfs of one A/B slot. An **application update
must never replace any of them live.** Changing them means shipping a new
firmware image and going through the slot/rollback machinery.

### Application — independently updateable

Klipper · Moonraker · Mainsail · the contents of the per-application venvs
under `/usr/data/nebulaos/envs/{klipper,moonraker}`.

These live on the persistent datastore, survive a slot switch, and are updated
by the update/recovery supervisors without reflashing.

## 2. Why the boundary needs stating at all

The two halves have **different lifetimes and different storage**, and that
asymmetry is load-bearing:

```
/usr/lib/python3.12   image-owned   per-slot     changes on firmware update
/usr/data/.../envs    persistent    slot-shared  survives firmware update AND rollback
```

A venv therefore outlives the interpreter it was built against, in **both**
directions — forward on an OTA, and backward on an A/B rollback. That is the
concrete failure this migration had to handle, and it is handled in
`/usr/libexec/nebulaos-venv-lib.sh` (`venv_matches_platform`), which compares a
venv against the *running* image rather than assuming a direction of travel.

## 3. What this release actually ships

Buildroot provides a **complete offline factory baseline**: every dependency
the pinned Klipper and Moonraker need is built into the image, so a
factory-fresh or recovered device is fully functional with no network and no
compiler on the printer.

The venvs are created with `--system-site-packages`, so today they are thin
shims over the image's `site-packages` and contain essentially nothing of their
own. **That is the current state, not a commitment.** It is also the reason a
future application update cannot yet bring its own dependency versions: it
would be resolving against the immutable image.

Nothing in this migration prevents changing that — which was the actual
requirement.

## 4. Recommended future model (NOT implemented here)

```
immutable NebulaOS platform
        +
independently updateable application source
        +
independently versioned application venv
```

The shape that fits this device:

1. **NebulaOS CI builds MIPS/XBurst wheels** using the same toolchain and ABI as
   the firmware — same GCC, same glibc, same `mips32r2` / FPXX / legacy-NaN
   settings. Wheel ABI tags make the compatibility contract explicit and
   machine-checkable rather than implied.
2. **The printer downloads verified prebuilt wheels.** Hashes checked before
   use. **No compiler on the printer** — the device has 208 MiB of RAM and
   compiling `numpy` there is not a realistic operation.
3. **Stage a new venv beside the current one**, install into it, verify it, then
   **atomically activate** source + matching venv together. The staging and
   atomic-swap primitives this needs already exist and are already tested:
   `swap_venv_into_place` and `recover_torn_venv` in
   `/usr/libexec/nebulaos-venv-lib.sh`.
4. **Preserve the previous generation for rollback.** Application rollback
   should restore source *and* its matching venv as one unit; they are a pair,
   and rolling back one without the other reproduces exactly the
   interpreter/venv mismatch this migration fixed.

A full package repository is explicitly out of scope.

## 5. Compatibility metadata (sketch)

When an application update needs to state what platform it requires, something
of this shape is sufficient — three fields, declarative, checkable before
anything is written:

```
NEBULAOS_PLATFORM_API=<integer, bumped on breaking platform change>
PYTHON=<major.minor of the interpreter the venv was built against>
OPENSSL=<major.minor>
```

Deliberately **not** implemented now. The two rules that matter:

- An update whose requirements the running platform cannot satisfy must **fail
  cleanly and early**, with the equivalent of `NebulaOS platform update
  required`, leaving the working installation untouched.
- It must **never** attempt to satisfy itself by mutating the immutable OS.

This is the fail-closed direction: refusing an update is recoverable, a
half-mutated platform is not.

## 6. What this migration already contributes to that future

- `venv_matches_platform` makes "is this venv valid for this platform?" an
  explicit, testable predicate instead of an `[ -x bin/python3 ]` guess. A
  future version check slots into the same place.
- `swap_venv_into_place` / `recover_torn_venv` give atomic, power-cut-safe venv
  replacement with a recoverable intermediate state.
- Python paths and the CPython ABI tag are derived from `sysconfig` /
  `EXT_SUFFIX` rather than written down, so a future minor bump does not
  require repeating the 3.11→3.12 cleanup.
- `br2-external/package/` establishes the pattern for adding a target Python
  package with a pinned, hash-verified source and no network access at build
  time — the same discipline a wheel-building CI job would need.
