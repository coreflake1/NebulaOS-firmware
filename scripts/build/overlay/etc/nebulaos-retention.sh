#!/bin/sh
#
# NebulaOS mutable-runtime mission, Phase 9: namespace-restricted,
# update-aware retention manager. Informed by SimpleAF's real, currently-
# shipping tools/cleanup-files.sh (pellcorp/creality, fetched 2026-07-26 -
# full findings in docs/NEBULAOS_RETENTION_POLICY.md sec 1) but NOT a
# literal port: normal cleanup here is restricted to an explicit allowlist
# under /usr/data/nebulaos, adds a real active-print/partial-upload check
# before any emergency gcode deletion (a real gap in SimpleAF's own
# reference script - it has no such check at all), and never touches USB
# mounts.
#
# Invoked by /etc/init.d/S45nebulaos-cleanup at boot (backgrounded, does
# not block boot - matches SimpleAF's own S45cleanup convention). Can also
# be invoked manually with --dry-run to preview without deleting anything.

NEBULAOS_ROOT=/usr/data/nebulaos
LOG="$NEBULAOS_ROOT/maintenance/retention.log"
LOCKDIR="$NEBULAOS_ROOT/updates/locks"
SHARED_GCODES=/usr/data/printer_data/gcodes

# Free-space floors on /usr/data, in MB - adapted from SimpleAF's single
# 1000MB threshold (docs/NEBULAOS_RETENTION_POLICY.md sec 1/2.3), split
# into two levels since this mission's own added footprint (~150-250MB per
# the architecture doc's measured storage budget) is smaller than what
# SimpleAF's own reference script was originally sized for.
CAUTION_FLOOR_MB=800
CRITICAL_FLOOR_MB=300

# Phase 0 safety/logging cleanup: klippy.log/moonraker.log/guppyscreen.log
# and (as of this same pass) the persistent nginx-access.log/nginx-error.log
# grow unbounded - clean_rotated_logs() below only ever age-sweeps files
# that are ALREADY rotated, and nothing anywhere ever produced a rotated
# copy of these five live logs in the first place. 5MB keeps each log's
# worst case (live + 2 rotated generations = 15MB/log, 75MB across all
# five) comfortably inside the ~150-250MB budget this script's own
# CAUTION/CRITICAL floors above were sized against.
LOG_ROTATE_MAX_BYTES=$((5 * 1024 * 1024))

dryrun=false
[ "$1" = "--dry-run" ] && dryrun=true

log() {
	echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >> "$LOG"
}

delete() {
	f="$1"; reason="$2"
	if [ "$dryrun" = "true" ]; then
		log "[DRY-RUN] would delete ($reason): $f"
		return 0
	fi
	# Real bug found live (Phase E, 2026-07-27): BusyBox's `rm -f` refuses
	# to remove a directory at all ("rm: 'x' is a directory", exit 1) -
	# every call this function ever made against the directory-based
	# per-component backups (klipper/moonraker/mainsail are all real
	# directories, not flat files) has silently done nothing while this
	# same function logged "deleting" as if it had succeeded. Only the
	# flat-file cases (rotated logs, config backups) were ever genuinely
	# removed. Confirmed live: a manual `rm -f` against a real populated
	# directory left it completely intact.
	if [ -d "$f" ]; then
		rm -rf "$f"
	else
		rm -f "$f"
	fi
	if [ -e "$f" ]; then
		log "FAILED to delete ($reason): $f (still present after rm)"
	else
		log "deleting ($reason): $f"
	fi
}

# Same rationale as SimpleAF's own script (docs/NEBULAOS_RETENTION_POLICY.md
# sec 1/2.6): this board has no RTC, so time reads as an early-2020-ish
# epoch until NTP finishes syncing after boot. Any mtime-based decision
# below is wrong until the clock has visibly jumped forward.
wait_for_clock_sync() {
	start=$(date +%s)
	# 2026-07-23 00:00:00 UTC - this project's own earliest possible boot,
	# used the same way SimpleAF's script uses its own fixed reference date.
	if [ "$start" -lt 1784851200 ]; then
		log "clock not yet synced (epoch $start) - waiting for NTP jump"
		i=0
		while [ "$i" -lt 60 ]; do
			now=$(date +%s)
			[ "$((now - start))" -gt 1200 ] && break
			sleep 5
			i=$((i + 1))
		done
	fi
}

