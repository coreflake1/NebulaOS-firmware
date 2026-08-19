#!/bin/sh
# Final rootfs build - bakes everything stage 4 assembled in the overlay
# (Klipper, Moonraker, ustreamer, Mainsail, the cross-compiled extras) into
# the actual rootfs.ext2/rootfs.squashfs. Assumes 02 and 03 already ran in
# this same session (02 for any overlay/config changes, 03 for any kernel
# source changes with its own forced dirclean) - this script does not
# re-sync the overlay or force a kernel rebuild itself, so a change to
# either that hasn't gone through 02/03 first will silently not appear here.
set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

# Final Closure mission (2026-08-15): DEPS_MANIFEST provides BUILD_IMAGE_REPO/
# BUILD_IMAGE_DIGEST (the digest-pinned unified build container - see
# manifests/dependencies.conf's own comment on that entry) plus every other
# pin recorded below. Named DEPS_MANIFEST, not MANIFEST, to not collide with
# this script's own, unrelated later use of $MANIFEST for the build's own
# output manifest.
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
[ -f "$DEPS_MANIFEST" ] || { echo "FATAL: $DEPS_MANIFEST not found" >&2; exit 1; }
. "$DEPS_MANIFEST"

# 2026-07-23: see 02-configure-buildroot.sh for why this lock exists.
exec 9>"$REPO_ROOT/.nebulaos-build.lock"
flock -n 9 || { echo "another build stage already owns $REPO_ROOT/.nebulaos-build.lock" >&2; exit 1; }

# Phase 11 (2026-08-15): the orphaned-container-cleanup loop and per-call
# `--label openke-build-pid=$$` that used to live here are gone - see
# 02-configure-buildroot.sh's own Phase 11 note.
BUILDROOT_DIR="$REPO_ROOT/vendor/buildroot-x2000"
KERNEL_MOUNT="$REPO_ROOT/vendor/x2000_kernel_6.6/kernel/kernel-6.6"

# 2026-07-23: source-fingerprint check - refuse to package an image built
# from a source tree that changed mid-build (a real risk in this project:
# multiple sessions/processes have edited files in this same repo while a
# build was in flight before). Snapshot before the real make, compare after
# copying artifacts, abort rather than silently ship a mismatched build.
#
# 2026-07-26: excludes artifacts/buildroot-halley5-v30-image/ from the main
# repo's status - this script itself overwrites xImage/rootfs.*/*.config
# under that exact path a few lines below (see the artifact-copy step), which
# was previously included in both the BEFORE and AFTER snapshots and so
# self-tripped this check on every build that changes the kernel/buildroot
# config in a way that produces a different kernel.config/buildroot.config
# than what's currently committed - a false positive, not a real "something
# else touched the tree mid-build" case (which is what this check is
# actually meant to catch).
source_fingerprint() {
	(
		cd "$REPO_ROOT" && git rev-parse HEAD && \
			git status --porcelain=v2 -- . ":(exclude)artifacts/buildroot-halley5-v30-image/"
		cd "$REPO_ROOT/vendor/x2000_kernel_6.6" && git rev-parse HEAD && git status --porcelain=v2
	) | sha256sum | awk '{print $1}'
}
FINGERPRINT_BEFORE=$(source_fingerprint)

( cd "$BUILDROOT_DIR" && make )

mkdir -p "$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
cp "$BUILDROOT_DIR/output/images/xImage" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/xImage"
cp "$BUILDROOT_DIR/output/images/rootfs.ext2" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/rootfs.ext2"
cp "$BUILDROOT_DIR/output/images/rootfs.squashfs" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/rootfs.squashfs"
cp "$BUILDROOT_DIR/.config" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/buildroot.config"
cp "$BUILDROOT_DIR/output/build/linux-custom/.config" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/kernel.config"
cp "$KERNEL_MOUNT/module_drivers/dts/x2000/halley5_v30.dts" "$REPO_ROOT/artifacts/buildroot-halley5-v30-image/halley5_v30.dts"

FINGERPRINT_AFTER=$(source_fingerprint)
if [ "$FINGERPRINT_BEFORE" != "$FINGERPRINT_AFTER" ]; then
	echo "ABORT: source tree changed during the build (fingerprint $FINGERPRINT_BEFORE -> $FINGERPRINT_AFTER)" >&2
	echo "Refusing to trust these artifacts - re-run the build against a stable tree." >&2
	exit 1
fi

# Optional hard gate for a real release build (2026-07-31,
# NEBULAOS_CAMERA_USB_RT_SOURCE_ANALYSIS.md's vendor-pin audit / pre-
# qualification mission Phase A2): "reject release builds from a dirty main
# repository" is the right rule for a FINAL production build, but this same
# script also produces every intermediate experimental/A-B variant build,
# which this project routinely does against a dirty, in-progress tree - a
# blanket rejection here would break that normal workflow. Opt-in via
# NEBULAOS_REQUIRE_CLEAN_TREE=1 (set only for the final Phase 13 production
# build), default off so today's iterative builds are unaffected.
if [ "${NEBULAOS_REQUIRE_CLEAN_TREE:-0}" = "1" ]; then
	# Phase 1.5 closure mission (2026-08-19): the FIRST real exercise of
	# this gate (previously unreachable through build.sh at all - see that
	# script's own history) found it trips on artifacts/guppyscreen-mips/{
	# guppyscreen,guppybeep} - tracked binaries that stage 04
	# (cross-compile-app-stack.sh) deterministically rewrites on every
	# build, BEFORE this gate ever runs, as this project's own already-
	# established convention of committing build-proof artifacts (see the
	# Phase 0+1 integration closeout's own note on
	# artifacts/buildroot-halley5-v30-image/halley5-nebulaos-fragment.config
	# being "a regenerated tracked artifact... rewrites on every build").
	# Not a source change and not evidence of an in-progress, uncommitted
	# edit - excluding it here is the same narrow, named pathspec-exclusion
	# pattern 06-verify.sh already uses for klippy/chelper/c_helper.so.
	# Nothing else is excluded; any other uncommitted change still fails
	# this gate.
	if [ -n "$(cd "$REPO_ROOT" && git status --porcelain -- . ":!artifacts/guppyscreen-mips/")" ]; then
		echo "FATAL: NEBULAOS_REQUIRE_CLEAN_TREE=1 but the main repository has uncommitted changes outside the known, deterministically-regenerated artifacts/guppyscreen-mips/ path - a release build must come from a clean, committed tree" >&2
		echo "$(cd "$REPO_ROOT" && git status --porcelain -- . ":!artifacts/guppyscreen-mips/")" >&2
		exit 1
	fi
