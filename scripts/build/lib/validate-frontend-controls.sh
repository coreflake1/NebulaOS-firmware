#!/bin/sh
#
# NebulaOS mainline print-controls mission (2026-07-29, see
# docs/NEBULAOS_FRONTEND_PRINT_CONTROLS.md). Shared by
# scripts/build/04-cross-compile-app-stack.sh (real build, validates the
# tracked overlay source) and tests/nebulaos-frontend-controls-validation-
# tests.sh (offline fixture configs) - kept in its own file specifically
# so the tests exercise this exact function, not a second/parallel
# reimplementation of its validation rules (same convention as
# scripts/build/lib/make-seed-archive.sh).
#
# Every function here prints its own OK/FATAL lines and returns 0/1 - none
# of them call exit, so callers (a real build script, or a test harness
# that wants to keep going after a failure) decide what a failure means.
#
# Resolves every [include ...] starting from a given config file, relative
# to a config source directory, into a single flat file - this project's
# configs only ever use plain literal filenames in includes (one level of
# GuppyScreen/ nesting), never glob patterns, so this is a deliberately
# simple closure builder, not a general Klipper config parser.
#
# Phase 1.5 persistent-namespace mission (2026-08): printer.cfg now also
# uses ABSOLUTE-path includes for the immutable, slot-owned config under
# /etc/nebulaos/klipper/ - a real Klipper feature (configfile.py's
# os.path.join(dirname, include_spec) returns include_spec unchanged when
# it's absolute), not a workaround. At real device boot time that resolves
# against the live rootfs. At BUILD time there is no live rootfs yet - only
# the tracked overlay source tree this same build is assembling one from -
# so an absolute include starting with /etc/nebulaos/ is resolved against
# the 4th (optional) <overlay_root> argument instead of <config_src_dir>,
# mirroring exactly how scripts/build/04-cross-compile-app-stack.sh's own
# overlay-copy step will place it at runtime (scripts/build/overlay/X ->
# /X in the image, 1:1). Any other absolute path is left unresolved and
# reported FATAL - this project's build never expects a config to reach
# outside its own overlay tree.
#
# Usage: frontend_controls_resolve_closure <config_src_dir> <entry_file> <closure_out_file> [overlay_root]
frontend_controls_resolve_closure() {
	fc_src="$1"
	fc_entry="$2"
	fc_out="$3"
	fc_overlay_root="${4:-}"
	: > "$fc_out"
	_frontend_controls_resolve_one "$fc_src" "$fc_entry" "$fc_out" "$fc_overlay_root"
}

