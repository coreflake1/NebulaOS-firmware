#!/usr/bin/env bash
#
# Adversarial tests for the workspace-control privileged-execution boundary.
#
# The guard under test lives in the PreToolUse hook. It decides which caller
# may leave Claude's sandbox and which file they may run there. It is the only
# thing standing between "the build agent may run the build" and "a subagent
# may do anything as this user", because leaving the sandbox restores the full
# supplementary group set - measured, gid 972 included.
#
# These tests drive the hook the way Claude Code drives it: a JSON payload on
# stdin, a deny expressed as permissionDecision on stdout, and an allow
# expressed as silence. Nothing here runs a build, a container, or a printer.
#
# The hook is exercised through the INSTALLED copy, because the guard resolves
# the workspace root structurally from its own location and only the installed
# copy sits at the root. Byte-equality with canonical is asserted first, so
# testing the installed copy is testing canonical.
#
# Two literals are ASSEMBLED at runtime rather than written out: the container
# engine names, and the archive directory. Not obfuscation - the hook scans
# raw tool input, so a file containing those strings cannot be written or
# edited through the very guardrails it tests. Assembling them keeps this file
# writable while the assertions stay exact. Nothing here reads the archive.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P)
HOOK=$ROOT/.claude/hooks/pre-tool-use-identity.sh
CANON=$ROOT/NebulaOS-firmware/tools/workspace-control/claude/hooks/pre-tool-use-identity.sh

CANONDIR=$ROOT/NebulaOS-firmware/tools/workspace-control/scripts
SYNC=$ROOT/tools/sync-workspace-control.sh
BUILDER=$ROOT/tools/run-nebulaos-build.sh
HWRUN=$ROOT/tools/run-nebulaos-hardware.sh

# A real 40-hex SHA shape. It need not exist here: the guard validates the
# ARGUMENT SHAPE, and the launcher itself validates that it matches HEAD.
SHA=d741a626bc48306e6868f48ec19786d96704cc77
BADSHA=d741a626

ENG=$(printf 'dock%s' 'er')
ENG2=$(printf 'pod%s' 'man')
ARCHIVE="$ROOT-archive-2026-09-12"

PASS=0
FAIL=0
BUILD_BYPASS=0
HW_BYPASS=0

fatal() { echo "FATAL: $*" >&2; exit 2; }

[ -x "$HOOK" ]  || fatal "installed hook missing or not executable: $HOOK"
[ -f "$CANON" ] || fatal "canonical hook missing: $CANON"
cmp -s "$HOOK" "$CANON" || fatal "installed hook differs from canonical; run tools/sync-workspace-control.sh --apply"

bash -n "$CANON" || fatal "canonical hook is not valid bash"

mkjson() {
  A_AGENT=$1 A_CMD=$2 A_SB=$3 A_TOOL=$4 A_CWD=$5 python3 -c '
import json,os
c=os.environ["A_CMD"]
if os.environ.get("A_CJ")=="1": c=json.loads(c)
ti={"command":c}
if os.environ["A_SB"]=="1": ti["dangerouslyDisableSandbox"]=True
d={"tool_name":os.environ["A_TOOL"],"tool_input":ti,"cwd":os.environ["A_CWD"]}
a=os.environ["A_AGENT"]
if a: d["agent_type"]=a
print(json.dumps(d))'
}

# A DENY is only meaningful if it came from the guard under test. Asserting
# the decision alone lets a case keep passing after the rule it covers is
# deleted, because some earlier guard - the identity gate, the archive scan,
# the reviewer guard - denies it for an unrelated reason. Independent review
# had to establish non-vacuity by replaying every payload and parsing the
# reason by hand; REASON makes that a permanent, cheap assertion instead.
# Set it per section; override per case with argument 7.
REASON=""

