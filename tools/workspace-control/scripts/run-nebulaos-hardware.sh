#!/usr/bin/env bash
#
# NebulaOS hardware qualification launcher - the ONLY command the Hardware
# Qualification Agent (nebulaos-hardware) is permitted to run outside Claude's
# sandbox, and its only permitted route to a printer.
#
# WHY THIS EXISTS
#
# The PreToolUse hook refuses ssh/scp/sftp/ping/nc/socat/... to the hardware
# agent outright (rule 4), with no target-bound exception. That refusal is
# deliberate and STAYS: raw device commands remain denied to the agent even
# after this launcher exists. The agent reaches hardware only by invoking this
# file, whose command word is `run-nebulaos-hardware.sh` and therefore does not
# match the refused set. All device contact is encapsulated here, where it can
# be constrained, rather than being spelled out ad hoc in agent-authored shell.
#
# Like the build launcher, the escape is bound to this file by REAL PATH **and
# by CONTENT** - the installed copy's bytes must equal the tracked canonical
# blob at firmware HEAD. Path identity alone is not enough: tools/ is
# unversioned derived state that the sandbox permits writing, so naming an
# allowed path could otherwise run arbitrary code with host privilege.
#
# THIS LAUNCHER REIMPLEMENTS NO WRITE
#
# Every partition write is performed by scripts/flash-spare-slot.sh, ON the
# device, exactly as docs/DEVELOPER_UPDATE.md documents. That script owns the
# slot model, the live-slot collision refusal, the capacity checks and the
# post-write read-back verification, and it has its own offline test suite
# (tests/flash-spare-slot-preflight-tests.sh). Duplicating any of that here
# would create a second implementation of the safety logic to keep correct.
# This file is a gate and a courier, not a second flasher.
#
# The two incidents recorded in flash-spare-slot.sh's header - a write that
# landed on the live executing rootfs, and a transfer truncated mid-flight -
# are the reason this launcher verifies hashes before handing anything over
# and then lets that script re-verify everything again on the device.
#
# PART 1 SCOPE ONLY
#
# This launcher implements system-image installation and read-only inspection.
# It contains no code path that homes an axis, moves a motor, heats a nozzle or
# bed, extrudes, runs a calibration, starts a print, or flashes/erases the MCU.
# Those belong to hardware qualification Part 2 and are deliberately absent, not
# merely discouraged.
#
# TARGET BINDING, AND WHY IT IS NOT JUST AN IP
#
# The printer's address is assigned by DHCP and can drift. An address is
# therefore NOT an identity: the machine answering at a remembered IP may be a
# different device entirely. So this launcher does two separate things:
#
#   1. constrains WHICH addresses may be spoken to at all - the bound default,
#      or an explicitly stated RFC1918 private IPv4. Never a hostname (which
#      would mean DNS, and a name that resolves anywhere), never a public
#      address, never a range or a scan.
#   2. pins WHAT answers there. On first contact it records the SSH host key
#      and a device fingerprint; on every later run it re-derives them and
#      refuses any destructive subcommand if either changed. A new machine on
#      the old lease is caught here rather than being flashed.
#
# Credentials: this image's /root is a read-only squashfs, so authorized_keys
# cannot be installed and password auth is the only option. Uses SSH_ASKPASS
# (no sshpass, which is not installed here; no setsid, which silently breaks
# stdout capture in this class of environment) - the same pattern already used
# by scripts/qa/display-live-capture.sh. The password is never placed in argv,
# where any local user could read it out of the process list.
#
# Usage:
#   run-nebulaos-hardware.sh [--host <private-ipv4>] <subcommand> \
#       <firmware-sha> <ximage-sha256> <rootfs-sha256>
#
# Subcommands (each is a separate, deliberate step - nothing chains):
#   inventory   read-only pre-flash inventory; writes nothing on the device
#   preflight   stage artifacts + flash-spare-slot.sh --check-only; no slot write
#   flash       write slot 2 via flash-spare-slot.sh; does NOT flip the marker
#   marker      flip the OTA marker to ota:kernel2; does NOT reboot
#   reboot      operator-triggered reboot
#   verify      post-boot running identity + service health; read-only
#
# All three identities are mandatory on every subcommand, including the
# read-only ones. A hardware session that did not state up front which release
# it is qualifying is not a qualification session, and `verify` needs them in
# order to have something to compare the running device against.
set -uo pipefail
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C

