#!/usr/bin/env python3
#
# Offline, repeatable tests for
# scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros (Phase 2
# macro-cleanup/Mainsail-grouping mission, 2026-09-04; extended 2026-09-06,
# RC2 overnight closure, for the hyphenated-ID rename, the legacy-ID
# migration, and the macros.mode=expert fresh-install default). Imports the
# actual production module directly (no parallel copy of the logic) and
# exercises run() with fake get_status/post/delete/sleep callables and a
# temp-directory marker path - no real Moonraker, no real device, no real
# network, ever.
#
# Mirrors tests/nebulaos-seed-camera-tests.py's own structure deliberately -
# same idempotence/never-overwrite/verify-after-write properties, same
# fake-transport pattern, adapted for a per-key database check instead of
# a single-list webcam check.
#
# Usage: python3 tests/nebulaos-seed-mainsail-macros-tests.py

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import shutil
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MODULE_PATH = os.path.join(
    SCRIPT_DIR, "..", "scripts", "build", "overlay", "usr", "libexec",
    "nebulaos-seed-mainsail-macros",
)


def _load_module():
    loader = importlib.machinery.SourceFileLoader("nebulaos_seed_mainsail_macros", MODULE_PATH)
    spec = importlib.util.spec_from_loader("nebulaos_seed_mainsail_macros", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


seed = _load_module()

PASS = 0
FAIL = 0


def check(desc, condition, detail=""):
    global PASS, FAIL
    if condition:
        print(f"PASS: {desc}")
        PASS += 1
    else:
        print(f"FAIL: {desc}" + (f" ({detail})" if detail else ""))
        FAIL += 1


class FakeMoonrakerDb:
    """A tiny, deterministic stand-in for Moonraker's real
    /server/database/item GET/POST/DELETE API - a flat dict of
    {key: value} under the mainsail namespace (any key shape, not just
    macros.macrogroups.<id> - the production module also uses
    macros.mode), plus counters so tests can assert exactly how many
    times each verb was called."""

    def __init__(self, existing=None, available=True):
        self.store = dict(existing or {})
        self.available = available
        self.get_calls = 0
        self.post_calls = 0
        self.delete_calls = 0

    def _key_from_path(self, path):
        assert "namespace=mainsail&key=" in path
        return path.split("key=", 1)[1]

    def get_status(self, path):
        self.get_calls += 1
        if not self.available:
            raise ConnectionError("moonraker not reachable")
        if path == "/server/database/list":
            return 200, json.dumps({"result": {"namespaces": ["mainsail"]}})
        key = self._key_from_path(path)
        if key not in self.store:
            return 404, None
        return 200, json.dumps({
            "result": {"namespace": "mainsail", "key": key, "value": self.store[key]}
        })

    def post(self, path, payload):
        self.post_calls += 1
        assert path == "/server/database/item"
        assert payload["namespace"] == "mainsail"
        key = payload["key"]
        self.store[key] = payload["value"]
        return json.dumps({"result": {"namespace": "mainsail", "key": key, "value": payload["value"]}})

    def delete(self, path):
        self.delete_calls += 1
        key = self._key_from_path(path)
        if key not in self.store:
            return 404, None
        value = self.store.pop(key)
        return 200, json.dumps({"result": {"namespace": "mainsail", "key": key, "value": value}})


def group_key(group_id):
    return f"macros.macrogroups.{group_id}"


TWO_GROUPS = {
    "group_a": {"name": "Group A", "macros": [{"pos": 0, "name": "RUN_A"}]},
    "group_b": {"name": "Group B", "macros": [{"pos": 0, "name": "RUN_B"}]},
}


def with_marker_dir(fn):
    d = tempfile.mkdtemp(prefix="mainsail-macros-seed-test-")
    try:
        return fn(os.path.join(d, "system", "default-mainsail-macros-seeded.json"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_seed(marker_path, moon, groups=None, legacy_map=None, retry_attempts=3, retry_delay=0):
    logs = []
    rc = seed.run(
        get_status=moon.get_status,
        post=moon.post,
        delete=moon.delete,
        marker_path=marker_path,
        log=logs.append,
        groups=groups if groups is not None else TWO_GROUPS,
        legacy_map=legacy_map if legacy_map is not None else {},
        retry_attempts=retry_attempts,
        retry_delay=retry_delay,
        sleep=lambda _s: None,
    )
    return rc, logs


# --- Test 1: Moonraker unavailable - bounded retry, no marker, safe exit ---
def test_moonraker_unavailable():
    def body(marker_path):
        moon = FakeMoonrakerDb(available=False)
        rc, logs = run_seed(marker_path, moon, retry_attempts=3, retry_delay=0)
        check("unavailable: rc==1", rc == 1)
        check("unavailable: attempted exactly retry_attempts GETs",
              moon.get_calls == 3, f"got {moon.get_calls}")
        check("unavailable: no POST calls", moon.post_calls == 0)
        check("unavailable: no marker written", not os.path.exists(marker_path))
        check("unavailable: failure logged",
              any("unavailable" in line or "never became available" in line for line in logs))

    with_marker_dir(body)


# --- Test 2: fresh install, neither group exists - both created and verified ---
def test_fresh_install_creates_both_groups():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc, logs = run_seed(marker_path, moon)
        check("fresh install: rc==0", rc == 0)
        check("fresh install: exactly two group POSTs plus one mode POST",
              moon.post_calls == 3, f"got {moon.post_calls}")
        check("fresh install: both groups now in store",
              set(moon.store.keys()) == {group_key("group_a"), group_key("group_b"), seed.MODE_KEY})
        check("fresh install: group content matches exactly",
              moon.store[group_key("group_a")] == TWO_GROUPS["group_a"]
              and moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])
        check("fresh install: macros.mode defaulted to expert",
              moon.store[seed.MODE_KEY] == "expert")
        with open(marker_path) as f:
            marker = json.load(f)
        check("fresh install: marker records both as created",
              set(marker.get("created", [])) == {"group_a", "group_b"})
        check("fresh install: marker has no failed entries", marker.get("failed") == [])
        check("fresh install: marker records mode_default=seeded",
              marker.get("mode_default") == "seeded")

    with_marker_dir(body)


# --- Test 3: one group already present (e.g. user-edited) - never overwritten ---
def test_existing_group_never_overwritten():
    def body(marker_path):
        user_customized = {"name": "My Custom Group", "macros": [{"pos": 0, "name": "SOMETHING_ELSE"}]}
        moon = FakeMoonrakerDb(existing={group_key("group_a"): user_customized})
        rc, logs = run_seed(marker_path, moon)
        check("existing group: rc==0", rc == 0)
        check("existing group: only one group POST (for group_b) plus mode POST",
              moon.post_calls == 2, f"got {moon.post_calls}")
        check("existing group: group_a completely unchanged",
              moon.store[group_key("group_a")] == user_customized)
        check("existing group: group_b created",
              moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("existing group: marker lists group_a as already_present",
              "group_a" in marker.get("already_present", []))
        check("existing group: marker lists group_b as created",
              "group_b" in marker.get("created", []))

    with_marker_dir(body)


# --- Test 4: second run after a first successful run - fully idempotent, zero POSTs ---
def test_repeated_invocation_is_idempotent():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        rc1, _ = run_seed(marker_path, moon)
        check("idempotent: first run rc==0", rc1 == 0)
        check("idempotent: first run posts (2 groups + mode)", moon.post_calls == 3)

        rc2, logs2 = run_seed(marker_path, moon)
        check("idempotent: second run rc==0", rc2 == 0)
        check("idempotent: second run makes zero additional POSTs",
              moon.post_calls == 3, f"got {moon.post_calls}")
        already_present_lines = [line for line in logs2 if "already present" in line]
        check("idempotent: second run logs both groups as already present",
              len(already_present_lines) == 2, f"got {already_present_lines}")
        check("idempotent: second run leaves macros.mode untouched",
              any("already set to" in line for line in logs2))

    with_marker_dir(body)


# --- Test 5: a NEW group introduced by a later firmware version seeds into an
#     existing, already-seeded install without touching the old ones ---
def test_new_group_added_later_seeds_into_existing_install():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        run_seed(marker_path, moon)  # first boot: only group_a/group_b exist

        three_groups = dict(TWO_GROUPS)
        three_groups["group_c"] = {"name": "Group C", "macros": [{"pos": 0, "name": "RUN_C"}]}
        rc, logs = run_seed(marker_path, moon, groups=three_groups)
        check("new group later: rc==0", rc == 0)
        check("new group later: exactly one new group POST (group_c only)",
              moon.post_calls == 4, f"got {moon.post_calls}")
        check("new group later: group_c now present", group_key("group_c") in moon.store)
        check("new group later: group_a/group_b untouched",
              moon.store[group_key("group_a")] == TWO_GROUPS["group_a"]
              and moon.store[group_key("group_b")] == TWO_GROUPS["group_b"])

    with_marker_dir(body)


# --- Test 6: POST "succeeds" but verification finds different content - failure, group not marked created ---
def test_creation_reports_success_but_verification_mismatches():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})

        def post_but_store_wrong_value(path, payload):
            moon.post_calls += 1
            key = payload["key"]
            if key.startswith("macros.macrogroups."):
                moon.store[key] = {"name": "WRONG", "macros": []}
            else:
                moon.store[key] = payload["value"]
            return json.dumps({"result": {}})

        logs = []
        rc = seed.run(
            get_status=moon.get_status,
            post=post_but_store_wrong_value,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("verification mismatch: rc==1", rc == 1)
        check("verification mismatch: marker still written (records the failure)",
              os.path.exists(marker_path))
        with open(marker_path) as f:
            marker = json.load(f)
        check("verification mismatch: both groups recorded as failed",
              set(marker.get("failed", [])) == {"group_a", "group_b"})
        check("verification mismatch: neither recorded as created",
              marker.get("created") == [])

    with_marker_dir(body)


# --- Test 7: transport error mid-check for one group doesn't block the other ---
def test_one_group_transport_error_does_not_block_the_other():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        real_get = moon.get_status

        def flaky_get(path):
            if "group_a" in path:
                raise ConnectionError("flaky")
            return real_get(path)

        logs = []
        rc = seed.run(
            get_status=flaky_get,
            post=moon.post,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("flaky group: rc==1 (group_a failed)", rc == 1)
        check("flaky group: group_b still created",
              moon.store.get(group_key("group_b")) == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("flaky group: group_a recorded as failed", "group_a" in marker.get("failed", []))
        check("flaky group: group_b recorded as created", "group_b" in marker.get("created", []))

    with_marker_dir(body)


# --- Test 8: real production DEFAULT_GROUPS is well-formed (every macro name
#     a plain non-empty string, every pos unique per group, every group has
#     a name and at least one macro, every group carries its required
#     metadata, and no NebulaOS-managed group ID contains "_" - mission
#     requirement) - catches a typo/duplicate/regression before it ever
#     reaches a real device. ---
def test_default_groups_are_well_formed():
    for group_id, definition in seed.DEFAULT_GROUPS.items():
        check(f"{group_id}: has a non-empty name",
              isinstance(definition.get("name"), str) and definition["name"])
        check(f"{group_id}: contains no underscore (Mainsail's Dashboard.vue "
              "parses a panel name as name.split('_')[1] - an id with a "
              "further underscore breaks that lookup)",
              "_" not in group_id, f"group_id={group_id!r}")
        check(f"{group_id}: has group-level color metadata",
              definition.get("color") == "primary")
        for flag in ("showInStandby", "showInPause", "showInPrinting"):
            check(f"{group_id}: has group-level {flag}=True",
                  definition.get(flag) is True)
        macros = definition.get("macros")
        check(f"{group_id}: has at least one macro",
              isinstance(macros, list) and len(macros) > 0)
        positions = [m.get("pos") for m in macros]
        check(f"{group_id}: macro positions are unique",
              len(positions) == len(set(positions)), f"positions={positions}")
        for m in macros:
            check(f"{group_id}: macro {m.get('name')!r} has a non-empty string name",
                  isinstance(m.get("name"), str) and m["name"])


# --- Test 9: LEGACY_GROUP_ID_MAP itself is well-formed: every value is a
#     real key in DEFAULT_GROUPS, every key is the exact pre-2026-09-06
#     underscore form, and no accidental self-mapping. ---
def test_legacy_group_id_map_is_well_formed():
    for old_id, new_id in seed.LEGACY_GROUP_ID_MAP.items():
        check(f"legacy map: {old_id!r} -> {new_id!r} target exists in DEFAULT_GROUPS",
              new_id in seed.DEFAULT_GROUPS)
        check(f"legacy map: {old_id!r} is a real underscore id (differs from its target)",
              old_id != new_id)


# --- Test 10: a fresh install with no legacy groups at all - migration is a
#     complete no-op, and every legacy id is reported "not_present" ---
def test_migration_noop_on_fresh_install():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "X"}]}},
                             legacy_map=legacy_map)
        check("migration noop: rc==0", rc == 0)
        check("migration noop: no DELETE calls", moon.delete_calls == 0)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration noop: legacy id reported not_present",
              marker.get("migration", {}).get("nebulaos_calibration") == "not_present")

    with_marker_dir(body)