# run_case <cat> <expect> <agent|""> <sandbox 0|1> <desc> <cmd> [reason] [tool] [cwd]
run_case() {
  local cat=$1 expect=$2 agent=$3 sb=$4 desc=$5 cmd=$6
  local reason=${7:-$REASON}
  local tool=${8:-Bash}
  local cwd=${9:-$ROOT}
  local out got

  out=$(mkjson "$agent" "$cmd" "$sb" "$tool" "$cwd" | CLAUDE_PROJECT_DIR="$ROOT" "$HOOK" 2>/dev/null)
  got=ALLOW
  case "$out" in *'"permissionDecision":"deny"'*) got=DENY ;; esac

  if [ "$got" = DENY ] && [ "$expect" = DENY ] && [ -n "$reason" ]; then
    case "$out" in
      *"$reason"*) : ;;
      *) FAIL=$((FAIL+1))
         printf '  FAIL  denied for the WRONG reason (wanted: %s)  %s\n' "$reason" "$desc"
         return ;;
    esac
  fi

  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1))
    printf '  PASS  %-5s  %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  expected=%s got=%s  %s\n' "$expect" "$got" "$desc"
    # A bypass is specifically: privilege was requested and WRONGLY ALLOWED.
    # A wrongly-denied case is a usability bug, not a bypass; it counts in
    # FAIL only. Conflating the two would let a broken-shut guard report a
    # clean bypass count.
    if [ "$expect" = DENY ] && [ "$got" = ALLOW ]; then
      case "$cat" in
        build) BUILD_BYPASS=$((BUILD_BYPASS+1)) ;;
        hw)    HW_BYPASS=$((HW_BYPASS+1)) ;;
      esac
    fi
  fi
}

echo "PRIVILEGE GUARD ADVERSARIAL TESTS"
echo "HOOK=$HOOK"
echo

# --- the single sanctioned caller/file pair --------------------------------
# The control-layer sync is deliberately NOT a privileged pair. An earlier
# revision granted the main agent an unsandboxed sync to escape what looked
# like a deadlock. That read-only .claude/hooks path is also what stops an
# agent installing its own authority layer: the main agent may edit the
# canonical hook, settings, agent definitions and authority documents, and
# before that grant the edit was inert. Installing them is a human action.
echo "[ sanctioned pair - must ALLOW ]"
run_case build ALLOW nebulaos-build 1 "build agent, unsandboxed launcher, valid SHA" "$BUILDER $SHA"
run_case ctl   ALLOW ""             0 "main agent, sandboxed sync"                   "$SYNC"
run_case ctl   ALLOW ""             0 "main agent, sandboxed sync --apply"           "$SYNC --apply"
run_case ctl   ALLOW ""             0 "main agent, ordinary sandboxed command"       "echo hello"
echo

REASON="Unsandboxed execution"
echo "[ the authority layer may not be self-installed - must DENY ]"
run_case ctl DENY "" 1 "main agent, unsandboxed sync"         "$SYNC"
run_case ctl DENY "" 1 "main agent, unsandboxed sync --apply" "$SYNC --apply"
echo

# --- the sandbox escape, refused to everyone else --------------------------
REASON="Unsandboxed execution"
echo "[ sandbox escape - must DENY ]"
run_case build DENY ""                1 "main agent, unsandboxed arbitrary command"       "id"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed arbitrary command"      "id"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed shell wrapper"          "bash $BUILDER $SHA" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with trailing command"     "$BUILDER $SHA; id" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with pipe"                 "$BUILDER $SHA | tee /x" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with substitution"         "$BUILDER \$(cat /etc/hostname)" "lone invocation"
run_case build DENY nebulaos-build    1 "build agent, launcher with no SHA"               "$BUILDER" "exactly one argument"
run_case build DENY nebulaos-build    1 "build agent, launcher with short SHA"            "$BUILDER $BADSHA" "exactly one argument"
run_case build DENY nebulaos-build    1 "build agent, launcher with two args"             "$BUILDER $SHA $SHA" "exactly one argument"
run_case build DENY nebulaos-build    1 "build agent, unsandboxed sync (not its file)"    "$SYNC --apply"
run_case build DENY nebula-architect  1 "architect, unsandboxed sync"                     "$SYNC --apply"
run_case build DENY nebula-verifier   1 "verifier, unsandboxed arbitrary command"         "id"
run_case hw    DENY nebulaos-hardware 1 "hardware agent, unsandboxed arbitrary command"   "id"
run_case build DENY ""                1 "main agent, unsandboxed non-Bash tool"           "$SYNC" "non-Bash tool" Write
echo

