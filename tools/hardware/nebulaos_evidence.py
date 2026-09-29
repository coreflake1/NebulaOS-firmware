"""The evidence a destructive hardware operation requires before it may proceed.

WHAT A DESTRUCTIVE OPERATION MUST BE ABLE TO PROVE

Not "the files look right" - that is satisfied by any self-consistent set of
bytes, including a half-finished build whose manifest happens to match its own
partial output. It must prove:

  * a v2 attestation exists for this exact product commit, and it VERIFIES
    under the attestation key (so the fields were produced by a holder of it);
  * the attestation's artifact digests equal the bytes about to be installed;
  * the build profile is release or candidate - a dev build, with ccache on and
    reused incremental output, never qualifies to reach a printer;
  * the product commit is published, so what lands on hardware corresponds to
    source someone else can fetch and review.

WHY v1 IS NOT ENOUGH, AND WHY IT IS NOT SILENTLY UPGRADED

The v1 record (.nebulaos-build-verified) is an unauthenticated text file in a
world-writable /var/tmp tree. Anything that can write the path can claim any
build passed. It is still useful - it is the build launcher's own statement that
build.sh exited zero and the canonical workspace stayed clean - but it is an
assertion, not evidence, and this module treats it as such.

A v1 record present without a v2 attestation is reported as exactly that, and
the destructive path refuses. It is never promoted, never "accepted because the
hashes match", and never treated as a degraded form of v2. An unauthenticated
record that is accepted whenever the authenticated one is missing is an
unauthenticated system with extra steps.

NO KEY MEANS NO INSTALL. THAT IS THE DESIGN.

The attestation key is created by a human and denied to agents. If it is absent,
nothing can be verified, and this refuses. That is not an obstacle to work
around - it is the control. An installer that falls back to "well, the hashes
look fine" when the key is missing has removed the only thing that made the
attestation worth having.
"""

import os
import subprocess
import sys

ATTEST_TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           "..", "attest", "nebulaos-attest.py")

# Profiles whose output may reach a printer. A dev build is excluded on purpose:
# it may have used ccache and reused incremental output, so its bytes are not
# the bytes a clean build of that source would produce.
INSTALLABLE_PROFILES = frozenset({"release", "candidate"})


class EvidenceError(Exception):
    """Evidence that is missing, unverifiable, or does not match the artifacts."""


class BuildEvidence:
    def __init__(self, path, fields, profile, source_head):
        self.path = path
        self.fields = fields
        self.profile = profile
        self.source_head = source_head

    def describe(self):
        return "\n".join([
            "ATTESTATION_V2_VERIFIED=YES",
            "ATTESTATION_PATH=%s" % self.path,
            "ATTESTATION_KEY_ID=%s" % self.fields.get("KEY_ID", ""),
            "ATTESTATION_SOURCE_HEAD=%s" % self.source_head,
            "ATTESTATION_SOURCE_REPO=%s" % self.fields.get("SOURCE_REPO", ""),
            "ATTESTATION_SOURCE_PUBLISHED_TIP=%s" % self.fields.get("SOURCE_PUBLISHED_TIP", ""),
            "ATTESTATION_BUILD_PROFILE=%s" % self.profile,
            "ATTESTATION_BUILD_MODE=%s" % self.fields.get("BUILD_MODE", ""),
            "ATTESTATION_CCACHE=%s" % self.fields.get("CCACHE", ""),
            "ATTESTATION_BUILDER_DIGEST=%s" % self.fields.get("BUILDER_DIGEST", ""),
        ])


def attestation_candidates(build_run, source_head, store=None):
    """Where a v2 attestation for this build might be, most specific first."""
    store = store or os.environ.get("NEBULAOS_ATTEST_STORE") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
        "nebulaos-evidence", "attestations")
    out = []
    if build_run:
        out.append(os.path.join(build_run, ".nebulaos-build-attestation-v2"))
    out.append(os.path.join(store, "%s.att" % source_head))
    return out


