#!/bin/sh
#
# NebulaOS Phase 1 no-fork migration: runtime composition of official,
# unmodified Klipper with the NebulaOS Klipper extension set.
#
# WHY THIS EXISTS
# ---------------
# Klipper's own module loader is a hard filesystem gate, not an import path.
# Printer.load_object() (klippy/klippy.py) does
#
#     os.path.exists(os.path.dirname(__file__) + '/extras/<name>.py')
#
# BEFORE it ever calls importlib. No PYTHONPATH entry, .pth file, namespace
# package, or wrapper launcher can satisfy that check - a file has to
# physically resolve at <klipper>/klippy/extras/<name>.py. See
# _project/missions/2026-08-phase1-klipper-no-fork-analysis.md section 6 for
# the empirical proof (raw importlib succeeds from an external directory
# while Klipper's own gate returns False on the same module).
#
# But os.path.exists() follows symlinks, and git can be told to ignore a
# path per-clone via .git/info/exclude, which lives inside .git/ and is
# never part of any working tree. So: symlink each managed module into the
# Klipper checkout, list it in that clone's exclude file, and BOTH
# checkouts stay content-pristine - `git status --porcelain` empty, `git
# describe --dirty` with no -dirty, Moonraker reporting pristine/valid with
# zero anomalies. That is the entire Architecture C mechanism, and it was
# proven end to end (216 tests identical composed-vs-forked) before any of
# this shipped.
#
# THE ONE REAL HAZARD, AND WHY VERIFICATION IS MANDATORY
# ------------------------------------------------------
# If upstream Klipper ever ships a regular file at a path this project also
# manages, git SILENTLY overwrites the symlink with upstream's file - exit
# code 0, no warning, nothing in any status output. The extension is then
# shadowed and the printer runs upstream's code believing it runs ours. The
# exposed names are the vendored community ones (gcode_shell_command,
# virtual_pins) - exactly the kind of module mainline could adopt.
#
# So a regular file at a managed destination is a HARD ERROR here. It is
# never overwritten, never worked around, never logged-and-continued. The
# extension manifest declares this contract explicitly as
# composition.require_symlink_resolving_inside_source, and
# extras/nebulaos_compat.py re-checks it from inside Klippy as a second
# layer.
#
# CRASH SAFETY
# ------------
# Every entry point is idempotent and every rebuild starts from a full
# teardown, because a half-completed prior run is a real state this device
# can reach (power loss, OOM kill, a reboot mid-boot). The states that can
# be left behind, and how the next run handles each:
#
#   * exclude lines written, symlinks not yet created  -> teardown finds the
#     managed names in the exclude block and clears them; rebuild relinks.
#   * symlinks created, exclude lines missing          -> teardown finds the
#     managed names in the manifest and removes the links; rebuild relinks.
#     (Cannot actually happen given the write order below, handled anyway.)
#   * symlinks dangling (extensions tree replaced)     -> teardown removes
#     them by name; verification would have refused them regardless.
#   * marker written but link set later damaged        -> verification fails
#     independently of the marker, forcing a rebuild.
#   * marker half-written (killed mid-write)           -> the marker is
#     written atomically (tmp + mv) and last, so a partial one cannot exist;
#     a missing one simply reads as "needs rebuild".
#
# The marker is therefore an optimisation ("can I skip the rebuild?"), never
# the safety property. Verification is the safety property, and it runs on
# every single invocation whether or not a rebuild happened.
#
# WRITE ORDER (deliberate)
# ------------------------
# Collision scan -> exclude block -> symlinks -> verify -> marker. The
# exclude entries are written BEFORE the symlinks they cover so the Klipper
# checkout is never dirty, not even transiently, at any instant during a
# rebuild. A reader running `git status` mid-compose sees a clean tree.
#
# Sourced by /etc/init.d/S05nebulaos-activate (boot activation) and
# /etc/nebulaos-update-supervisor.sh (post-update recomposition), the same
# shared-library convention as /etc/nebulaos-maintenance-gate.sh. Every
# function takes its paths as arguments so tests can drive it against
# fixture directories with no device involved.
#
# POSIX sh only - this runs under BusyBox ash on the device. No jq, no
# stat, no bash-isms, no arrays.