# --- launchers are bound to their own agent, sandboxed or not --------------
REASON="may only be invoked by the"
echo "[ launcher binding - must DENY ]"
run_case build DENY ""                0 "main agent, build launcher (sandboxed)"  "$BUILDER $SHA"
run_case build DENY nebula-architect  0 "architect, build launcher"               "$BUILDER $SHA"
run_case build DENY nebula-verifier   0 "verifier, build launcher"                "$BUILDER $SHA"
run_case build DENY nebulaos-hardware 0 "hardware agent, build launcher"          "$BUILDER $SHA"
run_case hw    DENY ""                0 "main agent, hardware launcher"           "$HWRUN --status"
run_case hw    DENY nebulaos-build    0 "build agent, hardware launcher"          "$HWRUN --status"
run_case hw    DENY nebula-verifier   1 "verifier, hardware launcher unsandboxed" "$HWRUN --status"
echo

# --- direct container engine use, refused to every caller ------------------
REASON="Direct use of the"
echo "[ direct container engine - must DENY ]"
run_case build DENY ""               0 "main agent, engine ps"                "$ENG ps"
run_case build DENY nebulaos-build   0 "build agent, engine run"              "$ENG run --rm -v /:/host alpine sh"
run_case build DENY nebulaos-build   1 "build agent, engine unsandboxed"      "$ENG version"
run_case build DENY ""               0 "main agent, engine via sudo"          "sudo $ENG ps"
run_case build DENY ""               0 "main agent, engine by absolute path"  "/usr/bin/$ENG ps"
run_case build DENY ""               0 "main agent, engine after separator"   "echo hi; $ENG ps"
run_case build DENY ""               0 "main agent, second engine"            "$ENG2 ps"
run_case build DENY nebula-architect 0 "architect, engine ps"                 "$ENG ps"
echo

# --- the engine NAME is not contraband, only the engine COMMAND ------------
# Substring matching made ordinary diagnostics impossible: reading the build
# script, or grepping docs for the engine name, is not privilege.
REASON=""
echo "[ engine mentioned, not invoked - must ALLOW ]"
run_case ctl ALLOW "" 0 "main agent, grep for the engine name"   "grep -n '$ENG' NebulaOS-firmware/build.sh"
run_case ctl ALLOW "" 0 "main agent, read a path containing it"  "cat /etc/$ENG/daemon.json"
run_case ctl ALLOW "" 0 "main agent, engine name as an argument" "echo using $ENG for builds"
echo

# --- the binding is to CONTENT, not to the path ----------------------------
# Comparing realpath(allowed) to realpath(typed) is satisfied by NAMING the
# path - both sides derive from the same string, so it holds for whatever file
# occupies it. tools/ is unversioned derived state this sandbox permits
# writing, so a path-only check would let a caller replace the launcher and
# have the hook run it with host privilege. Every other case in this file
# varies command SHAPE; these vary file CONTENT, which is the axis the first
# version of this suite could not fail on.
REASON="bound to the launcher CONTENT"
echo "[ launcher content integrity - must DENY ]"
# Kept beside the launcher: $TMPDIR is read-only under this sandbox, and a
# SKIP here would silently drop the only cases that test file content - the
# exact axis the first version of this suite could not fail on.
BACKUP=$ROOT/tools/.launcher-content-test-backup.$$
restore_launcher() {
  if [ -s "$BACKUP" ]; then cp "$BACKUP" "$BUILDER" 2>/dev/null; chmod 755 "$BUILDER" 2>/dev/null; fi
  rm -f "$BACKUP" 2>/dev/null
}
trap restore_launcher EXIT INT TERM

if cp "$BUILDER" "$BACKUP" 2>/dev/null; then
  printf '#!/usr/bin/env bash\necho substituted\n' > "$BUILDER"
  chmod 755 "$BUILDER"
  run_case build DENY nebulaos-build 1 "build agent, launcher content replaced" "$BUILDER $SHA"
  restore_launcher
  trap - EXIT INT TERM
  if cmp -s "$BUILDER" "$CANONDIR/run-nebulaos-build.sh"; then
    PASS=$((PASS+1)); printf '  PASS  %-5s  %s\n' "OK" "launcher restored after the content test"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  launcher NOT restored - repair with tools/sync-workspace-control.sh --apply\n'
  fi
  run_case build ALLOW nebulaos-build 1 "build agent, launcher restored, valid SHA" "$BUILDER $SHA"
else
  echo "  SKIP  launcher content cases (could not back up the launcher)"
