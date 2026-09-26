#!/usr/bin/env bash
#
# NebulaOS build-cache garbage collection.
#
#   tools/maintenance/build-cache-gc.sh --dry-run    what WOULD be removed
#   tools/maintenance/build-cache-gc.sh              actually remove it
#
# WHY THIS EXISTS
#
# /var/tmp/nebulaos-build reached 275 GB. Each build run is a full clone plus a
# fetched vendor tree plus Buildroot output - 14-29 GB apiece - and the build
# launcher's own retention only prunes runs older than 14 days. Nothing else
# ever removed anything, so the floor rose with every qualification cycle.
#
# WHAT THIS IS NOT
#
# It is not `<engine> system prune -a`. That would delete images and cache
# belonging to every other workload on this machine, including the pinned
# builder image this project needs and anything unrelated the user has running.
# Unrestricted pruning is refused here by design, not by omission.
#
# THE RULE: NOTHING IS REMOVED THAT WAS NOT POSITIVELY IDENTIFIED
#
# Every candidate must match a known NebulaOS shape AND survive an explicit
# keep-list. Anything this script does not recognise is left alone and counted
# as SKIPPED, loudly. A garbage collector that guesses is a data-loss tool.
#
# NEVER removed, mechanically:
#   - the active build workspace (a live .nebulaos-build.lock, or in use)
#   - any run carrying a build attestation (.nebulaos-build-verified) - that is
#     a release candidate's evidence, not scratch space
#   - the newest run per source SHA, regardless of age
#   - the canonical source repositories (this script never touches $ROOT)
#   - the current builder image named by manifests/dependencies.conf
#   - evidence/, manifests/, and anything under the workspace root
#   - Buildroot source downloads (kept on purpose - see below)
#   - .img / .ingenic artifacts, should they ever appear
#   - anything unrecognised
#
# WHY DOWNLOADS ARE KEPT
#
# The shared download cache is the one thing here that is expensive to lose and
# cheap to keep: every archive in it is pin-resolved and hash-verified before
# use, so it is never stale in a way that matters, and discarding it just means
# re-downloading gigabytes on the next build. It is reported, never collected.
#
set -uo pipefail
export LC_ALL=C GIT_OPTIONAL_LOCKS=0

DRY=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  "")        DRY=0 ;;
  *) echo "usage: $(basename "$0") [--dry-run]" >&2; exit 2 ;;
esac

SELF=$(readlink -f "${BASH_SOURCE[0]}")
ROOT=$(cd "$(dirname "$SELF")/../../.." && pwd -P)
FW="$ROOT/NebulaOS-firmware"
[ -d "$FW/.git" ] || { echo "FATAL: not a NebulaOS workspace root: $ROOT" >&2; exit 2; }

BUILD_BASE=${NEBULAOS_BUILD_BASE:-/var/tmp/nebulaos-build}
DL_CACHE=${NEBULAOS_DL_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/nebulaos/buildroot-dl}
CCACHE_DIR_=${NEBULAOS_CCACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nebulaos/ccache}
CCACHE_MAX=${NEBULAOS_CCACHE_MAXSIZE:-8G}
KEEP_DAYS=${NEBULAOS_GC_KEEP_DAYS:-14}