# --- Test 11: the real migration case - an existing install has the old
#     underscore group (possibly user-edited) and nothing under the new
#     hyphenated id yet. Migration must rename it (preserving content
#     exactly, including any user edits), delete the old key, and the
#     default-seed step must then see the new id as already present (never
#     re-seed a fresh default over the user's real data). ---
def test_migration_renames_legacy_group_preserving_user_edits():
    def body(marker_path):
        user_customized = {"name": "My Calibration", "macros": [{"pos": 0, "name": "MY_MACRO"}]}
        moon = FakeMoonrakerDb(existing={"macros.macrogroups.nebulaos_calibration": user_customized})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        fresh_default = {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": fresh_default},
                             legacy_map=legacy_map)
        check("migration rename: rc==0", rc == 0)
        check("migration rename: old underscore key is gone",
              "macros.macrogroups.nebulaos_calibration" not in moon.store)
        check("migration rename: new hyphenated key holds the USER's exact old content, "
              "not the fresh default",
              moon.store.get("macros.macrogroups.nebulaos-calibration") == user_customized)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration rename: marker records migrated",
              marker.get("migration", {}).get("nebulaos_calibration") == "migrated")
        check("migration rename: the default-seed step treated the migrated group as "
              "already present (did not overwrite it with the fresh default)",
              "nebulaos-calibration" in marker.get("already_present", []))

    with_marker_dir(body)