NEBULAOS_COMPOSE_EXCLUDE_BEGIN="# BEGIN nebulaos-klipper-extensions (managed by /etc/nebulaos-klipper-compose.sh - do not edit)"
NEBULAOS_COMPOSE_EXCLUDE_END="# END nebulaos-klipper-extensions"
NEBULAOS_COMPOSE_MANIFEST_NAME="nebulaos-extensions.json"

# Paths this script manages inside the Klipper checkout that are NOT
# extension modules: its own generation marker and the chelper preflight
# verdict written by /etc/nebulaos-chelper-preflight.sh. Both must be
# excluded from git or they would make the official Klipper checkout show
# untracked files, which is the exact anomaly this architecture exists to
# avoid.
NEBULAOS_COMPOSE_EXTRA_EXCLUDES="/.nebulaos-composed
/.nebulaos-chelper-verdict.json"

compose_log() {
	echo "nebulaos-klipper-compose: $1"
}

compose_err() {
	echo "nebulaos-klipper-compose: ERROR: $1" >&2
}

# --------------------------------------------------------------------------
# Manifest reading
#
# The manifest is NebulaOS-authored and its shape is fixed by
# docs/COMPATIBILITY.md in the extension repo, so a line-oriented parse is
# adequate and far cheaper than shipping a JSON parser to a 208MB device.
# It is not, however, trusted blindly: every accessor that returns nothing
# is treated as a hard failure by its caller, and compose_module_paths
# refuses to proceed on an empty module list rather than silently composing
# zero modules and leaving Klippy to fail later with "Unable to load module".
# --------------------------------------------------------------------------

compose_manifest_path() {
	echo "$1/$NEBULAOS_COMPOSE_MANIFEST_NAME"
}

# Extract one "key": "value" pair from within a named top-level JSON object.
# Scoping matters: "source_dir" appears in BOTH the "composition" and
# "chelper" blocks of the real manifest with different values, so an
# unscoped grep would silently return the wrong one.
# $1=manifest file  $2=block name  $3=key
compose_json_block_str() {
	sed -n "/\"$2\"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/p" "$1" 2>/dev/null | \
		grep -o "\"$3\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | \
		sed -E "s/.*:[[:space:]]*\"([^\"]*)\"/\1/" | head -1
}

# Same, for a bare (unquoted) value such as true/false/null/number.
compose_json_block_bare() {
	sed -n "/\"$2\"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/p" "$1" 2>/dev/null | \
		grep -o "\"$3\"[[:space:]]*:[[:space:]]*[a-zA-Z0-9_.-]*" | \
		sed -E "s/.*:[[:space:]]*([a-zA-Z0-9_.-]*)$/\1/" | head -1
}

# $1=extensions dir  $2=composition key
compose_cfg() {
	compose_json_block_str "$(compose_manifest_path "$1")" composition "$2"
}

# Every managed module path, relative to the extensions repo root.
# $1=extensions dir  $2=role filter: "runtime", "test", or "" for all.
#
# Test modules ARE composed on this platform: several of them are imported
# by their runtime siblings' own doubles, and the disk cost is a symlink
# apiece. A deployment that wants to skip them can pass "runtime".
compose_module_paths() {
	extdir="$1"; want_role="${2:-}"
	manifest=$(compose_manifest_path "$extdir")
	[ -f "$manifest" ] || return 1
	sed -n '/"modules"[[:space:]]*:[[:space:]]*\[/,/^[[:space:]]*\]/p' "$manifest" 2>/dev/null | \
	grep '"path"' | while IFS= read -r line; do
		p=$(printf '%s' "$line" | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | \
			sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
		[ -n "$p" ] || continue
		if [ -n "$want_role" ]; then
			r=$(printf '%s' "$line" | grep -o '"role"[[:space:]]*:[[:space:]]*"[^"]*"' | \
				sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
			[ "$r" = "$want_role" ] || continue
		fi
		printf '%s\n' "$p"
	done
}

# --------------------------------------------------------------------------
# Path safety
#
# The manifest is NebulaOS-owned, but it also travels over the network as
# part of an independently-updatable git repository, so a malformed or
# hostile entry must not be able to make this script write outside the
# destination directory. Every module path is required to be exactly
# "<source_dir>/<basename>" - one level, no traversal, no absolute path, no
# nesting.
# --------------------------------------------------------------------------

# $1=module path from the manifest  $2=declared source_dir
# Echoes the safe basename on success; returns non-zero (silently) on reject.
compose_safe_basename() {
	p="$1"; srcdir="$2"
	case "$p" in
		/*)      return 1 ;;   # absolute
		*..*)    return 1 ;;   # traversal, in any position
		"$srcdir"/*) ;;        # must live under the declared source dir
		*)       return 1 ;;
	esac
	rest=${p#"$srcdir"/}
	[ -n "$rest" ] || return 1
	case "$rest" in
		*/*) return 1 ;;       # no nesting below source_dir
		.|..) return 1 ;;
	esac
	printf '%s\n' "$rest"
}

