"""Control commit C, and why the working tree is never the source of privileged code.

C AND X

    C   the CONTROL commit. Reviewed, published, and the sole source of the code
        that touches a printer: the flash helper, the marker helper, the probes.
    X   the PRODUCT commit being installed. Supplies payload and data ONLY.

The separation exists because installing an OLD build must still use CURRENT
reviewed control machinery. If the helper scripts came from X, then installing a
six-month-old X would run six-month-old flashing code - including whatever bug
was fixed since - against a real printer. Worse, an X chosen by an attacker
would supply its own helpers.

So: helper BYTES come from C. Payload bytes come from X. They are different
commits and this module keeps them apart.

WHY GIT OBJECTS AND NOT FILES

A working tree is mutable. tools/ in this workspace is explicitly unversioned
derived state that the sandbox permits writing, and the repository checkout can
be edited by anything with write access - including the agent that is about to
ask for a flash. Reading a helper from the working tree means the thing being
executed is whatever was there a moment ago.

A git object at a named commit is immutable and content-addressed: `git cat-file
blob C:path` returns the same bytes for the same C, forever, and a blob whose
content changed would be a different object with a different hash and therefore
a different C. So privileged helpers are read out of the object database, never
off disk, and their hashes are checked against a manifest that is itself at C.

THE PROTECTED MIRROR

    ~/.local/state/nebulaos-hardware/mirror.git

A bare mirror fetched only from the canonical origin, fsck'd on refresh. It sits
outside the workspace so that an agent editing the workspace cannot alter the
objects a flash will read, and outside git's normal working paths so a stray
`git checkout` cannot touch it.

C MUST BE PUBLISHED. An unpushed commit is one nobody else can review or
reproduce, and control code that exists only on one laptop is not reviewed
control code. Resolution requires C to be reachable from a branch in the mirror
after a fetch from origin.

AN OPEN TRANSACTION FREEZES C

Once a transaction is under way, the control commit it started with is the one
it finishes with. Refreshing the mirror mid-transaction could otherwise swap the
helper bytes between the flash and the verification.
"""

import hashlib
import os
import subprocess

DEFAULT_STATE_HOME = os.path.join(
    os.path.expanduser("~"), ".local", "state", "nebulaos-hardware")
ENV_STATE_HOME = "NEBULAOS_HARDWARE_STATE"

# The manifest, AT C, that pins every privileged helper by content.
CONTROL_MANIFEST_PATH = "tools/hardware/CONTROL_MANIFEST"

# Two kinds of privileged file, with genuinely different guarantees.
#
#   ON_DEVICE  staged onto the printer. Its bytes are read from the git object
#              at C and sent, so the working tree cannot influence them at all.
#   HOST       control modules this launcher itself executes. Python is imported
#              from disk, so these cannot be "read from C" at run time - instead
#              the running copies are COMPARED against C and any difference is a
#              hard refusal. The effect is the same: drifted control code cannot
#              run a flash.
KIND_ON_DEVICE = "on-device"
KIND_HOST = "host"


class ControlError(Exception):
    """Control provenance that could not be established."""


def state_home():
    return os.environ.get(ENV_STATE_HOME) or DEFAULT_STATE_HOME


def mirror_path():
    return os.path.join(state_home(), "mirror.git")


def _git(args, cwd=None, timeout=300, check=True):
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_OPTIONAL_LOCKS"] = "0"
    proc = subprocess.run(["git"] + args, cwd=cwd, capture_output=True,
                          text=False, timeout=timeout, env=env)
    if check and proc.returncode != 0:
        raise ControlError("git %s failed: %s"
                           % (" ".join(args[:3]),
                              proc.stderr.decode("utf-8", "replace").strip()[:400]))
    return proc