# The build workspace base must be OUTSIDE the canonical workspace. If it ever
# resolves inside, something is badly wrong and this script must not run.
case "$BUILD_BASE" in
  "$ROOT"|"$ROOT"/*) echo "FATAL: build base $BUILD_BASE is inside the canonical workspace $ROOT - refusing" >&2; exit 2 ;;
  /|/var|/tmp|/var/tmp|/home|"$HOME") echo "FATAL: build base $BUILD_BASE is a system directory - refusing" >&2; exit 2 ;;
esac

RECLAIM_KB=0
REMOVED=0
KEPT=0
SKIPPED=0

hdr(){ printf '\n== %s ==\n' "$1"; }
kb_of(){ du -sk "$1" 2>/dev/null | cut -f1 || echo 0; }
hum(){ # KiB -> human
  awk -v k="$1" 'BEGIN{ s="KMGT"; i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f%s", k, substr(s,i,1) }'
}

echo "NEBULAOS BUILD CACHE GC"
echo "MODE=$([ "$DRY" = 1 ] && echo DRY_RUN || echo APPLY)"
echo "BUILD_BASE=$BUILD_BASE"
echo "KEEP_DAYS=$KEEP_DAYS"

# ---------------------------------------------------------------------------
# 1. disposable build run workspaces
# ---------------------------------------------------------------------------
# Layout is $BUILD_BASE/<40-hex sha>/run-<stamp>-<pid>. Both levels are matched
# explicitly: a directory that is not a 40-hex SHA, or a child that is not a
# run-*, is not something this tool created and is left alone.
hdr "build run workspaces"
if [ -d "$BUILD_BASE" ]; then
  for shadir in "$BUILD_BASE"/*; do
    [ -d "$shadir" ] || continue
    sha=$(basename "$shadir")
    case "$sha" in
      *[!0-9a-f]*|"") echo "  SKIP  $sha (not a source SHA - not ours)"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac
    [ "${#sha}" -eq 40 ] || { echo "  SKIP  $sha (not a 40-hex SHA)"; SKIPPED=$((SKIPPED+1)); continue; }

    # Newest run for this SHA is always kept, however old it is: it is the only
    # copy of that source generation's output and re-creating it costs hours.
    newest=$(find "$shadir" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | head -1 | cut -d' ' -f2-)

    for run in "$shadir"/run-*; do
      [ -d "$run" ] || continue
      base=$(basename "$run")
      sz=$(kb_of "$run")

      if [ -f "$run/.nebulaos-build-verified" ]; then
        echo "  KEEP  $sha/$base ($(hum "$sz")) - carries a build attestation"
        KEPT=$((KEPT+1)); continue
      fi
      if [ "$run" = "$newest" ]; then
        echo "  KEEP  $sha/$base ($(hum "$sz")) - newest run for this source"
        KEPT=$((KEPT+1)); continue
      fi
      if [ -f "$run/.nebulaos-build.lock" ] && fuser "$run/.nebulaos-build.lock" >/dev/null 2>&1; then
        echo "  KEEP  $sha/$base ($(hum "$sz")) - build lock is held, build is running"
        KEPT=$((KEPT+1)); continue
      fi
      # Release artifacts, present or future, are evidence and are never GC'd.
      if find "$run" -maxdepth 4 \( -name '*.img' -o -name '*.ingenic' \) -print -quit 2>/dev/null | grep -q .; then
        echo "  KEEP  $sha/$base ($(hum "$sz")) - contains .img/.ingenic release artifacts"
        KEPT=$((KEPT+1)); continue
      fi
      if [ -n "$(find "$run" -maxdepth 0 -mtime -"$KEEP_DAYS" 2>/dev/null)" ]; then
        echo "  KEEP  $sha/$base ($(hum "$sz")) - newer than $KEEP_DAYS days"
        KEPT=$((KEPT+1)); continue
      fi

      echo "  $([ "$DRY" = 1 ] && echo 'WOULD REMOVE' || echo 'REMOVE      ')  $sha/$base ($(hum "$sz"))"
      RECLAIM_KB=$((RECLAIM_KB + sz))
      REMOVED=$((REMOVED+1))
      if [ "$DRY" = 0 ]; then
        rm -rf -- "$run" || echo "    WARNING: could not remove $run" >&2
      fi
    done

    # An empty SHA directory left behind after its runs went is just noise.
    if [ "$DRY" = 0 ] && [ -d "$shadir" ] && [ -z "$(ls -A "$shadir" 2>/dev/null)" ]; then
      rmdir "$shadir" 2>/dev/null && echo "  RMDIR $sha (now empty)"
    fi
  done
else
  echo "  (no build base at $BUILD_BASE)"
fi

# ---------------------------------------------------------------------------
# 2. stale temporary build state
# ---------------------------------------------------------------------------
hdr "stale temporary build state"
STALE=0
for pat in "$BUILD_BASE"/.tmp-* "$BUILD_BASE"/*/.partial-*; do
  [ -e "$pat" ] || continue
  sz=$(kb_of "$pat")
  echo "  $([ "$DRY" = 1 ] && echo 'WOULD REMOVE' || echo 'REMOVE      ')  $(basename "$pat") ($(hum "$sz"))"
  RECLAIM_KB=$((RECLAIM_KB + sz)); STALE=$((STALE+1))
  [ "$DRY" = 0 ] && rm -rf -- "$pat"
done
[ "$STALE" -eq 0 ] && echo "  (none)"

# ---------------------------------------------------------------------------
# 3. ccache - bounded, never emptied
# ---------------------------------------------------------------------------
# Trimming to its configured ceiling is what ccache itself is for; this only
# asks it to enforce the bound. A dev cache that is merely large is working.
hdr "compiler ccache"
if [ -d "$CCACHE_DIR_" ]; then
  cur=$(kb_of "$CCACHE_DIR_")
  echo "  dir=$CCACHE_DIR_ size=$(hum "$cur") max=$CCACHE_MAX"
  if command -v ccache >/dev/null 2>&1; then
    if [ "$DRY" = 1 ]; then
      echo "  WOULD set max_size=$CCACHE_MAX and let ccache evict above it"
    else
      CCACHE_DIR="$CCACHE_DIR_" ccache --max-size="$CCACHE_MAX" >/dev/null 2>&1 \
        && echo "  max_size set to $CCACHE_MAX" || echo "  WARNING: could not set ccache max_size" >&2
      CCACHE_DIR="$CCACHE_DIR_" ccache --cleanup >/dev/null 2>&1 \
        && echo "  cleanup run" || true
    fi
  else
    echo "  (ccache not installed on this host - nothing to bound)"
  fi
