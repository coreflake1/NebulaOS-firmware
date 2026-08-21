#!/bin/sh
#
# Offline/real-remote assertions that Moonraker's built-in Recovery (soft:
# fetch + reset to the tracked ref; hard: full re-clone - see
# docs/NEBULAOS_UPDATER_AUDIT.md) cannot revert any accepted feature.
#
# REWRITTEN 2026-08-17 (Phase 1 no-fork migration, Phase K). The question
# this suite asks is unchanged and still worth asking. Its answer changed
# completely, because what Recovery resets changed completely.
#
# Under the retired fork architecture, the accepted modules lived in
# coreflake1/NebulaOS-klipper's own klippy/extras/, so "Recovery is safe"
# meant "the fork's branch tip still contains every accepted file, byte for
# byte identical to this repository's klippy_extras/ mirror". Both of those
# assertions are now actively wrong:
#
#   * KLIPPER_REPO is official Klipper3d/klipper. It does not contain, and
#     must never contain, a NebulaOS module - the old test's central
#     assertion would now fail by DESIGN, and "fixing" it by adding files
#     upstream is the fork this migration exists to remove.
#
#   * The old test also required KLIPPER_PIN to equal the branch tip. That
#     was reasonable for a fork nobody else committed to. Against upstream
#     it is wrong on purpose: NebulaOS pins a QUALIFIED commit and upstream
#     moves on without us. Requiring equality would turn every upstream
#     commit into a red test and train people to ignore this suite.
#
# So the property is re-derived rather than re-asserted. Recovery safety now
# rests on three separable facts, each checked below:
#
#   1. Klipper's recovery target really is official upstream, and the exact
#      pinned commit is really reachable there - so a re-clone can land on
#      it rather than on whatever master happens to be that day.
#   2. Upstream at that pin ships NONE of the managed module names, so
#      composition has no collision to resolve and no accepted feature can
#      be shadowed by an upstream file.
#   3. The accepted modules live in the extensions repository at
#      KLIPPER_EXTENSIONS_PIN, which is a SEPARATE checkout that a Klipper
#      Recovery does not touch at all.
#
# What a Klipper reset/re-clone does to the composed symlinks is a different
# question, answered empirically by tests/klipper-git-survival-tests.sh
# (they survive reset --hard; a full re-clone loses them and the next
# activation rebuilds them). This suite deliberately does not duplicate it.
#
# Usage: sh tests/recovery-safety-tests.sh

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
DEPS_MANIFEST="$REPO_ROOT/manifests/dependencies.conf"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/recovery-safety-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0
SKIP=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

. "$DEPS_MANIFEST"

# The NebulaOS-accepted klippy/extras modules whose loss to a Recovery would
# silently regress an accepted, safety-relevant feature. Deliberately the
# same list the retired version of this file used, so the comparison across
# architectures is like for like.
ACCEPTED_FILES="z_compensate.py prtouch_v2.py prtouch_probe.py prtouch_mcu.py prtouch_nozzle.py prtouch_calibration.py"

OFFICIAL_KLIPPER="https://github.com/Klipper3d/klipper.git"

# --- Test 1: every place that hardcodes a branch agrees, for BOTH halves --
# The original bug this guarded: two branches existed, only one was pinned,
# and they silently diverged. There are now two components, so there are two
# ways for it to happen.

