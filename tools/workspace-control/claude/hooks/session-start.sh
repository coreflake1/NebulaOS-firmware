#!/usr/bin/env bash
#
# SessionStart hook - inject a SMALL, current identity summary.
#
# Purpose: architectural identity must be present in context from the first
# token, and must survive compaction. This deliberately injects facts only -
# no project history, no narrative. Pages of history are what caused agents to
# reason from stale prose in the first place.
#
#   session-start.sh             startup | resume | clear  (full check)
#   session-start.sh --compact   after compaction          (fast re-inject)
#
# Never blocks a session: a hook that hard-fails on startup would make the
# workspace unusable offline. It reports status; PreToolUse is what fails closed.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

COMPACT=0; [ "${1:-}" = "--compact" ] && COMPACT=1
ROOT=${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P)}
cd "$ROOT" 2>/dev/null || exit 0

man(){ local v; v=$(grep -E "^$1=" "$ROOT/NebulaOS-firmware/manifests/dependencies.conf" 2>/dev/null | tail -1 | cut -d= -f2-); echo "${v:-UNRESOLVED}"; }
head_of(){ git -C "$ROOT/$1" rev-parse HEAD 2>/dev/null || echo UNRESOLVED; }
br_of(){ git -C "$ROOT/$1" rev-parse --abbrev-ref HEAD 2>/dev/null || echo UNRESOLVED; }

if [ "$COMPACT" = 1 ]; then
  GATE=$("$ROOT/tools/verify-workspace-identity.sh" --local 2>&1)
  MODE="post-compaction re-injection (local check)"
else
  GATE=$("$ROOT/tools/verify-workspace-identity.sh" 2>&1)
  MODE="session start (full check)"
fi
IDENT=$(printf '%s\n' "$GATE" | grep -E '^(WORKSPACE_IDENTITY_VALID|LOCAL_IDENTITY_VALID)=' | tail -1)
CTRL=$(printf '%s\n' "$GATE" | grep -E '^WORKSPACE_CONTROL_VALID=' | tail -1)
SENT=$(printf '%s\n' "$GATE" | grep -E '^LAUNCH_SENTINELS_OK=' | tail -1)

ARCH=$("$ROOT/tools/verify-architecture.sh" --quick 2>&1 | grep -E '^(ARCHITECTURE_INVARIANTS_VALID|INVARIANTS_(PASS|FAIL|DOCUMENTED_ONLY))=' | tr '\n' ' ')

CAND=$ROOT/NebulaOS-firmware/scripts/build/overlay/opt/nebulaos/mcu-candidates/candidate-001.bin
MCUPROV=UNRESOLVED
if [ -f "$CAND" ]; then
  w=$(grep -o '"packaged_bin_sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]*"' "${CAND%.bin}.provenance.json" 2>/dev/null | grep -o '[0-9a-f]\{64\}')
  g=$(sha256sum "$CAND" 2>/dev/null | awk '{print $1}')
  [ -n "$w" ] && [ "$w" = "$g" ] && MCUPROV="VENDORED_ARTIFACT_SHA_OK" || MCUPROV="SHA_MISMATCH"
fi

cat <<EOF
NEBULAOS WORKSPACE IDENTITY - $MODE

${IDENT:-WORKSPACE_IDENTITY_VALID=UNRESOLVED}
${CTRL:-WORKSPACE_CONTROL_VALID=UNRESOLVED}
${SENT:-LAUNCH_SENTINELS_OK=UNRESOLVED}
$ARCH

firmware        $(br_of NebulaOS-firmware) $(head_of NebulaOS-firmware)
extensions main $(head_of NebulaOS-klipper-extensions)
extensions ship branch=$(man KLIPPER_EXTENSIONS_BRANCH) pin=$(man KLIPPER_EXTENSIONS_PIN)
host klipper    $(man KLIPPER_REPO) pin=$(man KLIPPER_PIN)
kernel          HEAD=$(head_of NebulaOS-kernel) pin=$(man KERNEL_PIN)
guppyscreen     HEAD=$(head_of NebulaOS-guppyscreen) pin=$(man GUPPYSCREEN_PIN)
mcu             HEAD=$(head_of NebulaOS-klipper-mcu) provenance=$MCUPROV

CURRENT_HEAD_BUILD_VERIFIED=NO
HARDWARE_QUALIFIED=NO

Rules: architecture is not memory - derive it from the identity gate,
CURRENT_STATE.md, the firmware manifest/source, and tools/verify-architecture.sh.
REPOSITORY_HEAD != SHIPPING_PIN. Auto-memory is disabled. The archive is blocked.
If identity is not valid, STOP and report rather than proceeding.
EOF
exit 0