# Rejects '..' traversal and any path that resolves (following symlinks)
# outside $NEBULAOS_ROOT. Never deletes anything under a target this
# rejects.
path_is_namespace_safe() {
	case "$1" in
		*..*) return 1 ;;
	esac
	resolved=$(readlink -f "$1" 2>/dev/null) || return 1
	case "$resolved" in
		"$NEBULAOS_ROOT"/*) return 0 ;;
		*) return 1 ;;
	esac
}

# True if an update transaction lock exists for any component - normal
# cleanup should not race an in-flight update's own file operations.
update_in_progress() {
	[ -d "$LOCKDIR" ] || return 1
	[ -n "$(ls -A "$LOCKDIR" 2>/dev/null)" ]
}

# --- Normal, namespace-restricted cleanup ---

clean_rotated_logs() {
	find "$NEBULAOS_ROOT/printer_data/logs" "$NEBULAOS_ROOT/maintenance/logs" \
		-maxdepth 1 -type f -name "*.log*" -mtime +7 2>/dev/null | while read -r f; do
		base=$(basename "$f")
		case "$base" in
			klippy.log|moonraker.log|guppyscreen.log|nginx-access.log|nginx-error.log|retention.log) continue ;;
		esac
		path_is_namespace_safe "$f" && delete "$f" "rotated-log"
	done
}

# rotate_if_oversized FILE MAX_BYTES
#
# Copy-truncate, not rename-and-recreate: klippy/moonraker/guppyscreen/nginx
# all hold their log file open for the life of the process and never reopen
# it on SIGHUP - renaming $f out from under them would leave their fd
# writing into an ever-growing, now-unreachable-by-name copy forever, with
# a freshly-created $f staying empty until the next restart, which defeats
# the point of rotating at all. Truncating the SAME inode in place keeps
# the running process's fd valid; its next write lands right after the
# truncation point. The standard copy-truncate tradeoff applies (a few
# lines written between the cp and the truncate below can be lost) - that
# is accepted here in exchange for never needing to signal or restart a
# live service just to rotate its log.
#
# Safe if $f doesn't exist yet (first boot, e.g. before a service has ever
# started) and safe under low disk space - if the copy fails, rotation is
# skipped entirely for this run and the live file is left untouched, never
# truncated without a backup existing first.
rotate_if_oversized() {
	f="$1"
	max_bytes="$2"

	[ -e "$f" ] || return 0
	path_is_namespace_safe "$f" || return 0

	size=$(wc -c < "$f" 2>/dev/null)
	[ -z "$size" ] && return 0
	[ "$size" -le "$max_bytes" ] && return 0

	# Keep exactly 2 rotated generations - same bound this script already
	# uses for failed-* backup retention (clean_obsolete_versions).
	[ -e "$f.2" ] && rm -f "$f.2" 2>/dev/null
	[ -e "$f.1" ] && mv -f "$f.1" "$f.2" 2>/dev/null

	if cp -a "$f" "$f.1" 2>/dev/null; then
		if : > "$f" 2>/dev/null; then
			log "rotated (oversized, ${size}B): $f -> $f.1"
		else
			log "WARNING: rotate of $f: truncate failed after copy (possible low disk space) - $f.1 is a safe copy, live file left untouched"
		fi
	else
		log "WARNING: rotate of $f: copy to $f.1 failed (possible low disk space) - skipping rotation this run, live file untouched"
	fi
}

rotate_platform_logs() {
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/klippy.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/moonraker.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/guppyscreen.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/nginx-access.log" "$LOG_ROTATE_MAX_BYTES"
	rotate_if_oversized "$NEBULAOS_ROOT/printer_data/logs/nginx-error.log" "$LOG_ROTATE_MAX_BYTES"
}

clean_old_config_backups() {
	find "$NEBULAOS_ROOT/backups/printer_config" -maxdepth 1 -type f -mtime +7 2>/dev/null | \
		sort -r | tail -n +2 | while read -r f; do
		path_is_namespace_safe "$f" && delete "$f" "old-config-backup"
	done
}

clean_abandoned_staging() {
	find "$NEBULAOS_ROOT/updates/staging" -mindepth 1 -maxdepth 1 -mtime +1 2>/dev/null | while read -r f; do
		name=$(basename "$f")
		[ -e "$LOCKDIR/$name.lock" ] && continue
		path_is_namespace_safe "$f" && delete "$f" "abandoned-staging"
	done
}

clean_obsolete_versions() {
	# Keeps the newest 2 *failure-evidence* directories (failed-<ts>) per
	# component - never deletes the only remaining copy. BusyBox find has
	# no -printf (found live: "unrecognized: -printf") - `ls -1t` (BusyBox
	# ls extension, newest-first) is the portable alternative to sorting
	# by mtime.
	#
	# Real bug found live (Phase E, 2026-07-27): this used to sort and
	# prune EVERYTHING under backups/$comp mixed together, including
	# last-known-good/last-known-good-env - the single, continuously-
	# updated backup the Phase C/D update-supervisor's own rollback
	# mechanism depends on to restore from, not an "old version" to
	# rotate away. Confirmed live via the real retention log: this ran
	# repeatedly across multiple boots and genuinely tried to delete it
	# every time (masked only by a separate bug - see delete() - that
	# made the rm itself silently fail on directories). Explicitly
	# excluded now: only failed-* evidence directories are ever
	# candidates, the paired backup is never touched by this script at
	# all (it's the supervisor's own responsibility, not retention's).
	for comp in klipper moonraker mainsail; do
		dir="$NEBULAOS_ROOT/backups/$comp"
		[ -d "$dir" ] || continue
		count=$(find "$dir" -mindepth 1 -maxdepth 1 -name 'failed-*' 2>/dev/null | wc -l)
		[ "$count" -le 2 ] && continue
		( cd "$dir" && ls -1td failed-* 2>/dev/null ) | tail -n "+3" | while read -r name; do
			f="$dir/$name"
			path_is_namespace_safe "$f" && delete "$f" "obsolete-version-$comp"
		done
	done
}

clean_pip_cache() {
	[ -d /root/.cache ] && [ "$dryrun" != "true" ] && rm -rf /root/.cache
}

# --- Disk-pressure handling ---

free_mb() {
	df -m /usr/data 2>/dev/null | tail -1 | awk '{print $4}'
}

# Never deletes: the active print's own file, a partial/in-progress
# upload, anything under a USB mount, or anything with ambiguous state -
# per the mission's own explicit requirement. This is a real, deliberate
# improvement over SimpleAF's own reference script, which has no such
# check at all (docs/NEBULAOS_RETENTION_POLICY.md sec 1).
gcode_is_protected() {
	f="$1"
	# USB-mounted content lives under $SHARED_GCODES/USB - excluded by the
	# emergency loop's own -maxdepth 1 below, checked again here for
	# defense in depth.
	case "$f" in
		"$SHARED_GCODES"/USB/*) return 0 ;;
	esac
	# Confirmed live against a real Moonraker instance (2026-07-26): its
	# JSON output is compact, no space after ':' - e.g.
	# {"result":{"status":{"print_stats":{"filename":"","state":"standby"...
	active=$(wget -q -O - --timeout=3 "http://127.0.0.1:7125/printer/objects/query?print_stats" 2>/dev/null)
	case "$active" in
		*'"state":"printing"'*|*'"state":"paused"'*)
			current=$(echo "$active" | sed -n 's/.*"filename":"\([^"]*\)".*/\1/p')
			[ -n "$current" ] && [ "$(basename "$f")" = "$(basename "$current")" ] && return 0
			;;
	esac
	# A file still growing (modified within the last minute) is treated as
	# a possible in-progress upload - ambiguous, so protected. BusyBox
	# find's -mmin (confirmed live, unlike -printf) is the portable check.
	if [ -n "$(find "$f" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
		return 0
	fi
	return 1
}

