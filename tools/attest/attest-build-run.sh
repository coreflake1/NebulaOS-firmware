#!/usr/bin/env bash
#
# Produce a v2 authenticated attestation for a completed build workspace.
#
# WHY THIS IS A SEPARATE SCRIPT
#
# The v1 attestation (.nebulaos-build-verified) is written by
# tools/run-nebulaos-build.sh, which is a CONTROL-LAYER file: the workspace
# identity gate compares the installed copy against the canonical one, and any
# drift blocks every build and every hardware operation until a human runs
# tools/sync-workspace-control.sh. Folding the v2 signer into that launcher
# therefore makes attestation and the build system land together, and makes an
# ordinary attestation change require a privileged re-sync.
#
# So the SIGNER lives here, outside the control layer, and can be run against
# any completed build workspace. The launcher calling it automatically is a
# separate, deliberate control-layer change.
#
# WHAT IT ADDS OVER v1
#
# v1 is a plain text file in a world-writable /var/tmp tree: anything that can
# write the path can claim any build passed. That was fine while a human was the
# only reader and is not fine now that a Hardware Agent decides whether to flash
# a printer on the strength of it.
#
# v2 is the same facts plus a HMAC-SHA256 over a domain-separated canonical
# serialisation, so a reader can tell whether the fields were produced by a
# holder of the attestation key. It also records what v1 never did: which
# repository and published tip the source came from, the build launcher's own
# blob hash, the build profile, whether ccache was on, and digests of the build
# log and the build manifest.
#
# THE KEY IS NOT OURS TO CREATE
#
# ~/.config/nebulaos-attest/attest.key is created by a human, out of band, and
# is denied to agents. If it is absent this script says so and exits non-zero
# WITHOUT writing anything - a build with no attestation is a build a Hardware
# Agent will refuse to install, which is the correct outcome. It never invents a
# key and never downgrades to an unauthenticated record.
set -uo pipefail
export LC_ALL=C

die(){ printf 'ATTEST_BUILD_RUN=FAILED\nREASON: %s\n' "$1" >&2; exit 2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FW=$(cd "$SCRIPT_DIR/../.." && pwd)
ATTEST="$SCRIPT_DIR/nebulaos-attest.py"
[ -f "$ATTEST" ] || die "the attestation tool is missing: $ATTEST"

BUILD_RUN=""; BUILD_LOG=""; PROFILE="release"; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-run)  BUILD_RUN=${2:-}; shift 2 ;;
    --build-log)  BUILD_LOG=${2:-}; shift 2 ;;
    --profile)    PROFILE=${2:-}; shift 2 ;;
    --out)        OUT=${2:-}; shift 2 ;;
    *) die "unknown option '$1'. Usage: attest-build-run.sh --build-run <dir> [--build-log <file>] [--profile release] [--out <file>]" ;;
  esac
done
[ -n "$BUILD_RUN" ] || die "--build-run is required"
[ -d "$BUILD_RUN" ] || die "no such build workspace: $BUILD_RUN"

ART="$BUILD_RUN/artifacts/buildroot-halley5-v30-image"
XIMAGE="$ART/xImage"; ROOTFS="$ART/rootfs.squashfs"; MANIFEST="$ART/build-manifest.txt"
for f in "$XIMAGE" "$ROOTFS" "$MANIFEST"; do
  [ -f "$f" ] || die "the build workspace is incomplete: $f is missing"
done

# --- the v1 record, which is the build launcher's own statement of success ---
# Read, not trusted blindly: every fact below is recomputed from the bytes. The
# v1 file supplies the things only the launcher knows (mode, builder digest,
# epoch) and its BUILD_VERIFIED flag, which is its assertion that build.sh
# exited zero AND the canonical workspace stayed clean.
V1="$BUILD_RUN/.nebulaos-build-verified"
[ -f "$V1" ] || die "no build record at $V1 - refusing to attest a build that never reported success"
v1(){ grep -m1 "^$1=" "$V1" 2>/dev/null | cut -d= -f2-; }
[ "$(v1 BUILD_VERIFIED)" = YES ] || die "the build record does not say BUILD_VERIFIED=YES"

SOURCE_HEAD=$(v1 SOURCE_HEAD)
BUILD_MODE=$(v1 BUILD_MODE)
BUILDER_DIGEST=$(v1 BUILDER_DIGEST)
SOURCE_DATE_EPOCH=$(v1 SOURCE_DATE_EPOCH)
[ -n "$SOURCE_HEAD" ] && [ -n "$SOURCE_DATE_EPOCH" ] || die "the build record is missing SOURCE_HEAD or SOURCE_DATE_EPOCH"

# --- recompute every artifact fact from the bytes ---------------------------
X_SHA=$(sha256sum "$XIMAGE" | cut -d' ' -f1)
R_SHA=$(sha256sum "$ROOTFS"  | cut -d' ' -f1)
M_SHA=$(sha256sum "$MANIFEST" | cut -d' ' -f1)
[ "$(v1 XIMAGE_SHA256)" = "$X_SHA" ] || die "xImage on disk does not match the build record"
[ "$(v1 ROOTFS_SQUASHFS_SHA256)" = "$R_SHA" ] || die "rootfs.squashfs on disk does not match the build record"