class ControlMirror:
    """The protected, canonical-origin-only object store for control code."""

    def __init__(self, origin, path=None):
        self.origin = origin
        self.path = path or mirror_path()

    def exists(self):
        return os.path.isdir(os.path.join(self.path, "objects"))

    def refresh(self, verify=True):
        """Create or update the mirror from the canonical origin, then fsck it.

        `--prune` so a branch deleted upstream stops being resolvable here too:
        a mirror that silently retains withdrawn refs would let a revoked C keep
        working.
        """
        parent = os.path.dirname(self.path)
        os.makedirs(parent, mode=0o700, exist_ok=True)
        if not self.exists():
            _git(["clone", "--mirror", self.origin, self.path], timeout=1800)
        else:
            got = _git(["-C", self.path, "remote", "get-url", "origin"]).stdout
            got = got.decode("utf-8", "replace").strip()
            if got != self.origin:
                raise ControlError(
                    "the control mirror at %s points at %s, not the canonical origin %s. "
                    "Refusing to fetch - a mirror that can be repointed is not protected."
                    % (self.path, got, self.origin))
            _git(["-C", self.path, "fetch", "--prune", "origin",
                  "+refs/heads/*:refs/heads/*"], timeout=1800)
        if verify:
            # Object-level integrity. A corrupted or tampered object database is
            # exactly the thing a content-addressed read is supposed to rule out,
            # so it gets checked rather than assumed.
            _git(["-C", self.path, "fsck", "--connectivity-only", "--no-dangling"],
                 timeout=1800)
        try:
            os.chmod(self.path, 0o700)
        except OSError:
            pass
        return True

    def commit_exists(self, commit):
        proc = _git(["-C", self.path, "cat-file", "-e", "%s^{commit}" % commit], check=False)
        return proc.returncode == 0

    def is_published(self, commit):
        """True when `commit` is reachable from a branch in the mirror.

        The mirror only ever fetches refs/heads/* from the canonical origin, so
        reachability here means reachability from a published branch there.
        """
        proc = _git(["-C", self.path, "branch", "--contains", commit], check=False)
        if proc.returncode != 0:
            return False, "commit %s is not reachable from any branch in the mirror" % commit
        branches = [b.strip().lstrip("* ").strip()
                    for b in proc.stdout.decode("utf-8", "replace").splitlines() if b.strip()]
        if not branches:
            return False, ("commit %s exists in the mirror but is on no branch - an unpublished "
                           "commit is not reviewed control code" % commit)
        return True, "published on: %s" % ", ".join(branches)

    def read_blob(self, commit, path):
        """The exact bytes of one file at one commit. Never touches a working tree."""
        proc = _git(["-C", self.path, "cat-file", "blob", "%s:%s" % (commit, path)], check=False)
        if proc.returncode != 0:
            raise ControlError("no blob at %s:%s in the control mirror" % (commit[:12], path))
        return proc.stdout

    def commit_subject(self, commit):
        proc = _git(["-C", self.path, "log", "-1", "--format=%s", commit], check=False)
        return proc.stdout.decode("utf-8", "replace").strip() if proc.returncode == 0 else ""


class LocalControlSource:
    """DEV_INSTALL's control source: CONTROL_HEAD's git objects in the local repo.

    Same interface as ControlMirror, so ControlSet reads helper bytes from
    commit objects (never the working tree) either way. It is NOT the protected
    mirror and asserts no publication: that is exactly what RELEASE_INSTALL adds.
    """

    def __init__(self, repo_root):
        self.path = repo_root
        self.origin = "local:" + repo_root

    def exists(self):
        return os.path.isdir(os.path.join(self.path, ".git")) or \
            os.path.isfile(os.path.join(self.path, ".git"))

    def commit_exists(self, commit):
        proc = _git(["-C", self.path, "cat-file", "-e", "%s^{commit}" % commit], check=False)
        return proc.returncode == 0

    def is_published(self, commit):
        return False, "publication is not asserted for a DEV_INSTALL control source"

    def read_blob(self, commit, path):
        proc = _git(["-C", self.path, "cat-file", "blob", "%s:%s" % (commit, path)], check=False)
        if proc.returncode != 0:
            raise ControlError("no blob at %s:%s in the local repository" % (commit[:12], path))
        return proc.stdout


