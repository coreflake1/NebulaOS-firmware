#!/bin/sh
#
# NebulaOS Phase 1 no-fork migration: the c_helper.so mtime invariant.
#
# WHY THIS EXISTS
# ---------------
# Klipper decides whether to rebuild its C library by comparing MTIMES, not
# hashes. From official klippy/chelper/__init__.py at the qualified commit:
#
#     def check_build_code(sources, target):
#         src_times = get_mtimes(sources)
#         obj_times = get_mtimes([target])
#         return not obj_times or max(src_times) > min(obj_times)
#
#     def check_build_c_library():
#         srcdir  = os.path.dirname(os.path.realpath(__file__))
#         ...
#         if not check_build_code(srcfiles+ofiles+[__file__], destlib):
#             # Code already built
#             return destlib
#         ...
#         do_build_code(cmd % (tempdestlib, ' '.join(srcfiles)))
#
# where sources = SOURCE_FILES (*.c) + OTHER_FILES (*.h) + __init__.py, all
# inside klippy/chelper/, and target = klippy/chelper/c_helper.so.
#
# If ANY of those is newer than the prebuilt .so, mainline shells out to
# gcc. This device has no toolchain, so do_build_code() raises and Klippy
# does not start - a total printer outage produced by a file timestamp.
# That is the whole reason NebulaOS does not need (and deliberately does not
# carry) the old fork's patch to this file: it is a firmware packaging
# problem, and packaging is where it is solved.
#
# TWO HALVES, BOTH REQUIRED
# -------------------------
#  1. Build time - scripts/build/04-cross-compile-app-stack.sh calls
#     chelper_enforce_mtime() as the LAST step over every staged copy of the
#     Klipper tree, then chelper_check_mtime() as a hard gate. The build
#     fails rather than shipping an image that will not boot. This is
#     deliberate belt-and-braces: relying on "the .so happens to be built
#     after the sources were checked out" is exactly the build-order luck
#     that a `cp -r` (which does not preserve mtimes) or a later
#     `git read-tree -mu` can quietly invert.
#
#  2. Boot time - S05nebulaos-activate calls chelper_write_verdict() after
#     composition and before Klipper starts. Packaging correctness at build
#     time does not survive everything the device can do afterwards: a
#     Moonraker-driven `git pull` that touches a chelper source, a
#     `git reset --hard` during rollback, a restored backup. So the
#     invariant is re-checked against the tree that is actually about to
#     run, and the verdict is written where the extension set's own preflight
#     (extras/nebulaos_compat.py, via the manifest's
#     chelper.platform_result_file) will read it.
#
# The verdict file therefore makes a stale .so surface as a named,
# fail-closed preflight error at config load - "the platform reported the
# chelper prebuilt-library invariant as NOT satisfied" - instead of as a gcc
# crash part way through boot, or worse, a slow successful on-device
# compile that masks a real packaging bug.
#
# WHY find -newer AND NOT stat
# ----------------------------
# BusyBox on this device has no `stat` applet at all (confirmed live
# elsewhere in this project - see S05nebulaos-activate's own `ls -ldn`
# workaround). `find -newer` performs precisely the comparison Klipper's own
# check performs, is present in BusyBox find, and needs no arithmetic on
# timestamps. The glob below (*.c, *.h, __init__.py) is a strict SUPERSET of
# SOURCE_FILES+OTHER_FILES+__file__, so this check can only ever be stricter
# than Klipper's, never laxer.
#
# POSIX sh only - BusyBox ash. Sourced by S05nebulaos-activate,
# nebulaos-update-supervisor.sh, and 04-cross-compile-app-stack.sh.

NEBULAOS_CHELPER_VERDICT_NAME=".nebulaos-chelper-verdict.json"
NEBULAOS_CHELPER_SUBDIR="klippy/chelper"
NEBULAOS_CHELPER_TARGET="klippy/chelper/c_helper.so"

# Progress goes to stderr, deliberately, and this is not a style choice.
# chelper_enforce_mtime() is called from inside make_seed_archive(), whose
# stdout IS its return value - the packaged commit SHA, captured by the build
# as `klipper_seed_commit=$(make_seed_archive ...)`. A log line on stdout
# there does not look like a logging mistake, it silently corrupts the seed
# manifest and the migration_version hash derived from it. Found by
# tests/klipper-stack-lifecycle-tests.sh, which compares migrated commits
# against the values make_seed_archive reported.
chelper_log() {
	echo "nebulaos-chelper-preflight: $1" >&2
}

chelper_err() {
	echo "nebulaos-chelper-preflight: ERROR: $1" >&2
}

