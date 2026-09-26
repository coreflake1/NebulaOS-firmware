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

# --- build / qualification status, DERIVED ---------------------------------
# These two lines used to be hard-coded NO. A constant is not a status: it kept
# reporting NO after a build had in fact been verified, and would have kept
# reporting NO forever, which trains a reader to ignore the line entirely.
#
# CURRENT_HEAD_BUILD_VERIFIED is now answered by the build launcher's own
# attestation (.nebulaos-build-verified, written only on a clean successful
# build) for the CURRENT firmware HEAD. A build of some earlier generation is
# deliberately not evidence about this one - the whole point of the field is to
# say whether THIS source has been built.
#
# Bounded on purpose: a plain glob over one directory, no find, no du, no
# network. This runs at session start and must stay cheap.
FW_HEAD=$(head_of NebulaOS-firmware)
BUILD_VERIFIED=NO
BUILD_VERIFIED_DETAIL=""
if [ "$FW_HEAD" != UNRESOLVED ]; then
  for att in /var/tmp/nebulaos-build/"$FW_HEAD"/*/.nebulaos-build-verified; do
    [ -f "$att" ] || continue
    v=$(grep -m1 '^BUILD_VERIFIED=' "$att" 2>/dev/null | cut -d= -f2-)
    h=$(grep -m1 '^SOURCE_HEAD='    "$att" 2>/dev/null | cut -d= -f2-)
    m=$(grep -m1 '^BUILD_MODE='     "$att" 2>/dev/null | cut -d= -f2-)
    if [ "$v" = YES ] && [ "$h" = "$FW_HEAD" ]; then
      BUILD_VERIFIED=YES
      BUILD_VERIFIED_DETAIL=" (mode=$m)"
      break
    fi
  done
fi

# HARDWARE_QUALIFIED is likewise derived, from a qualification record for this
# exact source generation. No record for THIS head means NO - never a remembered
# YES from an earlier one.
HW_QUALIFIED=NO
[ "$FW_HEAD" != UNRESOLVED ] \
  && [ -f "$ROOT/evidence/hardware-qualification/$FW_HEAD/QUALIFIED" ] \
  && HW_QUALIFIED=YES

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

CURRENT_HEAD_BUILD_VERIFIED=$BUILD_VERIFIED$BUILD_VERIFIED_DETAIL
HARDWARE_QUALIFIED=$HW_QUALIFIED

Rules: architecture is not memory - derive it from the identity gate,
CURRENT_STATE.md, the firmware manifest/source, and tools/verify-architecture.sh.
REPOSITORY_HEAD != SHIPPING_PIN. Auto-memory is disabled. The archive is blocked.
If identity is not valid, STOP and report rather than proceeding.
EOF
exit 0
