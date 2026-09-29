#!/usr/bin/env python3
"""The Hardware Agent's four operations, and the proofs each one requires.

THE PUBLIC INTERFACE IS SEMANTIC

    inspect   read-only: what is this printer, what is it running, what is on it
    status    read-only: is a transaction open, and what state is it in
    verify    read-only: does this printer currently run this exact build
    install   the developer install, NebulaOS -> Stock -> flash -> NebulaOS

There is no ssh, scp, dd, marker, reboot, flash, raw usbboot, --host, --password
or --command. Not because they are filtered - because no such operation exists
here to name. The device is reached only through DeviceSession, whose vocabulary
is closed, and the target is chosen only by enrolled device id.

WHAT REPLACED "ALL REPOS MUST BE CLEAN"

The old hardware launcher refused any destructive operation unless all five
canonical repositories were clean. That was a blunt instrument standing in for
several different proofs, and it had a real cost: an unrelated edit in another
session - someone writing a doc, an agent mid-refactor - could invalidate an
open hardware transaction that had nothing to do with it.

It is replaced by the proofs that were actually meant:

    control commit C is published, resolvable, and content-bound
    host control code matches C exactly
    on-device helper bytes come from C's git objects
    product commit X is published
    X has a v2 attestation that verifies
    the attestation's digests equal the artifact bytes
    the build profile is release or candidate
    workspace topology, archive isolation and sentinels are valid

What is NOT relaxed: the full online identity gate still runs. A commit that was
never compared against the canonical remote is an unverified source generation,
and flashing is the least reversible boundary in the project.
"""

import argparse
import hashlib
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import nebulaos_control as control      # noqa: E402
import nebulaos_device as device        # noqa: E402
import nebulaos_evidence as evidence    # noqa: E402
import nebulaos_install as install      # noqa: E402
import nebulaos_journal as journal      # noqa: E402
import nebulaos_marker as marker        # noqa: E402
import nebulaos_profile as profiles     # noqa: E402
import nebulaos_target as targets       # noqa: E402
import nebulaos_verify as verifylib     # noqa: E402

FW_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
BUILD_BASE = "/var/tmp/nebulaos-build"


class AgentRefusal(Exception):
    """A precondition that was not met. Always names what to do about it."""


def say(text=""):
    print(text)


# ---------------------------------------------------------------------------
# artifact location
# ---------------------------------------------------------------------------

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locate_artifacts(source_head, ximage_sha, rootfs_sha):
    """Find the build workspace for this exact source identity.

    Deliberately not a "latest" symlink and not a newest-mtime pick: the
    workspace is keyed by commit, the clone inside it must BE that commit, and
    the bytes must hash to what the caller stated. Three independent agreements.
    """
    base = os.path.join(BUILD_BASE, source_head)
    if not os.path.isdir(base):
        raise AgentRefusal(
            "no build workspace for %s under %s. Build it first through the nebulaos-build "
            "agent; this launcher never builds and never picks an artifact by filename."
            % (source_head, BUILD_BASE))

    problems = []
    for run in sorted(os.listdir(base)):
        run_dir = os.path.join(base, run)
        art = os.path.join(run_dir, "artifacts", "buildroot-halley5-v30-image")
        ximage = os.path.join(art, "xImage")
        rootfs = os.path.join(art, "rootfs.squashfs")
        manifest = os.path.join(art, "build-manifest.txt")
        if not all(os.path.isfile(p) for p in (ximage, rootfs, manifest)):
            continue
        got_x = sha256_file(ximage)
        got_r = sha256_file(rootfs)
        if got_x != ximage_sha:
            problems.append("%s: xImage is %s" % (run, got_x[:16]))
            continue
        if got_r != rootfs_sha:
            problems.append("%s: rootfs is %s" % (run, got_r[:16]))
            continue
        return install.Artifacts(
            source_head=source_head, ximage_path=ximage, rootfs_path=rootfs,
            manifest_path=manifest, ximage_sha=got_x, ximage_size=os.path.getsize(ximage),
            rootfs_sha=got_r, rootfs_size=os.path.getsize(rootfs)), run_dir

    raise AgentRefusal(
        "no build under %s has artifacts matching the stated hashes.%s"
        % (base, ("\n       " + "\n       ".join(problems)) if problems else ""))


# ---------------------------------------------------------------------------
# preconditions
# ---------------------------------------------------------------------------