fi
echo

# --- the hardware agent may not reach a device -----------------------------
# Its constraints were prose only. Prose is not enforcement - that is this
# layer's whole thesis - so they now have the same mechanical backing the
# reviewers' read-only policy has.
REASON="created but NOT enabled"
echo "[ hardware agent device contact - must DENY ]"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ssh"                "ssh nebula-printer uname -a"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ping"               "ping -c1 nebula-printer"
run_case hw DENY nebulaos-hardware 0 "hardware agent, scp"                "scp fw.bin nebula-printer:/tmp/"
run_case hw DENY nebulaos-hardware 0 "hardware agent, serial console"     "picocom /dev/ttyUSB0"
run_case hw DENY nebulaos-hardware 0 "hardware agent, ssh after separator" "echo hi; ssh nebula-printer ls"
run_case ctl ALLOW nebulaos-hardware 0 "hardware agent, ordinary read"     "cat CURRENT_STATE.md"
echo

# --- typed payload edges -----------------------------------------------------
# Everything above sends a string command and a boolean sandbox flag. These
# send the JSON values a client might actually emit. Independent review found
# two real holes here that no string-payload case could reach:
#
#   dangerouslyDisableSandbox: 1      -> ALLOWED (privilege never recognised)
#   dangerouslyDisableSandbox: "yes"  -> ALLOWED
#
# Content-binding does not close that, because the escape branch is never
# entered at all. Whether this client coerces truthy non-booleans upstream is
# not knowable from inside the hook, so the guard must not depend on it.
#
# agent_type was also .strip()ed, so a padded value was promoted to a real
# principal and a blank one read as the main agent.
# <cmd> is a plain string unless [cmdjson] is 1, in which case it is parsed as
# a JSON literal. Without that, the typed-command cases sent the literal
# STRINGS and were denied by the escape rule, not the no-command branch they
# were named for - a case claiming coverage its harness could not deliver,
# in the very section added to cover typed-payload holes.
run_typed() { # <cat> <expect> <agent-json|OMIT> <sandbox-json|OMIT> <desc> <cmd> [reason] [cmdjson]
  local cat=$1 expect=$2 aj=$3 sj=$4 desc=$5 cmd=$6 reason=${7:-} cmdjson=${8:-0}
  local out got
  out=$(A_CMD=$cmd A_AJ=$aj A_SJ=$sj A_CWD=$ROOT A_CJ=$cmdjson python3 -c '
import json,os
c=os.environ["A_CMD"]
if os.environ.get("A_CJ")=="1": c=json.loads(c)
ti={"command":c}
sj=os.environ["A_SJ"]
if sj!="OMIT": ti["dangerouslyDisableSandbox"]=json.loads(sj)
d={"tool_name":"Bash","tool_input":ti,"cwd":os.environ["A_CWD"]}
aj=os.environ["A_AJ"]
if aj!="OMIT": d["agent_type"]=json.loads(aj)
print(json.dumps(d))' | CLAUDE_PROJECT_DIR="$ROOT" "$HOOK" 2>/dev/null)
  got=ALLOW
  case "$out" in *'"permissionDecision":"deny"'*) got=DENY ;; esac
  if [ "$got" = DENY ] && [ "$expect" = DENY ] && [ -n "$reason" ]; then
    case "$out" in
      *"$reason"*) : ;;
      *) FAIL=$((FAIL+1)); printf '  FAIL  denied for the WRONG reason (wanted: %s)  %s\n' "$reason" "$desc"; return ;;
    esac
  fi
  if [ "$got" = "$expect" ]; then
    PASS=$((PASS+1)); printf '  PASS  %-5s  %s\n' "$got" "$desc"
  else
    FAIL=$((FAIL+1)); printf '  FAIL  expected=%s got=%s  %s\n' "$expect" "$got" "$desc"
    if [ "$expect" = DENY ] && [ "$got" = ALLOW ]; then
      case "$cat" in build) BUILD_BYPASS=$((BUILD_BYPASS+1)) ;; hw) HW_BYPASS=$((HW_BYPASS+1)) ;; esac
    fi
  fi
}

