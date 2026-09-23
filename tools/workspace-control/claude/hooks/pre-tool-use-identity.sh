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
    deny "NebulaOS guardrail: cannot resolve workspace root. Start Claude from the NebulaOS workspace root."
fi

# --- launch location -------------------------------------------------------
# .claude/settings.json (hooks, permissions, subagents) loads from the PRIMARY
# project directory. If that is one of the five repos rather than the workspace
# root, the root guardrails are not in force.
#
# The root is identified STRUCTURALLY, never by a hard-coded absolute path: it
# is the directory holding both the installed identity gate and the tracked
# canonical control source that gate was installed from. A nested repo has
# neither, so the check below still catches the launch-location mistake it
# exists for. Pinning an absolute path here instead would mean that relocating
# the workspace denies every edit - including the edit that would fix the pin.
RROOT=$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")
SELF_ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd -P) || SELF_ROOT=$RROOT
if [ ! -x "$RROOT/tools/verify-workspace-identity.sh" ] \
|| [ ! -f "$RROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST" ] \
|| [ "$RROOT" != "$SELF_ROOT" ]; then
  deny "NEBULAOS_WORKSPACE_ROOT_VALID=NO

Claude's primary project directory is:
  $RROOT

Source modification is blocked because the NebulaOS root guardrails
(identity gate, archive isolation, architecture invariants, reviewers)
load only from the workspace root.

Restart Claude from:
  $SELF_ROOT

Reading for diagnosis is still permitted."
fi
ROOT=$RROOT

# --- archive isolation (Bash route) ----------------------------------------
# The permission deny rules and the sandbox both cover this; this is the third
# layer, and the one that produces an explanatory message.
case "$INPUT" in
  *NebulaOS-archive*)
    deny "NebulaOS guardrail: the archived workspace is out of bounds.

/home/tim/workspace/NebulaOS-archive-* is preserved evidence, not
authority, and normal sessions must not read it. Historical investigation is a
separate, explicitly user-requested session - see
NebulaOS-firmware/tools/workspace-control/historian/README.md."
    ;;
esac

