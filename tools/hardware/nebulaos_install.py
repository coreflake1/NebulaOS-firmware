"""The developer install: NebulaOS -> Stock -> flash -> NebulaOS, as a state machine.

THE OPERATION, AND WHY IT GOES THROUGH STOCK AT ALL

NebulaOS lives in slot 2. A running system cannot overwrite the partitions it is
executing from - an earlier version of this project tried, landed a write on the
live rootfs, and needed a manual power cycle to recover. So installing a new
NebulaOS means booting something else first, and the only something else is
Creality's slot 1.

That makes stock a dependency of the install, which is why so much of this file
is about proving stock will work BEFORE committing to it.

THE DANGEROUS WINDOW

From the moment the marker is set to ota:kernel until the moment a verified
NebulaOS is running again, the printer is either about to boot stock or is
booting stock. Booting stock is survivable; POWER-CYCLING into stock is what
lets its MCU updater reflash the GD32 with Creality firmware, destroying the
qualified MCU build. This project can perform a software reboot and cannot
perform a power cycle, so the window is survivable by construction - but the
journal and the output both say POWER_CYCLE_DANGEROUS=YES throughout it, because
a human pulling the plug at the wrong moment is the remaining risk.

ARMED, AND DISARMING

"ARMED_STOCK" means: NebulaOS is still running, and the marker says boot stock.
It is a real, recoverable state, and every failure that happens in it must undo
it - set the marker back to kernel2, flush, read the bytes back, confirm. A
failure that leaves the marker armed turns the next unrelated reboot into an
unplanned trip to stock.

A resumed transaction that finds NebulaOS running with the marker on stock
disarms FIRST, before considering anything else. It does not continue forward on
the assumption that it must have meant to.

ONCE SLOT 2 IS VERIFIED, THE MARKER IS THE NEXT THING

Not log collection, not a status report, not a health check. The device is
sitting on stock with a freshly written NebulaOS slot; the single most valuable
next byte is the one that points the bootloader back at it. Everything else can
happen after.

REALITY WINS

The journal says what a previous process intended. Every decision here is made
from what the device says now: which OS is running, what the active root is,
what the boot id is, what the marker bytes are, what the slot hashes are. The
journal is consulted to understand an in-progress transaction, never to skip a
check.
"""

import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nebulaos_device as device      # noqa: E402
import nebulaos_journal as journal    # noqa: E402
import nebulaos_marker as marker      # noqa: E402
import nebulaos_target as targets     # noqa: E402
import nebulaos_verify as verify      # noqa: E402


class InstallError(Exception):
    """An install that stopped. Carries the state it stopped in."""

    def __init__(self, message, state=None, disarmed=None):
        super().__init__(message)
        self.state = state
        self.disarmed = disarmed


class Artifacts:
    """The exact product build being installed."""

    def __init__(self, source_head, ximage_path, rootfs_path, manifest_path,
                 ximage_sha, ximage_size, rootfs_sha, rootfs_size):
        self.source_head = source_head
        self.ximage_path = ximage_path
        self.rootfs_path = rootfs_path
        self.manifest_path = manifest_path
        self.ximage_sha = ximage_sha
        self.ximage_size = ximage_size
        self.rootfs_sha = rootfs_sha
        self.rootfs_size = rootfs_size

    def total_bytes(self):
        return self.ximage_size + self.rootfs_size

    def describe(self):
        return "\n".join([
            "PRODUCT_HEAD=%s" % self.source_head,
            "PRODUCT_XIMAGE_SHA256=%s" % self.ximage_sha,
            "PRODUCT_XIMAGE_SIZE=%d" % self.ximage_size,
            "PRODUCT_ROOTFS_SHA256=%s" % self.rootfs_sha,
            "PRODUCT_ROOTFS_SIZE=%d" % self.rootfs_size,
        ])


