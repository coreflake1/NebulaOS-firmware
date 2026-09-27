#!/bin/sh
# nebulaos-venv-lib.sh - shared persistent-venv compatibility helpers.
#
# Sourced by /etc/init.d/S04nebulaos-factory-seed (which owns creating and
# replacing these environments) and by /etc/init.d/S05nebulaos-activate (which
# only decides whether to bind-mount one). It deliberately lives in ONE place:
# two copies of an init-time predicate that must agree is the same hazard
# 02-configure-buildroot.sh documents at length for overlay files, where an
# older generation sorted first and silently won.
#
# Defines: venv_matches_platform, recover_torn_venv, swap_venv_into_place.
#
# Callers may define log(); if they do not, a no-op stand-in is used so this
# file is safe to source from anywhere.
command -v log >/dev/null 2>&1 || log() { echo "nebulaos-venv: $1"; }

# NOTE ON VARIABLE NAMES: POSIX sh has no function-local scope, so every
# helper below uses its OWN distinct prefix (_vmp_, _rtv_, _svp_). This is not
# style. An earlier revision had all three using `_envdir`, so when
# recover_torn_venv() called venv_matches_platform("$_envdir.old") the callee
# overwrote the caller's `_envdir`, and the subsequent `mv "$_envdir.old"`
# addressed "<env>.old.old" - silently failing to recover the one surviving
# copy of a user's environment. Caught by
# tests/venv-platform-migration-tests.sh, which is why that suite exercises
# these functions for real rather than reimplementing them.

# Buildroot 2025.02.18 / Python 3.12 migration (2026-09-27).
#
# Is this persistent venv usable by the interpreter THIS IMAGE ships?
#
# The old test was `[ -x "$envdir/bin/python3" ]`. That asks whether a file
# exists, which is not the question. /usr/data/nebulaos/envs is PERSISTENT and
# slot-independent; /usr/lib/python3.x and /usr/bin/python3.x are image-owned
# and per-slot. So the interpreter a venv was built against can disappear
# underneath it without the venv changing at all:
#
#   forward   OTA from a 3.11 slot to a 3.12 slot
#   backward  A/B ROLLBACK from a migrated 3.12 slot back to the 3.11 slot
#
# Both directions matter and neither is special-cased here - the venv is
# compared against the RUNNING image's interpreter, so a mismatch either way
# is caught identically. Rollback is the safety mechanism; a migration that
# only handled the upgrade direction would disarm it.
#
# (If /usr/data/nebulaos/envs were ever made slot-scoped, this predicate
# becomes a no-op and the failure would be silent. It is the persistence
# asymmetry above that makes the whole design work.)
#
# Returns 0 only if ALL of these hold:
#   1. bin/python3 exists and is executable
#   2. it actually RUNS (a dangling symlink is not executable, but a venv can
#      also be torn in ways that only show up on exec)
#   3. its major.minor equals the running image's /usr/bin/python3
#   4. pyvenv.cfg is present and its recorded version agrees
#   5. the component's own import smoke test passes
venv_matches_platform() {
	_vmp_dir="$1"; _vmp_smoke="${2:-}"

	[ -d "$_vmp_dir" ] || return 1
	[ -x "$_vmp_dir/bin/python3" ] || return 1

	_vmp_venv_mm=$("$_vmp_dir/bin/python3" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
	[ -n "$_vmp_venv_mm" ] || return 1

	_vmp_sys_mm=$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
	[ -n "$_vmp_sys_mm" ] || return 1

	[ "$_vmp_venv_mm" = "$_vmp_sys_mm" ] || {
		log "venv $_vmp_dir targets python $_vmp_venv_mm but this image ships python $_vmp_sys_mm - rebuilding"
		return 1
	}

	[ -f "$_vmp_dir/pyvenv.cfg" ] || {
		log "venv $_vmp_dir has no pyvenv.cfg - rebuilding"
		return 1
	}
	_vmp_cfg_ver=$(sed -n 's/^version[[:space:]]*=[[:space:]]*//p' "$_vmp_dir/pyvenv.cfg" 2>/dev/null | head -1)
	case "$_vmp_cfg_ver" in
		"$_vmp_sys_mm"|"$_vmp_sys_mm".*) : ;;
		"") log "venv $_vmp_dir pyvenv.cfg records no version - rebuilding"; return 1 ;;
		*)  log "venv $_vmp_dir pyvenv.cfg records version $_vmp_cfg_ver, image ships $_vmp_sys_mm - rebuilding"; return 1 ;;
	esac

	if [ -n "$_vmp_smoke" ]; then
		"$_vmp_dir/bin/python3" -c "$_vmp_smoke" >/dev/null 2>&1 || {
			log "venv $_vmp_dir failed its import smoke test - rebuilding"
			return 1
		}
	fi
	return 0
}