fi

# Build manifest - the source of truth flash-spare-slot.sh verifies against
# before writing anything to real hardware (see its own --manifest handling).
# Git commits/dirty-state let a later "which build is this" question be
# answered without guessing from file timestamps.
#
# Expanded 2026-07-31 (same audit) to cover every vendored git tree, not just
# main + kernel - a future investigator holding only this manifest can now
# reconstruct exactly which commit of every dependency produced a given
# shipped image, without needing the live vendor/ checkouts to still exist.
ARTIFACT_DIR="$REPO_ROOT/artifacts/buildroot-halley5-v30-image"
MANIFEST="$ARTIFACT_DIR/build-manifest.txt"
# Phase 1.5 closure mission (2026-08-19): extracted into its own file so
# tests/git-provenance-tests.sh exercises this exact function (both the
# normal-clone and git-worktree shapes) instead of a second, parallel
# reimplementation of its resolution rules.
. "$SCRIPT_DIR/lib/git-provenance.sh"
git_field() {
	# name, vendor-relative-path (empty = repo root)
	git_provenance_field "$1" "$REPO_ROOT${2:+/$2}"
}
artifact_sha256() {
	# name, path
	if [ -f "$2" ]; then
		echo "$1=$(sha256sum "$2" | awk '{print $1}')"
	else
		echo "$1=absent"
	fi
}
{
	echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	# Final Closure mission (2026-08-15): which factory produced this
	# artifact, not just which sources went into it - see Phase L. Read
	# directly from dependencies.conf (already sourced as DEPS_MANIFEST
	# above), so this can never silently drift from the pin actually used.
	echo "build_image_repo=${BUILD_IMAGE_REPO:-absent}"
	echo "build_image_digest=${BUILD_IMAGE_DIGEST:-absent}"
	git_field git_commit_main ""
	git_field git_commit_kernel vendor/x2000_kernel_6.6
	git_field git_commit_buildroot vendor/buildroot-x2000
	git_field git_commit_klipper vendor/klipper
	git_field git_commit_moonraker vendor/moonraker
	git_field git_commit_guppyscreen vendor/nebulaos-guppyscreen
	git_field git_commit_pellcorp_creality vendor/pellcorp-creality
	git_field git_commit_k1_ustreamer vendor/k1-ustreamer
	git_field git_commit_v4l_utils vendor/v4l-utils
	if [ -d "$REPO_ROOT/vendor/k1-ustreamer/.git" ]; then
		echo "git_submodules_k1_ustreamer=$(cd "$REPO_ROOT/vendor/k1-ustreamer" && git submodule status | awk '{printf "%s@%s;", $2, $1}')"
	else
		echo "git_submodules_k1_ustreamer=absent"
	fi
	artifact_sha256 mainsail_zip_sha256 "$REPO_ROOT/vendor/mainsail-dist/mainsail.zip"
	artifact_sha256 guppyscreen_sha256 "$REPO_ROOT/artifacts/guppyscreen-mips/guppyscreen"
	artifact_sha256 guppybeep_sha256 "$REPO_ROOT/artifacts/guppyscreen-mips/guppybeep"
	artifact_sha256 wifi_firmware_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.bin"
	artifact_sha256 wifi_clm_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.clm_blob"
	artifact_sha256 wifi_nvram_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/brcm/brcmfmac43430-sdio.txt"
	artifact_sha256 regulatory_db_sha256 "$REPO_ROOT/scripts/build/overlay/lib/firmware/regulatory.db"
	artifact_sha256 kernel_config_sha256 "$ARTIFACT_DIR/kernel.config"
	artifact_sha256 buildroot_config_sha256 "$ARTIFACT_DIR/buildroot.config"
	artifact_sha256 device_tree_sha256 "$ARTIFACT_DIR/halley5_v30.dts"
	artifact_sha256 xImage_sha256 "$ARTIFACT_DIR/xImage"
	echo "xImage_size=$(wc -c < "$ARTIFACT_DIR/xImage")"
	artifact_sha256 rootfs_squashfs_sha256 "$ARTIFACT_DIR/rootfs.squashfs"
	echo "rootfs_squashfs_size=$(wc -c < "$ARTIFACT_DIR/rootfs.squashfs")"
} > "$MANIFEST"

echo "== final build complete, artifacts copied to artifacts/buildroot-halley5-v30-image/ (xImage, rootfs.ext2, rootfs.squashfs) =="
echo "== build manifest: $MANIFEST =="
cat "$MANIFEST"