BOUND_HOST_DEFAULT=192.168.0.98
SSH_USER_DEFAULT=root
STATE_BASE=/var/tmp/nebulaos-hardware

say(){ printf '%s\n' "$*"; }
die(){ printf 'RUN_NEBULAOS_HARDWARE=REFUSED\nREASON: %s\n' "$1" >&2; exit 2; }
fail(){ printf 'RUN_NEBULAOS_HARDWARE=FAILED\nREASON: %s\n' "$1" >&2; exit 3; }

# --- resolve the workspace root structurally, never by a hard-coded path ----
SELF=$(readlink -f "${BASH_SOURCE[0]}") || die "cannot resolve own path"
SELF_DIR=$(dirname "$SELF")
case "$SELF_DIR" in
  */NebulaOS-firmware/tools/workspace-control/scripts) ROOT=$(cd "$SELF_DIR/../../../.." && pwd -P) ;;
  */tools)                                             ROOT=$(cd "$SELF_DIR/.." && pwd -P) ;;
  *) die "launcher is not in a recognised location: $SELF_DIR" ;;
esac

# --- structural proof this is a live workspace root, not a decoy ------------
[ -x "$ROOT/tools/verify-workspace-identity.sh" ] \
  || die "not a NebulaOS workspace root (no installed identity gate): $ROOT"
[ -f "$ROOT/NebulaOS-firmware/tools/workspace-control/MANIFEST" ] \
  || die "not a NebulaOS workspace root (no canonical control source): $ROOT"
FW="$ROOT/NebulaOS-firmware"
[ -d "$FW/.git" ] || die "$FW is not a git checkout"

FLASH_SCRIPT="$FW/scripts/flash-spare-slot.sh"
[ -f "$FLASH_SCRIPT" ] || die "the documented on-device flash script is missing: $FLASH_SCRIPT"

# --- arguments --------------------------------------------------------------
HOST=$BOUND_HOST_DEFAULT
HOST_EXPLICIT=no
if [ "${1:-}" = "--host" ]; then
  HOST=${2:-}
  HOST_EXPLICIT=yes
  shift 2 2>/dev/null || die "--host requires an address"
fi
case "${1:-}" in
  --*) die "unknown option '${1}'. Accepts only: [--host <private-ipv4>] <subcommand> <firmware-sha> <ximage-sha256> <rootfs-sha256>" ;;
esac

[ "$#" -eq 4 ] || die "usage: run-nebulaos-hardware.sh [--host <private-ipv4>] <subcommand> <firmware-sha> <ximage-sha256> <rootfs-sha256> (got $# argument(s))"
SUBCMD=$1; EXPECT_FW=$2; EXPECT_XIMAGE=$3; EXPECT_ROOTFS=$4

case "$SUBCMD" in
  inventory|preflight|flash|marker|reboot|verify) ;;
  *) die "unknown subcommand '$SUBCMD'. Part 1 subcommands: inventory preflight flash marker reboot verify.
       Motion, heating, extrusion, calibration and MCU flashing are Part 2 and are not implemented here." ;;
esac

is_hex(){ case "$1" in *[!0-9a-f]*|"") return 1 ;; esac; [ "${#1}" -eq "$2" ]; }
is_hex "$EXPECT_FW"     40 || die "firmware-sha must be a full 40-character lowercase hex SHA"
is_hex "$EXPECT_XIMAGE" 64 || die "ximage-sha256 must be a full 64-character lowercase hex SHA256"
is_hex "$EXPECT_ROOTFS" 64 || die "rootfs-sha256 must be a full 64-character lowercase hex SHA256"

# --- target constraint ------------------------------------------------------
# A literal dotted-quad only. No hostname, so no DNS lookup and no name that
# could resolve off-LAN. No CIDR, no range, no list: exactly one host.
case "$HOST" in
  *[!0-9.]*|"") die "target must be a literal IPv4 address, not a hostname: '$HOST'" ;;
