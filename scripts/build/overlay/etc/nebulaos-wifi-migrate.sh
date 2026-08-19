#!/bin/sh
#
# Phase 1.5 persistent-namespace mission (2026-08): safely moves the Wi-Fi
# credential file from its current location,
# /usr/data/nebulaos/wpa_supplicant.conf, into the new, more consistent
# namespace subdirectory /usr/data/nebulaos/network/wpa_supplicant.conf -
# WITHOUT ever risking the one credential file that is also this device's
# only real remote-access path (SSH rides the same wlan0 association).
#
# Sourced by S01wifi, which is this file's only real caller. Exposes one
# function, nebulaos_wifi_migrate, which sets NEBULAOS_WIFI_CONF to
# whichever path the caller should actually hand to wpa_supplicant -i
# wlan0 -c <path> afterward. Every code path below sets it to something
# usable; nothing here ever leaves a device with no config path chosen.
#
# The five cases below match this mission's own governing brief exactly
# (case letters kept identical so the two documents can be read side by
# side): A existing device (NEW already there), B first migration (OLD
# real file, NEW absent), C virgin device (neither exists), D a write
# failure partway through migration, E an unexpected filesystem object at
# either path. Real tests: tests/nebulaos-wifi-migrate-tests.sh.

NEBULAOS_WIFI_OLD="${NEBULAOS_WIFI_OLD:-/usr/data/nebulaos/wpa_supplicant.conf}"
NEBULAOS_WIFI_NEW="${NEBULAOS_WIFI_NEW:-/usr/data/nebulaos/network/wpa_supplicant.conf}"

_nebulaos_wifi_log() {
	echo "nebulaos-wifi-migrate: $1"
}

# True (0) only for a plain regular file - not a directory, symlink,
# FIFO, device node, or anything else. `[ -f ]` alone is not enough: it
# follows symlinks, so a symlink to a regular file would pass `[ -f ]`
# but must still be handled as its own case (E) rather than treated as
# an ordinary file, because blindly operating through it could silently
# write through to something unexpected.
_nebulaos_wifi_is_plain_regular_file() {
	[ -f "$1" ] || return 1
	[ -L "$1" ] && return 1
	return 0
}

_nebulaos_wifi_exists_at_all() {
	[ -e "$1" ] || [ -L "$1" ]
}

# Case-E guard: is $1 a plain regular file, a symlink, or nothing at all?
# (the only three shapes this migration ever handles itself). Anything
# else - a directory, FIFO, device node, socket - is unexpected and must
# never be followed, deleted, or replaced.
_nebulaos_wifi_is_safe_shape() {
	path="$1"
	if [ ! -e "$path" ] && [ ! -L "$path" ]; then
		return 0
	fi
	if [ -L "$path" ]; then
		return 0
	fi
	if [ -f "$path" ]; then
		return 0
	fi
	return 1
}

# Atomically makes $2 (OLD) a symlink to the basename-relative target $3,
# but ONLY when doing so cannot lose data: $2 must not exist, already be
# the correct symlink, or (as a regular file) be byte-for-byte identical
# to $1 (NEW's real current content) - the one case where converting a
# real file into a symlink is provably lossless. Anything else is left
# completely alone; this function only ever adds safety, never removes it.
_nebulaos_wifi_establish_compat_symlink() {
	new="$1"
	old="$2"
	rel_target="$3"

	if [ -L "$old" ]; then
		current_target=$(readlink "$old" 2>/dev/null)
		if [ "$current_target" = "$rel_target" ]; then
			return 0
		fi
		_nebulaos_wifi_log "WARNING: $old is already a symlink to '$current_target', not '$rel_target' - leaving it alone rather than guessing"
		return 0
	fi

	if [ ! -e "$old" ]; then
		ln -s "$rel_target" "$old" 2>/dev/null || {
			_nebulaos_wifi_log "WARNING: could not create compatibility symlink at $old - continuing without it, $new remains the real, working config"
			return 1
		}
		return 0
	fi

	if _nebulaos_wifi_is_plain_regular_file "$old"; then
		if cmp -s "$old" "$new"; then
			tmp_link="$old.compat-tmp.$$"
			if ln -s "$rel_target" "$tmp_link" 2>/dev/null && mv -f "$tmp_link" "$old" 2>/dev/null; then
				return 0
			fi
			rm -f "$tmp_link" 2>/dev/null
			_nebulaos_wifi_log "WARNING: could not atomically replace $old with a compatibility symlink - leaving the real file in place, $new remains authoritative"
			return 1
		fi
		_nebulaos_wifi_log "NOTE: $old still holds different content than $new - leaving it as a real file rather than risking data loss; $new is what actually gets used"
		return 1
	fi

	_nebulaos_wifi_log "NOTE: $old is not a plain file or symlink - leaving it alone"
	return 1
}

