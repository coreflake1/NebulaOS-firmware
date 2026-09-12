#!/usr/bin/env bash
#
# PreToolUse hook - fast local identity gate before any source-changing tool.
#
# FAILS CLOSED. If this script cannot prove the workspace is sound, it denies.
# Every early exit path below emits a deny, including "the gate script is
# missing" and "jq is unavailable" - a guardrail that silently degrades into
# allow-everything is not a guardrail.
#
# It deliberately does NOT do network I/O and does NOT require clean working
# trees, so ordinary editing stays fast and possible. Source-generation truth
# is enforced at session start (full check) and by the audit gate.
#
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0

deny(){ printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
        "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"NebulaOS guardrail: blocked."')"; exit 0; }
allow(){ exit 0; }   # silence = proceed to normal permission handling

INPUT=$(cat 2>/dev/null || true)

ROOT=${CLAUDE_PROJECT_DIR:-}
if [ -z "$ROOT" ]; then
  ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P) || \
    deny "NebulaOS guardrail: cannot resolve workspace root. Start Claude from /home/tim/Documents/workspace/NebulaOS."
fi

# --- launch location -------------------------------------------------------
# .claude/settings.json (hooks, permissions, subagents) loads from the PRIMARY
# project directory. If that is one of the five repos rather than the workspace
# root, the root guardrails are not in force.
EXPECTED_ROOT=/home/tim/Documents/workspace/NebulaOS
RROOT=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")
if [ "$RROOT" != "$EXPECTED_ROOT" ]; then
  deny "NEBULAOS_WORKSPACE_ROOT_VALID=NO

Claude's primary project directory is:
  $RROOT

Source modification is blocked because the NebulaOS root guardrails
(identity gate, archive isolation, architecture invariants, reviewers)
load only from the workspace root.

Restart Claude from:
  $EXPECTED_ROOT

Reading for diagnosis is still permitted."
fi

# --- archive isolation (Bash route) ----------------------------------------
# The permission deny rules and the sandbox both cover this; this is the third
# layer, and the one that produces an explanatory message.
case "$INPUT" in
  *NebulaOS-archive*)
    deny "NebulaOS guardrail: the archived workspace is out of bounds.

/home/tim/Documents/workspace/NebulaOS-archive-* is preserved evidence, not
authority, and normal sessions must not read it. Historical investigation is a
separate, explicitly user-requested session - see
NebulaOS-firmware/tools/workspace-control/historian/README.md."
    ;;
esac

# --- read-only reviewers ---------------------------------------------------
# nebula-architect and nebula-verifier have no Edit/Write/NotebookEdit tool,
# but they DO have Bash - and this build's sandbox permits writes inside the
# working directory, which is the workspace. Scoped Bash grants in agent
# frontmatter were tested against this build and are NOT enforced (a command
# outside the granted scope ran normally), so the tool list cannot carry this
# property on its own.
#
# The PreToolUse payload carries agent_type for subagent calls and omits it for
# the main agent, so enforcement happens here. Classification is done in Python:
# shell glob matching got this wrong (it missed `git -C <path> commit`, because
# the -C option breaks token adjacency), and a guard that looks right while
# missing the obvious case is worse than none.
#
# This is a command-pattern guard, deliberately the third layer - behind the
# absent edit tools and the agents' own instructions - not a kernel boundary.
REVIEW_VERDICT=$(printf '%s' "$INPUT" | python3 -c '
import json,shlex,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
if d.get("agent_type") not in ("nebula-architect","nebula-verifier"): sys.exit(0)
cmd=(d.get("tool_input") or {}).get("command","") or ""

# ignore redirections that discard output
scan=re.sub(r"[12]?>>?\s*/dev/null","",cmd) if (re:=__import__("re")) else cmd
scan=re.sub(r"[12]?>&[12]","",scan)

def hit(reason): print(reason); sys.exit(0)

if re.search(r"(?<![0-9])>>?", scan): hit("output redirection")
if re.search(r"\btee\b", scan):      hit("tee")
if re.search(r"\bsed\b[^|;&]*\s-(-in-place|i\b)", scan): hit("in-place sed")
if re.search(r"\bperl\b[^|;&]*\s-[a-zA-Z]*i", scan):      hit("in-place perl")

MUT_CMDS={"rm","mv","cp","touch","mkdir","rmdir","truncate","dd","install",
          "chmod","chown","ln","patch","tar","unzip","make","cmake","pip",
          "pip3","npm","yarn"}
GIT_MUT={"commit","push","add","checkout","switch","reset","clean","stash",
         "merge","rebase","tag","worktree","fetch","pull","rm","mv","apply",
         "cherry-pick","revert","update-ref","branch","gc","prune","filter-branch",
         "am","restore","submodule","remote","config","init","clone"}
GIT_SAFE_REMOTE={"ls-remote"}

try: toks=shlex.split(cmd)
except Exception: toks=cmd.split()

# walk tokens, resetting at shell separators so `a && rm b` is still caught
i=0; fresh=True
while i < len(toks):
    t=toks[i]
    if t in (";","&&","||","|","&"): fresh=True; i+=1; continue
    if fresh:
        base=t.split("/")[-1]
        if base in MUT_CMDS: hit(base)
        if base=="git":
            j=i+1
            while j < len(toks):
                g=toks[j]
                if g in ("-C","-c","--git-dir","--work-tree"): j+=2; continue
                if g.startswith("-"): j+=1; continue
                break
            if j < len(toks):
                sub=toks[j]
                if sub in GIT_SAFE_REMOTE: pass
                elif sub in GIT_MUT: hit("git "+sub)
        if base in ("sync-workspace-control.sh",) or "sync-workspace-control.sh" in t:
            hit("workspace-control sync")
        fresh=False
    i+=1
' 2>/dev/null || echo "")

if [ -n "$REVIEW_VERDICT" ]; then
  AT=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("agent_type",""))
except Exception: print("reviewer")' 2>/dev/null || echo reviewer)
  deny "$AT is READ-ONLY with respect to source; blocked: $REVIEW_VERDICT

This reviewer reports findings, it does not apply them. Return your verdict to
the main agent and let it make the change. If you need to record something, put
it in your reply, not on disk."
fi

# --- fast local identity gate ----------------------------------------------
GATE=$ROOT/tools/verify-workspace-identity.sh
[ -x "$GATE" ] || deny "NebulaOS guardrail: identity gate missing or not executable at $GATE. Failing closed. Run tools/sync-workspace-control.sh --apply."

OUT=$("$GATE" --hook 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then
  REASONS=$(printf '%s\n' "$OUT" | grep -E '^\s+FAIL:' | head -12)
  deny "WORKSPACE_IDENTITY_VALID=NO - source modification blocked.

$REASONS

Do not work around this and do not switch to another checkout. Resolve identity
first. If root authority files drifted from their tracked canonical source:
  tools/sync-workspace-control.sh            (show the difference)
  tools/sync-workspace-control.sh --apply    (install canonical)"
fi

allow