esac
IFS=. read -r o1 o2 o3 o4 extra <<<"$HOST"
[ -z "${extra:-}" ] || die "target is not a dotted quad: '$HOST'"
for o in "$o1" "$o2" "$o3" "$o4"; do
  [ -n "${o:-}" ] || die "target is not a dotted quad: '$HOST'"
  case "$o" in *[!0-9]*) die "target is not a dotted quad: '$HOST'" ;; esac
  [ "$o" -le 255 ] 2>/dev/null || die "target octet out of range: '$HOST'"
done
# RFC1918 only. A qualification rig is on a private LAN; refusing everything
# else means a typo or a bad argument cannot reach the public internet.
private=no
case "$o1.$o2" in
  10.*) private=yes ;;
  192.168) private=yes ;;
  172.1[6-9]|172.2[0-9]|172.3[01]) private=yes ;;
esac
[ "$private" = yes ] || die "refusing a non-RFC1918 target '$HOST'. This launcher speaks only to a private-LAN address."

SSH_USER=${NEBULAOS_SSH_USER:-$SSH_USER_DEFAULT}
# Default is NebulaOS's root password. Stock Creality's is Creality2023; pass it
# via the environment when addressing a device booted into the stock slot.
SSH_PASSWORD=${NEBULAOS_SSH_PASSWORD:-openke}

DESTRUCTIVE=no
case "$SUBCMD" in preflight|flash|marker|reboot) DESTRUCTIVE=yes ;; esac

# --- the canonical workspace must be sound before hardware is touched -------
# Same precondition as the build launcher: architecture is derived from a
# passing gate, never from recollection. Read-only subcommands still require it,
# because an inventory taken against an unknown source generation is not
# evidence of anything.
# FULL ONLINE gate, not the fast --hook gate. Flashing is the least reversible
# boundary in the project: what lands on the printer must correspond to source
# that was checked against the canonical remote, not merely to a locally
# self-consistent checkout. The fast gate never resolves a remote, so it cannot
# make that statement. Read-only subcommands require it too - an inventory taken
# against an unverified source generation is not evidence of anything.
"$ROOT/tools/verify-workspace-identity.sh" --full >/dev/null 2>&1 \
  || die "full online workspace identity gate failed - run tools/verify-workspace-identity.sh and resolve before any hardware operation.
       This boundary requires the canonical remotes to be reachable. An unresolved remote is an
       UNVERIFIED source generation, not a pass; it is refused rather than downgraded to offline."

if [ "$DESTRUCTIVE" = yes ]; then
  DIRTY=0
  for r in NebulaOS-firmware NebulaOS-klipper-extensions NebulaOS-kernel NebulaOS-guppyscreen NebulaOS-klipper-mcu; do
    [ -d "$ROOT/$r/.git" ] || continue
    n=$(git -C "$ROOT/$r" status --porcelain --untracked-files=all 2>/dev/null | grep -vc '^?? \.mcp\.json$' || true)
    [ "$n" -eq 0 ] || { printf 'REASON: %s has %s uncommitted change(s)\n' "$r" "$n" >&2; DIRTY=1; }
  done
  [ "$DIRTY" -eq 0 ] || die "refusing to flash from a dirty canonical workspace - what is on the printer must correspond to committed, published source"
fi

