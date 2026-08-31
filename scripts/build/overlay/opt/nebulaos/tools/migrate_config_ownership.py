#!/usr/bin/env python3
"""NebulaOS calibration config-ownership migration (Phase 2 calibration-
framework mission).

Klipper's own configfile.py refuses SAVE_CONFIG for any section/option that
already has a literal value anywhere in the regular (non-autosave) config
text, in ANY included file (`_disallow_include_conflicts`, klippy/
configfile.py) - and aborts the WHOLE SAVE_CONFIG call if even one staged
value conflicts, not just that one field. Before this mission, BLTouch
z_offset, extruder rotation_distance, and extruder/bed PID all had literal
factory-default values in the immutable, image-owned machine.cfg, which
made a real calibration's SAVE_CONFIG (PID_CALIBRATE, PROBE_CALIBRATE,
NEBULAOS_Z_OFFSET_CALIBRATE, NEBULAOS_E_STEPS_CALIBRATE, ...) impossible to
ever persist.

The fix (see docs/NEBULAOS_CALIBRATION_CONFIG_OWNERSHIP.md): machine.cfg no
longer defines these options at all, and the tracked printer.cfg SEED now
ships with a real, pre-baked Klipper SAVE_CONFIG autosave block carrying the
same factory-default values - functionally identical to a device that has
already run SAVE_CONFIG once, at build time, with no calibration drift. A
genuinely fresh device gets this for free (S02nebulaos-namespace copies the
seed verbatim). This tool is ONLY for a device that was already provisioned
by an OLDER image, before this mission - one whose live printer.cfg still
relies on machine.cfg's now-removed literals and does not yet have any of
these 4 sections/options in ITS OWN autosave block.

This is idempotent, per-section, and byte-conservative: it NEVER touches a
section/option that is already present anywhere in the existing autosave
block (that would mean a real (however currently theoretically impossible)
user calibration exists for it, and this tool's whole job is to never
clobber real calibration data) - it only ever ADDS the sections that are
genuinely missing, using the exact same factory-default constants the
tracked seed uses (safe by construction: since SAVE_CONFIG for these 4
sections was architecturally impossible before this mission, no existing
device's true persisted value for them could ever differ from the shipped
factory default). If it cannot confidently parse the existing autosave
region (Klipper's own corruption rules - see _find_autosave_data below),
it backs up and refuses rather than guessing, matching this repo's
existing migrate_printer_cfg() convention in S04nebulaos-migrate.

Standalone and dependency-light on purpose (same convention as this
directory's plr_tombstone.py) - this runs from a plain init-time shell
migration step, not from inside a running Klippy. It reimplements (does
NOT import) Klipper's own AUTOSAVE_HEADER-detection rules from klippy/
configfile.py, because depending on the vendored Klipper checkout from an
early-boot host migration script would be a real ordering hazard (the
Klipper checkout might not even be seeded yet on some paths through
S04nebulaos-migrate). tests/test_migrate_config_ownership.py cross-checks
this reimplementation directly against the real configfile.py's own
_find_autosave_data on shared fixture text, so the two are proven to agree
rather than merely assumed to.

Exit codes: 0 = no action needed or migration succeeded, 1 = refused
(printer.cfg backed up, left untouched - see stderr for why).

Usage: migrate_config_ownership.py <printer.cfg path> [<backup dir>]
"""
import os
import sys
import shutil
import time

# Must stay byte-for-byte identical to klippy/configfile.py's own
# AUTOSAVE_HEADER constant at the pinned commit (58bd67db...) - this is
# the exact string Klipper's own _find_autosave_data() searches for.
# tests/test_migrate_config_ownership.py asserts this equality directly
# against the real pinned source, so a future Klipper pin bump that
# changes this format is caught by a failing test, not a silent drift.
AUTOSAVE_HEADER = (
    "\n#*# <---------------------- SAVE_CONFIG ---------------------->\n"
    "#*# DO NOT EDIT THIS BLOCK OR BELOW. The contents are auto-generated.\n"
    "#*#\n"
)

