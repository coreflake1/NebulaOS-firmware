#!/usr/bin/env bash
#
# apply-workspace-control.sh - the ONE human command that installs the
# workspace-control layer and proves it took effect.
#
# Installing .claude/ (hooks, settings, agents) is deliberately a human action:
# the sandbox keeps it read-only to agents, so an agent cannot install its own
# authority layer. This wrapper does every human-owned step in one go:
#
#   1. refuses if the canonical control source has uncommitted changes - the
#      hook binds the privileged launchers to their COMMITTED bytes, so
#      installing uncommitted ones would only produce refusals later
#   2. installs canonical -> workspace root (sync --apply)
#   3. verifies: no drift, DEV identity valid
#   4. runs the fast control-layer test suites against the installed copies
#
# Idempotent (re-running changes nothing once applied), fails closed, prints
# what it changes, and exits non-zero on any partial failure.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

SELF=$(readlink -f "${BASH_SOURCE[0]}")
if [ -f "$(dirname "$SELF")/../MANIFEST" ]; then
  CANON=$(cd "$(dirname "$SELF")/.." && pwd -P)
  ROOT=$(cd "$CANON/../../.." && pwd -P)
else
  ROOT=$(cd "$(dirname "$SELF")/.." && pwd -P)
  CANON=$ROOT/NebulaOS-firmware/tools/workspace-control
fi
FW=$ROOT/NebulaOS-firmware

fail(){ printf '\nAPPLY_RESULT=FAIL\nREASON: %s\n' "$1"; exit 1; }

echo "WORKSPACE_ROOT=$ROOT"
[ -f "$CANON/MANIFEST" ] || fail "canonical MANIFEST not found under $CANON"

echo; echo "== 1. canonical control source is committed"
DIRTY=$(git -C "$FW" status --porcelain -- tools/workspace-control tools/hardware 2>/dev/null)
[ -z "$DIRTY" ] || fail "uncommitted control-layer changes (commit them, then re-run):
$DIRTY"
echo "OK   firmware $(git -C "$FW" rev-parse --short HEAD) on $(git -C "$FW" rev-parse --abbrev-ref HEAD)"

echo; echo "== 2. install canonical -> workspace root"
SYNC_OUT=$("$CANON/scripts/sync-workspace-control.sh" --apply 2>&1); echo "$SYNC_OUT"
printf '%s\n' "$SYNC_OUT" | grep -qx 'INSTALL_FAILURES=0' || fail "sync reported install failures"

echo; echo "== 3. verify"
GATE_OUT=$("$ROOT/tools/verify-workspace-identity.sh" --dev 2>&1) || { echo "$GATE_OUT" | tail -15; fail "DEV identity gate failed"; }
printf '%s\n' "$GATE_OUT" | grep -qx 'WORKSPACE_CONTROL_VALID=YES' || { echo "$GATE_OUT" | grep -E 'CONTROL|WARN'; fail "control layer still drifted after install"; }
echo "OK   DEV_IDENTITY_VALID=YES, WORKSPACE_CONTROL_VALID=YES"

echo; echo "== 4. fast control-layer tests"
RC=0
for t in workspace-dev-mode-tests.sh workspace-control-privilege-guard-tests.sh hardware-launcher-grammar-tests.sh; do
  if out=$(bash "$FW/tests/$t" 2>&1); then
    echo "PASS $t ($(printf '%s\n' "$out" | grep -cE '^\s*PASS'))"
  else
    echo "FAIL $t"; printf '%s\n' "$out" | grep -E 'FAIL|FATAL' | head -20; RC=1
  fi
done
[ "$RC" -eq 0 ] || fail "control-layer tests failed"

echo
echo "APPLY_RESULT=PASS"
echo "WORKSPACE_MODE=DEV (default). Restart Claude, or run /clear, so it loads the new hooks and settings."