def require_v2(source_head, ximage_sha, ximage_size, rootfs_sha, rootfs_size,
               build_run=None, store=None, attest_tool=None):
    """Verify a v2 attestation and bind it to these exact artifacts.

    Raises EvidenceError with a reason a human can act on. Returns BuildEvidence.
    """
    tool = attest_tool or ATTEST_TOOL
    tried = attestation_candidates(build_run, source_head, store)
    found = next((p for p in tried if os.path.isfile(p)), None)

    if found is None:
        v1 = os.path.join(build_run, ".nebulaos-build-verified") if build_run else None
        extra = ""
        if v1 and os.path.isfile(v1):
            extra = ("\n       A v1 record exists at %s. It is NOT accepted in place of a v2 "
                     "attestation: it is an unauthenticated text file in a world-writable tree, "
                     "so anything that can write the path can claim any build passed." % v1)
        raise EvidenceError(
            "no v2 build attestation for %s. Looked in:\n       %s%s\n"
            "       Produce one with tools/attest/attest-build-run.sh --build-run <dir>. That "
            "needs the attestation key, which a human creates at "
            "~/.config/nebulaos-attest/attest.key and which agents are denied."
            % (source_head, "\n       ".join(tried), extra))

    # Verification happens in the attestation tool, which owns the MAC and the
    # constant-time compare. Requiring SOURCE_HEAD here means a valid
    # attestation for a DIFFERENT build cannot be presented for this one.
    proc = subprocess.run(
        [sys.executable, tool, "verify", "--in", found,
         "--require", "SOURCE_HEAD=%s" % source_head,
         "--require", "XIMAGE_SHA256=%s" % ximage_sha,
         "--require", "ROOTFS_SQUASHFS_SHA256=%s" % rootfs_sha,
         "--require", "XIMAGE_SIZE=%d" % ximage_size,
         "--require", "ROOTFS_SQUASHFS_SIZE=%d" % rootfs_size],
        capture_output=True, text=True)

    if proc.returncode == 2:
        raise EvidenceError(
            "the attestation at %s could not be checked: %s\n"
            "       This is a refusal, not a failure to verify - the difference matters. "
            "Nothing is installed on evidence that could not be evaluated."
            % (found, proc.stderr.strip()[:300]))
    if proc.returncode != 0:
        raise EvidenceError(
            "the attestation at %s did not verify against these artifacts: %s"
            % (found, proc.stderr.strip()[:400]))

    fields = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            fields[key.strip()] = value.strip()

    profile = fields.get("BUILD_PROFILE", "")
    if profile not in INSTALLABLE_PROFILES:
        raise EvidenceError(
            "the attestation states BUILD_PROFILE=%r. Only %s may reach a printer: a dev build "
            "may have used ccache and reused incremental output, so its bytes are not the bytes a "
            "clean build of that source produces."
            % (profile, " or ".join(sorted(INSTALLABLE_PROFILES))))
    # Checked again on the consuming side: the profile is only as good as the
    # build it describes. The signer refuses these combinations too; an
    # attestation minted by an older signer must not slip past here.
    mode = fields.get("BUILD_MODE", "")
    if mode not in ("candidate", "qualified"):
        raise EvidenceError(
            "the attestation states BUILD_PROFILE=%s but BUILD_MODE=%r. Only a candidate or "
            "qualified build may reach a printer." % (profile, mode))
    if fields.get("CCACHE", "") != "disabled":
        raise EvidenceError(
            "the attestation states BUILD_PROFILE=%s but CCACHE=%r. An installable build must "
            "have ccache disabled." % (profile, fields.get("CCACHE", "")))

    return BuildEvidence(found, fields, profile, source_head)


def product_is_published(repo_root, source_head, remote="origin", fetch=True):
    """-> (ok, detail). What lands on a printer must be fetchable by someone else.

    Checked against REMOTE-TRACKING refs, and - unless `fetch` is disabled -
    after refreshing them. An earlier revision claimed to ask the remote while
    actually reading possibly-stale local refs, which would let a commit that
    was only ever pushed-then-deleted, or never pushed at all on a fresh clone,
    look published. ControlMirror.refresh() already fetches before judging C;
    this is the same discipline for X.
    """
    try:
        url = subprocess.run(["git", "-C", repo_root, "remote", "get-url", remote],
                             capture_output=True, text=True, timeout=30)
        if url.returncode != 0:
            return False, "cannot read the %s remote" % remote
        if fetch:
            # Fail CLOSED. This answer gates a destructive install, and refs that
            # could not be refreshed are exactly the stale view this check exists
            # to rule out: a commit pushed and then force-removed, or never pushed
            # from a fresh clone, would still look published. No network, no
            # proof of publication, no install.
            fetched = subprocess.run(["git", "-C", repo_root, "fetch", "--quiet", remote],
                                     capture_output=True, text=True, timeout=120)
            if fetched.returncode != 0:
                return False, ("could not refresh the %s remote refs (%s); publication of %s "
                               "cannot be established from possibly-stale refs"
                               % (remote, (fetched.stderr or "").strip()[:120], source_head[:12]))
            stale = ""
        else:
            stale = " (remote refs not refreshed)"
        proc = subprocess.run(["git", "-C", repo_root, "branch", "-r", "--contains", source_head],
                              capture_output=True, text=True, timeout=60)
        if proc.returncode != 0:
            return False, ("commit %s is not reachable from any remote-tracking branch - push it "
                           "before installing it" % source_head[:12])
        branches = [b.strip() for b in proc.stdout.splitlines() if b.strip()]
        if not branches:
            return False, ("commit %s is on no remote branch - an unpublished product commit is "
                           "one nobody else can fetch" % source_head[:12])
        return True, "published on %s%s" % (", ".join(branches), stale)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return False, "could not establish publication: %s" % exc
