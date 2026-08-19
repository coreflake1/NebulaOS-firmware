#!/bin/sh
# The one documented command to reproduce the current qualified NebulaOS
# baseline from a fresh clone:
#
#   git clone https://github.com/coreflake1/NebulaOS-firmware.git
#   cd NebulaOS-firmware
#   ./build.sh
#
# Fetches every pinned dependency (kernel, Klipper, GuppyScreen, Moonraker,
# Buildroot, ustreamer, Mainsail, wireless-regdb, WiFi firmware - see
# manifests/dependencies.conf), composes all 8 accepted baseline variants,
# builds the kernel/rootfs/app-stack, and verifies the result against the
# accepted-baseline assertions - scripts/build/build-qualified-baseline.sh
# does the actual sequencing; this is a thin, host-dependency-aware wrapper
# around it, not a reimplementation.
#
# Phase 11 (2026-08-15, unified-build-environment migration): this used to
# have two modes - run directly on a host with git/curl/etc already
# installed, or `--containerized` to get those from a thin wrapper image
# that then launched TWO MORE nested containers (pellcorp/k1-bash-build,
# ghcr.io/coreflake1/guppydev) via the host's own Docker socket for the
# actual work. That nested-container design is gone. There is now exactly
# ONE container, pinned by digest in manifests/dependencies.conf
# (BUILD_IMAGE_REPO/BUILD_IMAGE_DIGEST) - it already contains every host
# build tool the 00-06 pipeline needs (see build-env/Dockerfile), so
# nothing here or inside those stages ever calls `docker`/`apt-get` again.
#
# Requires on the host: Docker or Podman, and nothing else - not even git,
# since the container itself is what clones/builds everything once it's
# running with this checkout mounted in.
#
# Does NOT reuse any existing vendor/, build-work/, or artifacts/ state by
# itself - run this against a genuinely fresh clone for a real clean-room
# result (an already-populated vendor/ is convenient for iteration but
# defeats the point of using this script to prove reproducibility).
#
# Exits non-zero if any pin fails to resolve, any variant fails to apply,
# either baseline assertion fails, or any build stage fails - this script
# propagates the container's real exit status, it does not swallow it.

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/manifests/dependencies.conf"
[ -f "$MANIFEST" ] || { echo "FATAL: $MANIFEST not found" >&2; exit 1; }
. "$MANIFEST"

: "${BUILD_IMAGE_REPO:?FATAL: BUILD_IMAGE_REPO not set in $MANIFEST}"
: "${BUILD_IMAGE_DIGEST:?FATAL: BUILD_IMAGE_DIGEST not set in $MANIFEST}"
IMAGE_REF="${BUILD_IMAGE_REPO}@${BUILD_IMAGE_DIGEST}"

ENGINE=""
for candidate in docker podman; do
	command -v "$candidate" >/dev/null 2>&1 && { ENGINE="$candidate"; break; }
done
[ -n "$ENGINE" ] || {
	echo "FATAL: neither docker nor podman found on this host - one of them is required to run the pinned build environment ($IMAGE_REF)." >&2
	exit 1
}

echo "== build.sh: pulling pinned build environment $IMAGE_REF (engine: $ENGINE) =="
"$ENGINE" pull "$IMAGE_REF"

# NEBULAOS_REPO_ROOT: fixed container-internal mount point, deliberately
# NOT the host's own checkout path.
#
# Final Closure mission, Phase C (2026-08-15): this used to mount the
# checkout at the SAME absolute path inside the container as outside it
# (-v "$SCRIPT_DIR:$SCRIPT_DIR"), reasoned at the time as avoiding a path
# boundary crossing. That reasoning missed a real consequence, found by
# the Phase 9 vs Phase 11 artifact comparison: the host's own checkout
# path (which varies - different developers, different clone locations,
# even the same developer's own repeated test directories in this
# session) leaks straight into the build. CONFIG_EXTRA_FIRMWARE_DIR
# embedded it directly; GuppyScreen's binary carried ~770KB of diff
# traced to embedded absolute build-path strings, purely because the
# container saw a different host path on every separate clone. Two
# builds of byte-identical source, in the byte-identical image, produced
# different output for a reason that has nothing to do with the product.
#
# Mounting at one fixed internal path instead - regardless of where the
# user actually cloned this repo on the host - means every build sees the
# identical internal path, so anything that embeds it (Kconfig strings,
# __FILE__/assert() macros, debug info) embeds the same bytes every time.
# Every script under scripts/build/ already derives its own location via
# `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` rather than a hardcoded
# path, so this needs no changes anywhere else - they'll all resolve to
# NEBULAOS_REPO_ROOT automatically once the working directory is set here.
# Output files stay on the host exactly as before: a bind mount is a
# transparent, two-way passthrough regardless of which internal path it's
# mounted at, so anything the container writes under NEBULAOS_REPO_ROOT
# still lands at $SCRIPT_DIR on the host.
NEBULAOS_REPO_ROOT=/workspace/NebulaOS-firmware

