#!/usr/bin/env bash
#
# NebulaOS approved build launcher - the ONLY command the Build Agent is
# permitted to run outside Claude's sandbox.
#
# WHY THIS EXISTS
#
# The supported build path is NebulaOS-firmware/build.sh, which runs the whole
# pipeline inside the digest-pinned container. That needs the container socket,
# which Claude's sandbox denies by stripping supplementary groups. Leaving the
# sandbox restores the ENTIRE host group set - measured: an unsandboxed shell
# regains gid 972 and every other group the user holds. So the escape cannot be
# handed out as "the Build Agent may reach the container engine"; that is
# indistinguishable from "the Build Agent may do anything on this host".
#
# The escape is bound to this file by REAL PATH **and by CONTENT** in
# .claude/hooks/pre-tool-use-identity.sh - the installed copy's bytes must equal
# the tracked canonical blob at firmware HEAD. Path identity alone was not
# enough: this directory is unversioned derived state that the sandbox permits
# writing, so naming an allowed path could otherwise have run arbitrary code
# with host privilege.
#
# This file delegates to build.sh and reimplements no build stage. It is a
# gate, not a second build system.
#
# BUILD ISOLATION
#
# A qualification build NEVER runs in the canonical checkout. Stages 04 and 05
# copy their output over tracked paths under artifacts/, so a build in the
# canonical tree dirties the very repository this launcher requires to be
# clean - one build would block the next until a human ran `git checkout`, one
# slip away from a `git add -A` that commits build output.
#
# Instead the source is cloned fresh, from the canonical REMOTE, at the exact
# requested commit, into a disposable workspace OUTSIDE the NebulaOS workspace
# root (putting it inside would register as an unexpected top-level repository
# and the identity gate would rightly object). Cloning from the remote also
# means only a PUBLISHED commit can be built: an unpushed SHA simply will not
# resolve, which is the property a release build wants anyway.
#
# The canonical workspace is an immutable input. The build workspace is
# disposable and may be modified freely.
#
# BUILD MODES
#
# Exactly two, and they are semantic names, not pass-through options:
#
#   --qualified   (default) reproduce the already hardware-qualified baseline
#                 byte-exactly. Any difference from QUALIFIED_BASELINE_TAG is
#                 a failure, by design.
#   --candidate   the same resolved-artifact assertions, but the baseline
#                 comparison is informational. This is the correct mode for
#                 source that legitimately contains not-yet-hardware-qualified
#                 changes - see assert-baseline-config.sh's own header, which
#                 says in terms not to evaluate such a candidate in the
#                 reproduction mode.
#
# --candidate maps to exactly one thing: NEBULAOS_CANDIDATE_BUILD=1. No other
# environment is set, no option is forwarded to build.sh, and there is no
# general VAR=value facility. The Build Agent gains one semantic mode, not an
# environment.
#
# ON REFUSING THE PRESERVED HISTORICAL WORKSPACE
# This launcher deliberately carries no literal path match for it. Three layers
# already cover that and all three sit above this script: the OS sandbox's
# denyRead, the PreToolUse hook's input scan, and the identity gate's own
# topology checks. This launcher REQUIRES that gate to pass before it runs
# anything, so it inherits the refusal instead of duplicating it - and
# duplicating it here would mean writing the very string the hook refuses to
# accept in tool input.
#
# Usage:  tools/run-nebulaos-build.sh [--candidate|--qualified] <expected-firmware-sha>
#
# The SHA is mandatory and must be the full 40 characters. A build whose source
# identity was not stated up front is not a qualification build.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

die(){ printf 'RUN_NEBULAOS_BUILD=REFUSED\nREASON: %s\n' "$1" >&2; exit 2; }

# --- resolve the workspace root structurally, never by a hard-coded path ----
SELF=$(readlink -f "${BASH_SOURCE[0]}") || die "cannot resolve own path"
SELF_DIR=$(dirname "$SELF")
case "$SELF_DIR" in
  */NebulaOS-firmware/tools/workspace-control/scripts) ROOT=$(cd "$SELF_DIR/../../../.." && pwd -P) ;;
  */tools)                                             ROOT=$(cd "$SELF_DIR/.." && pwd -P) ;;
  *) die "launcher is not in a recognised location: $SELF_DIR" ;;
esac

# --- structural proof this is a live workspace root, not a decoy ------------
[ -x "$ROOT/tools/verify-workspace-identity.sh" ] \
  || die "not a NebulaOS workspace root (no installed identity gate): $ROOT"