def resolve_control(control_commit, refresh=True):
    """Resolve control commit C from the protected mirror."""
    import subprocess
    origin = subprocess.run(["git", "-C", FW_ROOT, "remote", "get-url", "origin"],
                            capture_output=True, text=True).stdout.strip()
    if not origin:
        raise AgentRefusal("cannot read the canonical firmware remote")
    mirror = control.ControlMirror(origin)
    if refresh:
        try:
            mirror.refresh()
        except control.ControlError as exc:
            raise AgentRefusal(
                "the protected control mirror could not be refreshed: %s\n"
                "       Privileged helper bytes are read from immutable git objects, so the "
                "mirror must be present and healthy before anything touches a printer." % exc)
    try:
        return control.ControlSet.load(mirror, control_commit)
    except control.ControlError as exc:
        raise AgentRefusal(str(exc))


def prove_preconditions(device_id, source_head, artifacts, build_run, control_commit,
                        destructive):
    """Everything that must hold before an operation may proceed."""
    say("--- preconditions ---")

    profile = profiles.DeviceProfile.load(device_id)
    say(profile.describe())
    say()

    control_set = resolve_control(control_commit)
    say(control_set.describe())

    # Host control code must BE control commit C. On-device helpers are read
    # from C's objects so the working tree cannot influence them; host modules
    # are imported from disk, so they are compared and a difference refuses.
    checked = control.assert_host_control_matches(control_set, FW_ROOT)
    say("CONTROL_HOST_MODULES_VERIFIED=%d" % len(checked))

    # Reported, not gated: the helper bytes that reach the printer come from the
    # object database, so a dirty working tree cannot change them. An unrelated
    # edit in another session must not be able to corrupt an open transaction.
    drifted = control.working_tree_differs(control_set, FW_ROOT)
    say("CONTROL_WORKING_TREE_DIFFERS=%d%s"
        % (len(drifted), (" (" + "; ".join(drifted) + ")") if drifted else ""))
    say()

    if not destructive:
        return profile, control_set, None

    published, why = evidence.product_is_published(FW_ROOT, source_head)
    if not published:
        raise AgentRefusal(
            "the product commit is not published: %s. What lands on a printer must correspond "
            "to source someone else can fetch." % why)
    say("PRODUCT_PUBLISHED=YES (%s)" % why)

    ev = evidence.require_v2(
        source_head, artifacts.ximage_sha, artifacts.ximage_size,
        artifacts.rootfs_sha, artifacts.rootfs_size, build_run=build_run)
    say(ev.describe())
    say()
    return profile, control_set, ev


def ssh_session_factory(profile):
    """The production seam. Builds an SSH session against an enrolled address."""
    import tempfile

    def factory(which_os, address):
        known = os.path.join(tempfile.mkdtemp(prefix=".nebulaos-kh."), "known_hosts")
        profile.write_known_hosts(which_os, address, known)
        return device.SshDeviceSession(
            address=address, username=profile.username(which_os),
            password=profile.credential(which_os), known_hosts_path=known)
    return factory


# ---------------------------------------------------------------------------
# operations
# ---------------------------------------------------------------------------

def op_inspect(args):
    profile, control_set, _ = prove_preconditions(
        args.device, None, None, None, args.control_commit, destructive=False)
    say(targets.capability_report())
    say()
    say(targets.DEV_PRESERVE_STOCK.report(prefix="DEV_INSTALL_POLICY"))
    say()

    factory = ssh_session_factory(profile)
    for which in (device.OS_NEBULAOS, device.OS_STOCK):
        for address in profiles.candidate_addresses(profile, which):
            try:
                session = factory(which, address)
            except Exception as exc:
                say("PROBE=%s@%s unreachable (%s)" % (which, address, str(exc)[:100]))
                continue
            try:
                identity = session.probe_identity()
                ok, why = profile.identity_matches(identity)
                say("PROBE=%s@%s reachable" % (which, address))
                say(identity.describe())
                say("DEVICE_IDENTITY_MATCHES_PROFILE=%s (%s)" % ("YES" if ok else "NO", why))
                say("DEVICE_RUNNING_OS=%s" % session.which_os())
                say("DEVICE_ACTIVE_ROOT=%s" % session.active_root())
                state, reason = marker.parse(session.read_marker_block())
                say(marker.describe(state, reason))
                say(session.idle_state().describe())
                for key, value in sorted(session.service_health().items()):
                    say("SERVICE_%s=%s" % (key.upper(), value))
                return 0
            finally:
                session.close()
    say("INSPECT=NO_DEVICE_REACHABLE")
    return 3