# --- Test 12: running migration twice makes no further change (idempotent) ---
def test_migration_is_idempotent_across_two_runs():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={"macros.macrogroups.nebulaos_calibration": {"name": "C", "macros": [{"pos": 0, "name": "X"}]}})
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        groups = {"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}}

        rc1, _ = run_seed(marker_path, moon, groups=groups, legacy_map=legacy_map)
        check("migration idempotent: first run rc==0", rc1 == 0)
        state_after_first = dict(moon.store)

        rc2, logs2 = run_seed(marker_path, moon, groups=groups, legacy_map=legacy_map)
        check("migration idempotent: second run rc==0", rc2 == 0)
        check("migration idempotent: second run makes zero further store changes",
              moon.store == state_after_first)
        check("migration idempotent: second run reports the legacy id as not_present "
              "(already migrated, nothing left to do)",
              any("not_present" in line or "already present" in line for line in logs2))

    with_marker_dir(body)


# --- Test 13: both old and new ids already present with IDENTICAL content
#     (an interrupted prior migration that created the new key but failed
#     before deleting the old one) - migration must finish the cleanup by
#     deleting the now-redundant old key, without touching the new one. ---
def test_migration_finishes_an_interrupted_prior_run():
    def body(marker_path):
        same_value = {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}
        moon = FakeMoonrakerDb(existing={
            "macros.macrogroups.nebulaos_calibration": same_value,
            "macros.macrogroups.nebulaos-calibration": same_value,
        })
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": same_value},
                             legacy_map=legacy_map)
        check("interrupted migration: rc==0", rc == 0)
        check("interrupted migration: old key finally deleted",
              "macros.macrogroups.nebulaos_calibration" not in moon.store)
        check("interrupted migration: new key untouched",
              moon.store["macros.macrogroups.nebulaos-calibration"] == same_value)
        with open(marker_path) as f:
            marker = json.load(f)
        check("interrupted migration: marker records finished_interrupted",
              marker.get("migration", {}).get("nebulaos_calibration") == "finished_interrupted")

    with_marker_dir(body)