# --- privileged execution boundary -----------------------------------------
# The ONLY way a command escapes Claude sandbox in this build is the Bash
# tool dangerouslyDisableSandbox parameter. Measured on this host: an
# unsandboxed shell regains the user full supplementary group set, gid 972
# included, which is the container group. So "may reach the container engine"
# and "may do anything as this user" are the same grant, and the escape has to
# be bound to exact files rather than to a command name or a prefix.
#
# Enforced here rather than in agent frontmatter because scoped Bash grants
# are not enforced in this build - see the note under read-only reviewers.
#
# TWO files may run unsandboxed, each by exactly one caller:
#   nebulaos-build   the build launcher
#   main agent       the control-layer sync
#
# The second is not a convenience. This build sandboxes .claude/hooks as a
# read-only path, so the sanctioned installer CANNOT install a hook change
# while sandboxed. Without this allowance the control layer becomes
# permanently un-maintainable - the same deadlock the drift-recovery
# exception below exists to prevent, one level up. Measured, not assumed:
# the sandboxed sync fails with "Read-only file system".
#
# Rules:
#   1. the container engine invoked directly in COMMAND POSITION is refused
#      for every caller including the main agent. Matching is by command
#      position, not by substring, so ordinary diagnostics that merely
#      mention the engine are unaffected. The build launcher reaches the
#      engine through NebulaOS-firmware/build.sh, a subprocess this hook
#      never sees - that is the containment, not an oversight.
#   2. dangerouslyDisableSandbox is refused unless the request is one of the
#      two caller/file pairs above: no chaining, no wrapper, no extra
#      arguments.
#   3. each launcher is refused to every caller but its own agent, sandboxed
#      or not.
#   4. the hardware launcher is not enabled yet; rule 3 covers it already, so
#      it cannot be reached before the hardware mission binds a target.
#
# Fail-closed SCOPE: if the interpreter cannot run, the request is refused
# only when it actually asked for privilege. A privilege guard that degrades
# to allow is not a guard; one that degrades to "deny everything" takes the
# repair path down with it.
PRIV_VERDICT=$(printf '%s' "$INPUT" | NEBULA_ROOT="$ROOT" python3 -c '
import json,os,re,shlex,sys

BUILD_AGENT="nebulaos-build"
HW_AGENT="nebulaos-hardware"

def out(msg): print("DENY:"+msg); sys.exit(0)

try: d=json.load(sys.stdin)
except Exception: sys.exit(0)

agent=(d.get("agent_type") or "").strip()
ti=d.get("tool_input") or {}
tool=(d.get("tool_name") or "")

raw=ti.get("dangerouslyDisableSandbox")
sandbox_off = raw is True or (isinstance(raw,str) and raw.strip().lower()=="true")

if tool!="Bash":
    if sandbox_off: out("Unsandboxed execution was requested on a non-Bash tool. Refused.")
    sys.exit(0)

cmd=(ti.get("command") or "")
if not cmd.strip():
    if sandbox_off: out("Unsandboxed execution was requested with an empty command. Refused.")
    sys.exit(0)

root=os.environ["NEBULA_ROOT"]
def rp(*q): return os.path.realpath(os.path.join(root,*q))
CANON="NebulaOS-firmware/tools/workspace-control/scripts/"
BUILD={rp("tools/run-nebulaos-build.sh"), rp(CANON+"run-nebulaos-build.sh")}
HW={rp("tools/run-nebulaos-hardware.sh"), rp(CANON+"run-nebulaos-hardware.sh")}
SYNC={rp("tools/sync-workspace-control.sh"), rp(CANON+"sync-workspace-control.sh")}

try: toks=shlex.split(cmd)
except Exception: toks=[]

# --- 1. container engine in command position, any caller -------------------
ENGINES=("dock"+"er","pod"+"man")
PREFIX=("sudo","env","nohup","time","stdbuf","nice","exec","command","builtin")

# Split on shell separators FIRST, then tokenize each segment, and test only
# the COMMAND POSITION of each segment.
#
# Walking shlex tokens directly got this wrong: shlex keeps a separator glued
# to the preceding word ("hi;"), so `echo hi; <engine> ps` put the engine at a
# non-initial index and the freshness flag never reset. The adversarial suite
# caught it; reading the code had not. Segments also cover substitution, since
# the split includes the substitution delimiters.
SEGSPLIT="[;|&\n\r()"+chr(96)+"]"
for seg in re.split(SEGSPLIT,cmd):
    if not seg.strip(): continue
    try: st=shlex.split(seg)
    except Exception: st=seg.split()
    k=0
    while k < len(st):
        w=st[k]
        if w.split("/")[-1] in PREFIX or w.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=",w):
            k+=1; continue
        break
    if k < len(st):
        base=st[k].split("/")[-1]
        if base in ENGINES:
            out("Direct use of the "+base+" command through the Bash tool is refused for every\n"
                "caller, including the main agent.\n\n"
                "Container access is not granted as a command. It is granted only as the approved\n"
                "build launcher, which reaches the engine through NebulaOS-firmware/build.sh as a\n"
                "subprocess:\n\n"
                "  tools/run-nebulaos-build.sh <expected-firmware-sha>   (nebulaos-build agent only)\n\n"
                "Main agent: delegate the build to the nebulaos-build subagent.")

# one plain command: no chaining, redirection, substitution or expansion
bad=set(";&|<>(){}$\n\r"); bad.add(chr(96))
chained=any(c in cmd for c in bad)

t2=list(toks)
if t2 and t2[0] in ("bash","sh","/bin/bash","/bin/sh","/usr/bin/bash","/usr/bin/sh","source","."):
    wrapped=True; t2=t2[1:]
else:
    wrapped=False

target=None; args=[]
if t2:
    script,args=t2[0],t2[1:]
    if os.path.isabs(script): cand=script
    else:
        cwd=d.get("cwd")
        cand=os.path.join(cwd,script) if cwd else None
    if cand:
        try: target=os.path.realpath(cand)
        except Exception: target=None

is_build = bool(target) and target in BUILD
is_hw    = bool(target) and target in HW
is_sync  = bool(target) and target in SYNC

# --- 3. launchers are bound to their own agent, sandboxed or not -----------
if is_hw and agent!=HW_AGENT:
    out("The hardware qualification launcher may only be invoked by the "+HW_AGENT+" agent.\n"
        "Caller: "+(agent or "main agent")+".")

if is_build and agent!=BUILD_AGENT:
    out("The approved build launcher may only be invoked by the "+BUILD_AGENT+" agent.\n"
        "Caller: "+(agent or "main agent")+".\n\n"
        "Reviewers do not build, and the main agent delegates: use the nebulaos-build subagent.")

# --- 2. the sandbox escape -------------------------------------------------
if sandbox_off:
    if chained or wrapped:
        out("Unsandboxed execution must be a lone invocation of an approved file - no chaining,\n"
            "redirection, substitution, expansion, or shell wrapper. Refused.")
    if agent==BUILD_AGENT and is_build:
        if len(args)!=1 or len(args[0])!=40 or any(c not in "0123456789abcdef" for c in args[0]):
            out("The approved build launcher takes exactly one argument: the full 40-character\n"
                "firmware SHA to build. Refused - a qualification build states its source\n"
                "identity up front.")
    elif agent=="" and is_sync:
        if args not in ([],["--apply"]):
            out("The control-layer sync takes no arguments, or --apply. Refused.")
    else:
        out("Unsandboxed execution is refused for "+(agent or "the main agent")+" running this\n"
            "command.\n\n"
            "Leaving the sandbox restores this user full host privilege, so it is granted to\n"
            "exactly two caller/file pairs:\n\n"
            "  nebulaos-build   tools/run-nebulaos-build.sh <sha>\n"
            "  main agent       tools/sync-workspace-control.sh [--apply]\n\n"
            "Resolved to: "+str(target))
' 2>/dev/null); PRIV_RC=$?

# Interpreter failure denies ONLY privilege requests - see fail-closed scope.
if [ "$PRIV_RC" -ne 0 ]; then
  case "$INPUT" in
    *dangerouslyDisableSandbox*)
      deny "NebulaOS guardrail: the privilege guard could not evaluate this request, and the
