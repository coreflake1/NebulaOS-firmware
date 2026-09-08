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
KERNEL_SRCDIR="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

if [ ! -d "$BUILDROOT_DIR/.git" ]; then
	echo "vendor/buildroot-x2000 not found - run 00-fetch-vendor-sources.sh first" >&2
	exit 1
fi

cp "$ARTIFACTS/buildroot.config" "$BUILDROOT_DIR/.config"
mkdir -p "$BUILDROOT_DIR/board"
cp "$ARTIFACTS/halley5-nebulaos-fragment.config" "$BUILDROOT_DIR/board/halley5-nebulaos-fragment.config"
cp "$ARTIFACTS/halley5-nebulaos-busybox-fragment.config" "$BUILDROOT_DIR/board/halley5-nebulaos-busybox-fragment.config"
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
sed -i "s#/src/board/halley5-nebulaos-overlay#$BUILDROOT_DIR/board/halley5-nebulaos-overlay#" \
	"$BUILDROOT_DIR/board/halley5-nebulaos-fragment.config"
cat > "$BUILDROOT_DIR/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRCDIR
EOF
rm -rf "$BUILDROOT_DIR/board/halley5-nebulaos-overlay"
mkdir -p "$BUILDROOT_DIR/board/halley5-nebulaos-overlay"
cp -r "$REPO_ROOT/scripts/build/overlay/." "$BUILDROOT_DIR/board/halley5-nebulaos-overlay/"
mkdir -p "$BUILDROOT_DIR/board/halley5-nebulaos-overlay/opt/printer_data/comms" \
         "$BUILDROOT_DIR/board/halley5-nebulaos-overlay/opt/printer_data/logs" \
         "$BUILDROOT_DIR/board/halley5-nebulaos-overlay/opt/printer_data/gcodes"
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
rm -rf "$BUILDROOT_DIR/board/halley5-nebulaos-wheels"
mkdir -p "$BUILDROOT_DIR/board/halley5-nebulaos-wheels"
cp "$REPO_ROOT/scripts/build/vendor-wheels/"*.whl "$BUILDROOT_DIR/board/halley5-nebulaos-wheels/"
cp "$REPO_ROOT/scripts/build/vendor-patches/python-matplotlib/python-matplotlib.mk" "$BUILDROOT_DIR/package/python-matplotlib/python-matplotlib.mk"

# squashfs-tools 4.6.1: GitHub's auto-generated tag archives are mutable —
# the hash changed after Buildroot pinned it. Upstream Buildroot fixed this
# by switching to the stable release asset (same content, immutable URL).
# Apply the same fix idempotently to our pinned buildroot-x2000 checkout.
_sq_mk="$BUILDROOT_DIR/package/squashfs/squashfs.mk"
_sq_hash="$BUILDROOT_DIR/package/squashfs/squashfs.hash"
if grep -q 'call github,plougher' "$_sq_mk" 2>/dev/null; then
	sed -i \
		-e 's|^SQUASHFS_SITE = .*|SQUASHFS_SOURCE = squashfs-tools-$(SQUASHFS_VERSION).tar.gz\nSQUASHFS_SITE = https://github.com/plougher/squashfs-tools/releases/download/$(SQUASHFS_VERSION)|' \
		"$_sq_mk"
	sed -i \
		-e 's|squashfs-4\.6\.1\.tar\.gz|squashfs-tools-4.6.1.tar.gz|' \
		"$_sq_hash"
	echo "== squashfs-tools: switched to stable release asset (upstream Buildroot fix) =="
else
	echo "== squashfs-tools: already using stable release asset =="
fi
if grep -q 'call github,plougher' "$_sq_mk" 2>/dev/null; then
	echo "FATAL: squashfs-tools still uses GitHub auto-generated archive after fix" >&2
	exit 1
fi
if ! grep -q 'squashfs-tools-4\.6\.1\.tar\.gz' "$_sq_hash" 2>/dev/null; then
	echo "FATAL: squashfs.hash does not reference the stable release asset filename" >&2
	exit 1
fi

echo "== normalizing .config (resolves any derived Kconfig selects) =="
( cd "$BUILDROOT_DIR" && make olddefconfig )

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