# --- locate the artifact by SOURCE IDENTITY, never by filename --------------
# Deliberately not a "latest" symlink or a newest-mtime pick. The build
# workspace is keyed by the exact commit, and the manifest inside it must agree.
BUILD_BASE=/var/tmp/nebulaos-build
ART_DIR=""
ART_RUN=""
if [ -d "$BUILD_BASE/$EXPECT_FW" ]; then
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    d="$cand/artifacts/buildroot-halley5-v30-image"
    [ -f "$d/xImage" ] && [ -f "$d/rootfs.squashfs" ] && [ -f "$d/build-manifest.txt" ] || continue
    # The clone that produced it must itself be the requested commit.
    got=$(git -C "$cand" rev-parse HEAD 2>/dev/null || true)
    [ "$got" = "$EXPECT_FW" ] || continue
    ART_DIR=$d; ART_RUN=$cand
    # Prefer a run that carries a build attestation. A run without one is still
    # usable for read-only inspection, but the destructive gate below refuses
    # it, so picking an attested run when one exists avoids a pointless refusal.
    [ -f "$cand/.nebulaos-build-verified" ] && break
  done < <(find "$BUILD_BASE/$EXPECT_FW" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi
[ -n "$ART_DIR" ] || die "no build workspace found for $EXPECT_FW under $BUILD_BASE with a complete, matching artifact set.
       Build it first via the nebulaos-build agent; this launcher never builds and never selects an artifact by filename."

XIMAGE="$ART_DIR/xImage"
ROOTFS="$ART_DIR/rootfs.squashfs"
MANIFEST="$ART_DIR/build-manifest.txt"

man_get(){ grep -m1 "^$1=" "$MANIFEST" 2>/dev/null | cut -d= -f2-; }

# --- artifact identity: three independent agreements ------------------------
# (1) the caller's stated hashes, (2) the bytes on disk, (3) the manifest the
# build itself emitted. All three must agree, and the manifest must name the
# same source commit. Any one of them alone is a weaker claim than it looks.
GOT_XIMAGE=$(sha256sum "$XIMAGE" 2>/dev/null | awk '{print $1}')
GOT_ROOTFS=$(sha256sum "$ROOTFS" 2>/dev/null | awk '{print $1}')
[ -n "$GOT_XIMAGE" ] && [ -n "$GOT_ROOTFS" ] || fail "cannot hash the artifacts in $ART_DIR"

MAN_XIMAGE=$(man_get xImage_sha256)
MAN_ROOTFS=$(man_get rootfs_squashfs_sha256)
MAN_COMMIT=$(man_get git_commit_main)

[ "$GOT_XIMAGE" = "$EXPECT_XIMAGE" ] || die "xImage on disk ($GOT_XIMAGE) != stated expected ($EXPECT_XIMAGE)"
[ "$GOT_ROOTFS" = "$EXPECT_ROOTFS" ] || die "rootfs.squashfs on disk ($GOT_ROOTFS) != stated expected ($EXPECT_ROOTFS)"
[ "$MAN_XIMAGE" = "$GOT_XIMAGE" ]    || die "xImage does not match the build manifest ($MAN_XIMAGE) - the artifact and its manifest disagree"
[ "$MAN_ROOTFS" = "$GOT_ROOTFS" ]    || die "rootfs.squashfs does not match the build manifest ($MAN_ROOTFS) - the artifact and its manifest disagree"
[ "$MAN_COMMIT" = "$EXPECT_FW" ]     || die "the build manifest records git_commit_main=$MAN_COMMIT, not the requested $EXPECT_FW"

# --- BUILD_VERIFIED: bytes agreeing is not the same as a build having passed --
# The three checks above prove the artifact set is internally consistent and is
# the one the caller named. They do NOT prove a build ever completed cleanly: a
# half-finished run whose manifest happens to match its own partial output would
# satisfy every one of them.
#
# The build launcher writes .nebulaos-build-verified only when build.sh exited
# zero AND the canonical workspace was still clean afterwards. That attestation
# is the authority for BUILD_VERIFIED here; it is not recomputed, because
# recomputing it would mean reimplementing the build's own success criteria.
ATT="$ART_RUN/.nebulaos-build-verified"
BUILD_VERIFIED=NO
ATT_MODE=none
if [ -f "$ATT" ]; then
  att_get(){ grep -m1 "^$1=" "$ATT" 2>/dev/null | cut -d= -f2-; }
  if [ "$(att_get BUILD_VERIFIED)" = YES ] \
  && [ "$(att_get SOURCE_HEAD)" = "$EXPECT_FW" ] \
  && [ "$(att_get XIMAGE_SHA256)" = "$GOT_XIMAGE" ] \
  && [ "$(att_get ROOTFS_SQUASHFS_SHA256)" = "$GOT_ROOTFS" ]; then
    BUILD_VERIFIED=YES
    ATT_MODE=$(att_get BUILD_MODE)
  fi
fi

printf 'RUN_NEBULAOS_HARDWARE=ARTIFACT_VERIFIED\nARTIFACT_SOURCE_HEAD=%s\nARTIFACT_XIMAGE_SHA256=%s\nARTIFACT_ROOTFS_SHA256=%s\nARTIFACT_BUILD_RUN=%s\nARTIFACT_DIR=%s\nARTIFACT_IDENTITY_VERIFIED=YES\nBUILD_VERIFIED=%s\nBUILD_ATTESTED_MODE=%s\n' \
  "$EXPECT_FW" "$GOT_XIMAGE" "$GOT_ROOTFS" "$ART_RUN" "$ART_DIR" "$BUILD_VERIFIED" "$ATT_MODE"

if [ "$DESTRUCTIVE" = yes ] && [ "$BUILD_VERIFIED" != YES ]; then
  die "BUILD_VERIFIED=NO - refusing a destructive hardware operation.
       No build attestation at $ATT, or it does not match these exact artifacts.
       The artifact bytes are self-consistent, but nothing proves a build of $EXPECT_FW
       completed cleanly and kept its isolation guarantee. Re-run the build through the
       nebulaos-build agent; this launcher never attests a build it did not witness.
       Read-only subcommands (inventory, verify) remain available."
fi

# --- ssh plumbing -----------------------------------------------------------
STATE_DIR="$STATE_BASE/$HOST"
mkdir -p "$STATE_DIR" 2>/dev/null || die "cannot create launcher state directory $STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
KNOWN_HOSTS="$STATE_DIR/known_hosts"
FINGERPRINT="$STATE_DIR/device-fingerprint"

ASKPASS=$(mktemp) || die "cannot create an askpass helper"
chmod 700 "$ASKPASS"
# Single-quoted body would not interpolate; this heredoc deliberately expands
# $SSH_PASSWORD into a private temp file rather than passing it in argv, where
# it would be visible in the process list to every local user.
cat > "$ASKPASS" <<EOF
#!/bin/sh
printf '%s\n' "$SSH_PASSWORD"
EOF
cleanup(){ rm -f "$ASKPASS"; }
trap cleanup EXIT INT TERM

SSH_BASE_OPTS=(
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o ConnectTimeout=10
  -o BatchMode=no
)

remote(){
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    ssh "${SSH_BASE_OPTS[@]}" "$SSH_USER@$HOST" "$@"
}
push(){
  SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    scp "${SSH_BASE_OPTS[@]}" "$1" "$SSH_USER@$HOST:$2"
}

# --- device identity: an address is not an identity -------------------------
# DHCP can move the lease. Before anything destructive, prove the machine
# answering now is the machine we pinned earlier.
probe_fingerprint(){
  remote 'printf "cid=%s\n" "$(cat /sys/class/net/wlan0/address 2>/dev/null || echo unknown)";
          printf "machine=%s\n" "$(cat /etc/machine-id 2>/dev/null || echo unknown)";
          printf "partlabels=%s\n" "$(ls /dev/disk/by-partlabel/ 2>/dev/null | tr "\n" "," || echo unknown)"' 2>/dev/null
}

looks_like_the_printer(){
  # Structural, not cosmetic: the A/B slot model must actually be present.
  remote 'test -b /dev/mmcblk0p6 && test -b /dev/mmcblk0p8 && test -f /proc/cmdline' >/dev/null 2>&1
}

say ""
say "== contacting $SSH_USER@$HOST =="
if ! remote true >/dev/null 2>&1; then
  fail "cannot open an SSH session to $HOST as $SSH_USER.
       The address may have drifted (DHCP). Re-derive it with the documented method and pass
       --host <new-private-ipv4>; do not scan the network. If the device is booted into the
       stock slot, the root password differs - set NEBULAOS_SSH_PASSWORD accordingly."
fi

looks_like_the_printer \
  || fail "the host at $HOST does not present the expected A/B slot layout (mmcblk0p6 + mmcblk0p8).
       Refusing to treat it as the printer. This is the DHCP-drift guard doing its job."

NOW_FP=$(probe_fingerprint | sort)
[ -n "$NOW_FP" ] || fail "could not read a device fingerprint from $HOST"

if [ -f "$FINGERPRINT" ]; then
  if ! printf '%s\n' "$NOW_FP" | diff -q - "$FINGERPRINT" >/dev/null 2>&1; then
    say "DEVICE_FINGERPRINT_CHANGED=YES"
    say "--- pinned ---"; cat "$FINGERPRINT"
    say "--- now ---";    printf '%s\n' "$NOW_FP"
    if [ "$DESTRUCTIVE" = yes ]; then
      fail "the device at $HOST is not the one pinned for this address.
       A DHCP lease can move to a different machine; flashing the wrong one is not recoverable
       over the network. Confirm the target by hand, then remove $FINGERPRINT to re-pin."
    fi
    say "(read-only subcommand: continuing, but the mismatch is recorded above)"
  else
    say "DEVICE_FINGERPRINT_MATCHES_PIN=YES"
  fi
else
  printf '%s\n' "$NOW_FP" > "$FINGERPRINT"
  say "DEVICE_FINGERPRINT_PINNED=YES (first contact with $HOST)"
  if [ "$HOST_EXPLICIT" = yes ] && [ "$DESTRUCTIVE" = yes ]; then
    fail "first contact with an explicitly supplied address $HOST, and this is a destructive subcommand.
       The fingerprint has now been recorded. Re-run to proceed, having confirmed it is the right machine."
  fi
fi

ACTIVE_ROOT=$(remote 'cat /proc/cmdline' 2>/dev/null | tr ' ' '\n' | grep '^root=' | head -1)
say "ACTIVE_ROOT_CMDLINE=${ACTIVE_ROOT:-unknown}"

STAGE_DIR=/usr/data/nebulaos-hwqual
# Deliberately /usr/data, not /tmp: /tmp here is a small tmpfs and cannot hold a
# ~100 MB squashfs. DEVELOPER_INSTALL_FROM_STOCK.md says the same.

case "$SUBCMD" in

inventory|verify)
  say ""
  say "== $SUBCMD (read-only) =="
  remote 'set -x
    hostname; uname -a; uptime; cat /proc/cmdline
    df -h; free -m
    cat /proc/partitions; ls -la /dev/disk/by-partlabel/ 2>/dev/null
    cat /usr/data/nebulaos/build-manifest.txt 2>/dev/null || echo NO_RUNTIME_MANIFEST
    cat /etc/ota_marker.sh >/dev/null 2>&1 && echo OTA_MARKER_HELPER=present || echo OTA_MARKER_HELPER=absent
    for s in klipper moonraker guppyscreen nginx; do
      printf "service %s: " "$s"; (/etc/init.d/S*"$s"* status 2>/dev/null || pgrep -f "$s" >/dev/null && echo running || echo not-running)
    done
    curl -s --max-time 5 http://127.0.0.1:7125/printer/info || echo NO_MOONRAKER_RESPONSE
    curl -s --max-time 5 http://127.0.0.1:7125/server/info || echo NO_SERVER_INFO
    dmesg 2>/dev/null | tail -100
  ' 2>&1
  say ""
  say "RUN_NEBULAOS_HARDWARE=${SUBCMD^^}_COMPLETE"
  ;;