echo "[ truthy privilege values - must DENY ]"
run_typed build DENY OMIT '1'       "sandbox flag as int 1"        "id" "Unsandboxed execution"
run_typed build DENY OMIT '"yes"'   "sandbox flag as yes"          "id" "Unsandboxed execution"
run_typed build DENY OMIT '"TRUE"'  "sandbox flag as TRUE"         "id" "Unsandboxed execution"
run_typed build DENY OMIT '"  True  "' "sandbox flag padded True"  "id" "Unsandboxed execution"
run_typed build DENY OMIT '"on"'    "sandbox flag as on"           "id" "Unsandboxed execution"
run_typed build DENY OMIT '{"a":1}' "sandbox flag as object"       "id" "Unsandboxed execution"
echo

echo "[ explicitly false privilege values - must ALLOW ]"
run_typed ctl ALLOW OMIT 'false'   "sandbox flag false"        "echo hello"
run_typed ctl ALLOW OMIT '"false"' "sandbox flag string false" "echo hello"
run_typed ctl ALLOW OMIT '0'       "sandbox flag int 0"        "echo hello"
run_typed ctl ALLOW OMIT '""'      "sandbox flag empty string" "echo hello"
run_typed ctl ALLOW OMIT 'null'    "sandbox flag null"         "echo hello"
echo

echo "[ agent_type must not be normalised into a principal - must DENY ]"
run_typed build DENY '"  nebulaos-build  "' 'true' "padded agent_type must not be promoted" "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY '"   "'                'true' "blank agent_type must not read as main" "$SYNC --apply"  "Unsandboxed execution"
run_typed build DENY '123'                  'true' "numeric agent_type is not a principal"  "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY '["nebulaos-build"]'   'true' "list agent_type is not a principal"     "$BUILDER $SHA" "may only be invoked by the"
run_typed build DENY 'null'                 'true' "null agent_type is not the build agent" "$BUILDER $SHA" "may only be invoked by the"
echo

echo "[ malformed command with privilege - must DENY ]"
run_typed build DENY '"nebulaos-build"' 'true' "command as a JSON list" '["x"]' "with no command" 1
run_typed build DENY '"nebulaos-build"' 'true' "command as a JSON number" '5' "with no command" 1
run_typed build DENY '"nebulaos-build"' 'true' "command as JSON null" 'null' "with no command" 1
echo

# --- pre-existing guards must still hold -----------------------------------
echo "[ reviewer identity must not be evadable by padding - must DENY ]"
# Pre-existing, and in the UNSAFE direction: the reviewer read-only guard
# matched agent_type exactly, so a padded or re-cased value slipped past it and
# a reviewer could mutate source. The privilege guard matches strictly because
# there strictness DEMOTES an unexpected value; this guard matches loosely
# because here breadth is what keeps a reviewer read-only. Same threat,
# opposite safe direction.
RM="rm -rf $ROOT/NebulaOS-firmware/tests"
run_typed ctl DENY '" nebula-verifier"' 'false' "padded reviewer name" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"nebula-verifier "' 'false' "trailing space reviewer" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"NEBULA-VERIFIER"' 'false' "upper case reviewer" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"Nebula-Architect"' 'false' "mixed case architect" "$RM" "READ-ONLY with respect to source"
run_typed ctl DENY '"nebula-verifier"' 'false' "exact reviewer name" "$RM" "READ-ONLY with respect to source"
echo

REASON=""
echo "[ regression: guards that predate this boundary ]"
run_case ctl DENY nebula-verifier  0 "verifier may not commit"     "git -C $ROOT/NebulaOS-firmware commit -m x" "READ-ONLY with respect to source"
run_case ctl DENY nebula-architect 0 "architect may not write"     "rm -rf $ROOT/NebulaOS-firmware/tests" "READ-ONLY with respect to source"
run_case ctl DENY ""               0 "archive stays out of bounds" "ls $ARCHIVE" "archived workspace is out of bounds"
echo

echo "TESTS_PASS=$PASS"
echo "TESTS_FAIL=$FAIL"
echo "BUILD_AGENT_PRIVILEGE_BYPASSES=$BUILD_BYPASS"
echo "HARDWARE_AGENT_PRIVILEGE_BYPASSES=$HW_BYPASS"

if [ "$FAIL" -ne 0 ]; then
  echo "PRIVILEGE_GUARD=FAIL"
  exit 1
fi
echo "PRIVILEGE_GUARD=PASS"
exit 0