# Recover a torn replacement from a previous boot.
#
# The swap below is rename-based, so a power cut can leave "$envdir.old"
# holding the only real environment. The recovery trigger is deliberately NOT
# "$envdir is missing": S02nebulaos-namespace runs before this script and
# mkdir -p's envs/klipper and envs/moonraker, so $envdir is essentially always
# present - as an EMPTY directory after a torn swap. Testing for absence would
# therefore never fire, the old environment would sit in .old forever, and the
# component would fall back to bare /usr/bin/python3.
#
# So: recover when .old exists AND $envdir does not satisfy the platform
# predicate. An empty directory fails that trivially, as does a torn one.
recover_torn_venv() {
	_rtv_dir="$1"; _rtv_smoke="${2:-}"
	[ -d "$_rtv_dir.old" ] || return 0
	if venv_matches_platform "$_rtv_dir" "$_rtv_smoke"; then
		# The swap completed; .old is just leftover garbage.
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
		return 0
	fi
	if venv_matches_platform "$_rtv_dir.old" "$_rtv_smoke"; then
		log "recovering $_rtv_dir from $_rtv_dir.old (previous replacement was interrupted)"
		rm -rf "$_rtv_dir" 2>/dev/null || true
		if mv "$_rtv_dir.old" "$_rtv_dir"; then
			log "recovered $_rtv_dir successfully"
		else
			log "ERROR: could not restore $_rtv_dir from $_rtv_dir.old - leaving .old in place for manual recovery"
		fi
	else
		log "$_rtv_dir.old exists but is not usable by this image either - discarding it and reseeding"
		rm -rf "$_rtv_dir.old" 2>/dev/null || true
	fi
}

# Swap a verified staging directory into place WITHOUT destroying the existing
# one first.
#
# This used to be `rm -rf "$envdir"; mv "$envdir.partial" "$envdir"`. Those two
# statements have a window between them in which the machine has NO
# environment at all, and a power cut there is unrecoverable - the old one is
# already gone and the new one is not yet in place. On a 3D printer that loses
# power mid-print this is a real failure mode, not a theoretical one.
#
# Rename the old one aside, move the new one in, then delete. Every
# intermediate state is recoverable by recover_torn_venv() above. The final
# delete is non-fatal on purpose: failing to remove a leftover directory must
# not fail a replacement that has already succeeded.
#
# DISK COST: none beyond what the previous implementation already paid. It is
# tempting to think holding <env>, <env>.old and <env>.partial at once needs a
# third copy's worth of space - it does not. All three are siblings in
# /usr/data/nebulaos/envs, so `mv` is a rename within one filesystem, not a
# copy. Peak usage is <env> plus <env>.partial, which is exactly what the old
# `rm -rf <env>; mv <env>.partial <env>` sequence also held at its peak, since
# .partial was fully populated before the rm. A venv here measures ~25MB
# (04-cross-compile-app-stack.sh records the figure), so this is ~50MB peak
# per component either way, unchanged by this fix.
swap_venv_into_place() {
	_svp_dir="$1"
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	if [ -e "$_svp_dir" ]; then
		if ! mv "$_svp_dir" "$_svp_dir.old"; then
			log "ERROR: could not move $_svp_dir aside - refusing to replace it, leaving the existing environment untouched"
			rm -rf "$_svp_dir.partial" 2>/dev/null || true
			return 1
		fi
	fi
	if ! mv "$_svp_dir.partial" "$_svp_dir"; then
		log "ERROR: could not move $_svp_dir.partial into place - restoring the previous environment"
		[ -d "$_svp_dir.old" ] && mv "$_svp_dir.old" "$_svp_dir"
		return 1
	fi
	rm -rf "$_svp_dir.old" 2>/dev/null || true
	return 0
}