# --- provenance the v1 record never carried ---------------------------------
ORIGIN=$(git -C "$FW" remote get-url origin 2>/dev/null) || die "cannot read the canonical remote"
# The PUBLISHED tip, from the remote itself. A build of a commit that is not on
# a published branch is not a release build, and this records which tip it was
# reachable from at attestation time.
PUBLISHED_TIP=$(git -C "$FW" ls-remote "$ORIGIN" refs/heads/main 2>/dev/null | awk '{print $1}')
[ -n "$PUBLISHED_TIP" ] || die "cannot resolve the published tip of $ORIGIN (network required)"

# The build launcher's own bytes, so an attestation names the machinery that
# produced it and a swapped launcher is visible after the fact.
LAUNCHER="$FW/tools/workspace-control/scripts/run-nebulaos-build.sh"
[ -f "$LAUNCHER" ] || die "cannot find the canonical build launcher at $LAUNCHER"
LAUNCHER_BLOB=$(sha256sum "$LAUNCHER" | cut -d' ' -f1)

if [ -n "$BUILD_LOG" ] && [ -f "$BUILD_LOG" ]; then
  LOG_SHA=$(sha256sum "$BUILD_LOG" | cut -d' ' -f1)
else
  # No log supplied. Record the digest of the empty string rather than a blank:
  # a field that is present but hollow reads as evidence. This value is
  # recognisably "nothing was supplied" to anyone who checks.
  LOG_SHA=$(printf '' | sha256sum | cut -d' ' -f1)
fi

# ccache is OFF for release and candidate builds by construction - build.sh
# refuses to enable it outside dev mode - so this records the fact rather than
# asking. A release attestation with ccache enabled is refused by the signer.
case "$BUILD_MODE" in
  candidate|qualified) CCACHE=disabled ;;
  *)                   CCACHE=unknown ;;
esac

OUT=${OUT:-$BUILD_RUN/.nebulaos-build-attestation-v2}

# The evidence store is overridable so a test run cannot deposit an attestation
# signed with a throwaway key into the real one. That happened once during
# development and is worth preventing structurally: a fake attestation sitting
# in the evidence store is indistinguishable from a real one at a glance, which
# is the whole problem attestations exist to solve.
STORE="${NEBULAOS_ATTEST_STORE:-${XDG_STATE_HOME:-$HOME/.local/state}/nebulaos-evidence/attestations}"

printf 'ATTEST_BUILD_RUN=STARTING\nSOURCE_HEAD=%s\nBUILD_RUN=%s\nPROFILE=%s\n\n' \
  "$SOURCE_HEAD" "$BUILD_RUN" "$PROFILE"

FIELDS=$(cat <<EOF
ATTESTATION_VERSION=2
SOURCE_HEAD=$SOURCE_HEAD
SOURCE_REPO=$ORIGIN
SOURCE_PUBLISHED_TIP=$PUBLISHED_TIP
BUILD_LAUNCHER_BLOB=$LAUNCHER_BLOB
BUILD_MODE=$BUILD_MODE
BUILD_PROFILE=$PROFILE
CCACHE=$CCACHE
BUILD_LOG_SHA256=$LOG_SHA
XIMAGE_SHA256=$X_SHA
XIMAGE_SIZE=$(stat -c %s "$XIMAGE")
ROOTFS_SQUASHFS_SHA256=$R_SHA
ROOTFS_SQUASHFS_SIZE=$(stat -c %s "$ROOTFS")
MANIFEST_SHA256=$M_SHA
BUILDER_DIGEST=$BUILDER_DIGEST
SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
BUILD_RUN=$BUILD_RUN
ATTESTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
)

# The signer's stderr goes to a temp file, not next to the output: a build
# workspace can be on read-only storage, and failing to report WHY an
# attestation was withheld because the error file could not be created is a
# uniquely unhelpful failure.
ERRFILE=$(mktemp "${TMPDIR:-/tmp}/nebulaos-attest.XXXXXX") || die "cannot create a temp file"
if ! printf '%s\n' "$FIELDS" | python3 "$ATTEST" sign --out "$OUT" 2>"$ERRFILE"; then
  REASON=$(cat "$ERRFILE" 2>/dev/null); rm -f "$ERRFILE"
  printf 'ATTESTATION_V2=WITHHELD\n' >&2
  printf '%s\n' "$REASON" >&2
  printf '\nNo attestation was written. A build with no v2 attestation is one the Hardware\nAgent refuses to install, which is the correct outcome - not something to work\naround. The key is created by a human, never by an agent.\n' >&2
  exit 3
fi
rm -f "$ERRFILE"

mkdir -p -m 0700 "$STORE" 2>/dev/null || true
cp -f "$OUT" "$STORE/$SOURCE_HEAD.att" 2>/dev/null && chmod 0600 "$STORE/$SOURCE_HEAD.att" 2>/dev/null

printf 'ATTESTATION_V2=WRITTEN\nATTESTATION_PATH=%s\nATTESTATION_STORE=%s\n' \
  "$OUT" "$STORE/$SOURCE_HEAD.att"
python3 "$ATTEST" verify --in "$OUT" --require BUILD_PROFILE="$PROFILE"