test_branch_consistency() {
	for spec in "klipper:$KLIPPER_BRANCH" \
	            "nebulaos-klipper-extensions:$KLIPPER_EXTENSIONS_BRANCH"; do
		app=${spec%%:*}
		want=${spec#*:}
		seed=$(grep -o "seed_git_app $app [a-zA-Z0-9_-]*" \
			"$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-factory-seed" \
			| awk '{print $3}' | head -1)
		mig=$(grep -o "reseed_git_app $app [a-zA-Z0-9_-]*" \
			"$REPO_ROOT/scripts/build/overlay/etc/init.d/S04nebulaos-migrate" \
			| awk '{print $3}' | head -1)
		if [ -n "$want" ] && [ "$want" = "$seed" ] && [ "$want" = "$mig" ]; then
			pass "$app: manifest ($want), factory-seed ($seed) and migrate ($mig) all track the same branch"
		else
			fail "$app: branch drift - manifest='$want' factory-seed='$seed' migrate='$mig'"
		fi
	done
}

# --- Test 2: the recovery target is official upstream, and the pin is on it

test_recovery_target_is_official_and_reachable() {
	if [ "$KLIPPER_REPO" = "$OFFICIAL_KLIPPER" ]; then
		pass "KLIPPER_REPO is official Klipper3d/klipper - NebulaOS hosts no Klipper fork, so Recovery resets to upstream itself"
	else
		fail "KLIPPER_REPO is '$KLIPPER_REPO', not official upstream ($OFFICIAL_KLIPPER)"
		return
	fi

	# Moonraker's reserved klipper slot hardcodes this same origin, so a
	# recovery that cannot reach the pin would strand the device on whatever
	# the branch tip is. Fetching the exact object is the check that matters;
	# equality with the tip deliberately is NOT.
	clone_dir="$WORK/klipper-recovery-target"
	mkdir -p "$clone_dir"
	git -C "$clone_dir" init -q
	git -C "$clone_dir" remote add origin "$KLIPPER_REPO"
	if git -C "$clone_dir" fetch -q --depth 1 origin "$KLIPPER_PIN" 2>"$WORK/fetch-error.log"; then
		git -C "$clone_dir" checkout -q FETCH_HEAD
		got=$(git -C "$clone_dir" rev-parse HEAD)
		if [ "$got" = "$KLIPPER_PIN" ]; then
			pass "the pinned commit $KLIPPER_PIN is fetchable from the official remote - a hard Recovery can land exactly on the qualified commit"
		else
			fail "fetching $KLIPPER_PIN produced $got"
		fi
	else
		skip "could not reach $KLIPPER_REPO (network): $(head -1 "$WORK/fetch-error.log")"
		rm -rf "$clone_dir"
	fi
}

# --- Test 3: upstream at the pin ships none of the managed names ----------
# This is the collision guard's precondition, verified against the real
# remote rather than assumed. If upstream ever adopts one of these names,
# composition refuses to activate (by design), and this test is where that
# is supposed to be discovered - at build time, not on a printer.

test_upstream_has_no_managed_names() {
	clone_dir="$WORK/klipper-recovery-target"
	[ -d "$clone_dir/.git" ] || { skip "no upstream checkout available (test 2 skipped)"; return; }

	collisions=""
	for f in $ACCEPTED_FILES; do
		[ -e "$clone_dir/klippy/extras/$f" ] && collisions="$collisions $f"
	done
	if [ -z "$collisions" ]; then
		pass "official Klipper at the pin ships NONE of the accepted module names - zero core patches, and nothing for composition to collide with"
	else
		fail "upstream at the pin now ships:$collisions - composition will refuse to activate until each name is renamed or dropped (this is the documented hazard, not a test bug)"
	fi

	# The other half of "zero core patches": if the pipeline patched Klipper
	# after cloning it, a Recovery would silently drop the patch. Scoped to
	# klipper deliberately - the pipeline does legitimately patch other
	# components (GuppyScreen's submodules, Moonraker's sqlite-nolock fix).
	if ! grep -B3 -A3 "git apply\|patch -" \
		"$REPO_ROOT/scripts/build/00-fetch-vendor-sources.sh" \
		"$REPO_ROOT/scripts/build/04-cross-compile-app-stack.sh" 2>/dev/null \
		| grep -qi "klipper"; then
		pass "no post-clone patch step targets klipper - a plain clone of the pin reproduces exactly what NebulaOS ships"
	else
		fail "a git apply/patch step targeting klipper was found in the build pipeline - Recovery would not reapply it"
	fi
}

# --- Test 4: the accepted features live in the extensions repo at its pin -

test_extensions_pin_carries_every_accepted_feature() {
	ext_dir=""
	for cand in "$REPO_ROOT/vendor/nebulaos-klipper-extensions" \
	            "$REPO_ROOT/../../../NebulaOS-klipper-extensions"; do
		[ -d "$cand/.git" ] && { ext_dir="$cand"; break; }
	done

	work_dir="$WORK/extensions-recovery-target"
	if [ -n "$ext_dir" ] && git clone -q --shared "$ext_dir" "$work_dir" 2>/dev/null \
		&& git -C "$work_dir" checkout -q "$KLIPPER_EXTENSIONS_PIN" 2>/dev/null; then
		src="local checkout $ext_dir"
	elif git clone -q "$KLIPPER_EXTENSIONS_REPO" "$work_dir" 2>"$WORK/ext-clone-error.log" \
		&& git -C "$work_dir" checkout -q "$KLIPPER_EXTENSIONS_PIN" 2>/dev/null; then
		src="the remote $KLIPPER_EXTENSIONS_REPO"
	else
		skip "no extensions checkout at $KLIPPER_EXTENSIONS_PIN available (the repository is private; run scripts/build/00-fetch-vendor-sources.sh, or clone it with credentials)"
		return
	fi

	missing=""
	empty=""
	for f in $ACCEPTED_FILES; do
		path="$work_dir/extras/$f"
		if [ ! -f "$path" ]; then
			missing="$missing $f"
		elif [ ! -s "$path" ]; then
			empty="$empty $f"
		fi
	done
	if [ -z "$missing" ] && [ -z "$empty" ]; then
		pass "every accepted module is present and non-empty in the extensions repository at $KLIPPER_EXTENSIONS_PIN (via $src) - a Klipper Recovery cannot reach this checkout at all"
	else
		fail "the extensions pin is missing or has empty accepted modules - missing:[$missing] empty:[$empty]"
	fi

	# Every accepted module must also be DECLARED, or composition would
	# never link it and Recovery safety would be moot.
	undeclared=""
	for f in $ACCEPTED_FILES; do
		grep -q "\"extras/$f\"" "$work_dir/nebulaos-extensions.json" || undeclared="$undeclared $f"
	done
	if [ -z "$undeclared" ]; then
		pass "every accepted module is declared in nebulaos-extensions.json, so composition actually links it"
	else
		fail "accepted modules present but NOT declared in the manifest:$undeclared - they would never be composed"
	fi
}

# --- Test 5: the fork-era mirror is not shipped --------------------------
# This repository still carries klippy_extras/ as a fork-era reviewable
# mirror, and some tests still import from it. It is NO LONGER the source of
# truth - the extensions repository is - and it has already diverged. What
# matters for a shipped image is that no build step copies it anywhere, so a
# stale mirror cannot reach a printer.

test_mirror_is_not_shipped() {
	[ -d "$REPO_ROOT/klippy_extras" ] || {
		pass "the fork-era klippy_extras/ mirror no longer exists in this repository"
		return
	}
	if grep -rn "klippy_extras" "$REPO_ROOT/scripts/build/" --include="*.sh" 2>/dev/null \
		| grep -v "^[^:]*:[0-9]*:[[:space:]]*#" | grep -q .; then
		fail "a build script references klippy_extras/ outside a comment - the fork-era mirror could reach a shipped image"
	else
		pass "no build step copies klippy_extras/ into the image - the fork-era mirror is reviewable history only, and cannot ship stale module content"
	fi
}

test_branch_consistency
test_recovery_target_is_official_and_reachable
test_upstream_has_no_managed_names
test_extensions_pin_carries_every_accepted_feature
test_mirror_is_not_shipped

echo
echo "recovery-safety-tests: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