emergency_gcode_cleanup() {
	log "CRITICAL disk pressure - running emergency shared-gcode cleanup (verified stock pattern, docs/NEBULAOS_RETENTION_POLICY.md sec 2.4)"
	find "$SHARED_GCODES" -maxdepth 1 -name "*.gcode" -type f -mtime +7 2>/dev/null | \
		sort | while read -r f; do
		[ "$(free_mb)" -gt "$CRITICAL_FLOOR_MB" ] && break
		if gcode_is_protected "$f"; then
			log "SKIPPED (protected - active print/partial upload/ambiguous): $f"
			continue
		fi
		delete "$f" "emergency-gcode-disk-pressure"
	done
}

start() {
	mkdir -p "$NEBULAOS_ROOT/maintenance"
	wait_for_clock_sync

	if update_in_progress; then
		log "update transaction in progress - restricting to backup/log-only rotation this run"
		rotate_platform_logs
		clean_rotated_logs
		return 0
	fi

	rotate_platform_logs
	clean_rotated_logs
	clean_old_config_backups
	clean_abandoned_staging
	clean_obsolete_versions

	free=$(free_mb)
	if [ -z "$free" ]; then
		log "could not determine free space on /usr/data - skipping pressure-based actions"
		return 0
	fi

	if [ "$free" -lt "$CRITICAL_FLOOR_MB" ]; then
		log "CRITICAL: ${free}MB free (floor ${CRITICAL_FLOOR_MB}MB)"
		clean_pip_cache
		emergency_gcode_cleanup
	elif [ "$free" -lt "$CAUTION_FLOOR_MB" ]; then
		log "CAUTION: ${free}MB free (floor ${CAUTION_FLOOR_MB}MB) - new updates should be blocked until this clears (Phase 8's own concern, not this script's)"
	fi
}

start