preflight|flash)
  say ""
  say "== staging artifacts to $STAGE_DIR =="
  remote "mkdir -p $STAGE_DIR" >/dev/null 2>&1 || fail "cannot create $STAGE_DIR on the device"

  avail=$(remote "df -k $STAGE_DIR | awk 'NR==2{print \$4}'" 2>/dev/null)
  need=$(( ( $(stat -c %s "$XIMAGE") + $(stat -c %s "$ROOTFS") ) / 1024 + 20480 ))
  if [ -n "${avail:-}" ] && [ "$avail" -lt "$need" ] 2>/dev/null; then
    fail "insufficient space on the device: need ~${need} KiB, have ${avail} KiB at $STAGE_DIR"
  fi
  say "DEVICE_FREE_KIB=${avail:-unknown} REQUIRED_KIB=$need"

  push "$XIMAGE"       "$STAGE_DIR/xImage"          || fail "scp of xImage failed"
  push "$ROOTFS"       "$STAGE_DIR/rootfs.squashfs" || fail "scp of rootfs.squashfs failed"
  push "$MANIFEST"     "$STAGE_DIR/build-manifest.txt" || fail "scp of build-manifest.txt failed"
  push "$FLASH_SCRIPT" "$STAGE_DIR/flash-spare-slot.sh" || fail "scp of flash-spare-slot.sh failed"

  # Independent post-transfer verification ON the device. A transfer truncated
  # mid-flight is exactly the failure that motivated the manifest check inside
  # flash-spare-slot.sh; catching it here too means we never even invoke the
  # flasher with a bad payload.
  say ""
  say "== verifying transferred bytes on the device =="
  DEV_X=$(remote "sha256sum $STAGE_DIR/xImage" 2>/dev/null | awk '{print $1}')
  DEV_R=$(remote "sha256sum $STAGE_DIR/rootfs.squashfs" 2>/dev/null | awk '{print $1}')
  [ "$DEV_X" = "$EXPECT_XIMAGE" ] || fail "xImage on the device ($DEV_X) != expected ($EXPECT_XIMAGE) - transfer corrupted"
  [ "$DEV_R" = "$EXPECT_ROOTFS" ] || fail "rootfs.squashfs on the device ($DEV_R) != expected ($EXPECT_ROOTFS) - transfer corrupted"
  say "DEVICE_XIMAGE_SHA256=$DEV_X"
  say "DEVICE_ROOTFS_SHA256=$DEV_R"
  say "DEVICE_ARTIFACT_VERIFIED=YES"

  if [ "$SUBCMD" = preflight ]; then
    say ""
    say "== flash-spare-slot.sh --check-only (no write) =="
    remote "sh $STAGE_DIR/flash-spare-slot.sh --check-only $STAGE_DIR/xImage $STAGE_DIR/rootfs.squashfs $STAGE_DIR/build-manifest.txt" 2>&1
    rc=$?
    say ""
    say "PREFLIGHT_EXIT_CODE=$rc"
    [ "$rc" -eq 0 ] || fail "preflight refused the flash; resolve before attempting a write"
    say "RUN_NEBULAOS_HARDWARE=PREFLIGHT_PASS"
    exit 0
  fi

  say ""
  say "== flash-spare-slot.sh (writes slot 2 only) =="
  say "This delegates every write to the documented on-device script. It writes"
  say "mmcblk0p6 + mmcblk0p8 only, refuses to write the slot it is booted from,"
  say "and does NOT flip the OTA marker."
  remote "sh $STAGE_DIR/flash-spare-slot.sh $STAGE_DIR/xImage $STAGE_DIR/rootfs.squashfs $STAGE_DIR/build-manifest.txt" 2>&1
  rc=$?
  say ""
  say "FLASH_EXIT_CODE=$rc"
  [ "$rc" -eq 0 ] || fail "flash-spare-slot.sh reported failure; the marker was not touched and the device still boots the current slot"
  printf 'RUN_NEBULAOS_HARDWARE=FLASH_COMPLETE\nFLASH_ARTIFACT_PATH=%s\nFLASH_ARTIFACT_SHA256=%s\nFLASH_SOURCE_HEAD=%s\nFLASH_TARGET_SLOT=2 (mmcblk0p6 kernel2 + mmcblk0p8 rootfs2)\nFLASH_METHOD=scripts/flash-spare-slot.sh on-device\nOTA_MARKER_TOUCHED=NO\n' \
    "$XIMAGE" "$EXPECT_XIMAGE" "$EXPECT_FW"
  say ""
  say "Next deliberate step: 'marker', then 'reboot'. Neither happens automatically."
  ;;