# --------------------------------------------------------------------------
# Exclude-file management
# --------------------------------------------------------------------------

# Names currently listed inside our managed block, as bare basenames.
# Used by teardown so a module REMOVED from the manifest since the last
# compose is still cleaned up - the manifest alone would not mention it.
# $1=exclude file  $2=destination_dir
compose_excluded_names() {
	exclude="$1"; destdir="$2"
	[ -f "$exclude" ] || return 0
	sed -n "\|^$NEBULAOS_COMPOSE_EXCLUDE_BEGIN\$|,\|^$NEBULAOS_COMPOSE_EXCLUDE_END\$|p" "$exclude" | \
		grep "^/$destdir/" | sed "s|^/$destdir/||"
}

# Remove our managed block, and any stray managed line that ended up outside
# it (defence against an exclude file written by an older version of this
# script, or hand-edited). Never touches a line this script did not write.
# $1=exclude file  $2=destination_dir
compose_exclude_clear() {
	exclude="$1"; destdir="$2"
	[ -f "$exclude" ] || return 0
	tmp="$exclude.nebulaos-tmp.$$"
	awk -v b="$NEBULAOS_COMPOSE_EXCLUDE_BEGIN" -v e="$NEBULAOS_COMPOSE_EXCLUDE_END" \
	    -v d="/$destdir/" '
		$0 == b { inblock = 1; next }
		$0 == e { inblock = 0; next }
		inblock { next }
		index($0, d) == 1 { next }
		$0 == "/.nebulaos-composed" { next }
		$0 == "/.nebulaos-chelper-verdict.json" { next }
		{ print }
	' "$exclude" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	mv "$tmp" "$exclude"
}

# grep-before-append, as required: repeated boots must never accumulate
# duplicate ignore lines. compose_exclude_clear already guarantees a clean
# slate on a rebuild, but this makes the property hold even if this function
# is ever called outside one.
# $1=exclude file  $2=line
compose_exclude_add() {
	grep -qxF "$2" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}

# --------------------------------------------------------------------------
# Teardown
# --------------------------------------------------------------------------

# Remove every managed symlink, the marker, and the managed exclude block.
# Deliberately does NOT remove arbitrary symlinks found in the destination
# directory - only names this project is known to manage (union of the
# current manifest and whatever the previous run recorded in the exclude
# block). Upstream Klipper does not ship symlinks in klippy/extras today,
# but "delete every symlink here" would be a landmine if it ever did.
#
# $1=klipper checkout  $2=extensions dir
compose_teardown() {
	kdir="$1"; extdir="$2"
	srcdir=$(compose_cfg "$extdir" source_dir)
	destdir=$(compose_cfg "$extdir" destination_dir)
	excl=$(compose_cfg "$extdir" exclude_file)
	marker=$(compose_cfg "$extdir" marker_file)
	[ -n "$destdir" ] || destdir="klippy/extras"
	[ -n "$excl" ] || excl=".git/info/exclude"
	[ -n "$marker" ] || marker=".nebulaos-composed"
	[ -n "$srcdir" ] || srcdir="extras"

	names=$(
		compose_excluded_names "$kdir/$excl" "$destdir"
		compose_module_paths "$extdir" | while IFS= read -r p; do
			compose_safe_basename "$p" "$srcdir" || true
		done
	)

	removed=0
	for n in $names; do
		[ -n "$n" ] || continue
		t="$kdir/$destdir/$n"
		# -L is true for a dangling symlink too, which is exactly the
		# case that must be cleaned up after the extensions tree was
		# replaced by a migration.
		if [ -L "$t" ]; then
			rm -f "$t"
			removed=$((removed + 1))
		fi
	done

	rm -f "$kdir/$marker"
	compose_exclude_clear "$kdir/$excl" "$destdir"
	compose_log "teardown: removed $removed managed symlink(s) and the managed exclude block from $kdir"
	return 0
}

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

