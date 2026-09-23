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
# The ONLY way a command escapes Claude sandbox in this build is the Bash tool
# dangerouslyDisableSandbox parameter. Measured on this host: an unsandboxed
# shell regains the user full supplementary group set, gid 972 included, which
# is the container group. So "may reach the container engine" and "may do
# anything as this user" are the same grant.
#
# Enforced here rather than in agent frontmatter because scoped Bash grants
# are not enforced in this build - see the note under read-only reviewers.
#
# EXACTLY ONE caller/file pair may run unsandboxed:
#
#   nebulaos-build   tools/run-nebulaos-build.sh <40-hex sha>
#
# The control-layer sync is deliberately NOT such a pair. An earlier revision
# granted the main agent an unsandboxed sync, to resolve what looked like a
# deadlock: this build sandboxes .claude/hooks read-only, so a sandboxed sync
# cannot install a hook change, and an agent that edits the canonical hook then
# cannot install it. That read-only path is not only an obstacle - it is the
# property that stops an agent installing its own authority layer. The main
# agent CAN edit canonical hooks, settings, agent definitions and the authority
# documents, because those are ordinary tracked source; before that grant the
# edit was inert, and after it one sanctioned command made it live. Installing
# the authority layer requires a human running the sync out of band. That is
# the control, not a defect, and the installer says so when it fails.
#
# BINDING IS BY CONTENT, NOT BY PATH. Comparing realpath(allowed) against
# realpath(typed) is satisfied by NAMING the path: both sides derive from the
# same string, so it is true for whatever file occupies it. The workspace root
# is not a git repository and tools/ is unversioned derived state that this
# sandbox permits writing, so a path-only check would let any caller overwrite
# the launcher and have this hook run it with host privilege. Before allowing
# the escape, the target bytes are compared against the tracked canonical blob
# at firmware HEAD. An uncommitted or altered launcher is refused.
#
# Rules:
#   1. the container engine invoked directly in COMMAND POSITION is refused for
#      every caller. This is an affordance against accident, NOT containment:
#      indirect forms (xargs, find -exec, sh -c) are not matched, and cannot be
#      in general. The real containment is that a sandboxed caller has no
#      socket, and that the launcher reaches the engine through build.sh as a
#      subprocess this hook structurally never observes.
#   2. dangerouslyDisableSandbox is refused unless the request is the pair
#      above, with verified content, no chaining, no wrapper and no extra
#      arguments.
#   3. each launcher is refused to every caller but its own agent, sandboxed or
#      not.
#   4. the hardware agent is refused device-contact commands outright, so its
#      stated constraints have the same mechanical backing the reviewers have.
#      Its launcher path is reserved and bound to it alone, and no such file
#      exists.
#
# Fail-closed SCOPE: if the interpreter cannot run, the request is refused when
# it asked for privilege, OR named a launcher path, OR names an engine. Rules
# that apply to sandboxed requests would otherwise vanish silently along with
# the interpreter.
PRIV_VERDICT=$(printf '%s' "$INPUT" | NEBULA_ROOT="$ROOT" python3 -c '
import json,os,re,shlex,subprocess,sys

BUILD_AGENT="nebulaos-build"
HW_AGENT="nebulaos-hardware"

def out(msg): print("DENY:"+msg); sys.exit(0)

try: d=json.load(sys.stdin)
except Exception: sys.exit(0)

# agent_type is NOT stripped or coerced. Whitespace must not promote a caller
# to a different principal, and a blank-but-present value must not read as the
# main agent. A non-string is not a principal at all.
agent=d.get("agent_type")
if not isinstance(agent,str): agent=""
ti=d.get("tool_input") or {}
if not isinstance(ti,dict): ti={}
tool=d.get("tool_name")
if not isinstance(tool,str): tool=""

# Any value that is not absent, False, or an explicitly false string counts as
# a privilege request. Recognising only True and "true" meant an int 1 or a
# "yes" skipped the escape branch ENTIRELY - the bash fail-closed net does not
# catch that, because the interpreter exits 0 with no verdict. Whether this
# client coerces truthy non-booleans upstream is not knowable from in here, so
# the guard does not depend on the answer.
raw=ti.get("dangerouslyDisableSandbox")
if raw is None:               sandbox_off=False
elif isinstance(raw,bool):    sandbox_off=raw
elif isinstance(raw,str):     sandbox_off = raw.strip().lower() not in ("","false","0","no","off")
else:
    try: sandbox_off=bool(raw)
    except Exception: sandbox_off=True

if tool!="Bash":
    if sandbox_off: out("Unsandboxed execution was requested on a non-Bash tool. Refused.")
    sys.exit(0)

cmd=ti.get("command")
if not isinstance(cmd,str): cmd=""
if not cmd.strip():
    if sandbox_off: out("Unsandboxed execution was requested with no command. Refused.")
    sys.exit(0)

root=os.environ["NEBULA_ROOT"]
FW=os.path.join(root,"NebulaOS-firmware")
CANON="tools/workspace-control/scripts/"
def rp(*q): return os.path.realpath(os.path.join(root,*q))
BUILD={rp("tools/run-nebulaos-build.sh"), rp("NebulaOS-firmware/"+CANON+"run-nebulaos-build.sh")}
HW={rp("tools/run-nebulaos-hardware.sh"), rp("NebulaOS-firmware/"+CANON+"run-nebulaos-hardware.sh")}

try: toks=shlex.split(cmd)
except Exception: toks=[]

ENGINES=("dock"+"er","pod"+"man")
PREFIX=("sudo","env","nohup","time","stdbuf","nice","exec","command","builtin")
DEVICE=("ssh","scp","sftp","ping","ping6","telnet","nc","ncat","socat",
        "picocom","minicom","cu","stty","avrdude","dfu-util","esptool.py","esptool")

SEGSPLIT="[;|&\n\r()"+chr(96)+"]"
def command_words(text):
    words=[]
    for seg in re.split(SEGSPLIT,text):
        if not seg.strip(): continue
        try: st=shlex.split(seg)
        except Exception: st=seg.split()
        k=0
        while k < len(st):
            w=st[k]
            if w.split("/")[-1] in PREFIX or w.startswith("-") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=",w):
                k+=1; continue
            break
        if k < len(st): words.append(st[k].split("/")[-1])
    return words

CW=command_words(cmd)

# --- 1. container engine in command position, any caller -------------------
for base in CW:
    if base in ENGINES:
        out("Direct use of the "+base+" command through the Bash tool is refused for every\n"
            "caller, including the main agent.\n\n"
            "Container access is not granted as a command. It is granted only as the approved\n"
            "build launcher, which reaches the engine through NebulaOS-firmware/build.sh as a\n"
            "subprocess:\n\n"
            "  tools/run-nebulaos-build.sh <expected-firmware-sha>   (nebulaos-build agent only)\n\n"
            "Main agent: delegate the build to the nebulaos-build subagent.")

# --- 4. the hardware agent may not touch a device --------------------------
if agent==HW_AGENT:
    for base in CW:
        if base in DEVICE:
            out("The "+HW_AGENT+" agent is refused the "+base+" command.\n\n"
                "This agent is created but NOT enabled: it has no bound target, no credentials\n"
                "and no launcher. Its no-device-contact constraint is mechanical, not advisory,\n"
                "so it cannot reach a printer before a mission binds one.\n\n"
                "If you were asked to qualify hardware, report HARDWARE_QUALIFIED=NOT_ATTEMPTED.")

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
        cand=os.path.join(cwd,script) if isinstance(cwd,str) and cwd else None
    if cand:
        try: target=os.path.realpath(cand)
        except Exception: target=None

is_build = bool(target) and target in BUILD
is_hw    = bool(target) and target in HW

# --- 3. launchers are bound to their own agent, sandboxed or not -----------
if is_hw and agent!=HW_AGENT:
    out("The hardware qualification launcher may only be invoked by the "+HW_AGENT+" agent.\n"
        "Caller: "+(agent or "main agent")+".")

if is_build and agent!=BUILD_AGENT:
    out("The approved build launcher may only be invoked by the "+BUILD_AGENT+" agent.\n"
        "Caller: "+(agent or "main agent")+".\n\n"
        "Reviewers do not build, and the main agent delegates: use the nebulaos-build subagent.")

def content_is_canonical(path):
    # The executed bytes must equal the tracked canonical blob at firmware HEAD.
    # Path identity is not enough: the installed copy is unversioned derived
    # state in a directory this sandbox permits writing.
    try:
        with open(path,"rb") as fh: have=fh.read()
    except Exception:
        return (False,"the launcher could not be read")
    try:
        r=subprocess.run(["git","-C",FW,"cat-file","blob",
                          "HEAD:"+CANON+os.path.basename(path)],
                         stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
    except Exception:
        return (False,"the canonical blob could not be read from git")
    if r.returncode!=0:
        return (False,"the launcher is not tracked at firmware HEAD")
    if have!=r.stdout:
        return (False,"the launcher on disk differs from the tracked canonical blob")
    return (True,"")

# --- 2. the sandbox escape -------------------------------------------------
if sandbox_off:
    if agent!=BUILD_AGENT or not is_build:
        out("Unsandboxed execution is refused for "+(agent or "the main agent")+" running this\n"
            "command.\n\n"
            "Leaving the sandbox restores this user full host privilege, so it is granted to\n"
            "exactly one caller running exactly one file:\n\n"
            "  nebulaos-build   tools/run-nebulaos-build.sh <40-hex sha>\n\n"
            "The control-layer sync is NOT in that set. Installing the authority layer\n"
            "requires a human running it out of band - that is the control, not a defect.\n\n"
            "Resolved to: "+str(target))
    if chained or wrapped:
        out("Unsandboxed execution must be a lone invocation of the approved launcher - no\n"
            "chaining, redirection, substitution, expansion, or shell wrapper. Refused.")
    if len(args)!=1 or len(args[0])!=40 or any(c not in "0123456789abcdef" for c in args[0]):
        out("The approved build launcher takes exactly one argument: the full 40-character\n"
            "firmware SHA to build. Refused - a qualification build states its source\n"
            "identity up front.")
    ok,why=content_is_canonical(target)
    if not ok:
        out("Unsandboxed execution is bound to the launcher CONTENT, not to its path.\n\n"
            "Refused: "+why+".\n\n"
            "Naming an allowed path is not enough. tools/ is unversioned derived state that\n"
            "this sandbox permits writing, so a path-only check would let any caller replace\n"
            "the launcher and have this hook run it with host privilege. Commit the launcher\n"
            "and re-sync, then retry.")
' 2>/dev/null); PRIV_RC=$?

# Interpreter failure denies any request that asked for privilege, named a
# launcher, or names an engine - see fail-closed scope above.
if [ "$PRIV_RC" -ne 0 ]; then
  case "$INPUT" in
    *dangerouslyDisableSandbox*|*run-nebulaos-*|*dock"er"*|*pod"man"*)
      deny "NebulaOS guardrail: the privilege guard could not evaluate this request, and the
request asked for unsandboxed execution, named a launcher, or named a container
engine. Refusing." ;;
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