marker)
  say ""
  say "== flipping the OTA marker to ota:kernel2 =="
  remote 'test -f /etc/ota_marker.sh' >/dev/null 2>&1 \
    || fail "/etc/ota_marker.sh is absent - this device is probably booted into the stock slot.
       From stock the documented tool is /etc/ota_bin/ota_local_method.sh's local_set_next_boot_device.
       This launcher does not flip the marker from stock; do that step by hand per docs/A_B_SLOT_MODEL.md."
  remote '. /etc/ota_marker.sh; write_ota_marker "ota:kernel2"; echo MARKER_WRITE_RC=$?' 2>&1
  say ""
  say "RUN_NEBULAOS_HARDWARE=MARKER_SET_KERNEL2"
  say "The device has NOT been rebooted. 'reboot' is a separate, deliberate step."
  ;;

reboot)
  say ""
  say "== operator-triggered reboot =="
  # The project never automates reboot (NEBULAOS_OTA_FLOW.md). This subcommand
  # exists so the reboot is still an explicit, separately-invoked act.
  remote 'sync; (sleep 1; reboot) >/dev/null 2>&1 &' 2>&1
  say "REBOOT_ISSUED=YES"
  say "RUN_NEBULAOS_HARDWARE=REBOOT_ISSUED"
  say "Reconnect with 'verify' once the device is back. Do not power-cycle."
  ;;

esac

exit 0
