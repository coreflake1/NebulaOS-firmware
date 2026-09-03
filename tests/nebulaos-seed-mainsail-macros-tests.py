#!/usr/bin/env python3
#
# Offline, repeatable tests for
# scripts/build/overlay/usr/libexec/nebulaos-seed-mainsail-macros (Phase 2
# macro-cleanup/Mainsail-grouping mission, 2026-09-04). Imports the actual
# production module directly (no parallel copy of the logic) and exercises
# run() with fake get_status/post/sleep callables and a temp-directory
# marker path - no real Moonraker, no real device, no real network, ever.
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
    """A tiny, deterministic stand-in for Moonraker's database API - a
    dict of {key: value} under the mainsail namespace, plus counters so
    tests can assert exactly how many times get/post were called."""

    def __init__(self, existing=None, available=True):
        self.store = dict(existing or {})
        self.available = available
        self.get_calls = 0
        self.post_calls = 0

    def get_status(self, path):
        self.get_calls += 1
        if not self.available:
            raise ConnectionError("moonraker not reachable")
        if path == "/server/database/list":
            return 200, json.dumps({"result": {"namespaces": ["mainsail"]}})
        assert path.startswith("/server/database/item?namespace=mainsail&key=macros.macrogroups.")
        key = path.split("key=", 1)[1]
        group_id = key[len("macros.macrogroups."):]
        if group_id not in self.store:
            return 404, None
        return 200, json.dumps({
            "result": {"namespace": "mainsail", "key": key, "value": self.store[group_id]}
        })

    def post(self, path, payload):
        self.post_calls += 1
        assert path == "/server/database/item"
        assert payload["namespace"] == "mainsail"
        key = payload["key"]
        assert key.startswith("macros.macrogroups.")
        group_id = key[len("macros.macrogroups."):]
        self.store[group_id] = payload["value"]
        return json.dumps({"result": {"namespace": "mainsail", "key": key, "value": payload["value"]}})


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


def run_seed(marker_path, moon, groups=None, retry_attempts=3, retry_delay=0):
    logs = []
    rc = seed.run(
        get_status=moon.get_status,
        post=moon.post,
        marker_path=marker_path,
        log=logs.append,
        groups=groups if groups is not None else TWO_GROUPS,
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
        check("fresh install: exactly two POSTs", moon.post_calls == 2, f"got {moon.post_calls}")
        check("fresh install: both groups now in store",
              set(moon.store.keys()) == {"group_a", "group_b"})
        check("fresh install: group content matches exactly",
              moon.store["group_a"] == TWO_GROUPS["group_a"]
              and moon.store["group_b"] == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("fresh install: marker records both as created",
              set(marker.get("created", [])) == {"group_a", "group_b"})
        check("fresh install: marker has no failed entries", marker.get("failed") == [])

    with_marker_dir(body)


# --- Test 3: one group already present (e.g. user-edited) - never overwritten ---
def test_existing_group_never_overwritten():
    def body(marker_path):
        user_customized = {"name": "My Custom Group", "macros": [{"pos": 0, "name": "SOMETHING_ELSE"}]}
        moon = FakeMoonrakerDb(existing={"group_a": user_customized})
        rc, logs = run_seed(marker_path, moon)
        check("existing group: rc==0", rc == 0)
        check("existing group: only one POST (for group_b only)",
              moon.post_calls == 1, f"got {moon.post_calls}")
        check("existing group: group_a completely unchanged",
              moon.store["group_a"] == user_customized)
        check("existing group: group_b created",
              moon.store["group_b"] == TWO_GROUPS["group_b"])
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
        check("idempotent: first run created both", moon.post_calls == 2)

        rc2, logs2 = run_seed(marker_path, moon)
        check("idempotent: second run rc==0", rc2 == 0)
        check("idempotent: second run makes zero additional POSTs",
              moon.post_calls == 2, f"got {moon.post_calls}")
        already_present_lines = [line for line in logs2 if "already present" in line]
        check("idempotent: second run logs both groups as already present",
              len(already_present_lines) == 2, f"got {already_present_lines}")

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
        check("new group later: exactly one new POST (group_c only)",
              moon.post_calls == 3, f"got {moon.post_calls}")
        check("new group later: group_c now present", "group_c" in moon.store)
        check("new group later: group_a/group_b untouched",
              moon.store["group_a"] == TWO_GROUPS["group_a"]
              and moon.store["group_b"] == TWO_GROUPS["group_b"])

    with_marker_dir(body)


# --- Test 6: POST "succeeds" but verification finds different content - failure, group not marked created ---
def test_creation_reports_success_but_verification_mismatches():
    def body(marker_path):
        moon = FakeMoonrakerDb(existing={})

        def post_but_store_wrong_value(path, payload):
            moon.post_calls += 1
            key = payload["key"]
            group_id = key[len("macros.macrogroups."):]
            moon.store[group_id] = {"name": "WRONG", "macros": []}
            return json.dumps({"result": {}})

        logs = []
        rc = seed.run(
            get_status=moon.get_status,
            post=post_but_store_wrong_value,
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
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
            marker_path=marker_path,
            log=logs.append,
            groups=TWO_GROUPS,
            retry_attempts=3,
            retry_delay=0,
            sleep=lambda _s: None,
        )
        check("flaky group: rc==1 (group_a failed)", rc == 1)
        check("flaky group: group_b still created", moon.store.get("group_b") == TWO_GROUPS["group_b"])
        with open(marker_path) as f:
            marker = json.load(f)
        check("flaky group: group_a recorded as failed", "group_a" in marker.get("failed", []))
        check("flaky group: group_b recorded as created", "group_b" in marker.get("created", []))

    with_marker_dir(body)


# --- Test 8: real production DEFAULT_GROUPS is well-formed (every macro name
#     a plain non-empty string, every pos unique per group, every group has
#     a name and at least one macro) - catches a typo/duplicate before it
#     ever reaches a real device. ---
def test_default_groups_are_well_formed():
    for group_id, definition in seed.DEFAULT_GROUPS.items():
        check(f"{group_id}: has a non-empty name",
              isinstance(definition.get("name"), str) and definition["name"])
        macros = definition.get("macros")
        check(f"{group_id}: has at least one macro",
              isinstance(macros, list) and len(macros) > 0)
        positions = [m.get("pos") for m in macros]
        check(f"{group_id}: macro positions are unique",
              len(positions) == len(set(positions)), f"positions={positions}")
        for m in macros:
            check(f"{group_id}: macro {m.get('name')!r} has a non-empty string name",
                  isinstance(m.get("name"), str) and m["name"])


def main():
    test_moonraker_unavailable()
    test_fresh_install_creates_both_groups()
    test_existing_group_never_overwritten()
    test_repeated_invocation_is_idempotent()
    test_new_group_added_later_seeds_into_existing_install()
    test_creation_reports_success_but_verification_mismatches()
    test_one_group_transport_error_does_not_block_the_other()
    test_default_groups_are_well_formed()

    print()
    print(f"=== {PASS} passed, {FAIL} failed ===")
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