# --- Test 14: both old and new ids present with DIFFERENT content - a real
#     collision this script cannot safely resolve on its own. Must leave
#     BOTH untouched and flag it, never guess which one is "right". ---
def test_migration_leaves_a_genuine_collision_untouched():
    def body(marker_path):
        old_value = {"name": "Old Calibration", "macros": [{"pos": 0, "name": "OLD_MACRO"}]}
        new_value = {"name": "Someone else's group", "macros": [{"pos": 0, "name": "DIFFERENT_MACRO"}]}
        moon = FakeMoonrakerDb(existing={
            "macros.macrogroups.nebulaos_calibration": old_value,
            "macros.macrogroups.nebulaos-calibration": new_value,
        })
        legacy_map = {"nebulaos_calibration": "nebulaos-calibration"}
        rc, logs = run_seed(marker_path, moon,
                             groups={"nebulaos-calibration": {"name": "Calibration", "macros": [{"pos": 0, "name": "NEBULAOS_AUTO_CALIBRATE"}]}},
                             legacy_map=legacy_map)
        check("migration collision: rc==1 (flagged, not silently resolved)", rc == 1)
        check("migration collision: old key left exactly as-is",
              moon.store["macros.macrogroups.nebulaos_calibration"] == old_value)
        check("migration collision: new key left exactly as-is",
              moon.store["macros.macrogroups.nebulaos-calibration"] == new_value)
        check("migration collision: no DELETE was attempted",
              moon.delete_calls == 0)
        with open(marker_path) as f:
            marker = json.load(f)
        check("migration collision: marker records ambiguous_left_untouched",
              marker.get("migration", {}).get("nebulaos_calibration") == "ambiguous_left_untouched")

    with_marker_dir(body)