else
  echo "  (no ccache dir at $CCACHE_DIR_)"
fi

# ---------------------------------------------------------------------------
# 4. Buildroot downloads - REPORTED, NEVER COLLECTED
# ---------------------------------------------------------------------------
hdr "buildroot download cache (kept by policy)"
if [ -d "$DL_CACHE" ]; then
  n=$(find "$DL_CACHE" -type f 2>/dev/null | wc -l)
  echo "  dir=$DL_CACHE files=$n size=$(hum "$(kb_of "$DL_CACHE")")"
  echo "  KEPT - every archive is pin-resolved and hash-verified before use;"
  echo "  discarding it only forces a re-download."
else
  echo "  (no download cache at $DL_CACHE)"
fi

# ---------------------------------------------------------------------------
# 5. builder images - only NebulaOS ones, never the current pin
# ---------------------------------------------------------------------------
hdr "builder images"
CUR_REPO=$(grep -E '^BUILD_IMAGE_REPO=' "$FW/manifests/dependencies.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')
CUR_DIGEST=$(grep -E '^BUILD_IMAGE_DIGEST=' "$FW/manifests/dependencies.conf" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"')
echo "  current pin: ${CUR_REPO:-unresolved}@${CUR_DIGEST:-unresolved}"
ENGINE=""
for e in docker podman; do command -v "$e" >/dev/null 2>&1 && { ENGINE=$e; break; }; done
if [ -z "$ENGINE" ]; then
  echo "  (no container engine on PATH - skipping)"
elif [ -z "$CUR_REPO" ]; then
  echo "  (cannot read the current pin - refusing to judge any image)"
else
  # Scoped to the pinned repository ONLY. Images from any other repository are
  # someone else's and are never listed as candidates, let alone removed.
  found=0
  while read -r id digest; do
    [ -n "$id" ] || continue
    found=1
    if [ "$digest" = "$CUR_DIGEST" ]; then
      echo "  KEEP  $CUR_REPO@${digest:0:19}... - current pin"
      KEPT=$((KEPT+1))
    else
      echo "  $([ "$DRY" = 1 ] && echo 'WOULD REMOVE' || echo 'REMOVE      ')  $CUR_REPO@${digest:0:19}... - superseded NebulaOS builder"
      REMOVED=$((REMOVED+1))
      [ "$DRY" = 0 ] && "$ENGINE" rmi "$id" >/dev/null 2>&1 || true
    fi
  done < <("$ENGINE" images --no-trunc --format '{{.ID}} {{.Digest}}' "$CUR_REPO" 2>/dev/null)
  [ "$found" -eq 0 ] && echo "  (no images for $CUR_REPO)"
fi

# ---------------------------------------------------------------------------
# 6. engine build cache - reclaimable only, never -a
# ---------------------------------------------------------------------------
hdr "engine build cache"
if [ -z "${ENGINE:-}" ]; then
  echo "  (no container engine on PATH - skipping)"
elif [ "$ENGINE" = docker ]; then
  if [ "$DRY" = 1 ]; then
    echo "  WOULD run: docker builder prune -f   (reclaimable layers only, never -a)"
    docker system df 2>/dev/null | sed 's/^/    /' || true
  else
    docker builder prune -f 2>/dev/null | sed 's/^/    /' || echo "  WARNING: builder prune failed" >&2
  fi
else
  echo "  (podman: no unscoped prune is performed here)"
fi

# ---------------------------------------------------------------------------
hdr "summary"
printf 'GC_MODE=%s\n' "$([ "$DRY" = 1 ] && echo DRY_RUN || echo APPLY)"
printf 'ITEMS_%s=%s\n' "$([ "$DRY" = 1 ] && echo WOULD_REMOVE || echo REMOVED)" "$REMOVED"
printf 'ITEMS_KEPT=%s\n' "$KEPT"
printf 'ITEMS_SKIPPED_UNRECOGNISED=%s\n' "$SKIPPED"
printf 'SPACE_%s=%s\n' "$([ "$DRY" = 1 ] && echo RECLAIMABLE || echo RECLAIMED)" "$(hum "$RECLAIM_KB")"
printf 'BUILD_BASE_SIZE_NOW=%s\n' "$(hum "$(kb_of "$BUILD_BASE")")"
printf 'DOWNLOAD_CACHE=PRESERVED\n'
printf 'UNRESTRICTED_PRUNE_USED=NO\n'
[ "$DRY" = 1 ] && echo && echo "Nothing was removed. Re-run without --dry-run to apply."
exit 0