# The exact same factory-default values the tracked printer.cfg seed ships
# (scripts/build/overlay/opt/printer_data/config/printer.cfg) and machine.cfg
# used to define directly. Keep these two in sync by hand - there is no
# single source of truth to derive both from without adding a build-time
# code-generation step for four constants, which is not worth the
# complexity; a static test asserts the seed file's own autosave block
# matches these constants exactly, so drift is caught, not silent.
FACTORY_DEFAULTS = {
    "bltouch": {"z_offset": "0.000"},
    "extruder": {
        "control": "pid",
        "pid_kp": "20.584",
        "pid_ki": "1.737",
        "pid_kd": "60.981",
        "rotation_distance": "7.530",
    },
    "heater_bed": {
        "control": "pid",
        "pid_kp": "70.652",
        "pid_ki": "1.798",
        "pid_kd": "694.157",
    },
}
# Order matters only for deterministic, readable output - not for
# correctness (Klipper's own parser does not care about section order).
TARGET_SECTIONS = ("bltouch", "extruder", "heater_bed")


def find_autosave_data(data):
    """Reimplements klippy/configfile.py's ConfigAutoSave._find_autosave_data
    EXACTLY (including its own "just warn and treat as empty" behavior on a
    malformed block, rather than raising - test_migrate_config_ownership.py
    cross-checks this against the real function on shared fixtures). Splits
    `data` into (regular_data, autosave_data) where autosave_data has the
    '#*# ' line-prefix already stripped, same as upstream returns it - this
    is the representation a real fileconfig parser expects. Returns
    autosave_data == "" both when there is genuinely no autosave block yet
    (the normal, expected state for a device this migration is meant to
    help) and when an existing one is malformed (matching upstream, which
    logs a warning and carries on rather than treating it as fatal - this
    tool raises RefusedError instead, at the one call site that cares,
    rather than silently discarding a block that might be salvageable by a
    human)."""
    # Deliberately a line-for-line port of the real algorithm's variable
    # structure (not a "cleaner" restructuring) - upstream has at least one
    # non-obvious quirk (an absent header still produces a non-empty-but-
    # blank "\n\n" via the pos<0 short-circuit falling through the same
    # for-loop with autosave_data=""), and matching the real control flow
    # exactly is the only way to be sure every such quirk is reproduced
    # rather than silently "fixed" into a behavioral difference. All
    # downstream callers in this file treat autosave_data by its
    # .strip()'d truthiness, never by plain truthiness, specifically
    # because of this.
    regular_data = data
    autosave_data = ""
    pos = data.find(AUTOSAVE_HEADER)
    if pos >= 0:
        regular_data = data[:pos]
        autosave_data = data[pos + len(AUTOSAVE_HEADER):].strip()
    if "\n#*# " in regular_data or autosave_data.find(AUTOSAVE_HEADER) >= 0:
        return data, ""
    out = [""]
    for line in autosave_data.split("\n"):
        if ((not line.startswith("#*#")
             or (len(line) >= 4 and not line.startswith("#*# ")))
                and autosave_data):
            return data, ""
        out.append(line[4:])
    out.append("")
    return regular_data, "\n".join(out)


def raw_autosave_slice(data):
    """The EXACT on-disk bytes of the autosave region (still '#*# '-prefixed,
    unprocessed) - used only to preserve an existing block byte-for-byte
    when appending new sections to it, never to detect or parse values.
    Callers must already know (via find_autosave_data) that a real,
    non-corrupted block exists before trusting this."""
    pos = data.find(AUTOSAVE_HEADER)
    if pos < 0:
        return ""
    return data[pos + len(AUTOSAVE_HEADER):]


def parse_autosave_sections(autosave_data):
    """Returns {section_lower: {option_lower: raw_value_line}} already
    present in an existing (already-validated, already '#*# '-unprefixed -
    see find_autosave_data) autosave block. Only cares about section/option
    PRESENCE for the skip-if-already-there check, not value semantics - so
    this is intentionally simpler than a real INI parser (no continuation
    lines, no interpolation - Klipper's own writer never emits either for
    the sections this tool cares about)."""
    sections = {}
    current = None
    for line in autosave_data.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current = stripped[1:-1].strip().lower()
            sections.setdefault(current, {})
            continue
        if current is None:
            continue
        for sep in ("=", ":"):
            if sep in stripped:
                key = stripped.split(sep, 1)[0].strip().lower()
                sections[current][key] = stripped
                break
    return sections