def op_status(args):
    txn = journal.Transaction.open(args.device)
    if txn is None:
        say("TRANSACTION_OPEN=NO")
        say("# No install transaction is recorded for this device.")
        return 0
    say("TRANSACTION_OPEN=YES")
    say(txn.describe())
    if txn.state in journal.ARMED_FOR_STOCK_STATES:
        say()
        say("# This device is ARMED FOR STOCK. Do not power cycle: a power cycle into")
        say("# Creality's slot lets its updater reflash the MCU. Re-run `install` to")
        say("# disarm, or resolve the marker by hand.")
    return 0


def op_verify(args):
    profile, control_set, _ = prove_preconditions(
        args.device, args.source_head, None, None, args.control_commit, destructive=False)
    artifacts, _ = locate_artifacts(args.source_head, args.ximage_sha, args.rootfs_sha)

    factory = ssh_session_factory(profile)
    for address in profiles.candidate_addresses(profile, device.OS_NEBULAOS):
        try:
            session = factory(device.OS_NEBULAOS, address)
        except Exception:
            continue
        try:
            result = verifylib.part1_verify(
                session, artifacts.ximage_sha, artifacts.ximage_size,
                artifacts.rootfs_sha, artifacts.rootfs_size, args.source_head,
                profile=profile)
            mcu = verifylib.observe_mcu_restore(session)
            say(verifylib.render_part1(result, args.source_head, mcu_restore_result=mcu))
            return 0 if result.ok() else 1
        finally:
            session.close()
    raise AgentRefusal("could not reach the enrolled printer as NebulaOS at any enrolled address")


def op_install(args):
    artifacts, build_run = locate_artifacts(args.source_head, args.ximage_sha, args.rootfs_sha)
    profile, control_set, ev = prove_preconditions(
        args.device, args.source_head, artifacts, build_run, args.control_commit,
        destructive=True)

    with journal.HostLock(args.device):
        txn = journal.Transaction.open(args.device)
        if txn is not None:
            same, why = txn.matches(args.device, control_set.commit, args.source_head,
                                    artifacts.ximage_sha, artifacts.rootfs_sha)
            say("TRANSACTION_RESUMABLE=%s (%s)" % ("YES" if same else "NO", why))
            if not same:
                txn = journal.Transaction.begin(
                    args.device, control_set.commit, args.source_head,
                    artifacts.ximage_sha, artifacts.rootfs_sha)
        else:
            txn = journal.Transaction.begin(
                args.device, control_set.commit, args.source_head,
                artifacts.ximage_sha, artifacts.rootfs_sha)

        installer = install.Installer(
            args.device, profile, control_set, artifacts,
            ssh_session_factory(profile), txn=txn)
        try:
            result = installer.run()
        except install.InstallError as exc:
            say(installer.result.render())
            say()
            say("INSTALL=REFUSED")
            say("REASON: %s" % exc)
            txn.advance(journal.FAILED_NEEDS_ATTENTION, str(exc)[:200])
            return 3
        say(result.render())
        return 0 if result.ok else 1


# ---------------------------------------------------------------------------

def main(argv):
    parser = argparse.ArgumentParser(
        prog="nebulaos-agent",
        description="NebulaOS Hardware Agent: semantic operations on an enrolled printer")
    parser.add_argument("--device", required=True, help="an enrolled device id")
    parser.add_argument("--control-commit", required=True,
                        help="control commit C: the reviewed, published source of privileged code")
    sub = parser.add_subparsers(dest="op", required=True)

    sub.add_parser("inspect")
    sub.add_parser("status")
    for name in ("verify", "install"):
        p = sub.add_parser(name)
        p.add_argument("source_head")
        p.add_argument("ximage_sha")
        p.add_argument("rootfs_sha")

    args = parser.parse_args(argv)
    handler = {"inspect": op_inspect, "status": op_status,
               "verify": op_verify, "install": op_install}[args.op]
    try:
        return handler(args)
    except AgentRefusal as exc:
        sys.stderr.write("RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n" % exc)
        return 2
    except (profiles.ProfileError, control.ControlError, evidence.EvidenceError) as exc:
        sys.stderr.write("RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
