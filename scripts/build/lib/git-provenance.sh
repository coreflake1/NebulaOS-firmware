#!/bin/sh
#
# Phase 1.5 closure mission (2026-08-19). Extracted from 05-final-build.sh's
# inline git_field() so tests/git-provenance-tests.sh can exercise the exact
# function a real build uses, not a second, parallel reimplementation (same
# convention as scripts/build/lib/validate-frontend-controls.sh).
#
# Prints two manifest lines for a given git checkout: <name>=<commit-or-
# absent> and <name>_dirty=<yes|no|unknown>. Every one of git_provenance_field's
# callers relies on BOTH lines always being printed, in that order, even on
# failure - artifact_sha256() and the rest of build-manifest.txt's generator
# treat a partial/missing line as a manifest-format bug, not a soft failure.
#
# Usage: git_provenance_field <manifest-field-name> <absolute-checkout-dir>
git_provenance_field() {
	fname="$1"
	fdir="$2"
	# `-d "$fdir/.git"` alone is only true for a normal clone - a git
	# WORKTREE's .git is a FILE (a "gitdir: <path>" pointer), so checking
	# only for a directory used to silently report every worktree build as
	# "absent" regardless of whether the checkout was real and resolvable.
	# `-e` (true for a file OR a directory) plus actually asking git to
	# resolve HEAD is the correct check - it also naturally handles the
	# case where a worktree's .git file points at a gitdir that isn't
	# reachable from the current process (e.g. a container without the
	# host's git-common-dir mounted), which `-e "$fdir/.git"` alone cannot
	# detect since the pointer FILE itself still exists either way.
	if [ -e "$fdir/.git" ] && git -C "$fdir" rev-parse HEAD >/dev/null 2>&1; then
		echo "${fname}=$(git -C "$fdir" rev-parse HEAD)"
		echo "${fname}_dirty=$([ -z "$(git -C "$fdir" status --porcelain)" ] && echo no || echo yes)"
	else
		echo "${fname}=absent"
		echo "${fname}_dirty=unknown"
	fi
}