def render_missing_sections(existing_sections):
    """Returns the '#*# [section]\\n#*# key = value' text for every target
    section that is not ALREADY present (by section+option, not by value -
    presence of even one already-known option under a target section is
    treated as "this section is already user-owned, do not touch any of
    it", the conservative choice). Empty string if nothing is missing."""
    blocks = []
    for section in TARGET_SECTIONS:
        existing_opts = existing_sections.get(section.lower(), {})
        target_opts = FACTORY_DEFAULTS[section]
        if any(opt in existing_opts for opt in target_opts):
            continue  # already has real data for this section - hands off
        lines = ["#*# [%s]" % section]
        for opt, val in target_opts.items():
            lines.append("#*# %s = %s" % (opt, val))
        blocks.append("\n".join(lines))
    return "\n#*#\n".join(blocks)


def verify_factory_seed(printer_cfg_path):
    """Returns None if printer.cfg's SAVE_CONFIG autosave block (if any)
    contains ONLY the known, tracked FACTORY_DEFAULTS content - safe to
    ship as an immutable build-time seed for every unit - or a human-
    readable string describing why it looks like real, non-factory
    calibration data if not.

    Before this mission, the build's own factory-seed guard
    (04-cross-compile-app-stack.sh) rejected ANY SAVE_CONFIG block at all
    in the tracked printer.cfg, on the theory that the only way one could
    get there is a developer's real device calibration accidentally
    committed. Task 1 of this mission (see this module's own docstring)
    deliberately ships a real, pre-baked, factory-default SAVE_CONFIG
    block for exactly this file, to fix the config-ownership problem - so
    that blanket check is now a guaranteed false positive, found by
    actually running the real pinned build (not by static review). This
    function replaces it with the narrower, still-real check: not "is
    there a SAVE_CONFIG block", but "is its content exactly the known
    factory defaults, byte for byte, nothing more" - still refuses a
    developer's carried-over real calibration data (any extra section, any
    differing value), just no longer refuses the legitimate seed content
    this mission's own fix produces.
    """
    with open(printer_cfg_path, "r") as f:
        data = f.read()
    if data.find(AUTOSAVE_HEADER) < 0:
        return None
    _, autosave_data = find_autosave_data(data)
    if not autosave_data.strip():
        return ("printer.cfg has a SAVE_CONFIG header but its autosave "
                 "block does not parse cleanly (see find_autosave_data) - "
                 "refusing to ship an unparseable factory seed")
    actual = parse_autosave_sections(autosave_data)
    expected = {
        section.lower(): {
            opt.lower(): "%s = %s" % (opt, val)
            for opt, val in FACTORY_DEFAULTS[section].items()
        }
        for section in TARGET_SECTIONS
    }
    if actual != expected:
        return (
            "printer.cfg's SAVE_CONFIG autosave block does not match the "
            "known factory-default content exactly - this looks like "
            "real, non-factory calibration data (a developer's own device "
            "drift, or a genuine calibration run) carried into the "
            "tracked seed. Refusing to ship it as the factory default for "
            "every unit.\nfound:    %r\nexpected: %r" % (actual, expected))
    return None


def _backup(printer_cfg_path, backup_dir, tag):
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    os.makedirs(backup_dir, exist_ok=True)
    backup = os.path.join(backup_dir, "printer.cfg.%s.%s" % (tag, ts))
    shutil.copy2(printer_cfg_path, backup)
    return backup


