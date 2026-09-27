#!/bin/sh
# Wire up Buildroot's configuration: the real, already-verified .config this
# project produced (artifacts/buildroot-halley5-v30-image/buildroot.config),
# the kernel config fragment (FIRMWARE.md sec 10-12's additions on top of
# the vendor x2000_halley5_v30_linux defconfig), the LINUX_OVERRIDE_SRCDIR
# pointer, and this repo's own hand-written overlay content.
#
# Reusing the exact verified .config here (rather than re-deriving every
# BR2_PACKAGE_* option from scratch) is deliberate: several of those options
# hit a real class of bug this session where a naive `echo "X=y" >> .config`
# landed on a duplicate line that a later `make olddefconfig` pass then lost
# to the file's *other*, unedited copy of the same symbol (see FIRMWARE.md
# sec 14) - copying the known-good, already-normalized file sidesteps that
# whole class of mistake rather than risking reintroducing it.
#
# IMPORTANT: always re-run this script after ANY change to scripts/build/overlay/
# or the kernel fragment/buildroot.config artifacts, and before 03/05 - a real
# bug this session (FIRMWARE.md sec 24): editing the git-tracked overlay
# template alone does nothing, since Buildroot only ever reads from
# vendor/buildroot-x2000/board/halley5-nebulaos-overlay/ (gitignored), which
# this script is what syncs the template into. A rebuild after only touching
# the template, without re-running this first, silently uses whatever this
# script last copied there.
#
# IMPORTANT: renaming or deleting a file from scripts/build/overlay/ does NOT
# remove it from a real build - a genuinely separate bug from the one above,
# found for real deleting S01tmpfs-datastore in favor of
# S01persistent-datastore (the GuppyScreen persistent-storage work): this
# script re-syncs the overlay TEMPLATE cleanly every time (the rm -rf above),
# but Buildroot's own output/target/ staging directory only ever gets files
# ADDED or OVERWRITTEN by the rootfs-overlay step, never removed, and
# accumulates across every build since the last full clean. Both
# S01tmpfs-datastore (deleted from the overlay days earlier) and
# S01persistent-datastore (its replacement) ended up in the same built image
# at once - actively dangerous here specifically, since the stale script
# re-mounted tmpfs right after the new one finished setting up real
# persistent storage, silently undoing it. Buildroot has no cheap way to
# selectively re-sync output/target/ (its package install stamps live
# elsewhere and do not get invalidated by removing target files directly, so
# deleting output/target/ alone leaves it mostly empty instead of clean) - a
# renamed or deleted overlay file must also be removed by hand from
# vendor/buildroot-x2000/output/target/ before the next 05-final-build.sh, or
# the build needs a full clean. 06-verify.sh also cannot catch this on its
# own: it only inspects rootfs.ext2, and both rootfs.ext2 and rootfs.squashfs
# are built from this same stale output/target/, so a leftover file is wrong
# in both images identically - checking the actual packaged rootfs.squashfs
# directly (e.g. via unsquashfs) is the only real way to confirm a removed
# file is genuinely gone.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this script
# used to wrap every step in `docker run pellcorp/k1-bash-build ...`,
# crossing a container boundary that meant paths differed between the host
# view (/repo/vendor/...) and the container's own view (/repo/... mounted
# from the host root). Now that the whole 00-06 pipeline already runs
# inside ONE unified nebulaos-build container (or directly on a host that
# has build-env/'s tools installed), there is no second boundary to cross -
# every path below is just the real filesystem path, and the root/non-root
# chown dance that used to follow every docker --user root call is gone
# because there's no longer a second UID entering the picture. The
# per-container `--label openke-build-pid=$$` / orphan-container-cleanup
# logic is gone for the same reason: nothing here spawns a container of its
# own to leak.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: this and the other numbered build stages all write into the
# same shared vendor/buildroot-x2000 tree - running two of these at once
# (e.g. from two terminals) would silently interleave writes. Cheap
# insurance: a single exclusive lock file, held for the whole script.
exec 9>"$REPO_ROOT/.nebulaos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.nebulaos-build.lock" >&2; exit 1; }

BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
ARTIFACTS="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
# The NebulaOS BR2_EXTERNAL tree. Everything this project adds to Buildroot
# lives here; nothing under $BUILDROOT_DIR is written except local.mk (which
# carries LINUX_OVERRIDE_SRCDIR and has nowhere else to go). That property is
# the acceptance test for the migration - 06-verify.sh's check_vendor_pin()
# allowlist encodes it.
BR2_EXT="$REPO_ROOT/br2-external"
BR2_EXT_BOARD="$BR2_EXT/board/nebulaos-x2000"
export BR2_EXTERNAL="$BR2_EXT"
KERNEL_SRCDIR="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

if [ ! -d "$BUILDROOT_DIR/.git" ]; then
	echo "vendor/buildroot-x2000 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

# Buildroot 2025.02.18 migration (2026-09-27): the configuration is now
# produced by Buildroot's own defconfig workflow from a minimal, maintainable
# input, instead of copying a 4258-line frozen .config over the tree.
#
#   br2-external/configs/nebulaos_x2000_defconfig   <- INPUT  (84 lines, tracked)
#   artifacts/buildroot-halley5-v30-image/buildroot.config <- OUTPUT (written below)
#
# Both are kept deliberately. The defconfig is what a human edits; the full
# resolved .config is still written back to artifacts/ at the end of this
# script because it is a GATED artifact, not merely a build input -
# baseline-difference-gate.sh and assert-baseline-config.sh diff it verbatim
# against the qualified baseline tag, and a savedefconfig shares almost no
# lines with a full .config, so substituting one for the other would make
# those diffs 100% noise WITHOUT any gate failing. That silence is the danger.
#
# The old duplicate-line hazard this script used to guard against (appending
# "X=y" onto a .config that already had another copy of X, which a later
# olddefconfig then resolved from the OTHER copy) is gone by construction:
# nothing appends to .config any more. `make <defconfig>` writes it from
# scratch every time.
mkdir -p "$BR2_EXT_BOARD"
# BR2_ROOTFS_POST_BUILD_SCRIPT now names this through
# $(BR2_EXTERNAL_NEBULAOS_PATH), so it no longer has to live inside the
# Buildroot tree. It pins the /etc/shadow root hash after the finalize hooks
# and the overlay have run - see the script itself for why neither
# BR2_TARGET_GENERIC_ROOT_PASSWD nor the overlay can do it.
cp "$SCRIPT_DIR/nebulaos-post-build.sh" "$BR2_EXT_BOARD/post-build.sh"
chmod 755 "$BR2_EXT_BOARD/post-build.sh"
cp "$ARTIFACTS/halley5-nebulaos-fragment.config" "$BR2_EXT_BOARD/halley5-nebulaos-fragment.config"
cp "$ARTIFACTS/halley5-nebulaos-busybox-fragment.config" "$BR2_EXT_BOARD/halley5-nebulaos-busybox-fragment.config"
# Phase 11 (2026-08-15): CONFIG_EXTRA_FIRMWARE_DIR in the tracked fragment
# is a literal "/src/board/halley5-nebulaos-overlay/lib/firmware" - valid
# only under the old nested pellcorp/k1-bash-build container, which always
# mounted this project at the fixed path /src regardless of the host
# checkout location. Now that the pipeline runs natively (real host paths
# throughout, no fixed mount point), that path doesn't exist and the kernel
# build fails outright once it reaches drivers/base/firmware_loader. Fixing
# up the *copy* here (not the tracked artifacts/ file, which stays as the
# real historical record of what the old container-based build actually
# used, and which assert-baseline-config.sh/baseline-difference-gate.sh
# diff verbatim against the accepted baseline tag) to point at where the
# overlay's firmware actually lands post-copy below: real host path, so it
# works from any checkout location.
sed -i "s#/src/board/halley5-nebulaos-overlay#$BR2_EXT_BOARD/overlay#" \
	"$BR2_EXT_BOARD/halley5-nebulaos-fragment.config"