class InstallResult:
    def __init__(self):
        self.lines = []
        self.state = journal.SAFE_NEBULAOS
        self.part1 = None
        self.disarmed = False
        self.ok = False

    def say(self, text):
        self.lines.append(text)

    def render(self):
        out = list(self.lines)
        out.append("")
        out.append("INSTALL_FINAL_STATE=%s" % self.state)
        out.append("INSTALL_DISARM_PERFORMED=%s" % ("YES" if self.disarmed else "NO"))
        out.append("PART1_INSTALL_VERIFIED=%s" % ("YES" if self.ok else "NO"))
        out.append("HARDWARE_QUALIFIED=NO")
        return "\n".join(out)


class Installer:
    """Drives one install. Talks to the device only through DeviceSession.

    `session_factory(which_os, address) -> DeviceSession` is the single seam
    between this logic and the transport. Production passes an SSH factory;
    tests pass one backed by a simulator. Nothing else in this class knows which
    it got, which is what makes every adversarial path testable offline.
    """

    # Bounded waits. Injected clock/sleep so tests do not actually sleep.
    REBOOT_GONE_TIMEOUT = 120
    REBOOT_BACK_TIMEOUT = 300

    def __init__(self, device_id, profile, control_set, artifacts, session_factory,
                 policy=None, txn=None, sleep=time.sleep, now=time.time):
        self.device_id = device_id
        self.profile = profile
        self.control = control_set
        self.artifacts = artifacts
        self.session_factory = session_factory
        self.policy = policy or targets.DEV_PRESERVE_STOCK
        self.txn = txn
        self.sleep = sleep
        self.now = now
        self.result = InstallResult()

    # -- helpers -----------------------------------------------------------
    def _say(self, text):
        self.result.say(text)

    def _advance(self, state, note=""):
        self.result.state = state
        if self.txn:
            self.txn.advance(state, note)
        self._say("STATE=%s%s" % (state, ("  (%s)" % note) if note else ""))

    def _connect(self, which_os, addresses=None):
        """Find the printer and prove it is ours before returning a session.

        Tries each candidate address in turn. An address that answers but is the
        wrong machine is not a fallback - it is the exact thing this refuses.
        """
        import nebulaos_profile as profiles
        candidates = addresses or profiles.candidate_addresses(self.profile, which_os)
        if not candidates:
            raise InstallError(
                "no known address for this printer while it runs %s. Rediscovery searches only "
                "the addresses a human enrolled - it does not scan." % which_os,
                state=self.result.state)

        problems = []
        for address in candidates:
            if not profiles.is_private_ipv4(address):
                problems.append("%s is not an RFC1918 address" % address)
                continue
            try:
                session = self.session_factory(which_os, address)
            except Exception as exc:
                problems.append("%s: %s" % (address, str(exc)[:120]))
                continue
            try:
                identity = session.probe_identity()
                ok, why = self.profile.identity_matches(identity)
                if not ok:
                    session.close()
                    problems.append("%s: %s" % (address, why))
                    continue
                self._say("CONNECTED=%s os=%s identity=matched" % (address, which_os))
                return session, address
            except Exception as exc:
                try:
                    session.close()
                except Exception:
                    pass
                problems.append("%s: %s" % (address, str(exc)[:120]))

        raise InstallError(
            "could not reach the enrolled printer as %s. Tried: %s"
            % (which_os, "; ".join(problems)), state=self.result.state)

    def _read_marker(self, session):
        block = session.read_marker_block()
        state, why = marker.parse(block)
        self._say("OTA_MARKER=%s (%s)" % (state, why))
        return state, why

    def _set_marker_verified(self, session, want):
        """Set the marker and prove it landed, by reading the physical bytes back.

        A marker write that is not read back is a marker write that might not
        have happened. This is the operation the whole slot dance depends on.
        """
        session.write_marker(want)
        block = session.read_marker_block()
        ok, why = marker.verify_readback(want, block)
        self._say("OTA_MARKER_WRITE=%s readback_ok=%s (%s)" % (want, "YES" if ok else "NO", why))
        return ok, why

    def _disarm(self, session, reason):
        """NebulaOS is running and the marker says stock. Put it back.

        Returns True only when the marker has been physically re-read as
        kernel2. Anything less is reported as a dangerous state rather than
        quietly tolerated.
        """
        self._say("DISARMING=YES reason=%s" % reason)
        self._advance(journal.CLOSE_BACKWARD, "disarming: %s" % reason)
        try:
            ok, why = self._set_marker_verified(session, marker.KERNEL2)
        except Exception as exc:
            self._say("DISARM_FAILED=YES detail=%s" % str(exc)[:200])
            return False
        self.result.disarmed = ok
        if not ok:
            self._say("DISARM_FAILED=YES detail=%s" % why)
        return ok

    def _wait_for_reboot(self, which_os, previous_boot_id, addresses=None):
        """Wait for the device to go away and come back as `which_os`.

        The proof that a reboot happened is a CHANGED boot id, not that a
        connection succeeded - a connection can succeed because the device never
        went down at all.
        """
        deadline = self.now() + self.REBOOT_BACK_TIMEOUT
        last = ""
        while self.now() < deadline:
            try:
                session, address = self._connect(which_os, addresses)
            except InstallError as exc:
                last = str(exc)[:160]
                self.sleep(5)
                continue
            try:
                now_boot = session.boot_id()
                if previous_boot_id and now_boot == previous_boot_id:
                    last = "boot_id unchanged (%s) - the device has not rebooted yet" % now_boot[:8]
                    session.close()
                    self.sleep(5)
                    continue
                running = session.which_os()
                if running != which_os:
                    last = "running %s, waiting for %s" % (running, which_os)
                    session.close()
                    self.sleep(5)
                    continue
                self._say("REBOOT_OBSERVED=YES os=%s boot_id=%s->%s"
                          % (which_os, (previous_boot_id or "?")[:8], (now_boot or "?")[:8]))
                return session, address
            except Exception as exc:
                last = str(exc)[:160]
                try:
                    session.close()
                except Exception:
                    pass
                self.sleep(5)
        raise InstallError(
            "the device did not come back as %s within %ds. Last: %s"
            % (which_os, self.REBOOT_BACK_TIMEOUT, last), state=self.result.state)

    # -- the phases --------------------------------------------------------
    def _precheck_on_nebulaos(self, session):
        """Everything that must be true before the marker is touched."""
        self._say("")
        self._say("--- preconditions, checked while retreat is still free ---")
        self._say("MCU_CONSEQUENCE=this install boots Creality's slot, whose updater may reflash "
                  "the GD32 MCU with stock firmware. NebulaOS's guard gets ONE bounded restore "
                  "attempt on the way back; PART1 requires that restore to be confirmed.")

        root = session.active_root()
        self._say("ACTIVE_ROOT=%s" % root)
        if root != "/dev/mmcblk0p8":
            raise InstallError(
                "NebulaOS should be running from /dev/mmcblk0p8 but root=%s. Refusing to plan a "
                "slot switch from an unexpected root." % root, state=self.result.state)

        idle = verify.idle_proof(session)
        self._say(idle.render())
        if not idle.ok():
            raise InstallError(
                "the printer is not idle: %s. A slot switch during a job loses the job, and a hot "
                "heater with no firmware to manage it is worse."
                % session.idle_state().why_not_idle(), state=self.result.state)

        wayout = verify.stock_wayout_proof(session, self.profile, self.artifacts.total_bytes())
        self._say(wayout.render())
        if not wayout.ok():
            raise InstallError(
                "the Stock way-out proof failed: %s. Refusing to set the stock marker - after the "
                "reboot, stock is the only way to continue or to undo anything."
                % "; ".join(c.name for c in wayout.failures()), state=self.result.state)
        return True

    def _stage(self, session):
        """Put the payload and the control helpers on the device, and hash them there.

        Helper bytes come from the control commit's git objects, never from the
        working tree. The payload comes from the attested build.
        """
        self._say("")
        self._say("--- staging ---")
        staged = {}
        for name, path in (("xImage", self.artifacts.ximage_path),
                           ("rootfs.squashfs", self.artifacts.rootfs_path),
                           ("build-manifest.txt", self.artifacts.manifest_path)):
            got = session.stage_file(path, name)
            staged[name] = got
            self._say("STAGED=%s sha256=%s" % (name, got))

        import tempfile
        for control_path in self.control.paths_of_kind("on-device"):
            name = os.path.basename(control_path)
            tmp = os.path.join(tempfile.mkdtemp(prefix=".nebulaos-helper."), name)
            self.control.write_helper(control_path, tmp)
            got = session.stage_file(tmp, name)
            expected = self.control.helper_sha256(control_path)
            os.unlink(tmp)
            if got != expected:
                raise InstallError(
                    "helper %s arrived on the device as %s but the control commit says %s"
                    % (name, got[:16], expected[:16]), state=self.result.state)
            self._say("STAGED_HELPER=%s sha256=%s (from control commit %s)"
                      % (name, got, self.control.commit[:12]))

        if staged.get("xImage") != self.artifacts.ximage_sha:
            raise InstallError("staged xImage hashes %s on the device, expected %s"
                               % (staged.get("xImage"), self.artifacts.ximage_sha),
                               state=self.result.state)
        if staged.get("rootfs.squashfs") != self.artifacts.rootfs_sha:
            raise InstallError("staged rootfs.squashfs hashes %s on the device, expected %s"
                               % (staged.get("rootfs.squashfs"), self.artifacts.rootfs_sha),
                               state=self.result.state)
        return staged

    def _flash_on_stock(self, session):
        """The Stock window. Short on purpose."""
        self._say("")
        self._say("--- stock window: POWER_CYCLE_DANGEROUS=YES ---")

        root = session.active_root()
        self._say("ACTIVE_ROOT=%s" % root)
        if root != "/dev/mmcblk0p7":
            raise InstallError(
                "expected to be running stock from /dev/mmcblk0p7 but root=%s" % root,
                state=journal.STOCK_RUNNING)

        mcu_before = session.mcu_state()
        self._say("STOCK_MCU_UPDATER_MARKER=%s" % mcu_before.get("stock_updater_marker", "unknown"))

        # Re-hash on the device. The payload was staged before a reboot; between
        # then and now the device ran a different OS.
        for name, want in (("xImage", self.artifacts.ximage_sha),
                           ("rootfs.squashfs", self.artifacts.rootfs_sha)):
            got = session.staged_sha256(name)
            self._say("RESTAGED_CHECK=%s sha256=%s" % (name, got))
            if got != want:
                raise InstallError(
                    "staged %s now hashes %s, expected %s - the payload changed across the reboot"
                    % (name, got[:16], want[:16]), state=journal.STOCK_RUNNING)

        owner = "%s:%d" % (self.device_id, os.getpid())
        got_lock, holder = session.acquire_flash_lock(owner)
        if not got_lock:
            raise InstallError(
                "the device-side flash lock is held by %s. Two installers writing one printer is "
                "exactly what this prevents." % holder, state=journal.STOCK_RUNNING)

        try:
            plans = [
                self.policy.select("kernel2").plan_write(
                    self.artifacts.ximage_size, self.artifacts.ximage_sha),
                self.policy.select("rootfs2").plan_write(
                    self.artifacts.rootfs_size, self.artifacts.rootfs_sha),
            ]
            for plan in plans:
                self._say(plan.describe())

            self._advance(journal.FLASHING, "writing the NebulaOS slot")
            ok, report = session.apply_write_plans(plans, "build-manifest.txt")
            self._say(report.strip()[-2000:] if report else "")
            if not ok:
                raise InstallError(
                    "the flash helper reported failure. The marker still selects stock and slot 2 "
                    "must be treated as damaged - refusing to boot it.",
                    state=journal.FLASHING)

            # Verify the BYTES, not the exit code.
            for target_name, want, size in (
                    ("kernel2", self.artifacts.ximage_sha, self.artifacts.ximage_size),
                    ("rootfs2", self.artifacts.rootfs_sha, self.artifacts.rootfs_size)):
                got = session.region_sha256(target_name, size)
                self._say("FLASH_VERIFY=%s sha256=%s expected=%s" % (target_name, got, want))
                if got != want:
                    raise InstallError(
                        "%s verifies as %s, expected %s. Refusing to select a damaged slot."
                        % (target_name, got[:16], want[:16]), state=journal.FLASHING)
        finally:
            session.release_flash_lock(owner)

        self._advance(journal.FLASH_VERIFIED, "slot 2 written and verified")

        # IMMEDIATELY. Nothing between the verification and this.
        ok, why = self._set_marker_verified(session, marker.KERNEL2)
        if not ok:
            raise InstallError(
                "slot 2 is good but the marker could not be set to kernel2 (%s). NOT rebooting: "
                "a reboot now returns to stock with a freshly written NebulaOS slot that nothing "
                "points at." % why, state=journal.FLASH_VERIFIED)
        self._advance(journal.ARMED_NEBULAOS, "marker set to kernel2 and read back")

        mcu_after = session.mcu_state()
        updater_acted = mcu_after.get("stock_updater_marker") == "present" \
            and mcu_before.get("stock_updater_marker") != "present"
        if updater_acted:
            self._say("STOCK_MCU_UPDATER_ACTED=YES")
        return updater_acted

    # -- entry point -------------------------------------------------------
    def run(self):
        """Install, from wherever the device currently is."""
        self._say(self.artifacts.describe())
        self._say(self.control.describe())
        self._say(self.policy.report(prefix="DEV_INSTALL_POLICY"
                                     if self.policy is targets.DEV_PRESERVE_STOCK
                                     else "POLICY"))
        self._say("")

        session, address = self._connect_either()
        running = session.which_os()
        self._say("DEVICE_RUNNING_OS=%s" % running)

        try:
            if running == device.OS_NEBULAOS:
                state, _ = self._read_marker(session)
                if marker.is_armed_for_stock(state):
                    # A resumed or crashed transaction. Disarm FIRST.
                    self._say("")
                    self._say("--- found NebulaOS running with the marker on stock: ARMED_STOCK ---")
                    self._advance(journal.ARMED_STOCK, "discovered on connect")
                    if not self._disarm(session, "resumed transaction found the device armed"):
                        raise InstallError(
                            "found the device armed for stock and could not disarm it. Do not power "
                            "cycle. Resolve the marker by hand before anything else.",
                            state=journal.FAILED_NEEDS_ATTENTION)
                    self._say("DISARMED=YES - restarting the install from a safe state")
                    state, _ = self._read_marker(session)

                if state != marker.KERNEL2:
                    raise InstallError(
                        "the marker is %s while NebulaOS runs. Refusing to proceed from an "
                        "indeterminate marker - the next boot target cannot be predicted." % state,
                        state=journal.FAILED_NEEDS_ATTENTION)

                updater_acted = self._install_from_nebulaos(session)
            elif running == device.OS_STOCK:
                self._say("")
                self._say("--- device is already running stock: entering the stock window ---")
                self._advance(journal.STOCK_RUNNING, "device was already on stock")
                updater_acted = self._install_from_stock(session)
            else:
                raise InstallError(
                    "could not identify the running OS. Refusing to act on an unidentified system.",
                    state=journal.FAILED_NEEDS_ATTENTION)
        finally:
            try:
                session.close()
            except Exception:
                pass

        return self._close_forward(updater_acted)

    def _connect_either(self):
        """Find the printer without yet knowing which OS it is running."""
        import nebulaos_profile as profiles
        problems = []
        for which in (device.OS_NEBULAOS, device.OS_STOCK):
            try:
                session, address = self._connect(which)
                return session, address
            except InstallError as exc:
                problems.append(str(exc)[:200])
        raise InstallError("could not reach the printer as NebulaOS or as stock. %s"
                           % " | ".join(problems), state=self.result.state)

    def _install_from_nebulaos(self, session):
        self._precheck_on_nebulaos(session)
        self._stage(session)
        self._advance(journal.PRECHECKED, "identity, idle, way-out and payload all proven")

        boot_before = session.boot_id()

        # write_ota_marker("ota:kernel") on the device fires the PLR tombstone.
        #
        # Wrapped, because the dangerous case is not "it returned False" - it is
        # "it raised". An SSH drop AFTER conv=fsync has already committed the
        # bytes leaves the device physically armed for stock while this process
        # believes it never got that far. Letting that exception propagate would
        # skip the disarm entirely; the next run would recover it via the
        # ARMED_STOCK path, but only if a human re-runs instead of power-cycling,
        # and a power cycle into stock is what costs the MCU.
        try:
            ok, why = self._set_marker_verified(session, marker.KERNEL)
        except Exception as exc:
            self._say("MARKER_WRITE_RAISED=YES detail=%s" % str(exc)[:200])
            self._disarm(session, "the stock marker write raised; the bytes may have landed")
            raise InstallError(
                "the stock marker write failed with an exception (%s). A disarm was attempted "
                "because the write may still have committed. Do NOT power cycle: if the marker "
                "is on stock, a power cycle boots Creality's slot and reflashes the MCU."
                % str(exc)[:160], state=journal.CLOSE_BACKWARD)
        if not ok:
            self._say("MARKER_WRITE_FAILED=YES - NOT rebooting")
            self._disarm(session, "the stock marker write did not verify")
            raise InstallError(
                "could not set the marker to stock (%s). The device was not rebooted." % why,
                state=journal.SAFE_NEBULAOS)
        self._advance(journal.ARMED_STOCK, "marker=kernel, read back, PLR tombstone fired")
        self._say("POWER_CYCLE_DANGEROUS=YES")

        # Last look before the point of no easy return.
        idle = session.idle_state()
        if not idle.is_idle():
            self._disarm(session, "the printer stopped being idle after arming")
            raise InstallError("the printer became busy after arming (%s); disarmed and stopped."
                               % idle.why_not_idle(), state=journal.CLOSE_BACKWARD)

        try:
            session.reboot()
            self._advance(journal.REBOOTING_TO_STOCK, "software reboot issued")
        except Exception as exc:
            self._disarm(session, "the reboot could not be issued")
            raise InstallError("could not issue the reboot (%s); disarmed and stopped." % exc,
                               state=journal.CLOSE_BACKWARD)
        finally:
            try:
                session.close()
            except Exception:
                pass

        stock_session, _ = self._wait_for_reboot(device.OS_STOCK, boot_before)
        self._advance(journal.STOCK_RUNNING, "rediscovered as stock, identity re-proven")
        try:
            return self._install_from_stock(stock_session)
        finally:
            try:
                stock_session.close()
            except Exception:
                pass

    def _install_from_stock(self, session):
        updater_acted = self._flash_on_stock(session)
        boot_before = session.boot_id()
        session.reboot()
        self._advance(journal.REBOOTING_TO_NEBULAOS, "software reboot issued from stock")
        self._pending_reboot = (device.OS_NEBULAOS, boot_before)
        return updater_acted

    def _close_forward(self, updater_acted):
        which, boot_before = getattr(self, "_pending_reboot", (device.OS_NEBULAOS, ""))
        session, address = self._wait_for_reboot(which, boot_before)
        self._advance(journal.NEBULAOS_RUNNING, "rediscovered as NebulaOS")
        try:
            result = verify.part1_verify(
                session,
                self.artifacts.ximage_sha, self.artifacts.ximage_size,
                self.artifacts.rootfs_sha, self.artifacts.rootfs_size,
                self.artifacts.source_head, profile=self.profile,
                expected_boot_id_changed_from=boot_before)
            mcu_restore = verify.observe_mcu_restore(session)
            self._say("")
            self._say(verify.render_part1(result, self.artifacts.source_head,
                                          mcu_restore_result=mcu_restore))
            self.result.part1 = result
            verified = result.ok()
            if updater_acted:
                # Close forward regardless - the device must end up on NebulaOS -
                # but the install is not verified.
                self._say("")
                self._say("PART1_INSTALL_VERIFIED=NO")
                self._say("# Stock's MCU updater appears to have acted during the window. The "
                          "install completed and the device is back on NebulaOS, but the MCU is "
                          "not the one that was qualified.")
                verified = False
            self.result.ok = verified
            self._advance(journal.DONE if verified else journal.FAILED_NEEDS_ATTENTION,
                          "part1 verified" if verified else "part1 verification failed")
        finally:
            try:
                session.close()
            except Exception:
                pass
        return self.result