def migrate(printer_cfg_path, backup_dir):
    with open(printer_cfg_path, "r") as f:
        data = f.read()

    has_header = data.find(AUTOSAVE_HEADER) >= 0
    regular_data, autosave_data = find_autosave_data(data)

    if has_header and not autosave_data.strip() and raw_autosave_slice(data).strip():
        # find_autosave_data (matching upstream Klipper exactly) treats an
        # unparseable existing block as "no usable autosave data" rather
        # than raising - fine for Klipper's own boot-time tolerance, but
        # NOT fine for this tool to build on top of: silently discarding a
        # block a human might still be able to recover, and writing our
        # own fresh one over/near it, is exactly the kind of "guess"
        # migrate_printer_cfg() already refuses to make elsewhere in this
        # repo. Back up and refuse instead.
        backup = _backup(printer_cfg_path, backup_dir,
                         "config-ownership-migration-refused")
        sys.stderr.write(
            "migrate_config_ownership: REFUSED (existing SAVE_CONFIG "
            "autosave block does not parse cleanly) - backed up to %s, "
            "printer.cfg left untouched\n" % backup)
        return 1

    existing_sections = parse_autosave_sections(autosave_data) if autosave_data.strip() else {}
    missing_block = render_missing_sections(existing_sections)
    if not missing_block:
        print("migrate_config_ownership: nothing to do - bltouch/extruder/"
              "heater_bed calibration ownership already present or already "
              "user-owned")
        return 0

    backup = _backup(printer_cfg_path, backup_dir,
                     "pre-config-ownership-migration")

    if has_header:
        # A real autosave block already exists (e.g. from a prior
        # LOAD_CELL_CALIBRATE) - append the missing sections onto the SAME
        # block, preserving its EXACT existing on-disk bytes untouched
        # (never re-derived from the parsed/unprefixed representation, to
        # avoid any risk of subtly reformatting real user data). Klipper's
        # own writer separates sections with a bare "#*#" line; match that
        # so the result is indistinguishable from something Klipper itself
        # wrote.
        new_data = (regular_data.rstrip("\n") + "\n" + AUTOSAVE_HEADER
                    + raw_autosave_slice(data).rstrip("\n")
                    + "\n#*#\n" + missing_block + "\n")
    else:
        new_data = (data.rstrip("\n") + "\n" + AUTOSAVE_HEADER + "\n"
                    + missing_block + "\n")

    # Re-validate the result with the SAME parser before committing -
    # refuse rather than write something even this tool cannot read back.
    _, reparsed_autosave = find_autosave_data(new_data)
    if not reparsed_autosave.strip():
        sys.stderr.write(
            "migrate_config_ownership: INTERNAL ERROR - the autosave block "
            "this tool just built does not parse cleanly. Refusing to "
            "write; original left untouched (backup at %s)\n" % backup)
        return 1

    tmp = printer_cfg_path + ".config-ownership-migrate-tmp"
    with open(tmp, "w") as f:
        f.write(new_data)
    os.rename(tmp, printer_cfg_path)
    print("migrate_config_ownership: added missing calibration-ownership "
          "section(s) to printer.cfg's SAVE_CONFIG block (original backed "
          "up at %s)" % backup)
    return 0


def main(argv):
    if len(argv) == 3 and argv[1] == "--verify-factory-seed":
        error = verify_factory_seed(argv[2])
        if error:
            sys.stderr.write("migrate_config_ownership: %s\n" % error)
            return 1
        print("migrate_config_ownership: %s is a valid factory seed "
              "(no SAVE_CONFIG block, or exactly the known factory "
              "defaults)" % argv[2])
        return 0
    if len(argv) not in (2, 3):
        sys.stderr.write(
            "usage: migrate_config_ownership.py <printer.cfg path> "
            "[<backup dir>]\n"
            "       migrate_config_ownership.py --verify-factory-seed "
            "<printer.cfg path>\n")
        return 2
    printer_cfg_path = argv[1]
    backup_dir = argv[2] if len(argv) == 3 else os.path.join(
        os.path.dirname(printer_cfg_path), ".config-ownership-migration-backups")
    if not os.path.isfile(printer_cfg_path):
        print("migrate_config_ownership: %s does not exist - nothing to do"
              % printer_cfg_path)
        return 0
    return migrate(printer_cfg_path, backup_dir)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