# Every input Klipper's own check_build_code() considers, plus a margin.
# $1=klipper checkout
chelper_sources() {
	find "$1/$NEBULAOS_CHELPER_SUBDIR" -maxdepth 1 -type f \
		\( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) 2>/dev/null
}

# Returns 0 when the invariant holds (no source is newer than the target).
# Echoes the offending file list on failure so the caller can report it.
# $1=klipper checkout
chelper_check_mtime() {
	kdir="$1"
	target="$kdir/$NEBULAOS_CHELPER_TARGET"
	srcdir="$kdir/$NEBULAOS_CHELPER_SUBDIR"

	if [ ! -d "$srcdir" ]; then
		chelper_err "$srcdir does not exist - not a Klipper checkout"
		return 2
	fi
	if [ ! -f "$target" ]; then
		chelper_err "prebuilt $NEBULAOS_CHELPER_TARGET is MISSING from $kdir. Klipper would invoke gcc to build it, and this device has no toolchain."
		return 3
	fi

	newer=$(find "$srcdir" -maxdepth 1 -type f \
		\( -name '*.c' -o -name '*.h' -o -name '__init__.py' \) \
		-newer "$target" 2>/dev/null)
	if [ -n "$newer" ]; then
		chelper_err "the following chelper source(s) are NEWER than $NEBULAOS_CHELPER_TARGET, so Klipper's check_build_code() would trigger a gcc rebuild:"
		printf '%s\n' "$newer" >&2
		return 1
	fi
	return 0
}

# Make the invariant true, deterministically, rather than hoping build order
# produced it. Called at build time only - never on the device, where
# touching the .so forward would paper over a real staleness problem that
# the verdict file is meant to expose.
# $1=klipper checkout
chelper_enforce_mtime() {
	kdir="$1"
	target="$kdir/$NEBULAOS_CHELPER_TARGET"
	if [ ! -f "$target" ]; then
		chelper_err "cannot enforce the mtime invariant: $target does not exist"
		return 1
	fi
	# `touch` with no -r/-d sets the file to now, which is >= the mtime of
	# every file already on disk. The verification immediately afterwards is
	# what makes this a guarantee rather than an assumption - if anything
	# writes a source file in the same second (or later), the build fails
	# loudly here instead of the printer failing to boot later.
	touch "$target" || return 1
	chelper_check_mtime "$kdir" || {
		chelper_err "the mtime invariant STILL does not hold for $kdir after touching $NEBULAOS_CHELPER_TARGET - something is rewriting chelper sources after this step; fix the step ordering rather than retrying"
		return 1
	}
	chelper_log "mtime invariant enforced and verified for $kdir"
	return 0
}

# Write the platform's verdict where extras/nebulaos_compat.py reads it.
# Always writes a file - a failing verdict is information the extension
# preflight needs, and its absence is treated by that code as its own
# distinct (also fail-closed) error.
# $1=klipper checkout
# Returns 0 only when the verdict is "ok".
chelper_write_verdict() {
	kdir="$1"
	out="$kdir/$NEBULAOS_CHELPER_VERDICT_NAME"
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	chelper_check_mtime "$kdir"
	rc=$?

	case "$rc" in
		0) status="ok";      detail="prebuilt c_helper.so is newer than every chelper source; Klipper will not invoke gcc" ;;
		1) status="stale";   detail="one or more chelper sources are newer than the prebuilt c_helper.so; Klipper would attempt a gcc rebuild and this device has no toolchain" ;;
		3) status="missing"; detail="the prebuilt c_helper.so is absent from the Klipper checkout" ;;
		*) status="invalid"; detail="the Klipper checkout has no klippy/chelper directory" ;;
	esac

	kc=$(git -C "$kdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	tmp="$out.tmp.$$"
	cat > "$tmp" <<EOF
{
  "schema": 1,
  "status": "$status",
  "detail": "$detail",
  "requirement": "prebuilt_so_mtime_newer_than_all_chelper_sources",
  "target": "$NEBULAOS_CHELPER_TARGET",
  "source_dir": "$NEBULAOS_CHELPER_SUBDIR",
  "klipper_commit": "$kc",
  "checked_at": "$now",
  "checked_at_caveat": "may read as an early-epoch date if this boot occurred before NTP sync",
  "checked_by": "/etc/nebulaos-chelper-preflight.sh"
}
EOF
	mv "$tmp" "$out"

	if [ "$status" = "ok" ]; then
		chelper_log "verdict ok - wrote $out"
		return 0
	fi
	chelper_err "verdict '$status' - wrote $out; Klipper must NOT be started against this tree"
	return 1
}