# --- Test 15: macros.mode is never overwritten once any value is present,
#     including an explicit user choice of "simple" - the fresh-install
#     Expert default must never become a persistent "force expert". ---
def test_mode_default_never_overwrites_existing_value():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={seed.MODE_KEY: "simple"})
        rc, logs = run_seed(marker_path, moon)
        check("mode preserved: rc==0", rc == 0)
        check("mode preserved: macros.mode is still 'simple'",
              moon.store[seed.MODE_KEY] == "simple")
        check("mode preserved: logged as already set, never re-posted",
              any("already set to" in line for line in logs))
        with open(marker_path) as f:
            marker = json.load(f)
        check("mode preserved: marker records mode_default=already_set",
              marker.get("mode_default") == "already_set")

    with_marker_dir(body)


# --- Test 16: mode-default seeding failing transport-wise is reported but
#     does not block group seeding from completing. ---
def test_mode_default_transport_failure_does_not_block_groups():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})
        real_get = moon.get_status

        def flaky_get(path):
            if "macros.mode" in path:
                raise ConnectionError("flaky")
            return real_get(path)

        logs = []
        rc = seed.run(
            get_status=flaky_get,
            post=moon.post,
            delete=moon.delete,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            legacy_map={},
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("mode transport failure: rc==1 (mode failed)", rc == 1)
        check("mode transport failure: both groups still created",
              moon.store.get(group_key("group_a")) == TWO_GROUPS["group_a"]
              and moon.store.get(group_key("group_b")) == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("mode transport failure: marker records mode_default=failed",
              marker.get("mode_default") == "failed")

    with_marker_dir(body)


def main():
    test_moonraker_unavailable()
    test_fresh_install_creates_both_groups()
    test_existing_group_never_overwritten()
    test_repeated_invocation_is_idempotent()
    test_new_group_added_later_seeds_into_existing_install()
    test_creation_reports_success_but_verification_mismatches()
    test_one_group_transport_error_does_not_block_the_other()
    test_default_groups_are_well_formed()
    test_legacy_group_id_map_is_well_formed()
    test_migration_noop_on_fresh_install()
    test_migration_renames_legacy_group_preserving_user_edits()
    test_migration_is_idempotent_across_two_runs()
    test_migration_finishes_an_interrupted_prior_run()
    test_migration_leaves_a_genuine_collision_untouched()
    test_mode_default_never_overwrites_existing_value()
    test_mode_default_transport_failure_does_not_block_groups()

    print()
    print(f"=== {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
