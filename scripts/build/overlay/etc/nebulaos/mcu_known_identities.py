"""Known MCU application-firmware identities for the KE GD32F303.

Distinguishes APPLICATION identity (which firmware is currently running,
read via Klipper's own MCU IDENTIFY protocol - see mcu_application_identify.py)
from HARDWARE identity (which physical MCU/bootloader is present, read via
creality_flash.py's bootloader protocol). These are NOT the same thing: the
bootloader hardware ID (mcu0_001_G32-mcu0_005_000) has been observed
identical whether candidate-001 or stock Creality firmware is installed
(compare _evidence/phase1.8-candidate/identity-query-result.txt, taken with
candidate-001 flashed, against phase1.8-os-candidate-004.txt's
LIVE_MCU_HW_ID, taken moments after the stock slot had just auto-flashed
stock firmware back on - both report mcu0_001_G32). Only the APPLICATION
identity (Klipper's own `version` field) tells you which firmware is
actually running.

Values below are not invented: they are exactly what's already on file in
this repo's own build evidence.
"""

# The exact `version` string in candidate-001's own compiled MCU dictionary.
# Source: _evidence/phase1.8-candidate/klipper.dict -> "version" field.
# This is a git-describe string against upstream Klipper 58bd67db plus the
# one native-support patch (commit 01a9c2f92) - see
# _evidence/phase1.8-candidate/phase1.8-candidate-001.txt for the exact
# provenance chain (MCU_REPO_COMMIT, PATCH_COMMIT, PACKAGED_BIN_SHA256).
NATIVE_CANDIDATE_001_VERSION = "v0.13.0-742-g01a9c2f92"

# candidate-001's packaged binary hash, for the restore path (mcu_restore.py).
# Source: _evidence/phase1.8-candidate/phase1.8-candidate-001.txt, PACKAGED_BIN_SHA256.
NATIVE_CANDIDATE_001_SHA256 = (
    "c2db4f34586c5df88b0d8d40e1d2d1c0f3bea90ab879c7c3a1ccc3a64f91db0c"
)

# Exact stock Creality application version string(s) observed on this unit.
# Source: printer/objects/query?mcu -> mcu_version, observed identically on
# 2026-08-22 (_evidence/phase1.8-candidate/identity-query-result.txt) and
# 2026-08-28 (_evidence/reports/2026-08-28-phase1.8-live-verification/).
# This is a SINGLE-SAMPLE observation of one hardware unit's one firmware
# build - it is NOT a verified family/pattern across all possible Creality
# firmware versions. Do not assume a future Creality update produces this
# exact string. Only exact matches here authorize a restore; anything else
# (including a plausible-looking but different Creality-style string) must
# classify as UNKNOWN_APPLICATION, never auto-restored, pending a human
# decision to add the new string to this tuple.
KNOWN_STOCK_VERSIONS = (
    "38d96adc-dirty-20231016_135251-longer-virtual-machine",
)

NATIVE_CANDIDATE_001 = "NATIVE_CANDIDATE_001"
KNOWN_STOCK = "KNOWN_STOCK"
UNKNOWN_APPLICATION = "UNKNOWN_APPLICATION"


def classify_application_identity(version_string):
    """Classify a Klipper MCU `version` string into one of the three
    application-identity classes. Exact string match only - no prefix/regex
    guessing, since a guessed match that's wrong is worse than an honest
    UNKNOWN_APPLICATION requiring a human decision."""
    if version_string == NATIVE_CANDIDATE_001_VERSION:
        return NATIVE_CANDIDATE_001
    if version_string in KNOWN_STOCK_VERSIONS:
        return KNOWN_STOCK
    return UNKNOWN_APPLICATION
