#!/usr/bin/env bash
#
# NebulaOS approved build launcher - the ONLY command the Build Agent is
# permitted to run outside Claude's sandbox.
#
# WHY THIS EXISTS
#
# The supported build path is NebulaOS-firmware/build.sh, which runs the whole
# pipeline inside the digest-pinned container. That needs the Docker socket,
# which Claude's sandbox denies by stripping supplementary groups. Disabling
# the sandbox restores the ENTIRE host group set - measured: an unsandboxed
# shell regains gid 972 (docker) and every other group the user holds. So the
# escape cannot be handed out as "the Build Agent may run docker"; that would
# be indistinguishable from "the Build Agent may do anything on this host".
#
# The escape is therefore bound to exactly this file by realpath in
# .claude/hooks/pre-tool-use-identity.sh, and this file delegates to build.sh
# rather than reimplementing any build stage. It is a gate, not a second build
# system.
#
# ON REFUSING THE PRESERVED HISTORICAL WORKSPACE
# This launcher deliberately carries no literal path match for it. Three layers
# already cover that and all three sit above this script: the OS sandbox's
# denyRead, the PreToolUse hook's input scan, and the identity gate's own
# topology checks (forbidden active paths, preserved-tree directories inside
# the active root). This launcher REQUIRES that gate to pass before it runs
# anything, so it inherits the refusal instead of duplicating - and
# duplicating it here would mean writing the very string the hook refuses to
# accept in tool input, which is why the structural checks below are the
# mechanism.
#
# Usage:  tools/run-nebulaos-build.sh <expected-firmware-sha>
#
# The SHA is mandatory and must match firmware HEAD exactly. A build whose
# source identity was not stated up front is not a qualification build.
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
[ -x "$FW/build.sh" ] || die "$FW/build.sh missing or not executable"

# --- exactly one argument: the expected firmware SHA -----------------------
[ "$#" -eq 1 ] || die "usage: run-nebulaos-build.sh <expected-firmware-sha> (got $# argument(s)); this launcher accepts no build options and forwards none"
EXPECT=$1
case "$EXPECT" in
  *[!0-9a-f]*|"") die "expected-firmware-sha must be a full lowercase hex SHA" ;;
esac
[ "${#EXPECT}" -eq 40 ] || die "expected-firmware-sha must be a full 40-character SHA (got ${#EXPECT})"

# --- source identity -------------------------------------------------------
HEAD=$(git -C "$FW" rev-parse HEAD 2>/dev/null) || die "cannot read firmware HEAD"
[ "$HEAD" = "$EXPECT" ] || die "firmware HEAD $HEAD != requested $EXPECT - refusing to build a source generation that was not requested"

# --- every active repo must be clean ---------------------------------------
# .mcp.json is excluded: in some sandboxes it is a bind-mounted device node,
# not a file any commit added.
DIRTY=0
for r in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-kernel NebulaOS-guppyscreen NebulaOS-klipper-mcu; do
  [ -d "$ROOT/$r/.git" ] || continue
  n=$(git -C "$ROOT/$r" status --porcelain 2>/dev/null | grep -vc '^?? \.mcp\.json$' || true)
  [ "$n" -eq 0 ] || { printf 'REASON: %s has %s uncommitted change(s)\n' "$r" "$n" >&2; DIRTY=1; }
done
[ "$DIRTY" -eq 0 ] || die "refusing to build from a dirty workspace - a qualification build must come from committed source"

# --- identity gate (also the archive/topology refusal, see header) ----------
"$ROOT/tools/verify-workspace-identity.sh" --hook >/dev/null 2>&1 \
  || die "workspace identity gate failed - run tools/verify-workspace-identity.sh and resolve before building"

# --- record what is about to be built --------------------------------------
printf 'RUN_NEBULAOS_BUILD=STARTING\nBUILD_SOURCE_HEAD=%s\nWORKSPACE_ROOT=%s\nENTRYPOINT=%s/build.sh\nSTARTED_AT=%s\n' \
  "$HEAD" "$ROOT" "$FW" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- delegate to the official pipeline -------------------------------------
# No stage is reimplemented here. build.sh owns the container, the digest pin
# and every stage; this launcher only decides whether it may run at all.
( cd "$FW" && ./build.sh )
RC=$?

printf 'RUN_NEBULAOS_BUILD=FINISHED\nBUILD_SOURCE_HEAD=%s\nBUILD_EXIT_CODE=%s\nFINISHED_AT=%s\n' \
  "$HEAD" "$RC" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit "$RC"