cat > "$BUILDROOT_DIR/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRCDIR
EOF
rm -rf "$BR2_EXT_BOARD/overlay"
mkdir -p "$BR2_EXT_BOARD/overlay"
cp -r "$REPO_ROOT/scripts/build/overlay/." "$BR2_EXT_BOARD/overlay/"
mkdir -p "$BR2_EXT_BOARD/overlay/opt/printer_data/comms" \
         "$BR2_EXT_BOARD/overlay/opt/printer_data/logs" \
         "$BR2_EXT_BOARD/overlay/opt/printer_data/gcodes"
# Real bug found live on 2026-07-28: this rm -rf/cp only cleans the BOARD
# overlay staging dir (above), not output/target/ or
# output/build/buildroot-fs/ext2/target/ - per the IMPORTANT comment near
# the top of this file, those two are additive-only and keep every
# renamed-away overlay file forever unless a full clean is done. This has
# now bitten three separate renames (S01tmpfs-datastore ->
# S01persistent-datastore; S39wifi -> S01wifi; S03nebulaos-factory-seed/
# S04nebulaos-activate -> S04nebulaos-factory-seed/S05nebulaos-activate),
# and the last two shipped together on a real flashed device: BOTH old and
# new init.d scripts were present in the same booted squashfs, and because
# the new activate scripts bind_if_not_already() no-ops when its target
# is already mounted, the OLD (pre-fix, less-validated) activation script -
# which sorts earlier and ran first - was the one actually deciding every
# real bind-mount, silently shadowing the fix. Clean every historically
# renamed/removed overlay-relative path from both real output copies here;
# add to this list whenever an overlay file is renamed or deleted, the same
# way dcf7060 does for the seed archives in 04-cross-compile-app-stack.sh.
for obsolete_rel in \
	"etc/init.d/S01tmpfs-datastore" \
	"etc/init.d/S39wifi" \
	"etc/init.d/S03nebulaos-factory-seed" \
	"etc/init.d/S04nebulaos-activate"; do
	rm -f "$BUILDROOT_DIR/output/target/$obsolete_rel" \
	      "$BUILDROOT_DIR/output/build/buildroot-fs/ext2/target/$obsolete_rel" 2>/dev/null || true
done
# Buildroot 2025.02.18 migration: two edits to UPSTREAM Buildroot files used to
# happen here and are both gone.
#
#   1. package/python-matplotlib/python-matplotlib.mk was overwritten wholesale
#      with a vendored copy pinned to matplotlib 3.4.3 and pointed at a local
#      wheel directory (board/halley5-nebulaos-wheels/, carrying a prebuilt
#      numpy cp311 mipsel wheel). That workaround existed because matplotlib
#      3.4.3 built via setup.py, whose legacy setup_requires/fetch_build_eggs
#      path ran a nested pip that inherited _PYTHON_HOST_PLATFORM=linux-mipsel
#      and tried to resolve host build dependencies as target ones.
#      2025.02.18 ships python-matplotlib 3.10.0 and python-numpy 1.25.0 as
#      ordinary packages, and 3.10.0 builds through meson-python - the
#      setup_requires mechanism that caused the problem does not exist in that
#      path at all. Stock packages are used now; the vendored .mk and the
#      cp311 wheel are deleted.
#
#   2. package/squashfs/squashfs.{mk,hash} were sed-patched to switch from
#      GitHub's mutable auto-generated tag archive to the immutable release
#      asset. That was a backport of an upstream fix; 2025.02.18 already sets
#      SQUASHFS_SITE to the releases/download URL and already hashes
#      squashfs-tools-4.6.1.tar.gz. The sed was verified to be a no-op there
#      (its `call github,plougher` precondition is false), so it is deleted
#      rather than left as dead code guarding nothing.
#
# The rule this encodes: NO file under $BUILDROOT_DIR is modified by this
# project. A package Buildroot does not provide goes in br2-external/package/,
# never as a cp over package/.

