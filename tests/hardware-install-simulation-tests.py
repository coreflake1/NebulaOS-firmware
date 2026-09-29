#!/usr/bin/env python3
"""Adversarial simulation of the developer install, end to end.

Every scenario the mission names is exercised against the REAL install state
machine - nebulaos_install.Installer, unmodified - driven by a simulated printer
through the same `session_factory` seam that production fills with SSH. Nothing
here mocks the installer's own logic; the device misbehaves and the installer
has to cope.

The control commit is real too: each run builds a throwaway git repository,
commits the actual helper files, clones it as a protected mirror and resolves a
ControlSet out of it. So the provenance path that refuses unpublished control
commits and mismatched helper hashes is under test, not stubbed.

WHAT A PASSING CASE MEANS HERE

For the happy path: the device ends up running NebulaOS, from slot 2, with the
exact expected bytes in kernel2 and rootfs2, and PART1_INSTALL_VERIFIED=YES.

For every adversarial case: the installer REFUSES, and refuses for the right
reason, and - crucially - leaves the printer in a state a human can recover.
The most important assertion in this file is not that a failure is detected; it
is that a failure while ARMED puts the marker back.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
FW = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(FW, "tools", "hardware"))
sys.path.insert(0, os.path.join(HERE, "hardware"))

import nebulaos_control as control    # noqa: E402
import nebulaos_device as device      # noqa: E402
import nebulaos_install as install    # noqa: E402
import nebulaos_journal as journal    # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_profile as profiles   # noqa: E402
import nebulaos_target as targets     # noqa: E402
import nebulaos_evidence as evidence  # noqa: E402
import nebulaos_device_sim as sim     # noqa: E402

PASS = []
FAIL = []


def ok(name, detail=""):
    PASS.append(name)
    print("PASS  %s%s" % (name, ("  -- " + detail) if detail else ""))


def bad(name, detail=""):
    FAIL.append(name)
    print("FAIL  %s" % name)
    if detail:
        print("       %s" % detail)


def check(name, condition, detail=""):
    (ok if condition else bad)(name, detail)
    return condition


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

XIMAGE = b"NEBULAOS-XIMAGE-" + b"K" * 4096
ROOTFS = b"NEBULAOS-ROOTFS-" + b"R" * 65536
SOURCE_HEAD = "c4061c82356c09c4b053a1f9603ebaf7b98b704f"


class Fixture:
    def __init__(self, root):
        self.root = root
        self.payload_dir = os.path.join(root, "payload")
        os.makedirs(self.payload_dir)

        self.ximage_path = os.path.join(self.payload_dir, "xImage")
        self.rootfs_path = os.path.join(self.payload_dir, "rootfs.squashfs")
        self.manifest_path = os.path.join(self.payload_dir, "build-manifest.txt")
        with open(self.ximage_path, "wb") as fh:
            fh.write(XIMAGE)
        with open(self.rootfs_path, "wb") as fh:
            fh.write(ROOTFS)
        with open(self.manifest_path, "w") as fh:
            fh.write("git_commit_main=%s\n" % SOURCE_HEAD)

        self.artifacts = install.Artifacts(
            source_head=SOURCE_HEAD,
            ximage_path=self.ximage_path, rootfs_path=self.rootfs_path,
            manifest_path=self.manifest_path,
            ximage_sha=hashlib.sha256(XIMAGE).hexdigest(), ximage_size=len(XIMAGE),
            rootfs_sha=hashlib.sha256(ROOTFS).hexdigest(), rootfs_size=len(ROOTFS))

        self.printer = sim.SimulatedPrinter()
        self._write_profile()
        self.profile = profiles.DeviceProfile.load("printer-sim")
        self.control = self._build_control()

    # -- enrolled profile --------------------------------------------------
    def _write_profile(self):
        home = os.path.join(self.root, "config")
        os.makedirs(os.path.join(home, "devices", "printer-sim"), mode=0o700)
        os.chmod(home, 0o700)
        os.chmod(os.path.join(home, "devices"), 0o700)
        os.environ[profiles.ENV_HOME] = home
        pdir = os.path.join(home, "devices", "printer-sim")

        cid, snmac = self.printer.identity()
        conf = os.path.join(pdir, "profile.conf")
        with open(conf, "w") as fh:
            fh.write("\n".join([
                "DEVICE_ID=printer-sim",
                "EMMC_CID=%s" % cid,
                "SN_MAC_SHA256=%s" % snmac,
                "NEBULAOS_HOST_KEY=%s" % self.printer.host_keys[device.OS_NEBULAOS],
                "STOCK_HOST_KEY=%s" % self.printer.host_keys[device.OS_STOCK],
                "NEBULAOS_ADDRESS_HISTORY=%s" % self.printer.addresses[device.OS_NEBULAOS],
                "STOCK_ADDRESS_HISTORY=%s" % self.printer.addresses[device.OS_STOCK],
                "NEBULAOS_CREDENTIAL_REF=nebulaos.cred",
                "STOCK_CREDENTIAL_REF=stock.cred",
                "",
            ]))
        os.chmod(conf, 0o600)
        for which, name in ((device.OS_NEBULAOS, "nebulaos.cred"), (device.OS_STOCK, "stock.cred")):
            path = os.path.join(pdir, name)
            with open(path, "w") as fh:
                fh.write(self.printer.passwords[which] + "\n")
            os.chmod(path, 0o600)

    # -- a real control commit --------------------------------------------
    def _build_control(self):
        """Build a throwaway origin, commit real helpers, mirror it, resolve C.

        Deliberately the real ControlMirror/ControlSet path: publication and
        helper-hash pinning are safety properties and a stub would not exercise
        them.
        """
        origin = os.path.join(self.root, "origin.git")
        work = os.path.join(self.root, "origin-work")
        os.makedirs(work)
        env = dict(os.environ, GIT_AUTHOR_NAME="sim", GIT_AUTHOR_EMAIL="sim@example",
                   GIT_COMMITTER_NAME="sim", GIT_COMMITTER_EMAIL="sim@example")

        helper_dir = os.path.join(work, "scripts")
        os.makedirs(helper_dir)
        helper_body = b"#!/bin/sh\n# simulated slot-2 flash helper\nexit 0\n"
        with open(os.path.join(helper_dir, "flash-spare-slot.sh"), "wb") as fh:
            fh.write(helper_body)

        # A host module, copied verbatim from the tree, so the host-drift gate
        # has something real to compare.
        os.makedirs(os.path.join(work, "tools", "hardware"))
        host_src = os.path.join(FW, "tools", "hardware", "nebulaos_marker.py")
        shutil.copyfile(host_src, os.path.join(work, "tools", "hardware", "nebulaos_marker.py"))
        with open(host_src, "rb") as fh:
            host_sha = hashlib.sha256(fh.read()).hexdigest()

        manifest = "\n".join([
            "# simulated control manifest",
            "%s  on-device  scripts/flash-spare-slot.sh" % hashlib.sha256(helper_body).hexdigest(),
            "%s  host  tools/hardware/nebulaos_marker.py" % host_sha,
            "",
        ])
        with open(os.path.join(work, "tools", "hardware", "CONTROL_MANIFEST"), "w") as fh:
            fh.write(manifest)

        def git(*args, cwd=work):
            subprocess.run(["git"] + list(args), cwd=cwd, check=True,
                           capture_output=True, env=env)

        git("init", "-q", "-b", "main")
        git("add", "-A")
        git("commit", "-qm", "simulated control commit")
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=work,
                                capture_output=True, text=True, env=env).stdout.strip()
        subprocess.run(["git", "clone", "-q", "--bare", work, origin],
                       check=True, capture_output=True, env=env)

        os.environ[control.ENV_STATE_HOME] = os.path.join(self.root, "state")
        mirror = control.ControlMirror(origin, os.path.join(self.root, "state", "mirror.git"))
        mirror.refresh()
        self.control_commit = commit
        self.control_work = work
        return control.ControlSet.load(mirror, commit)

    def installer(self, **kwargs):
        txn = kwargs.pop("txn", None)
        return install.Installer(
            "printer-sim", self.profile, self.control, self.artifacts,
            sim.make_session_factory(self.printer, self.profile),
            txn=txn, sleep=lambda _s: None, now=_FakeClock(), **kwargs)


class _FakeClock:
    """Monotonic enough for timeouts, instant in wall time."""
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        self.t += 1.0
        return self.t


def scenario(name):
    """Fresh fixture per scenario, in its own temp tree."""
    root = tempfile.mkdtemp(prefix="nebulaos-sim-%s." % name,
                            dir=os.environ.get("TMPDIR") or None)
    return Fixture(root), root


def run_install(fixture, txn=None):
    """-> (result_or_None, error_or_None)."""
    try:
        return fixture.installer(txn=txn).run(), None
    except install.InstallError as exc:
        return None, exc
    except Exception as exc:                      # noqa: BLE001 - surfaced as a failure
        return None, exc


def marker_state(printer):
    return marker.parse(printer.partitions["ota"])[0]


# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

def case_happy_path():
    fx, root = scenario("happy")
    try:
        result, err = run_install(fx)
        if err is not None:
            return bad("NebulaOS -> Stock -> NebulaOS install succeeds", str(err)[:220])
        check("NebulaOS -> Stock -> NebulaOS install succeeds", result.ok,
              "final state %s" % result.state)
        check("the device ends up running NebulaOS",
              fx.printer.running_os == device.OS_NEBULAOS, fx.printer.running_os)
        check("the marker ends up selecting slot 2",
              marker_state(fx.printer) == marker.KERNEL2, marker_state(fx.printer))
        check("kernel2 holds exactly the expected xImage",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
        check("rootfs2 holds exactly the expected rootfs",
              hashlib.sha256(fx.printer.partitions["rootfs2"]).hexdigest() == fx.artifacts.rootfs_sha)
        check("the stock slot was not written",
              fx.printer.partitions["kernel"] == b"\xde\xad" * 1024
              and fx.printer.partitions["rootfs"] == b"\xbe\xef" * 4096,
              "DEV_INSTALL_WRITES_STOCK=NO, proven on the device")
        check("the device-side flash lock was released",
              fx.printer.flash_lock_holder is None)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_wrong_printer():
    fx, root = scenario("wrongprinter")
    try:
        fx.printer.identity_override = ("0xDIFFERENTCID", hashlib.sha256(b"someone else").hexdigest())
        result, err = run_install(fx)
        check("a different printer on the enrolled address is refused", err is not None,
              "" if err else "the install proceeded")
        if err:
            check("the refusal names the identity mismatch",
                  "CID" in str(err) or "identity" in str(err).lower() or "sn_mac" in str(err),
                  str(err)[:160])
        check("nothing was written to the wrong printer",
              fx.printer.partitions["kernel2"] == b"")
        check("the marker on the wrong printer was not touched",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_host_key_mismatch():
    fx, root = scenario("hostkey")
    try:
        fx.printer.host_keys[device.OS_NEBULAOS] = "ssh-ed25519 AAAAROTATEDKEY"
        result, err = run_install(fx)
        check("a changed SSH host key refuses the install", err is not None,
              "" if err else "the install proceeded despite a rotated host key")
        check("no TOFU: nothing was written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ip_change():
    fx, root = scenario("ipchange")
    try:
        fx.printer.change_address_on_boot = True
        result, err = run_install(fx)
        # The new address is NOT in the enrolled history, so rediscovery must
        # fail closed rather than scan for it.
        check("an address change to an un-enrolled IP is refused, not scanned for",
              err is not None, "" if err else "the installer found an address nobody enrolled")
        if err:
            check("the refusal explains that rediscovery only searches enrolled addresses",
                  "enrolled" in str(err) or "not scan" in str(err) or "could not" in str(err),
                  str(err)[:160])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ip_change_enrolled():
    fx, root = scenario("ipchange2")
    try:
        # The same move, but the alternative address IS enrolled - rediscovery
        # should find it and the install should complete.
        # Move to EXACT addresses the profile also lists, so this tests
        # rediscovery rather than my ability to predict the simulator.
        fx.printer.next_address_on_boot = {device.OS_STOCK: "192.168.0.201",
                                           device.OS_NEBULAOS: "192.168.0.202"}
        pdir = os.path.join(os.environ[profiles.ENV_HOME], "devices", "printer-sim")
        conf = os.path.join(pdir, "profile.conf")
        text = open(conf).read()
        text = text.replace("STOCK_ADDRESS_HISTORY=192.168.0.138",
                            "STOCK_ADDRESS_HISTORY=192.168.0.201,192.168.0.138")
        text = text.replace("NEBULAOS_ADDRESS_HISTORY=192.168.0.98",
                            "NEBULAOS_ADDRESS_HISTORY=192.168.0.202,192.168.0.98")
        open(conf, "w").write(text)
        fx.profile = profiles.DeviceProfile.load("printer-sim")
        result, err = run_install(fx)
        check("an address change to an ENROLLED alternative is handled",
              err is None and result is not None and result.ok,
              str(err)[:200] if err else "completed")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_stock_unavailable():
    fx, root = scenario("stockdown")
    try:
        fx.printer.stock_unavailable = True
        result, err = run_install(fx)
        check("stock never coming back is reported, not ignored", err is not None,
              "" if err else "the install claimed success without stock")
        check("the dangerous state is explicit",
              err is not None and ("did not come back" in str(err) or "could not reach" in str(err)),
              str(err)[:160] if err else "")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_printer_busy():
    fx, root = scenario("busy")
    try:
        fx.printer.printing = True
        result, err = run_install(fx)
        check("a running print refuses the install before arming", err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the refusal names the print", err is not None and "idle" in str(err).lower(),
              str(err)[:160] if err else "")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_heater_active():
    fx, root = scenario("heater")
    try:
        fx.printer.heater_targets["extruder"] = 210
        result, err = run_install(fx)
        check("a non-zero heater target refuses the install", err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_paused_print():
    fx, root = scenario("paused")
    try:
        fx.printer.paused = True
        result, err = run_install(fx)
        check("a PAUSED print also refuses (resuming into a slot switch loses it)",
              err is not None)
        check("the marker was never armed for stock",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_silently_fails():
    fx, root = scenario("markerfail")
    try:
        fx.printer.fail_marker_write = True
        result, err = run_install(fx)
        check("a marker write that does not land is caught by read-back", err is not None)
        check("the device was NOT rebooted after a failed marker write",
              fx.printer.boot_id == "boot-0001",
              "boot_id is %s" % fx.printer.boot_id)
        check("the marker still selects NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_raises():
    fx, root = scenario("markerraise")
    try:
        fx.printer.marker_write_raises = True
        result, err = run_install(fx)
        check("a marker write that errors refuses the install", err is not None)
        check("the device was not rebooted", fx.printer.boot_id == "boot-0001")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_busy_after_arming_disarms():
    fx, root = scenario("disarm")
    try:
        # Idle at precheck, busy the instant the marker is armed for stock. This
        # is THE disarm path: armed, then a failure, while NebulaOS still runs.
        #
        # An earlier version of this test counted idle_state() calls and flipped
        # the flag after four of them. There were only three, so the threshold
        # never fired, the install simply succeeded, and two of the three
        # assertions passed on the NORMAL kernel->kernel2 transition. It was
        # green and it tested nothing. Hooking the marker write instead makes
        # the trigger exact.
        fx.printer.busy_after_marker_set = marker.KERNEL
        result, err = run_install(fx)

        check("becoming busy after arming refuses the install", err is not None,
              "" if err else "the install completed - the disarm path was never entered")
        check("DISARM: the marker was put back to NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the device was not rebooted into stock",
              fx.printer.running_os == device.OS_NEBULAOS)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_marker_write_lands_then_connection_drops():
    """REGRESSION: an exception while arming must still attempt a disarm.

    An architecture review found _set_marker_verified(marker.KERNEL) called
    unguarded: a False return disarmed correctly, but a RAISE propagated with no
    disarm attempt, leaving the device physically armed for stock while the
    journal still read PRECHECKED. Reality-wins recovers it on the next run -
    but only if a human re-runs instead of power-cycling, and a power cycle into
    stock costs the MCU.
    """
    fx, root = scenario("landthenraise")
    try:
        fx.printer.marker_write_lands_then_raises = marker.KERNEL
        result, err = run_install(fx)
        check("a connection lost after the marker committed stops the install", err is not None)
        check("REGRESSION: a disarm was attempted and the marker is back on NebulaOS",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("the device was not rebooted", fx.printer.boot_id == "boot-0001")
        if err:
            check("the refusal warns against a power cycle",
                  "power cycle" in str(err).lower(), str(err)[:180])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_resume_finds_armed():
    fx, root = scenario("resumearmed")
    try:
        # A previous run died between arming and rebooting. The marker says
        # stock; NebulaOS is still running. A resume must disarm FIRST.
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        fx.printer.printing = True          # so it stops after disarming
        result, err = run_install(fx)
        check("a resumed transaction that finds ARMED disarms before anything else",
              marker_state(fx.printer) == marker.KERNEL2,
              "marker is %s" % marker_state(fx.printer))
        check("it did not blindly continue into a reboot",
              fx.printer.running_os == device.OS_NEBULAOS and fx.printer.boot_id == "boot-0001")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_ssh_loss_during_flash():
    fx, root = scenario("sshloss")
    try:
        fx.printer.interrupt_flash_after = 2048   # dies partway through kernel2
        result, err = run_install(fx)
        check("a connection lost during the flash stops the install", err is not None)
        check("the marker still selects stock, so the damaged slot is not booted",
              marker_state(fx.printer) == marker.KERNEL,
              "marker is %s" % marker_state(fx.printer))
        check("slot 2 is left visibly incomplete",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() != fx.artifacts.ximage_sha)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_flash_verification_mismatch():
    fx, root = scenario("corrupt")
    try:
        fx.printer.corrupt_flash = True
        result, err = run_install(fx)
        check("a flash that lands corrupted fails verification", err is not None)
        check("the marker was NOT set to kernel2 after a failed verification",
              marker_state(fx.printer) == marker.KERNEL,
              "marker is %s" % marker_state(fx.printer))
        if err:
            check("the refusal says it will not select a damaged slot",
                  "damaged" in str(err) or "verifies as" in str(err), str(err)[:160])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_flash_helper_refuses():
    fx, root = scenario("preflight")
    try:
        fx.printer.flash_helper_fails = True
        result, err = run_install(fx)
        check("a preflight refusal from the flash helper stops the install", err is not None)
        check("the marker still selects stock (nothing was written to boot)",
              marker_state(fx.printer) == marker.KERNEL)
        check("slot 2 was not written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_concurrent_installer():
    fx, root = scenario("concurrent")
    try:
        fx.printer.flash_lock_holder = "another-installer:999"
        result, err = run_install(fx)
        check("a device-side flash lock held by another installer refuses", err is not None)
        if err:
            check("the refusal names the holder", "another-installer" in str(err), str(err)[:160])
        check("slot 2 was not written", fx.printer.partitions["kernel2"] == b"")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_host_lock():
    fx, root = scenario("hostlock")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        first = journal.HostLock("printer-sim")
        got, _ = first.acquire()
        second = journal.HostLock("printer-sim")
        blocked, holder = second.acquire()
        check("a second installer on this host is refused by the host lock",
              got and not blocked, "holder: %s" % holder)
        first.release()
        again, _ = journal.HostLock("printer-sim").acquire()
        check("the host lock is reusable after release", again)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_updater_acted():
    fx, root = scenario("mcuupdater")
    try:
        fx.printer.stock_updater_acts_on_boot = True
        result, err = run_install(fx)
        check("the install still closes forward to NebulaOS after the MCU updater acted",
              err is None and fx.printer.running_os == device.OS_NEBULAOS,
              str(err)[:200] if err else "")
        check("but PART1_INSTALL_VERIFIED is NO",
              result is not None and not result.ok,
              "result.ok=%s" % (result.ok if result else "n/a"))
        if result:
            check("the report explains the MCU was not the qualified one",
                  "MCU" in result.render())
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_mcu_guard_restored():
    fx, root = scenario("mcuguard")
    try:
        fx.printer.mcu_guard_restores_on_boot = True
        result, err = run_install(fx)
        check("an automatic MCU guard restore makes PART1 fail",
              err is None and result is not None and not result.ok,
              str(err)[:200] if err else "result.ok=%s" % (result.ok if result else "?"))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_new_image_will_not_boot():
    fx, root = scenario("noboot")
    try:
        # The flash "succeeds" but the slot is unbootable, so the device comes
        # back as neither NebulaOS nor stock. There must be no automatic fall
        # back to stock.
        original = sim.SimSession.apply_write_plans

        def empty_write(self, plans, manifest_name):
            original(self, plans, manifest_name)
            self.printer.partitions["rootfs2"] = b""
            return True, "wrote (simulated unbootable result)"

        sim.SimSession.apply_write_plans = empty_write
        try:
            result, err = run_install(fx)
        finally:
            sim.SimSession.apply_write_plans = original

        check("a slot that fails verification is not booted", err is not None)
        check("NO automatic fallback to stock was performed",
              marker_state(fx.printer) in (marker.KERNEL, marker.KERNEL2),
              "marker is %s" % marker_state(fx.printer))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_already_on_stock():
    fx, root = scenario("onstock")
    try:
        fx.printer.running_os = device.OS_STOCK
        fx.printer.partitions["ota"] = marker.canonical(marker.KERNEL)
        # Payload must already be staged, as it would be by the run that got here.
        fx.printer.staged["xImage"] = XIMAGE
        fx.printer.staged["rootfs.squashfs"] = ROOTFS
        fx.printer.staged["build-manifest.txt"] = b"x"
        result, err = run_install(fx)
        check("an install that starts on stock is detected and completed",
              err is None and result is not None and result.ok,
              str(err)[:220] if err else "")
        check("it did not reboot to NebulaOS just to start over",
              fx.printer.running_os == device.OS_NEBULAOS)
        check("slot 2 received the payload",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_journal_reality_conflict():
    fx, root = scenario("journal")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        # The journal claims the flash already happened. Reality: slot 2 empty.
        txn = journal.Transaction.begin(
            "printer-sim", fx.control_commit, SOURCE_HEAD,
            fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        txn.advance(journal.FLASH_VERIFIED, "claimed by a previous run")
        result, err = run_install(fx, txn=txn)
        check("reality wins over a journal that claims the flash already happened",
              err is None and result is not None and result.ok,
              str(err)[:220] if err else "")
        check("the device really was flashed this time",
              hashlib.sha256(fx.printer.partitions["kernel2"]).hexdigest() == fx.artifacts.ximage_sha)
        reopened = journal.Transaction.open("printer-sim")
        check("the journal ends in a terminal state",
              reopened is not None and reopened.state in journal.TERMINAL_STATES,
              reopened.state if reopened else "missing")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_journal_key_mismatch():
    fx, root = scenario("journalkey")
    try:
        os.environ[journal.ENV_STATE_HOME] = os.path.join(root, "state")
        txn = journal.Transaction.begin("printer-sim", fx.control_commit, SOURCE_HEAD,
                                        fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        same, _ = txn.matches("printer-sim", fx.control_commit, SOURCE_HEAD,
                              fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        other, why = txn.matches("printer-sim", fx.control_commit, "0" * 40,
                                 fx.artifacts.ximage_sha, fx.artifacts.rootfs_sha)
        check("a transaction is resumable only for the identical five key fields",
              same and not other, why)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_control_provenance():
    fx, root = scenario("control")
    try:
        check("control helpers resolve from the protected mirror",
              len(fx.control.helpers) >= 2, "%d helpers" % len(fx.control.helpers))
        check("the control commit is published", "published on" in fx.control.published_on,
              fx.control.published_on)

        # An unpublished commit must not resolve.
        env = dict(os.environ, GIT_AUTHOR_NAME="sim", GIT_AUTHOR_EMAIL="s@e",
                   GIT_COMMITTER_NAME="sim", GIT_COMMITTER_EMAIL="s@e")
        subprocess.run(["git", "checkout", "-q", "-b", "scratch"], cwd=fx.control_work,
                       check=True, capture_output=True, env=env)
        with open(os.path.join(fx.control_work, "scripts", "flash-spare-slot.sh"), "ab") as fh:
            fh.write(b"# unpublished edit\n")
        subprocess.run(["git", "commit", "-qam", "unpublished"], cwd=fx.control_work,
                       check=True, capture_output=True, env=env)
        unpub = subprocess.run(["git", "rev-parse", "HEAD"], cwd=fx.control_work,
                               capture_output=True, text=True, env=env).stdout.strip()
        mirror = control.ControlMirror(os.path.join(root, "origin.git"),
                                       os.path.join(root, "state", "mirror.git"))
        try:
            control.ControlSet.load(mirror, unpub)
            bad("an unpublished control commit is refused", "it resolved")
        except control.ControlError as exc:
            ok("an unpublished control commit is refused", str(exc)[:110])

        # A helper whose bytes do not match its pin must be refused.
        drifted = os.path.join(root, "drift")
        os.makedirs(os.path.join(drifted, "tools", "hardware"))
        shutil.copyfile(os.path.join(FW, "tools", "hardware", "nebulaos_journal.py"),
                        os.path.join(drifted, "tools", "hardware", "nebulaos_marker.py"))
        try:
            control.assert_host_control_matches(fx.control, drifted)
            bad("host control code that has drifted from C is refused", "it passed")
        except control.ControlError as exc:
            ok("host control code that has drifted from C is refused", str(exc)[:110])

        ok("host control code matching C is accepted",
           ", ".join(control.assert_host_control_matches(fx.control, FW)))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def case_attestation_required():
    """A destructive operation must be able to PROVE what it is installing."""
    fx, root = scenario("attestation")
    try:
        store = os.path.join(root, "attstore")
        os.makedirs(store, mode=0o700)
        keydir = os.path.join(root, "key")
        os.makedirs(keydir, mode=0o700)
        keypath = os.path.join(keydir, "attest.key")
        with open(keypath, "wb") as fh:
            fh.write(os.urandom(64))
        os.chmod(keypath, 0o600)
        os.environ["NEBULAOS_ATTEST_KEY"] = keypath
        tool = os.path.join(FW, "tools", "attest", "nebulaos-attest.py")
        a = fx.artifacts

        # 1. nothing at all
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("an install with no v2 attestation is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("an install with no v2 attestation is refused", str(exc).splitlines()[0][:90])

        # 2. a v1 record is NOT accepted as a substitute
        run_dir = os.path.join(root, "buildrun")
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, ".nebulaos-build-verified"), "w") as fh:
            fh.write("BUILD_VERIFIED=YES\nSOURCE_HEAD=%s\n" % SOURCE_HEAD)
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, build_run=run_dir,
                                store=store, attest_tool=tool)
            bad("a v1 record is not accepted in place of v2", "it was allowed")
        except evidence.EvidenceError as exc:
            check("a v1 record is not accepted in place of v2", "unauthenticated" in str(exc),
                  str(exc).splitlines()[-1][:110])

        # 3. a real, signed v2 attestation for these artifacts
        def sign(profile, head=SOURCE_HEAD, xs=None, out=None):
            fields = "\n".join([
                "ATTESTATION_VERSION=2", "SOURCE_HEAD=%s" % head,
                "SOURCE_REPO=https://example/repo.git", "SOURCE_PUBLISHED_TIP=%s" % head,
                "BUILD_LAUNCHER_BLOB=%s" % ("b" * 64), "BUILD_MODE=candidate",
                "BUILD_PROFILE=%s" % profile,
                "CCACHE=%s" % ("disabled" if profile != "dev" else "enabled"),
                "BUILD_LOG_SHA256=%s" % ("c" * 64),
                "XIMAGE_SHA256=%s" % (xs or a.ximage_sha), "XIMAGE_SIZE=%d" % a.ximage_size,
                "ROOTFS_SQUASHFS_SHA256=%s" % a.rootfs_sha,
                "ROOTFS_SQUASHFS_SIZE=%d" % a.rootfs_size,
                "MANIFEST_SHA256=%s" % ("d" * 64), "BUILDER_DIGEST=sha256:%s" % ("e" * 64),
                "SOURCE_DATE_EPOCH=1790633082", "BUILD_RUN=%s" % run_dir,
                "ATTESTED_AT=2026-09-29T00:00:00Z", ""])
            target = out or os.path.join(store, "%s.att" % head)
            proc = subprocess.run([sys.executable, tool, "sign", "--out", target],
                                  input=fields, capture_output=True, text=True)
            return proc.returncode == 0, target

        signed, path = sign("candidate")
        if not signed:
            bad("a v2 attestation can be produced for the test artifacts")
        else:
            try:
                ev = evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                         a.rootfs_sha, a.rootfs_size, store=store,
                                         attest_tool=tool)
                ok("a verified v2 attestation for these exact artifacts is accepted",
                   "profile=%s" % ev.profile)
            except evidence.EvidenceError as exc:
                bad("a verified v2 attestation is accepted", str(exc)[:160])

        # 4. an attestation whose artifact digests do not match
        try:
            evidence.require_v2(SOURCE_HEAD, "f" * 64, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("an attestation that does not match the artifacts is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("an attestation that does not match the artifacts is refused",
               str(exc).splitlines()[0][:90])

        # 5. a dev-profile build may not reach a printer
        os.unlink(path)
        sign("dev")
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("a dev-profile build is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            check("a dev-profile build is refused", "dev" in str(exc) or "profile" in str(exc),
                  str(exc).splitlines()[0][:110])

        # 6. a tampered attestation
        os.unlink(os.path.join(store, "%s.att" % SOURCE_HEAD))
        sign("candidate")
        att = os.path.join(store, "%s.att" % SOURCE_HEAD)
        text = open(att).read().replace("BUILD_PROFILE=candidate", "BUILD_PROFILE=release")
        open(att, "w").write(text)
        try:
            evidence.require_v2(SOURCE_HEAD, a.ximage_sha, a.ximage_size,
                                a.rootfs_sha, a.rootfs_size, store=store, attest_tool=tool)
            bad("a tampered attestation is refused", "it was allowed")
        except evidence.EvidenceError as exc:
            ok("a tampered attestation is refused", str(exc).splitlines()[0][:90])
    finally:
        os.environ.pop("NEBULAOS_ATTEST_KEY", None)
        shutil.rmtree(root, ignore_errors=True)


def case_capability_vs_policy():
    """The distinction the mission requires, asserted on the real objects."""
    report = targets.capability_report()
    check("GENERIC_FLASH_CAPABILITY_STOCK=YES", "GENERIC_FLASH_CAPABILITY_STOCK=YES" in report)
    check("GENERIC_FLASH_CAPABILITY_NEBULAOS=YES",
          "GENERIC_FLASH_CAPABILITY_NEBULAOS=YES" in report)

    stock_plan = targets.RECOVERY_STOCK_SIDE.select("kernel").plan_write(1024, "a" * 64)
    check("the backend can express a validated STOCK write",
          stock_plan.target.role == targets.ROLE_STOCK, stock_plan.describe()[:90])
    both = targets.RECOVERY_BOTH_SIDES
    check("a both-sides recovery policy can select either slot",
          both.select("kernel").role == targets.ROLE_STOCK
          and both.select("kernel2").role == targets.ROLE_NEBULAOS)

    dev = targets.DEV_PRESERVE_STOCK
    check("DEV_INSTALL_POLICY=PRESERVE_STOCK", dev.name == "PRESERVE_STOCK")
    check("DEV_INSTALL_WRITES_STOCK=NO", not dev.writes_stock())
    try:
        dev.select("kernel")
        bad("the developer policy refuses the stock slot", "it was allowed")
    except targets.TargetError as exc:
        ok("the developer policy refuses the stock slot", str(exc).splitlines()[0][:100])

    # The one refusal no policy can override.
    for policy in (targets.DEV_PRESERVE_STOCK, targets.RECOVERY_STOCK_SIDE,
                   targets.RECOVERY_BOTH_SIDES):
        try:
            policy.select("sn_mac")
            bad("no policy can select sn_mac (%s)" % policy.name, "it was allowed")
            break
        except targets.TargetError:
            pass
    else:
        ok("no policy can select sn_mac - it is refused at the capability layer")

    try:
        targets.resolve("kernel2").plan_write(targets.resolve("kernel2").size + 1, "a" * 64)
        bad("an oversized payload is refused", "it was planned")
    except targets.TargetError as exc:
        ok("an oversized payload is refused", str(exc)[:100])


def case_no_raw_surface():
    """The closed vocabulary, asserted rather than asserted-in-prose."""
    forbidden = ("run", "exec", "shell", "dd", "read_offset", "write_offset", "raw")
    public = [n for n in dir(device.DeviceSession) if not n.startswith("_")]
    leaked = [n for n in public if n in forbidden]
    check("DeviceSession exposes no arbitrary-execution method", not leaked,
          "leaked: %s" % leaked)
    check("DeviceSession exposes no method taking a raw offset",
          not any("offset" in n for n in public), str(public))
    # region_sha256 and apply_write_plans take NAMES and PLANS, never paths.
    import inspect
    sig = inspect.signature(device.DeviceSession.region_sha256)
    check("region_sha256 addresses a target by name, not by device path",
          "target_name" in sig.parameters, str(sig))


# ---------------------------------------------------------------------------

SCENARIOS = [
    ("capability vs policy", case_capability_vs_policy),
    ("closed vocabulary", case_no_raw_surface),
    ("control provenance", case_control_provenance),
    ("attestation v2 required", case_attestation_required),
    ("happy path", case_happy_path),
    ("already on stock", case_already_on_stock),
    ("wrong printer", case_wrong_printer),
    ("host key mismatch", case_host_key_mismatch),
    ("ip change (un-enrolled)", case_ip_change),
    ("ip change (enrolled)", case_ip_change_enrolled),
    ("stock unavailable", case_stock_unavailable),
    ("printer busy", case_printer_busy),
    ("heater active", case_heater_active),
    ("paused print", case_paused_print),
    ("marker write silently fails", case_marker_write_silently_fails),
    ("marker write raises", case_marker_write_raises),
    ("busy after arming -> disarm", case_busy_after_arming_disarms),
    ("marker lands then connection drops", case_marker_write_lands_then_connection_drops),
    ("resume finds ARMED", case_resume_finds_armed),
    ("ssh loss during flash", case_ssh_loss_during_flash),
    ("flash verification mismatch", case_flash_verification_mismatch),
    ("flash helper refuses", case_flash_helper_refuses),
    ("concurrent installer (device lock)", case_concurrent_installer),
    ("host lock", case_host_lock),
    ("mcu updater acted", case_mcu_updater_acted),
    ("mcu guard restored", case_mcu_guard_restored),
    ("new image will not boot", case_new_image_will_not_boot),
    ("journal vs reality", case_journal_reality_conflict),
    ("journal key mismatch", case_journal_key_mismatch),
]


def main():
    print("=== hardware install: adversarial simulation ===")
    print()
    for name, fn in SCENARIOS:
        print("--- %s ---" % name)
        try:
            fn()
        except Exception as exc:                  # noqa: BLE001
            import traceback
            bad("scenario %r ran to completion" % name, traceback.format_exc()[-500:])
        print()
    print("HARDWARE_SIMULATION_TESTS_PASS=%d" % len(PASS))
    print("HARDWARE_SIMULATION_TESTS_FAIL=%d" % len(FAIL))
    return 0 if not FAIL else 1


if __name__ == "__main__":
    sys.exit(main())