request asked for unsandboxed execution. Refusing." ;;
  esac
fi

case "${PRIV_VERDICT:-}" in
  DENY:*) deny "${PRIV_VERDICT#DENY:}" ;;
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

  # --- control-layer drift recovery ---------------------------------------
  # The only exception in this hook, and deliberately a narrow one.
  #
  # Without it the guardrail deadlocks. Editing the tracked canonical control
  # source is the documented way to change this layer; that makes the root
  # derived copies stale by design; stale copies then deny every Edit, Write
  # and Bash - including tools/sync-workspace-control.sh, the very command
  # the deny message below tells you to run. The repair sits inside the blast
  # radius of the fault, so the layer cannot be maintained at all.
  #
  # The exception opens exactly one command, and only when ALL of:
  #   - every gate failure is control-file drift that the sync repairs. Any
  #     other failure - repo identity, stale source generation, topology,
  #     sentinels, a missing canonical MANIFEST - still denies. Source
  #     identity is never bypassable this way.
  #   - the caller is the main agent. nebula-architect and nebula-verifier
  #     are refused here and, independently, by the reviewer guard above.
  #   - the tool is Bash and the command is a lone invocation of the canonical
  #     sync: no chaining, no redirection, no substitution, no extra
  #     arguments. `sync && rm -rf x` is not a sync.
  #   - the script resolves, through realpath, to the installed copy or the
  #     tracked canonical copy. Relative spellings resolve against the
  #     caller's reported cwd and are refused when cwd is unknown, so an
  #     earlier `cd` cannot aim the exception at some other file.
  #
  # The archive and launch-location guards ran earlier and have already
  # denied, so neither is reachable from here.
  if printf '%s\n' "$REASONS" | grep -qE '^[[:space:]]+FAIL: control: root files (drifted from canonical|missing):' \
  && ! printf '%s\n' "$REASONS" | grep -E '^[[:space:]]+FAIL:' \
       | grep -qvE '^[[:space:]]+FAIL: control: root files (drifted from canonical|missing):'; then
    SYNC_VERDICT=$(printf '%s' "$INPUT" | NEBULA_ROOT="$ROOT" python3 -c '
import json,os,shlex,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)

if d.get("agent_type"): sys.exit(0)                    # main agent only
if (d.get("tool_name") or "Bash") != "Bash": sys.exit(0)

cmd=((d.get("tool_input") or {}).get("command") or "")
if not cmd.strip(): sys.exit(0)

# one plain command: no chaining, redirection, substitution or expansion
bad=set(";&|<>(){}$\n\r"); bad.add(chr(96))
if any(c in cmd for c in bad): sys.exit(0)

try: toks=shlex.split(cmd)
except Exception: sys.exit(0)
if not toks: sys.exit(0)
if toks[0] in ("bash","sh","/bin/bash","/bin/sh","/usr/bin/bash","/usr/bin/sh"):
    toks=toks[1:]
if not toks: sys.exit(0)
script,args=toks[0],toks[1:]
if args not in ([],["--apply"]): sys.exit(0)

if os.path.isabs(script):
    target=script
else:
    cwd=d.get("cwd")
    if not cwd: sys.exit(0)            # cannot resolve safely -> refuse
    target=os.path.join(cwd,script)

root=os.environ["NEBULA_ROOT"]
allowed={os.path.realpath(os.path.join(root,"tools/sync-workspace-control.sh")),
         os.path.realpath(os.path.join(root,"NebulaOS-firmware/tools/workspace-control/scripts/sync-workspace-control.sh"))}
if os.path.realpath(target) in allowed: print("SYNC")
' 2>/dev/null)
    [ "$SYNC_VERDICT" = SYNC ] && allow
  fi

  deny "WORKSPACE_IDENTITY_VALID=NO - source modification blocked.

$REASONS

Do not work around this and do not switch to another checkout. Resolve identity
first. If root authority files drifted from their tracked canonical source:
  tools/sync-workspace-control.sh            (show the difference)
  tools/sync-workspace-control.sh --apply    (install canonical)"
fi

allow