[ -f "$ROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST" ] \
  || die "not a NebulaOS workspace root (no canonical control source): $ROOT"
FW="$ROOT/NebulaOS-firmware"
[ -d "$FW/.git" ] || die "$FW is not a git checkout"

# --- arguments: an optional semantic mode, then exactly one full SHA --------
MODE=qualified
case "${1:-}" in
  --candidate) MODE=candidate; shift ;;
  --qualified) MODE=qualified; shift ;;
  --*) die "unknown option '${1}'. This launcher accepts --candidate or --qualified and forwards no build options." ;;
esac
[ "$#" -eq 1 ] || die "usage: run-nebulaos-build.sh [--candidate|--qualified] <expected-firmware-sha> (got $# non-option argument(s))"
EXPECT=$1
case "$EXPECT" in
  *[!0-9a-f]*|"") die "expected-firmware-sha must be a full lowercase hex SHA" ;;
esac
[ "${#EXPECT}" -eq 40 ] || die "expected-firmware-sha must be a full 40-character SHA (got ${#EXPECT})"

# --- the canonical workspace must be sound before it is used as an input ----
"$ROOT/tools/verify-workspace-identity.sh" --hook >/dev/null 2>&1 \
  || die "workspace identity gate failed - run tools/verify-workspace-identity.sh and resolve before building"

DIRTY=0
for r in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-kernel NebulaOS-guppyscreen NebulaOS-klipper-mcu; do
  [ -d "$ROOT/$r/.git" ] || continue
  n=$(git -C "$ROOT/$r" status --porcelain --untracked-files=all 2>/dev/null | grep -vc '^?? \.mcp\.json$' || true)
  [ "$n" -eq 0 ] || { printf 'REASON: %s has %s uncommitted change(s)\n' "$r" "$n" >&2; DIRTY=1; }
done
[ "$DIRTY" -eq 0 ] || die "refusing to build from a dirty canonical workspace - a qualification build must come from committed, published source"

ORIGIN=$(git -C "$FW" remote get-url origin 2>/dev/null) || die "cannot read the canonical firmware remote"
[ -n "$ORIGIN" ] || die "the canonical firmware repository has no origin remote"

# --- disposable build workspace, OUTSIDE the NebulaOS workspace root --------
# Deliberately NOT $TMPDIR: under Claude's sandbox that points at a path the
# build cannot write, and a build workspace that silently fails to be created
# is worse than one in a fixed, boring location.
BUILD_BASE=/var/tmp/nebulaos-build
case "$BUILD_BASE" in "$ROOT"*) die "build workspace would fall inside the canonical workspace root" ;; esac
# One workspace per RUN, not per SHA. Proving reproducibility requires two
# independent builds of the SAME commit to exist at the same time, and the
# previous per-SHA layout made the second build delete the first. The run id
# also gives the two builds different absolute path LENGTHS, which is what
# exposes build-path leakage if any survives.
#
# Nothing is ever reused: each run gets a fresh clone, which is what build.sh's
# own header requires for a clean-room result.
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
WORK="$BUILD_BASE/$EXPECT/run-$RUN_ID"
mkdir -p "$BUILD_BASE/$EXPECT" || die "cannot create the build workspace base at $BUILD_BASE/$EXPECT"
[ -e "$WORK" ] && die "build workspace $WORK already exists"

printf 'RUN_NEBULAOS_BUILD=CLONING\nBUILD_SOURCE_HEAD=%s\nBUILD_MODE=%s\nBUILD_WORKSPACE=%s\nORIGIN=%s\n' \
  "$EXPECT" "$MODE" "$WORK" "$ORIGIN"