# Phase 1.5 persistent-namespace mission (2026-08): 06-verify.sh (and any
# other in-container script that shells out to `git` against the checkout)
# used to hard-fail with "fatal: not a git repository" whenever $SCRIPT_DIR
# is a git WORKTREE rather than a normal clone. A worktree's own .git is a
# FILE containing "gitdir: <host-absolute-path>/.git/worktrees/<name>" -
# that path is real on the host but does not exist inside the container,
# so any git command that walks up from $NEBULAOS_REPO_ROOT to resolve it
# fails outright, aborting the whole build under `set -e`.
#
# Fix: if that's a worktree, bind-mount the real git-common-dir it points
# at, AT THE SAME HOST-ABSOLUTE PATH, read-only, so the pointer resolves
# inside the container exactly like it does on the host. This is the one
# deliberate exception to the "container never sees a host path" rule
# above (Final Closure mission, Phase C) - that rule exists because a host
# path embedded in $NEBULAOS_REPO_ROOT can leak into compiled artifacts
# (Kconfig strings, debug info); a read-only mount used only for `git`
# metadata queries never touches compiled output, so it does not
# reintroduce that problem. A normal clone (.git is a real directory) needs
# no extra mount - it already resolves entirely inside $SCRIPT_DIR, which
# is already bind-mounted above.
HOST_GIT_COMMON_DIR=""
if [ -f "$SCRIPT_DIR/.git" ]; then
	# git rev-parse --git-common-dir is not guaranteed absolute across git
	# versions/invocation contexts - cd into whatever it prints and take
	# `pwd` to get a real, canonical absolute path regardless.
	GIT_COMMON_DIR_RAW=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null || true)
	if [ -n "$GIT_COMMON_DIR_RAW" ]; then
		# GIT_COMMON_DIR_RAW may be relative - if so it is relative to
		# $SCRIPT_DIR (where the git command ran via -C), not to this
		# script's own cwd, so resolve it from there explicitly.
		HOST_GIT_COMMON_DIR=$(cd "$SCRIPT_DIR" && cd "$GIT_COMMON_DIR_RAW" 2>/dev/null && pwd)
	fi
	if [ -n "$HOST_GIT_COMMON_DIR" ] && [ -d "$HOST_GIT_COMMON_DIR" ]; then
		echo "== build.sh: $SCRIPT_DIR is a git worktree - bind-mounting its common git dir ($HOST_GIT_COMMON_DIR) read-only so in-container git commands can resolve it =="
	else
		HOST_GIT_COMMON_DIR=""
		echo "== build.sh: WARNING: $SCRIPT_DIR looks like a git worktree but its common git dir could not be resolved on the host - in-container git metadata (git_commit_main, 06-verify.sh's pin checks) will report 'absent'/fail rather than guess ==" >&2
	fi
fi

# -e HOME=/tmp: an arbitrary host UID has no /etc/passwd entry inside the
# container, so HOME defaults to "/" (not writable by this UID) - confirmed
# live this would break any tool that wants to write a cache/config file
# (pip's download cache, git's config lookup). /tmp is writable by anyone
# and doesn't need to persist across runs.
# No -it: found live running this in the background (nohup, no attached
# terminal) - `-t` fails outright ("cannot attach stdin to a TTY-enabled
# container because stdin is not a terminal") when there's no real TTY, and
# this build never actually needs interactive stdin either way. Plain `-i`
# without `-t` would still block waiting on stdin in a backgrounded/piped
# invocation with none available - dropping both is correct for a batch
# build, not just a workaround.
# POSIX sh has no arrays, so the optional extra mount is built as
# positional parameters instead of a conditionally-included string (unsafe
# with paths containing spaces).
set -- "$ENGINE" run --rm \
	--user "$(id -u):$(id -g)" \
	-e HOME=/tmp \
	-e NEBULAOS_REPO_ROOT="$NEBULAOS_REPO_ROOT" \
	-v "$SCRIPT_DIR:$NEBULAOS_REPO_ROOT"
if [ -n "$HOST_GIT_COMMON_DIR" ]; then
	set -- "$@" -v "$HOST_GIT_COMMON_DIR:$HOST_GIT_COMMON_DIR:ro"
fi
set -- "$@" -w "$NEBULAOS_REPO_ROOT" "$IMAGE_REF" "sh scripts/build/build-qualified-baseline.sh"
exec "$@"