# Stage the tracked defconfig where Buildroot's `make <name>_defconfig` rule
# looks for it. Buildroot resolves a defconfig name against
# $(TOPDIR)/configs/ and against every BR2_EXTERNAL's configs/ directory; it is
# staged into the Buildroot tree here as well so the name resolves identically
# whether or not BR2_EXTERNAL is exported into a given sub-make.
mkdir -p "$BUILDROOT_DIR/configs"
cp "$BR2_EXT/configs/nebulaos_x2000_defconfig" "$BUILDROOT_DIR/configs/nebulaos_x2000_defconfig"

echo "== generating .config from nebulaos_x2000_defconfig =="
( cd "$BUILDROOT_DIR" && make BR2_EXTERNAL="$BR2_EXT" nebulaos_x2000_defconfig )
echo "== normalizing .config (resolves any derived Kconfig selects) =="
( cd "$BUILDROOT_DIR" && make BR2_EXTERNAL="$BR2_EXT" olddefconfig )

# A configuration that still selects options Buildroot has REMOVED sets
# BR2_LEGACY, and Buildroot refuses to build in that state. Catch it here with
# a clear message rather than several minutes into `make`.
if grep -qE '^BR2_LEGACY=y$' "$BUILDROOT_DIR/.config"; then
	echo "FATAL: the resolved .config sets BR2_LEGACY=y - it still selects options that" >&2
	echo "Buildroot 2025.02.18 has removed. Resolve them in" >&2
	echo "br2-external/configs/nebulaos_x2000_defconfig; do not mask them." >&2
	grep -B2 'BR2_LEGACY' "$BUILDROOT_DIR/.config" | head -20 >&2
	exit 1
fi

# Write the fully resolved .config back to the tracked artifact. This is NOT a
# convenience copy: artifacts/buildroot-halley5-v30-image/buildroot.config is a
# GATED baseline artifact. baseline-difference-gate.sh and
# assert-baseline-config.sh diff it verbatim against QUALIFIED_BASELINE_TAG,
# and lib/baseline-config-compare.sh carries filters written specifically for
# a full .config's shape. Keeping the defconfig as the human-edited INPUT and
# this file as the generated OUTPUT is what lets the minimal defconfig exist
# without silently disarming those gates.
cp "$BUILDROOT_DIR/.config" "$ARTIFACTS/buildroot.config"
echo "== resolved .config written back to artifacts/buildroot-halley5-v30-image/buildroot.config =="

# Reproducibility fix (2026-07-26, NebulaOS mutable-runtime mission): a real
# bug found by directly inspecting the built rootfs.squashfs with unsquashfs
# instead of trusting 05-final-build.sh's exit code - enabling
# BR2_PACKAGE_LIBOPENSSL_BIN=y (the openssl CLI) above did NOT get the
# openssl binary into the image, because libopenssl had already been built
# once before (as a transitive dependency of git/python3-ssl/curl) with that
# suboption off, and Buildroot's own per-package build stamps
# (output/build/<pkg>/.stamp_*) are not invalidated by a suboption-only
# .config change - only by the package's own source/patch/version changing.
# This is a general Buildroot limitation, not specific to openssl: ANY
# suboption added to an already-built package needs an explicit dirclean, or
# it silently keeps the old build. Forcing it here (rather than relying on
# whoever runs this script next to remember to do it by hand, which is
# exactly how this was first missed) makes the fix part of the tracked
# pipeline instead of a one-off manual step - dirclean is a safe no-op if
# the package was never built yet (e.g. on a genuinely fresh output/ tree).
(
	cd "$BUILDROOT_DIR"
	make libopenssl-dirclean 2>/dev/null || true
	# Same class of bug, found again (Memory Resilience Gate, 2026-07-26):
	# adding CONFIG_FEATURE_SWAPON_PRI via the busybox config fragment had
	# no effect on an already-built busybox (confirmed live on a flashed
	# image: swapon rejected the priority option outright) - same
	# stale-stamp mechanism as the libopenssl case above.
	make busybox-dirclean 2>/dev/null || true
)

echo "== buildroot configured =="