_frontend_controls_resolve_one() {
	# Every one of these must be `local` - this function recurses for nested
	# includes (e.g. GuppyScreen/guppy_cmd.cfg, simpleaf/*.cfg), and plain
	# (non-local) shell variables are shared across recursive calls, not
	# call-scoped. A prior version of this function used plain assignment
	# here, which meant a recursive call's rc_dirname (e.g. "GuppyScreen",
	# set while resolving a nested include) silently overwrote the caller's
	# own rc_dirname (e.g. "." while resolving printer.cfg's own top-level
	# includes) once the recursive call returned - invisible for years
	# because printer.cfg only ever had ONE nested-dir include, always last,
	# so there was never a "next top-level include" for the clobbered value
	# to corrupt. Adding a second nested-dir include (simpleaf/) after
	# GuppyScreen/guppy_cmd.cfg exposed it immediately: every subsequent
	# top-level include got silently misresolved as GuppyScreen/<name>.
	local rc_src="$1"
	local rc_rel="$2"
	local rc_out="$3"
	local rc_overlay_root="$4"
	local rc_f
	case "$rc_rel" in
		/etc/nebulaos/*)
			if [ -z "$rc_overlay_root" ]; then
				echo "FATAL: $rc_rel is an absolute include but no overlay_root was given to resolve it against" >&2
				return 1
			fi
			rc_f="$rc_overlay_root$rc_rel"
			;;
		/*)
			echo "FATAL: $rc_rel is an absolute include outside the recognized /etc/nebulaos/ image-owned tree - refusing to read outside the build's own overlay" >&2
			return 1
			;;
		*)
			rc_f="$rc_src/$rc_rel"
			;;
	esac
	if [ ! -f "$rc_f" ]; then
		echo "FATAL: $rc_rel is referenced (directly or via include) but does not exist ($rc_f)" >&2
		return 1
	fi
	cat "$rc_f" >> "$rc_out"
	local rc_status=0
	case "$rc_rel" in
		/*)
			# Absolute includes never carry a relative "nested dir" - any
			# further include lines inside them must themselves be plain
			# filenames relative to the SAME absolute directory, or another
			# absolute /etc/nebulaos/ path. today's /etc/nebulaos/klipper/
			# files include nothing themselves, so this path is exercised by
			# the test suite's synthetic fixtures, not real content yet.
			local rc_abs_dirname=$(dirname "$rc_rel")
			grep -o "^\[include [^]]*\]" "$rc_f" 2>/dev/null | sed -e "s/^\[include[[:space:]]*//" -e "s/[[:space:]]*\]\$//" | while read -r rc_inc; do
				local rc_inc_rel
				case "$rc_inc" in
					/*) rc_inc_rel="$rc_inc" ;;
					*) rc_inc_rel="$rc_abs_dirname/$rc_inc" ;;
				esac
				_frontend_controls_resolve_one "$rc_src" "$rc_inc_rel" "$rc_out" "$rc_overlay_root" || exit 1
			done || rc_status=1
			;;
		*)
			local rc_dirname=$(dirname "$rc_rel")
			grep -o "^\[include [^]]*\]" "$rc_f" 2>/dev/null | sed -e "s/^\[include[[:space:]]*//" -e "s/[[:space:]]*\]\$//" | while read -r rc_inc; do
				local rc_inc_rel
				case "$rc_inc" in
					/*) rc_inc_rel="$rc_inc" ;;
					*)
						if [ "$rc_dirname" = "." ]; then
							rc_inc_rel="$rc_inc"
						else
							rc_inc_rel="$rc_dirname/$rc_inc"
						fi
						;;
				esac
				_frontend_controls_resolve_one "$rc_src" "$rc_inc_rel" "$rc_out" "$rc_overlay_root" || exit 1
			done || rc_status=1
			;;
	esac
	return "$rc_status"
}

# Counts occurrences (case-insensitive) of an extended-regex section-header
# pattern in a resolved closure file, and enforces [min, max] inclusive.
# Usage: frontend_controls_check_count <label> <pattern> <min> <max> <closure_file>
frontend_controls_check_count() {
	cc_label="$1"
	cc_pattern="$2"
	cc_min="$3"
	cc_max="$4"
	cc_file="$5"
	cc_count=$(grep -c -i -E "$cc_pattern" "$cc_file")
	if [ "$cc_count" -lt "$cc_min" ]; then
		echo "FATAL: print-control config closure is missing $cc_label (found $cc_count, need at least $cc_min)" >&2
		return 1
	fi
	if [ "$cc_count" -gt "$cc_max" ]; then
		echo "FATAL: print-control config closure has $cc_count definitions of $cc_label (max $cc_max allowed)" >&2
		return 1
	fi
	return 0
}

# Detects a [gcode_macro X] section whose rename_existing value is X itself
# (case-insensitive) - a self-referential override Klipper would either
# reject or silently misbehave on.
# Usage: frontend_controls_check_circular_rename <closure_file>
frontend_controls_check_circular_rename() {
	cr_file="$1"
	cr_hits=$(awk '
		BEGIN { IGNORECASE = 1 }
		/^\[[[:space:]]*gcode_macro[[:space:]]+/ {
			name = $0
			sub(/^\[[[:space:]]*gcode_macro[[:space:]]+/, "", name)
			sub(/[[:space:]]*\]$/, "", name)
			cur = name
			next
		}
		/^\[/ { cur = "" }
		cur != "" && /^[[:space:]]*rename_existing[[:space:]]*:/ {
			val = $0
			sub(/^[[:space:]]*rename_existing[[:space:]]*:[[:space:]]*/, "", val)
			gsub(/[[:space:]]+$/, "", val)
			if (tolower(val) == tolower(cur)) {
				print cur
			}
		}
	' "$cr_file")
	if [ -n "$cr_hits" ]; then
		echo "FATAL: print-control config closure has a recursive rename_existing chain (a [gcode_macro X] renaming itself to X): $cr_hits" >&2
		return 1
	fi
	return 0
}

# Extracts [virtual_sdcard]'s path option value from a resolved closure
# file (empty string if the section or option is absent).
# Usage: frontend_controls_vsd_path <closure_file>
frontend_controls_vsd_path() {
	awk '
		/^\[[[:space:]]*virtual_sdcard[[:space:]]*\]/ { in_vsd = 1; next }
		/^\[/ { in_vsd = 0 }
		in_vsd && /^[[:space:]]*path[[:space:]]*:/ {
			sub(/^[[:space:]]*path[[:space:]]*:[[:space:]]*/, "")
			gsub(/[[:space:]]+$/, "")
			print
			exit
		}
	' "$1"
}

# Runs the full standard set of checks (all six named objects/commands,
# plus the circular-rename guard and the canonical gcode path) against an
# already-resolved closure file. Prints one line per check, returns 0 only
# if every check passed.
# Usage: frontend_controls_validate_closure <closure_file> <expected_gcode_path>
frontend_controls_validate_closure() {
	vc_file="$1"
	vc_expected_path="$2"
	vc_ok=0

	frontend_controls_check_count "[virtual_sdcard]" "^\[[[:space:]]*virtual_sdcard[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[pause_resume]" "^\[[[:space:]]*pause_resume[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[display_status]" "^\[[[:space:]]*display_status[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	# Required, not just optional, as of the 2026-07-29 live-evidence
	# addendum: Mainsail's own frontend checks configfile.settings for
	# these literal macro sections directly, regardless of whether
	# PAUSE/RESUME/CANCEL_PRINT already work at runtime via pause_resume.py.
	frontend_controls_check_count "[gcode_macro PAUSE]" "^\[[[:space:]]*gcode_macro[[:space:]]+pause[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[gcode_macro RESUME]" "^\[[[:space:]]*gcode_macro[[:space:]]+resume[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_count "[gcode_macro CANCEL_PRINT]" "^\[[[:space:]]*gcode_macro[[:space:]]+cancel_print[[:space:]]*\]" 1 1 "$vc_file" || vc_ok=1
	frontend_controls_check_circular_rename "$vc_file" || vc_ok=1

	vc_path=$(frontend_controls_vsd_path "$vc_file")
	if [ "$vc_path" != "$vc_expected_path" ]; then
		echo "FATAL: [virtual_sdcard] path is $vc_path, expected $vc_expected_path" >&2
		vc_ok=1
	fi

	return "$vc_ok"
}
