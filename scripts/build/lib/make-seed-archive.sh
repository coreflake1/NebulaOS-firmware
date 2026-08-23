#!/bin/sh
#
# NebulaOS auto-updates-camera-complete mission (2026-07-28, see
# docs/NEBULAOS_MOONRAKER_UPDATE_AND_CAMERA_ANALYSIS.md). Shared by
# scripts/build/04-cross-compile-app-stack.sh (real build - packages
# vendor/klipper and vendor/moonraker) and tests/factory-seed-git-tests.sh
# (offline fixture repos) - kept in its own file specifically so the tests
# exercise this exact function, not a second/parallel reimplementation of
# its validation rules.
#
# PRIOR APPROACH (removed): each vendor checkout was flattened into a
# single synthetic orphan commit ("NebulaOS factory seed snapshot of
# <branch> @ <true_commit>") before bundling, because a plain
# `git bundle create` of vendor/klipper's shallow clone (1-2 commits deep,
# 00-fetch-vendor-sources.sh's clone_pinned) produces a bundle that
# `git bundle verify` reports as fine but a real `git clone` of rejects
# with "Failed to traverse parents of commit ..." / "remote did not send
# all necessary objects" (confirmed again against git 2.55.0 - a genuine,
# still-present git limitation, not a syntax mistake). That synthetic
# commit had no shared ancestry with the real coreflake1/NebulaOS-klipper
# or Arksine/moonraker history on GitHub, which made Moonraker's own
# `git merge-base --is-ancestor HEAD origin/<branch>` check permanently
# fail (return code 1) on every freshly-seeded device - HEAD could never
# be an ancestor of a real remote branch it shared no history with. This
# set `diverged=true` -> `has_recoverable_errors()=true` ->
# `is_valid()=false` (vendor/moonraker/moonraker/components/update_manager/
# git_deploy.py) permanently, blocking every real Klipper/Moonraker update.
#
# FIX: stop bundling/flattening entirely. Archive each vendor checkout's
# REAL `.git` directory (shallow boundary, real branch, real commits) plus
# its working tree as a plain tar file, with the local branch renamed to
# match Moonraker's hardcoded reserved-slot expectation ("master" - see
# BASE_CONFIG in update_manager/common.py, not configurable) and origin
# rewritten to the real public remote. On-device seeding (S04) then
# extracts the tar directly into place - no `git clone` at all, which is
# also strictly cheaper on this 208MB device than the clone-from-bundle
# step it replaces (plain tar extraction does no object repacking).

# chelper_enforce_mtime() lives in the same overlay file the device itself
# uses at boot (/etc/nebulaos-chelper-preflight.sh), sourced here rather than
# reimplemented, so the build-time and boot-time definitions of the invariant
# cannot drift apart - the same reasoning that put make_seed_archive() itself
# in a shared file rather than duplicating it between the build and its tests.
# Only sourced if not already defined, so a caller that has already sourced it
# (04-cross-compile-app-stack.sh does) is unaffected.
if ! command -v chelper_enforce_mtime >/dev/null 2>&1; then
	_mksa_dir=$(cd "$(dirname "$0")" && pwd)
	for _cand in \
		"$_mksa_dir/overlay/etc/nebulaos-chelper-preflight.sh" \
		"$_mksa_dir/../scripts/build/overlay/etc/nebulaos-chelper-preflight.sh" \
		"$_mksa_dir/../build/overlay/etc/nebulaos-chelper-preflight.sh"; do
		if [ -f "$_cand" ]; then . "$_cand"; break; fi
	done
	unset _mksa_dir _cand
fi