# Assert every managed destination is a symlink resolving to the expected
# real file inside the extensions tree. This is the collision guard the
# extension manifest declares as mandatory, and it is what turns git's
# silent symlink-overwrite into a loud refusal.
#
# $1=klipper checkout  $2=extensions dir
compose_verify() {
	kdir="$1"; extdir="$2"
	srcdir=$(compose_cfg "$extdir" source_dir)
	destdir=$(compose_cfg "$extdir" destination_dir)
	[ -n "$srcdir" ] || srcdir="extras"
	[ -n "$destdir" ] || destdir="klippy/extras"

	src_root=$(readlink -f "$extdir/$srcdir" 2>/dev/null)
	if [ -z "$src_root" ] || [ ! -d "$src_root" ]; then
		compose_err "extensions source directory $extdir/$srcdir does not resolve to a real directory"
		return 1
	fi

	problems=0
	checked=0
	for p in $(compose_module_paths "$extdir"); do
		base=$(compose_safe_basename "$p" "$srcdir") || {
			compose_err "manifest declares an unsafe module path '$p' (absolute, traversing, or nested below $srcdir) - refusing"
			problems=$((problems + 1))
			continue
		}
		dst="$kdir/$destdir/$base"
		checked=$((checked + 1))

		if [ ! -L "$dst" ]; then
			if [ -e "$dst" ]; then
				compose_err "COLLISION: $destdir/$base is a regular file, not a NebulaOS symlink. Upstream Klipper now ships a file at a path this extension set manages, so the extension is SHADOWED. Refusing to activate - rename the extension module or drop it, do not overwrite upstream's file."
			else
				compose_err "$destdir/$base is missing - composition is incomplete"
			fi
			problems=$((problems + 1))
			continue
		fi

		resolved=$(readlink -f "$dst" 2>/dev/null)
		if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
			compose_err "$destdir/$base is a dangling symlink (target does not resolve to a file) - refusing"
			problems=$((problems + 1))
			continue
		fi
		case "$resolved" in
			"$src_root"/*) ;;
			*)
				compose_err "$destdir/$base resolves to $resolved, which is OUTSIDE the extensions source tree $src_root - refusing (improper symlink target or path traversal)"
				problems=$((problems + 1))
				continue
				;;
		esac
		expected=$(readlink -f "$extdir/$p" 2>/dev/null)
		if [ "$resolved" != "$expected" ]; then
			compose_err "$destdir/$base resolves to $resolved but the manifest declares $expected - refusing"
			problems=$((problems + 1))
		fi
	done

	if [ "$checked" -eq 0 ]; then
		compose_err "manifest declared zero modules - refusing to treat an empty composition as valid"
		return 1
	fi
	if [ "$problems" -ne 0 ]; then
		compose_err "composition verification FAILED with $problems problem(s) across $checked managed module(s)"
		return 1
	fi
	compose_log "verified $checked managed module(s): every destination is a symlink resolving inside $src_root"
	return 0
}

# Both checkouts must remain content-pristine. Any output at all is a
# failure - the whole point of the architecture is that neither tree is ever
# written to.
# $1=klipper checkout  $2=extensions dir
compose_verify_pristine() {
	rc=0
	for d in "$1" "$2"; do
		[ -d "$d/.git" ] || continue
		st=$(git -C "$d" status --porcelain 2>/dev/null)
		if [ -n "$st" ]; then
			compose_err "$d is not pristine after composition:"
			printf '%s\n' "$st" >&2
			rc=1
		fi
	done
	return $rc
}

# --------------------------------------------------------------------------
# Marker / generation signature
# --------------------------------------------------------------------------

# $1=klipper checkout  $2=extensions dir
compose_signature() {
	kdir="$1"; extdir="$2"
	kc=$(git -C "$kdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	ec=$(git -C "$extdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	mh=$(sha256sum "$(compose_manifest_path "$extdir")" 2>/dev/null | cut -d' ' -f1)
	[ -n "$mh" ] || mh="nomanifest"
	# The resolved extensions path is part of the signature so a change of
	# source location (a migration that moves the tree) forces a rebuild
	# even when both commits happen to be unchanged.
	sp=$(readlink -f "$extdir" 2>/dev/null || echo "$extdir")
	printf '%s:%s:%s:%s\n' "$kc" "$ec" "$mh" "$sp"
}

compose_marker_signature() {
	# $1=marker file
	[ -f "$1" ] || return 1
	sed -n 's/.*"signature"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1
}

# Written LAST and atomically, so it can never be observed half-complete.
# $1=klipper checkout  $2=extensions dir  $3=module count
compose_write_marker() {
	kdir="$1"; extdir="$2"; count="$3"
	marker=$(compose_cfg "$extdir" marker_file)
	[ -n "$marker" ] || marker=".nebulaos-composed"
	sig=$(compose_signature "$kdir" "$extdir")
	kc=$(git -C "$kdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	ec=$(git -C "$extdir" rev-parse HEAD 2>/dev/null || echo "nogit")
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	tmp="$kdir/$marker.tmp.$$"
	cat > "$tmp" <<EOF
{
  "schema": 1,
  "composed_at": "$now",
  "composed_at_caveat": "may read as an early-epoch date if this boot occurred before NTP sync",
  "klipper_commit": "$kc",
  "extensions_commit": "$ec",
  "extensions_source": "$(readlink -f "$extdir" 2>/dev/null || echo "$extdir")",
  "managed_module_count": $count,
  "signature": "$sig"
}
EOF
	mv "$tmp" "$kdir/$marker"
}

# --------------------------------------------------------------------------
# Build
# --------------------------------------------------------------------------

# Full teardown-then-rebuild. Always safe to call; never incremental.
# $1=klipper checkout  $2=extensions dir
compose_build() {
	kdir="$1"; extdir="$2"

	manifest=$(compose_manifest_path "$extdir")
	if [ ! -f "$manifest" ]; then
		compose_err "no compatibility manifest at $manifest - refusing to compose an unidentified extension tree"
		return 1
	fi

	srcdir=$(compose_cfg "$extdir" source_dir)
	destdir=$(compose_cfg "$extdir" destination_dir)
	excl=$(compose_cfg "$extdir" exclude_file)
	link_type=$(compose_cfg "$extdir" link_type)
	[ -n "$srcdir" ] || srcdir="extras"
	[ -n "$destdir" ] || destdir="klippy/extras"
	[ -n "$excl" ] || excl=".git/info/exclude"
	if [ -n "$link_type" ] && [ "$link_type" != "symlink" ]; then
		compose_err "manifest declares composition.link_type='$link_type', but this platform only implements 'symlink'"
		return 1
	fi

	if [ ! -d "$kdir/$destdir" ]; then
		compose_err "Klipper checkout $kdir has no $destdir directory - not a Klipper tree"
		return 1
	fi

	modules=$(compose_module_paths "$extdir")
	if [ -z "$modules" ]; then
		compose_err "manifest at $manifest declares no modules - refusing"
		return 1
	fi

	# Start from a genuinely clean slate. This is what makes recovery from
	# any half-completed prior run correct rather than merely likely.
	compose_teardown "$kdir" "$extdir"

	# Pass 1: collision + path-safety scan, BEFORE anything is written.
	# A collision must abort with the tree torn down, not half-composed.
	for p in $modules; do
		base=$(compose_safe_basename "$p" "$srcdir") || {
			compose_err "manifest declares an unsafe module path '$p' - refusing to compose"
			return 1
		}
		if [ ! -f "$extdir/$p" ]; then
			compose_err "manifest declares $p but no such file exists in the extensions repository at $extdir - refusing"
			return 1
		fi
		dst="$kdir/$destdir/$base"
		if [ -e "$dst" ] && [ ! -L "$dst" ]; then
			compose_err "COLLISION: upstream Klipper ships a regular file at $destdir/$base, which this extension set also manages. Refusing to compose - overwriting it would silently replace upstream's file, and leaving it would silently shadow the extension. This needs a deliberate decision (rename the NebulaOS module, or drop it because upstream now provides it)."
			return 1
		fi
	done

	# Pass 2: exclude entries FIRST, so the checkout is never dirty even
	# transiently while the symlinks are being created.
	mkdir -p "$(dirname "$kdir/$excl")"
	touch "$kdir/$excl" 2>/dev/null || {
		compose_err "cannot write $kdir/$excl"
		return 1
	}
	printf '%s\n' "$NEBULAOS_COMPOSE_EXCLUDE_BEGIN" >> "$kdir/$excl"
	for p in $modules; do
		base=$(compose_safe_basename "$p" "$srcdir") || continue
		compose_exclude_add "$kdir/$excl" "/$destdir/$base"
	done
	printf '%s\n' "$NEBULAOS_COMPOSE_EXTRA_EXCLUDES" | while IFS= read -r extra; do
		[ -n "$extra" ] && compose_exclude_add "$kdir/$excl" "$extra"
	done
	printf '%s\n' "$NEBULAOS_COMPOSE_EXCLUDE_END" >> "$kdir/$excl"

	# Pass 3: link, and verify each link the moment it is made rather than
	# only in bulk afterwards - a failure here names the exact module.
	count=0
	for p in $modules; do
		base=$(compose_safe_basename "$p" "$srcdir") || continue
		src="$extdir/$p"
		dst="$kdir/$destdir/$base"
		ln -sfn "$src" "$dst" || {
			compose_err "failed to create symlink $dst -> $src"
			return 1
		}
		resolved=$(readlink -f "$dst" 2>/dev/null)
		expected=$(readlink -f "$src" 2>/dev/null)
		if [ -z "$resolved" ] || [ "$resolved" != "$expected" ] || [ ! -f "$resolved" ]; then
			compose_err "post-link verification failed for $destdir/$base: resolves to '${resolved:-<nothing>}', expected '$expected'"
			return 1
		fi
		count=$((count + 1))
	done

	compose_verify "$kdir" "$extdir" || return 1
	compose_verify_pristine "$kdir" "$extdir" || return 1
	compose_write_marker "$kdir" "$extdir" "$count"
	compose_log "composed $count module(s) from $extdir into $kdir/$destdir"
	return 0
}

# --------------------------------------------------------------------------
# Idempotent entry point
# --------------------------------------------------------------------------

# Bring the composition to the correct state and prove it. Rebuilds only
# when the recorded generation no longer matches reality, but ALWAYS
# verifies - so a silently-shadowed module is caught even on a boot where
# nothing appeared to change.
#
# $1=klipper checkout  $2=extensions dir
# Returns 0 only when the composition is present, complete, and verified.
compose_ensure() {
	kdir="$1"; extdir="$2"

	if [ ! -d "$kdir" ]; then
		compose_err "Klipper checkout $kdir does not exist"
		return 1
	fi
	if [ ! -d "$extdir" ]; then
		compose_err "extensions checkout $extdir does not exist"
		return 1
	fi
	manifest=$(compose_manifest_path "$extdir")
	if [ ! -f "$manifest" ]; then
		compose_err "no compatibility manifest at $manifest"
		return 1
	fi

	marker_name=$(compose_cfg "$extdir" marker_file)
	[ -n "$marker_name" ] || marker_name=".nebulaos-composed"
	want=$(compose_signature "$kdir" "$extdir")
	have=$(compose_marker_signature "$kdir/$marker_name" 2>/dev/null)

	if [ -n "$have" ] && [ "$have" = "$want" ]; then
		if compose_verify "$kdir" "$extdir"; then
			compose_log "composition already current and verified (generation ${have%%:*}...) - nothing to rebuild"
			return 0
		fi
		compose_log "recorded generation matches but verification failed - forcing a full rebuild"
	elif [ -n "$have" ]; then
		compose_log "generation changed (recorded '$have', expected '$want') - rebuilding composition"
	else
		compose_log "no valid composition marker at $kdir/$marker_name - building composition"
	fi

	compose_build "$kdir" "$extdir"
}