class ControlSet:
    """The privileged helpers at one control commit, verified against their pins."""

    def __init__(self, commit, mirror, helpers, manifest_sha256, published_on, kinds):
        self.commit = commit
        self.mirror = mirror
        self.helpers = helpers            # path -> bytes, straight from git objects
        self.manifest_sha256 = manifest_sha256
        self.published_on = published_on
        self.kinds = kinds                # path -> KIND_ON_DEVICE | KIND_HOST

    def paths_of_kind(self, kind):
        return sorted(p for p, k in self.kinds.items() if k == kind)

    @classmethod
    def load(cls, mirror, commit, require_published=True):
        if not mirror.exists():
            raise ControlError(
                "no control mirror at %s. Privileged helper bytes are read from immutable git "
                "objects, not from the working tree, so the mirror must exist first."
                % mirror.path)
        if not mirror.commit_exists(commit):
            raise ControlError(
                "control commit %s is not in the mirror. Push it and refresh - control code "
                "that is not published has not been reviewed." % commit)

        published, why = mirror.is_published(commit)
        if require_published and not published:
            raise ControlError("control commit %s is not published: %s" % (commit, why))

        raw = mirror.read_blob(commit, CONTROL_MANIFEST_PATH)
        manifest_sha = hashlib.sha256(raw).hexdigest()

        pins, kinds = {}, {}
        for lineno, line in enumerate(raw.decode("utf-8", "replace").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 3:
                raise ControlError("%s line %d is not '<sha256>  <kind>  <path>': %r"
                                   % (CONTROL_MANIFEST_PATH, lineno, line))
            digest, kind, path = parts
            if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise ControlError("%s line %d has a malformed digest" % (CONTROL_MANIFEST_PATH, lineno))
            if kind not in (KIND_ON_DEVICE, KIND_HOST):
                raise ControlError("%s line %d has kind %r, expected %s or %s"
                                   % (CONTROL_MANIFEST_PATH, lineno, kind, KIND_ON_DEVICE, KIND_HOST))
            pins[path] = digest
            kinds[path] = kind
        if not pins:
            raise ControlError("%s at %s pins nothing" % (CONTROL_MANIFEST_PATH, commit[:12]))

        helpers, mismatches = {}, []
        for path, want in sorted(pins.items()):
            blob = mirror.read_blob(commit, path)
            got = hashlib.sha256(blob).hexdigest()
            if got != want:
                mismatches.append("%s: manifest says %s, object is %s" % (path, want, got))
            helpers[path] = blob
        if mismatches:
            raise ControlError(
                "helper content does not match the pins at control commit %s:\n       %s"
                % (commit[:12], "\n       ".join(mismatches)))

        return cls(commit, mirror, helpers, manifest_sha, why if published else "unpublished",
                   kinds)

    def helper(self, path):
        try:
            return self.helpers[path]
        except KeyError:
            raise ControlError(
                "%s is not a pinned control helper at %s. Only files named in %s may be "
                "staged onto a printer." % (path, self.commit[:12], CONTROL_MANIFEST_PATH))

    def helper_sha256(self, path):
        return hashlib.sha256(self.helper(path)).hexdigest()

    def write_helper(self, path, out_path):
        """Materialise a helper from its git object into a private temp file.

        The bytes come from the object database. The file this writes is a
        transient courier for scp; it is never read back as the source of truth.
        """
        blob = self.helper(path)
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(blob)
        return out_path

    def describe(self):
        lines = [
            "CONTROL_COMMIT=%s" % self.commit,
            "CONTROL_COMMIT_PUBLISHED=%s" % (
                "not asserted (DEV_INSTALL)" if isinstance(self.mirror, LocalControlSource)
                else self.published_on),
            "CONTROL_MANIFEST_SHA256=%s" % self.manifest_sha256,
            "CONTROL_HELPER_COUNT=%d" % len(self.helpers),
            "CONTROL_HELPER_SOURCE=%s" % (
                "git objects of CONTROL_HEAD in the local repository (DEV_INSTALL; never the "
                "working tree)" if isinstance(self.mirror, LocalControlSource)
                else "git objects in the protected mirror (never the working tree)"),
        ]
        for path in sorted(self.helpers):
            lines.append("CONTROL_HELPER=%s sha256=%s" % (path, self.helper_sha256(path)))
        return "\n".join(lines)


def assert_host_control_matches(control_set, repo_root):
    """Refuse if any HOST control module on disk differs from control commit C.

    This is the gate that gives host-side control code the same guarantee the
    on-device helpers get for free. Those are read from the object database and
    sent; these are imported by the Python interpreter from disk, so the only
    way to bind them to C is to check them and refuse.

    Deliberately scoped to the files the manifest names as HOST. An unrelated
    dirty file elsewhere in the workspace is NOT a reason to refuse a flash -
    that was the old global "all repos clean" rule, and it meant another
    session's in-progress edit could corrupt an open transaction.
    """
    drifted = []
    for path in control_set.paths_of_kind(KIND_HOST):
        disk = os.path.join(repo_root, path)
        try:
            with open(disk, "rb") as fh:
                got = hashlib.sha256(fh.read()).hexdigest()
        except OSError as exc:
            drifted.append("%s: cannot read the running copy (%s)" % (path, exc))
            continue
        want = control_set.helper_sha256(path)
        if got != want:
            drifted.append("%s: running copy %s != control commit %s" % (path, got[:16], want[:16]))
    if drifted:
        raise ControlError(
            "host control code does not match control commit %s:\n       %s\n"
            "       Privileged operations run only reviewed, published control code. Commit and "
            "push the change, then use the new commit as C." % (control_set.commit[:12],
                                                                "\n       ".join(drifted)))
    return control_set.paths_of_kind(KIND_HOST)


def working_tree_differs(control_set, repo_root):
    """Report where the working tree disagrees with the control commit.

    NOT a gate on flashing, and deliberately so. The helper bytes that reach the
    printer come from the object database, so a dirty working tree cannot change
    them - which is the whole point of reading from C. An unrelated edit in
    another session must not be able to corrupt an open transaction.

    It is still worth REPORTING, because a developer looking at an install log
    should be able to tell that what they are editing is not what just ran.
    """
    differing = []
    for path in sorted(control_set.helpers):
        disk = os.path.join(repo_root, path)
        try:
            with open(disk, "rb") as fh:
                got = hashlib.sha256(fh.read()).hexdigest()
        except OSError:
            differing.append("%s: absent from the working tree" % path)
            continue
        if got != control_set.helper_sha256(path):
            differing.append("%s: working tree %s != control commit %s"
                             % (path, got[:16], control_set.helper_sha256(path)[:16]))
    return differing