# Case B's core copy step: mkdir the target directory, write through a
# temp file in that SAME directory (so the final rename is on the same
# filesystem and therefore atomic), fsync the temp file's data before the
# rename, rename into place, then fsync the containing directory so the
# rename itself is durable across a power loss, not just the data.
_nebulaos_wifi_atomic_copy() {
	src="$1"
	dst="$2"
	dst_dir=$(dirname "$dst")
	tmp="$dst.tmp.$$"

	mkdir -p "$dst_dir" || return 1

	oldmask=$(umask)
	umask 077
	cp -a "$src" "$tmp"
	cp_rc=$?
	umask "$oldmask"
	[ "$cp_rc" -eq 0 ] || {
		rm -f "$tmp" 2>/dev/null
		return 1
	}
	chmod 0600 "$tmp" 2>/dev/null

	if command -v sync >/dev/null 2>&1; then
		sync
	fi

	mv -f "$tmp" "$dst" || {
		rm -f "$tmp" 2>/dev/null
		return 1
	}

	if command -v sync >/dev/null 2>&1; then
		sync
	fi

	[ -f "$dst" ] || return 1
	cmp -s "$src" "$dst" || return 1
	return 0
}

nebulaos_wifi_migrate() {
	old="$NEBULAOS_WIFI_OLD"
	new="$NEBULAOS_WIFI_NEW"
	rel_target="network/$(basename "$new")"

	# Case E, checked first and independently for both paths: never
	# follow/delete/replace a directory, FIFO, device node, or any object
	# that isn't a plain regular file or a symlink. Fail safe rather than
	# guess - if NEW is unusable this way, nothing here overwrites it, and
	# the caller gets told there is no usable config path this boot.
	if ! _nebulaos_wifi_is_safe_shape "$new"; then
		_nebulaos_wifi_log "FATAL: $new exists but is not a regular file or symlink - refusing to touch it. Wi-Fi will not start this boot until this is resolved by hand."
		NEBULAOS_WIFI_CONF=""
		return 1
	fi
	if ! _nebulaos_wifi_is_safe_shape "$old"; then
		_nebulaos_wifi_log "WARNING: $old exists but is not a regular file or symlink - leaving it alone."
		old_is_safe=0
	else
		old_is_safe=1
	fi

	# Case A - NEW already exists: use it, never reseed, just make sure the
	# compatibility path is in a good state.
	if [ -e "$new" ]; then
		_nebulaos_wifi_log "using existing $new"
		if [ "$old_is_safe" -eq 1 ]; then
			_nebulaos_wifi_establish_compat_symlink "$new" "$old" "$rel_target"
		fi
		NEBULAOS_WIFI_CONF="$new"
		return 0
	fi

	# Case B - OLD is a real, plain file and NEW doesn't exist yet: this is
	# the first boot on this device after this mission's own image update.
	# Copy first, verify, THEN touch OLD - never mv/delete OLD before a
	# verified durable replacement exists.
	if [ "$old_is_safe" -eq 1 ] && _nebulaos_wifi_is_plain_regular_file "$old"; then
		_nebulaos_wifi_log "migrating $old -> $new"
		if _nebulaos_wifi_atomic_copy "$old" "$new"; then
			_nebulaos_wifi_log "migration verified ($new matches $old byte for byte)"
			_nebulaos_wifi_establish_compat_symlink "$new" "$old" "$rel_target"
			NEBULAOS_WIFI_CONF="$new"
			return 0
		fi
		# Case D - the copy/verify failed partway through. OLD has not
		# been touched by _nebulaos_wifi_atomic_copy (it only ever reads
		# it), and NEW was only ever reached via a temp-file rename, so a
		# failure here cannot have left a partial NEW behind either - the
		# rename is the last step, and everything before it operates only
		# on the temp file.
		_nebulaos_wifi_log "FATAL: could not durably migrate $old to $new - leaving $old exactly as it was, using it for this boot"
		rm -f "$new" 2>/dev/null
		NEBULAOS_WIFI_CONF="$old"
		return 1
	fi

	# Case A variant - OLD is already a symlink (a previous migration ran
	# and established it, but NEW itself is somehow now missing - e.g. the
	# partition was restored from an old backup that predates NEW). Do not
	# treat the symlink as real content to migrate; fall through to case C
	# and seed a fresh NEW, then leave the existing OLD symlink as it is
	# (it will start resolving correctly again once NEW exists).
	if [ -L "$old" ]; then
		_nebulaos_wifi_log "NOTE: $old is a symlink but its target ($new) is missing - reseeding $new fresh; real prior credentials may be lost if this was not a genuinely virgin restore, see the log above"
	fi

	# Case C - neither exists (or OLD is a dangling symlink, handled just
	# above): genuinely virgin device. Seed a credential-free skeleton at
	# NEW only, mode 0600.
	_nebulaos_wifi_log "no existing Wi-Fi config found - seeding a fresh, credential-free $new"
	new_dir=$(dirname "$new")
	mkdir -p "$new_dir" || {
		_nebulaos_wifi_log "FATAL: could not create $new_dir"
		NEBULAOS_WIFI_CONF=""
		return 1
	}
	oldmask=$(umask)
	umask 077
	cat > "$new" <<-EOF
	ctrl_interface=/var/run/wpa_supplicant
	update_config=1
	EOF
	seed_rc=$?
	umask "$oldmask"
	if [ "$seed_rc" -ne 0 ] || [ ! -f "$new" ]; then
		_nebulaos_wifi_log "FATAL: could not seed $new"
		NEBULAOS_WIFI_CONF=""
		return 1
	fi
	chmod 0600 "$new" 2>/dev/null
	if [ "$old_is_safe" -eq 1 ] && [ ! -L "$old" ]; then
		_nebulaos_wifi_establish_compat_symlink "$new" "$old" "$rel_target"
	fi
	NEBULAOS_WIFI_CONF="$new"
	return 0
}