make_seed_archive() {
	src="$1"; active_branch="$2"; origin_url="$3"; out="$4"; sparse_exclude="${5:-}"
	# Production optimization mission, Phase 4 (2026-07-30): both optional,
	# trailing so every existing 5-arg call site (including
	# tests/factory-seed-git-tests.sh's offline fixtures, which have no
	# real target Python toolchain to test against) is unaffected and
	# simply skips precompilation. python3_bin must be a HOST-architecture
	# build of the *same* CPython version/build that runs on the target
	# (Buildroot's own output/host/bin/python3, exactly what
	# BR2_PACKAGE_PYTHON3_PYC_ONLY already uses for system packages) -
	# Python bytecode itself is not CPU-architecture-specific, only
	# CPython-version-specific, so this produces byte-identical .pyc
	# output to what the target interpreter would compile natively,
	# without needing target emulation. mount_path is the real absolute
	# path this tree runs from on the device (e.g. /opt/klipper) - used
	# only to make embedded tracebacks show real device paths instead of
	# this function's own mktemp staging path; purely cosmetic, no
	# functional effect on bytecode validity.
	python3_bin="${6:-}"; mount_path="${7:-}"
	tmp=$(mktemp -d)
	cp -r "$src/." "$tmp/"
	# Ensure the archived copy is checked out on the branch Moonraker's
	# reserved slot actually expects, without disturbing $src itself.
	#
	# Phase 1.8 candidate-001 root cause: the old code did a plain
	# `git checkout "$active_branch"` which, when $src had a DETACHED HEAD
	# at the pinned commit (the normal state after clone_pinned's non-shallow
	# path does `git checkout "$ref"`), switched to the local branch at its
	# ORIGINAL position (the clone's default HEAD, e.g. main at 448b59c)
	# instead of staying at the pinned commit (e.g. 7260389). The archive
	# then contained the wrong content. `checkout -B` forces the local
	# branch to the current HEAD position, which is always correct: if HEAD
	# is detached at the pin, the branch moves there; if HEAD is already on
	# the branch (shallow-clone path), it stays.
	git -C "$tmp" checkout -q -B "$active_branch"

	# Real bug found live (first full first-boot qualification, 2026-07-28):
	# a plain `tar -xzf` of vendor/klipper's real working tree still has to
	# write out its ~226MB of real files (mostly its own vendored MCU HAL/
	# SDK sources under lib/, needed only to compile MCU firmware - never
	# read by Klippy's own host-side runtime) - measured live at 1m51s on
	# the real device, on top of both venv creations and moonraker's own
	# seeding. The device was hard-rebooted twice by an impatient human
	# before that ever finished, leaving klipper/moonraker's app
	# directories seeded empty (no .git at all) - not a WiFi bug, a
	# too-slow factory seed. Fixed with git's own sparse-checkout: the
	# excluded path's blobs stay fully present in .git/objects (real,
	# complete history - the mission's core requirement - is untouched),
	# only the WORKING TREE omits it, and git treats that as intentional
	# sparsity, not a modification/deletion (confirmed live: `git status`
	# reports "in a sparse checkout", never a dirty/deleted lib/). Cut
	# klipper's real device extraction from 1m51s to a few seconds.
	if [ -n "$sparse_exclude" ]; then
		git -C "$tmp" sparse-checkout init --no-cone
		printf '/*\n!%s\n' "$sparse_exclude" > "$tmp/.git/info/sparse-checkout"
		git -C "$tmp" read-tree -mu HEAD
	fi
	# Reset ALL remotes to exactly one "origin" with the standard
	# wildcard fetch refspec. Real bug found while validating this
	# against the actual coreflake1/NebulaOS-klipper remote: vendor/
	# klipper's own "origin" remote (00-fetch-vendor-sources.sh's
	# clone_pinned) is scoped to a narrow `+refs/heads/jun2025:
	# refs/remotes/origin/jun2025` fetch refspec, left over from its
	# original single-branch clone. Archiving that config as-is would
	# make a later plain `git fetch origin` (exactly what Moonraker's
	# own GitDeploy refresh runs) silently fail to populate
	# refs/remotes/origin/master at all, reproducing the very
	# `merge-base --is-ancestor HEAD origin/master` failure
	# (diverged=true) this whole mission exists to fix - confirmed by
	# reproducing it locally before this fix. Removing every remote and
	# re-adding a single "origin" with git's normal wildcard refspec is
	# what a real `git clone` would have produced, and is what this
	# archive must reproduce without ever running a clone.
	for r in $(git -C "$tmp" remote); do
		git -C "$tmp" remote remove "$r"
	done
	# `git remote remove` does not always clean up a leftover
	# refs/remotes/<name>/HEAD symref (a known git quirk - HEAD is a
	# symbolic ref, not a plain remote-tracking branch); left in place it
	# points at nothing and makes `git fsck` print a spurious "invalid
	# sha1 pointer" error. Harmless to the actual ancestry check but real
	# noise in build logs, so clear the whole refs/remotes tree outright.
	rm -rf "$tmp/.git/refs/remotes"
	git -C "$tmp" remote add origin "$origin_url"
	git -C "$tmp" config "remote.origin.fetch" "+refs/heads/*:refs/remotes/origin/*"
	# Real, critical bug found live during the first genuinely successful
	# fresh-boot qualification: `branch --set-upstream-to` requires the
	# target remote-tracking ref (origin/<branch>) to already exist
	# locally, which it never does in an offline-built archive (no fetch
	# has ever happened against this freshly-added "origin" remote) - so
	# this silently failed every single time, swallowed by its own
	# `|| true`. Without it, the branch has no `branch.<name>.remote`
	# config at all, which is exactly what Moonraker's own GitDeploy reads
	# to populate `git_remote` (git_deploy.py's `config_get(f"branch.
	# {branch}.remote")`) - with that unset, git_remote is "?", and
	# is_valid()'s own `"?" not in (git_branch, git_remote,
	# upstream_commit)` check fails it directly, independent of and in
	# addition to the diverged/dirty/detached checks this mission already
	# fixed. Confirmed live: `is_valid` stayed false with a real, correctly
	# ancestor-reachable, non-diverged, non-dirty repo until this exact
	# config was set. Setting the two config keys directly (not via
	# `--set-upstream-to`) needs no pre-existing remote-tracking ref at
	# all - confirmed live this alone was sufficient to make Moonraker
	# report is_valid=true for both klipper and moonraker.
	git -C "$tmp" config "branch.$active_branch.remote" origin
	git -C "$tmp" config "branch.$active_branch.merge" "refs/heads/$active_branch"

	# Seed a remote-tracking ref so Moonraker's check_diverged()
	# succeeds. Without this, no refs/remotes/origin/$branch exists,
	# and `merge-base --is-ancestor HEAD origin/master` fails.
	mkdir -p "$tmp/.git/refs/remotes/origin"
	git -C "$tmp" rev-parse HEAD > "$tmp/.git/refs/remotes/origin/$active_branch"

	# clone_pinned leaves TWO entries in .git/shallow: the original
	# clone HEAD and the pinned commit fetch. The stale entry's
	# commit object references a parent that was never fetched
	# (beyond the original shallow boundary), so simply removing
	# the entry from .git/shallow makes git try to traverse past it
	# into a missing parent — breaking fsck, gc, and merge-base.
	# Fix: (1) rewrite .git/shallow to HEAD only, (2) clear reflogs
	# that reference the stale commit, (3) repack with only objects
	# reachable from current refs to physically remove the orphan.
	head_sha=$(git -C "$tmp" rev-parse HEAD)
	if [ -f "$tmp/.git/shallow" ]; then
		stale_count=$(grep -cv "^$head_sha$" "$tmp/.git/shallow" 2>/dev/null || echo 0)
		if [ "$stale_count" -gt 0 ]; then
			echo "$head_sha" > "$tmp/.git/shallow"
			rm -rf "$tmp/.git/logs"
			_reachable=$(mktemp)
			git -C "$tmp" rev-list --objects --all > "$_reachable"
			_pack_hash=$(git -C "$tmp" pack-objects "$tmp/.git/objects/pack/pack" < "$_reachable")
			rm -f "$_reachable"
			for _p in "$tmp"/.git/objects/pack/pack-*.pack; do
				_bn=$(basename "$_p" .pack)
				[ "$_bn" != "pack-$_pack_hash" ] && rm -f "$_p" "${_p%.pack}.idx" "${_p%.pack}.rev"
			done
		fi
	fi

	# Discard a wrong-architecture klippy/chelper/c_helper.so before
	# packaging (e.g. a host-recompiled x86 .so left over from a
	# developer running `make` locally, outside this project's own
	# cross-compile pipeline - must never ship to the MIPS target). Real
	# bug found while writing this function's own tests: an earlier
	# version did a blanket `git checkout -- .`, which discards ANY
	# tracked-file modification - that silently defeated the dirty-tree
	# rejection below for every tracked file, not just this one binary
	# (confirmed live: a deliberately dirtied source file was wiped clean
	# before the check ever ran, so "reject a dirty tree" never actually
	# fired). Only ever discard this specific, known-safe path; anything
	# else dirty must still fail the check below.
	#
	# Final Baseline Closure mission (2026-08-08): c_helper.so is no
	# longer git-tracked at all as of KLIPPER_PIN 845396f0 (it is a
	# generated build artifact, not source - see that pin's own commit
	# message and docs/NEBULAOS_C_HELPER_DIRTY_STATE_FIX.md), so there is
	# no longer a committed "known good" version for `git checkout` to
	# restore - that call would now fail every time (pathspec unknown to
	# git) and silently no-op behind its own `|| true`. A plain `rm -f`
	# achieves the same real safety property (never package a
	# wrong-architecture binary) more directly: a missing c_helper.so
	# fails loudly downstream (Klippy's own get_ffi() has no on-device
	# build fallback - see NebulaOS-klipper's klippy/chelper/__init__.py)
	# rather than silently shipping a binary that would have failed just
	# as loudly, just less predictably.
	if [ -e "$tmp/klippy/chelper/c_helper.so" ] \
		&& ! file -b "$tmp/klippy/chelper/c_helper.so" | grep -qi "MIPS"; then
		rm -f "$tmp/klippy/chelper/c_helper.so"
	fi

	# Defense in depth: this archive must contain zero synthetic history
	# and a genuinely clean, valid repo before it is ever packaged.
	if git -C "$tmp" log --all --format=%s 2>/dev/null | grep -q "NebulaOS factory seed snapshot"; then
		echo "ERROR: refusing to package $src - synthetic wrapper commit detected in history" >&2
		rm -rf "$tmp"
		return 1
	fi
	# Production optimization mission, Phase 9 (2026-07-30): real bug found
	# live - the properly cross-compiled, correctly stripped MIPS
	# klippy/chelper/c_helper.so built by the real pipeline is legitimately
	# ALWAYS different from whatever is tracked in git for this path (an
	# untrusted upstream binary, never intended to ship as-is - see the
	# comment on the check above this one), so this dirty-tree guard would
	# otherwise reject every real build. Exclude just this one, already-
	# understood, expected-to-differ path from the clean-tree check -
	# anything else dirty must still fail it.
	if [ -n "$(git -C "$tmp" status --porcelain -- . ':!klippy/chelper/c_helper.so')" ]; then
		echo "ERROR: refusing to package $src - working tree is not clean" >&2
		rm -rf "$tmp"
		return 1
	fi
	if ! git -C "$tmp" fsck --no-dangling >/dev/null; then
		echo "ERROR: refusing to package $src - git fsck reported repository damage" >&2
		rm -rf "$tmp"
		return 1
	fi

	# Precompile to .pyc, deliberately AFTER the clean-tree check above,
	# not before: __pycache__ directories are untracked, and the dirty-
	# tree guard would otherwise refuse to package a tree that compiled
	# cleanly. A failure here is non-fatal - it just means this seed
	# ships without precompiled bytecode and pays the normal one-time
	# compile-on-first-import cost instead, same as before this feature
	# existed; it must never block the whole build.
	#
	# Excludes top-level scripts/ as well as .git/: real failure found
	# live - Klipper's own scripts/stepstats.py is a Python-2-only dev
	# tool (a bare `print "..." %` statement) that Klippy's own runtime
	# never imports, but compileall's walk still reaches it and returns
	# non-zero for the whole tree over that one irrelevant file (Moonraker
	# has a handful of similarly never-imported scripts/*.py of its own -
	# losing bytecode for these purely host-side dev/release tools, never
	# run on the target, is a non-issue).
	if [ -n "$python3_bin" ]; then
		if [ -n "$mount_path" ]; then
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' -s "$tmp" -p "$mount_path" "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		else
			PYTHONPATH="" "$python3_bin" -m compileall -q \
				-x '(^|/)(\.git|scripts)($|/)' "$tmp" \
				|| echo "WARNING: bytecode precompilation failed for $src - shipping source-only, as before" >&2
		fi
	fi

	# Phase 1 no-fork migration: re-establish the c_helper.so mtime
	# invariant as the LAST thing before packaging, and fail the build if
	# it cannot be established.
	#
	# This is not belt-and-braces, it is load-bearing. Klipper decides
	# whether to shell out to gcc by comparing mtimes, and this function
	# has already done three separate things that rewrite them in
	# nondeterministic order: `cp -r "$src/." "$tmp/"` does NOT preserve
	# mtimes (no -p, no -a), `git checkout` can rewrite working-tree files,
	# and the sparse-checkout `read-tree -mu HEAD` rewrites them again.
	# After all that, whether the prebuilt library ends up newer than
	# klippy/chelper/*.c is decided by directory-walk order - which is to
	# say, by luck. On a bad roll the device gets an image whose Klippy
	# tries to invoke a compiler that does not exist and never starts.
	#
	# Deliberately guarded on the directory existing so this stays a shared
	# function: only the Klipper tree has a chelper, and moonraker (and the
	# offline fixture repos in tests/factory-seed-git-tests.sh) must pass
	# straight through.
	if [ -d "$tmp/klippy/chelper" ]; then
		if ! chelper_enforce_mtime "$tmp"; then
			echo "ERROR: refusing to package $src - could not establish the c_helper.so mtime invariant" >&2
			rm -rf "$tmp"
			return 1
		fi
	fi

	# gzip, not a plain tar: real bug found at the first full build after
	# this archive format landed - a plain tar of vendor/klipper's real
	# working tree (~226MB uncommitted source, mostly its own vendored
	# MCU HAL/SDK libraries under lib/) on top of the ALREADY-shipped
	# plain copy at /opt/klipper overflowed the fixed 400M rootfs.ext2
	# ("Could not allocate block in ext2 filesystem"). The old flattened-
	# commit bundle never hit this because git's own pack compression
	# made it ~11.5MB; gzip here brings a real tar back down to a
	# comparable order of magnitude (~40MB measured) while still
	# preserving real, non-synthetic history.
	tar -C "$tmp" -czf "$out" .
	git -C "$tmp" rev-parse HEAD
	rm -rf "$tmp"
}