git clone --quiet "$ORIGIN" "$WORK" || die "cannot clone $ORIGIN into $WORK"
git -C "$WORK" checkout --quiet --detach "$EXPECT" 2>/dev/null \
  || die "commit $EXPECT did not resolve in a fresh clone of $ORIGIN.
       A release build is built from PUBLISHED source. Either the commit is not on the
       remote at all (push it to a branch), or it is reachable only from refs that a
       plain clone does not fetch - a pull-request head under refs/pull/* is published
       on the forge but is not on any branch, and will not resolve here."

GOT=$(git -C "$WORK" rev-parse HEAD 2>/dev/null) || die "cannot read the build workspace HEAD"
[ "$GOT" = "$EXPECT" ] || die "build workspace HEAD $GOT != requested $EXPECT"

CLONE_ORIGIN=$(git -C "$WORK" remote get-url origin 2>/dev/null)
[ "$CLONE_ORIGIN" = "$ORIGIN" ] || die "build workspace origin $CLONE_ORIGIN != canonical $ORIGIN"

[ -x "$WORK/build.sh" ] || die "$WORK/build.sh missing or not executable"

# --- record what is about to be built --------------------------------------
printf 'RUN_NEBULAOS_BUILD=STARTING\nBUILD_SOURCE_HEAD=%s\nBUILD_MODE=%s\nBUILD_WORKSPACE=%s\nCANONICAL_WORKSPACE=%s\nENTRYPOINT=%s/build.sh\nSTARTED_AT=%s\n' \
  "$EXPECT" "$MODE" "$WORK" "$ROOT" "$WORK" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- delegate to the official pipeline, in the disposable clone -------------
# No stage is reimplemented here. build.sh owns the container, the digest pin
# and every stage. --candidate maps to exactly one variable and nothing else.
if [ "$MODE" = candidate ]; then
  ( cd "$WORK" && NEBULAOS_CANDIDATE_BUILD=1 ./build.sh )
else
  ( cd "$WORK" && ./build.sh )
fi
RC=$?

# --- the canonical workspace must be untouched by the build ----------------
CANON_DIRTY=0
for r in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-kernel NebulaOS-guppyscreen NebulaOS-klipper-mcu; do
  [ -d "$ROOT/$r/.git" ] || continue
  n=$(git -C "$ROOT/$r" status --porcelain --untracked-files=all 2>/dev/null | grep -vc '^?? \.mcp\.json$' || true)
  [ "$n" -eq 0 ] || { printf 'CANONICAL_REPO_DIRTIED=%s (%s file(s))\n' "$r" "$n" >&2; CANON_DIRTY=1; }
done

# --- retention -------------------------------------------------------------
# Each build workspace is a full clone plus a fetched vendor tree, which is
# tens of GB. Nothing else ever removes them, and /var/tmp here is on the root
# filesystem, so without a rule this grows without bound - one tree per
# distinct SHA ever built. Keep the current one and anything recent enough to
# still be useful for comparison; drop the rest. Failures to prune are
# reported, never fatal: a retention problem must not fail a good build.
# NUL-delimited, not newline-delimited. find -print splits on newlines, so a
# directory whose NAME contains a newline yields two read lines, and the second
# is a RELATIVE path that rm resolves against the current directory - outside
# the build base entirely. That was demonstrated, not theorised: the launcher
# runs with the workspace root as its working directory, and /var/tmp is
# world-writable and sticky, so a hostile local user can pre-create the base
# and choose the name. -print0 with read -d removes the class.
PRUNED=0
if [ -d "$BUILD_BASE" ]; then
  while IFS= read -r -d '' old; do
    [ -n "$old" ] || continue
    [ "$old" = "$WORK" ] && continue
    case "$old" in "$BUILD_BASE"/*) ;; *) continue ;; esac
    rm -rf -- "$old" 2>/dev/null && PRUNED=$((PRUNED+1))
  done < <(find "$BUILD_BASE" -mindepth 2 -maxdepth 2 -type d -mtime +14 -print0 2>/dev/null)
fi
RETAINED=$(find "$BUILD_BASE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
DISK=$(du -sh "$BUILD_BASE" 2>/dev/null | cut -f1)
printf 'BUILD_WORKSPACES_PRUNED=%s\nBUILD_WORKSPACES_RETAINED=%s\nBUILD_WORKSPACE_DISK=%s\n' \
  "$PRUNED" "$RETAINED" "${DISK:-unknown}"

printf 'RUN_NEBULAOS_BUILD=FINISHED\nBUILD_SOURCE_HEAD=%s\nBUILD_MODE=%s\nBUILD_WORKSPACE=%s\nBUILD_EXIT_CODE=%s\nCANONICAL_ACTIVE_REPOS_CLEAN=%s\nFINISHED_AT=%s\n' \
  "$EXPECT" "$MODE" "$WORK" "$RC" "$([ "$CANON_DIRTY" -eq 0 ] && echo YES || echo NO)" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A build that dirtied the canonical checkout has broken its own isolation
# guarantee, and that is a failure even when the build itself succeeded.
if [ "$CANON_DIRTY" -ne 0 ]; then
  printf 'REASON: the build modified the canonical workspace; isolation is broken\n' >&2
  exit 3
fi
exit "$RC"
