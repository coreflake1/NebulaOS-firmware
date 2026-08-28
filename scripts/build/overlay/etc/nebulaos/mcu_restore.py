"""MCU candidate restoration - the ONLY module in this lifecycle package
that erases/writes the MCU, and only when mcu_lifecycle.decide() has
already returned RESTORE_AUTHORIZED (known-stock application identity AND
a confirmed-supported bootloader hardware ID).

Artifact provenance (this is a NEW proposed convention - no prior on-device
deployment path for the MCU candidate existed anywhere in this repo before
this module; do not treat the path below as an existing fact):
  - Source of truth for the candidate binary and its hash: NebulaOS-klipper-mcu
    (build-time provenance in phase1.8-candidate-001.txt: MCU_REPO_COMMIT
    3aefd286..., built via that repo's GitHub Actions pipeline). This module
    does not build or fetch the artifact itself - it only validates and
    flashes whatever the OS image's build process already packaged.
  - Proposed on-device install path: /opt/nebulaos/mcu-candidates/<name>.bin
    plus a co-located provenance JSON. The build pipeline is responsible for
    placing the exact GitHub-Actions-built, already-ELF/target-validated
    artifact there - see creality_validator.py's validate_target(), which
    requires arm-none-eabi-readelf and is NOT re-run here (that binutils
    dependency is exactly why stage4_first_flash.py needed --skip-validator
    on-device; the fix is to never require it on-device at all, by doing
    that validation once at build time instead of on every boot).
  - Runtime validation split:
      BUILD TIME (already done, once, in NebulaOS-klipper-mcu's CI):
        - creality_validator.validate_format() / validate_target()
          (ELF section placement, .config sanity, GD32F303-specific checks)
        - exact hash computed and pinned into mcu_known_identities.py
      RUNTIME (this module, every restore attempt):
        - SHA256 verification of the on-device artifact against the pinned
          hash (cheap, no toolchain needed)
        - hardware identity allow-list (already done by mcu_lifecycle.py
          before RESTORE_AUTHORIZED is ever returned)
        - flash-result verification (creality_flash.flash_image()'s own
          status-byte checking)
        - post-flash APPLICATION identity verification (re-run the pre-Klippy
          identify handshake and confirm it now reports exactly
          NATIVE_CANDIDATE_001_VERSION - not just "flash reported success")

SAFETY CONTRACT:
  - Never called except when mcu_lifecycle.decide() returned RESTORE_AUTHORIZED.
  - Refuses to proceed on any hash mismatch or missing artifact.
  - Bounded: exactly one flash attempt per restore() call, no internal retry
    loop, no infinite retry. The caller (the init.d service) may choose to
    retry on a subsequent boot, but this module never loops on its own.
"""

import hashlib
import os

import mcu_application_identify as app_identify
import mcu_known_identities as known

CANDIDATE_PATH = os.environ.get(
    "MCU_CANDIDATE_PATH", "/opt/nebulaos/mcu-candidates/candidate-001.bin")
MCU_SERIAL_PORT = os.environ.get("MCU_SERIAL_PORT", "/dev/ttyS1")
MCU_APP_BAUD = int(os.environ.get("MCU_APP_BAUD", "230400"))

CANDIDATE_ARTIFACT_MISSING = "CANDIDATE_ARTIFACT_MISSING"
CANDIDATE_HASH_BAD = "CANDIDATE_HASH_BAD"
FLASH_FAILED = "FLASH_FAILED"
RESTORED_AND_VERIFIED = "RESTORED_AND_VERIFIED"


class RestoreResult:
    def __init__(self, state, detail=""):
        self.state = state
        self.detail = detail

    def as_dict(self):
        return {"MCU_RESTORE_RESULT": self.state, "MCU_RESTORE_DETAIL": self.detail}


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def restore(creality_flash_module=None, transport_factory=None,
            application_identify_fn=None, candidate_path=None,
            expected_sha256=None, port=None, baud=None,
            file_exists_fn=None, hash_fn=None):
    """Perform exactly one bounded restore attempt. All hardware/filesystem
    interaction points are injectable for testing with mocks."""
    candidate_path = candidate_path or CANDIDATE_PATH
    expected_sha256 = expected_sha256 or known.NATIVE_CANDIDATE_001_SHA256
    port = port or MCU_SERIAL_PORT
    baud = baud or MCU_APP_BAUD
    exists_fn = file_exists_fn or os.path.isfile
    sha_fn = hash_fn or _sha256_file
    identify_fn = application_identify_fn or app_identify.get_application_identity

    if not exists_fn(candidate_path):
        return RestoreResult(
            CANDIDATE_ARTIFACT_MISSING, f"not_found: {candidate_path}")

    actual_hash = sha_fn(candidate_path)
    if actual_hash != expected_sha256:
        return RestoreResult(
            CANDIDATE_HASH_BAD,
            f"expected={expected_sha256} actual={actual_hash}")

    if creality_flash_module is None or transport_factory is None:
        import sys as _sys
        _sys.path.insert(0, os.environ.get("CREALITY_FLASH_PATH", "/opt/nebulaos/tools"))
        import creality_flash as creality_flash_module  # noqa: F811

        def transport_factory():
            return creality_flash_module.SerialTransport(port, baud=baud, timeout=2.0)

    try:
        transport = transport_factory()
        # flash() is the single, already hardware-identity-gated write path
        # in creality_flash.py: it re-checks the bootloader hw-id itself and
        # refuses to erase/write on a mismatch, on top of the check
        # mcu_lifecycle.py already performed before authorizing this call.
        creality_flash_module.flash(transport, candidate_path)
    except creality_flash_module.FlashError as e:
        return RestoreResult(FLASH_FAILED, f"flash_error: {e}")
    except Exception as e:
        return RestoreResult(FLASH_FAILED, f"unexpected_error: {e}")

    # Post-flash verification: the flash reporting success is not sufficient
    # proof - confirm the application identity now actually matches
    # candidate-001, via the same pre-Klippy identify handshake used for the
    # original decision.
    try:
        version, _build_versions = identify_fn(port, baud)
    except Exception as e:
        return RestoreResult(
            FLASH_FAILED, f"post_flash_identify_failed: {e}")

    if known.classify_application_identity(version) != known.NATIVE_CANDIDATE_001:
        return RestoreResult(
            FLASH_FAILED,
            f"post_flash_identity_mismatch: got={version!r} "
            f"expected={known.NATIVE_CANDIDATE_001_VERSION!r}")

    return RestoreResult(RESTORED_AND_VERIFIED, f"application_identity={version}")
