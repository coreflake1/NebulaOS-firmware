#!/usr/bin/env bash
#
# Enrol a printer. A HUMAN runs this; no agent may.
#
# WHY ENROLMENT IS NOT AUTOMATED
#
# Enrolment is the moment someone asserts "this physical printer, the one in
# front of me, is the one called <id>". Everything downstream - strict host-key
# checking, the identity comparison before any destructive write, the refusal to
# flash a machine that moved onto a remembered DHCP lease - rests on that
# assertion being made by someone who could see the device.
#
# An installer that can enrol can also enrol the wrong printer. "First contact,
# record whatever answered" is precisely the trust-on-first-use failure that the
# rest of this design exists to prevent, and automating enrolment would
# reintroduce it at the one point where it cannot be detected afterwards.
#
# So this script is NOT in the set of launchers an agent may run, and the profile
# store it writes is denied to agents by both permission rules and the sandbox.
#
# WHAT IT RECORDS
#
#   the per-unit physical identity   eMMC CID, SHA-256 of the sn_mac partition
#   a pinned SSH host key PER OS     stock and NebulaOS are different systems
#                                    with different keys on the same printer
#   known addresses per OS           a search order for rediscovery, never proof
#   credentials                      in separate 0600 files
#
# It reads the identity FROM THE DEVICE, over SSH, and shows it to you before
# writing anything. Check it against the printer you are standing next to.
set -uo pipefail
export LC_ALL=C

die(){ printf 'ENROLL=FAILED\nREASON: %s\n' "$1" >&2; exit 2; }

HOME_DIR="${NEBULAOS_HARDWARE_HOME:-$HOME/.config/nebulaos-hardware}"

DEVICE=""; ADDRESS=""; WHICH=""
while [ "$#" -gt 0 ]; do
  case "${1:-}" in
    --device)  DEVICE=${2:-}; shift 2 ;;
    --address) ADDRESS=${2:-}; shift 2 ;;
    --os)      WHICH=${2:-}; shift 2 ;;
    *) die "usage: enroll-device.sh --device <id> --address <private-ipv4> --os nebulaos|stock" ;;
  esac
done
[ -n "$DEVICE" ] && [ -n "$ADDRESS" ] && [ -n "$WHICH" ] \
  || die "usage: enroll-device.sh --device <id> --address <private-ipv4> --os nebulaos|stock"
case "$WHICH" in nebulaos|stock) ;; *) die "--os must be nebulaos or stock" ;; esac
case "$DEVICE" in *[!A-Za-z0-9_-]*|"") die "device id must be letters, digits, '-' and '_'" ;; esac

# An enrolment target is still constrained to a private LAN: a typo must not be
# able to reach the public internet.
IFS=. read -r o1 o2 o3 o4 extra <<<"$ADDRESS"
[ -z "${extra:-}" ] || die "address is not a dotted quad: $ADDRESS"
for o in "$o1" "$o2" "$o3" "$o4"; do
  case "${o:-}" in ''|*[!0-9]*) die "address is not a dotted quad: $ADDRESS" ;; esac
  [ "$o" -le 255 ] 2>/dev/null || die "address octet out of range: $ADDRESS"
done
priv=no
case "$o1.$o2" in
  10.*) priv=yes ;; 192.168) priv=yes ;;
  172.1[6-9]|172.2[0-9]|172.3[01]) priv=yes ;;
esac
[ "$priv" = yes ] || die "refusing a non-RFC1918 address: $ADDRESS"

PDIR="$HOME_DIR/devices/$DEVICE"
mkdir -p -m 0700 "$HOME_DIR" "$HOME_DIR/devices" "$PDIR" || die "cannot create $PDIR"
chmod 0700 "$HOME_DIR" "$HOME_DIR/devices" "$PDIR"

echo "== reading the host key at $ADDRESS =="
HOSTKEY=$(ssh-keyscan -t ed25519 -T 10 "$ADDRESS" 2>/dev/null | grep -v '^#' | head -1 | cut -d' ' -f2-)
[ -n "$HOSTKEY" ] || die "no SSH host key at $ADDRESS - is the printer up and running $WHICH?"
echo "   $HOSTKEY"
echo

echo "== reading the per-unit identity from the device =="
echo "   (you will be prompted for the $WHICH root password)"
FACTS=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 "root@$ADDRESS" \
  'printf "cid=%s\n" "$(cat /sys/block/mmcblk0/device/cid 2>/dev/null)";
   printf "snmac=%s\n" "$(dd if=/dev/mmcblk0p2 bs=1024 count=1 2>/dev/null | sha256sum | cut -d" " -f1)"' \
  2>/dev/null) || die "could not read identity from $ADDRESS"

CID=$(printf '%s\n' "$FACTS" | sed -n 's/^cid=//p')
SNMAC=$(printf '%s\n' "$FACTS" | sed -n 's/^snmac=//p')
[ -n "$CID" ] && [ -n "$SNMAC" ] || die "the device did not return a complete identity"

cat <<EOF

== CHECK THIS AGAINST THE PRINTER IN FRONT OF YOU ==

   device id     $DEVICE
   address       $ADDRESS  (running $WHICH)
   eMMC CID      $CID
   sn_mac sha256 $SNMAC
   host key      ${HOSTKEY:0:60}...

This is the assertion everything else rests on. If this is not the printer you
mean, stop now: every later safety check compares against these values, so an
identity recorded from the wrong machine makes all of them agree with the wrong
machine.

EOF
printf 'Type the device id again to confirm: '
read -r CONFIRM
[ "$CONFIRM" = "$DEVICE" ] || die "not confirmed"

CONF="$PDIR/profile.conf"
touch "$CONF"; chmod 0600 "$CONF"
python3 - "$CONF" "$DEVICE" "$CID" "$SNMAC" "$WHICH" "$HOSTKEY" "$ADDRESS" <<'PY'
import sys
conf, device, cid, snmac, which, hostkey, address = sys.argv[1:8]
fields = {}
try:
    for line in open(conf):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            fields[k] = v
except OSError:
    pass
fields["DEVICE_ID"] = device
fields["EMMC_CID"] = cid
fields["SN_MAC_SHA256"] = snmac
fields["%s_HOST_KEY" % which.upper()] = hostkey
fields["%s_CREDENTIAL_REF" % which.upper()] = "%s.cred" % which
history = [a for a in fields.get("%s_ADDRESS_HISTORY" % which.upper(), "").split(",") if a]
if address in history:
    history.remove(address)
fields["%s_ADDRESS_HISTORY" % which.upper()] = ",".join([address] + history)
# Keep the other OS's fields if a previous run wrote them.
order = ["DEVICE_ID", "EMMC_CID", "SN_MAC_SHA256",
         "NEBULAOS_HOST_KEY", "STOCK_HOST_KEY",
         "NEBULAOS_ADDRESS_HISTORY", "STOCK_ADDRESS_HISTORY",
         "NEBULAOS_CREDENTIAL_REF", "STOCK_CREDENTIAL_REF",
         "NEBULAOS_USERNAME", "STOCK_USERNAME"]
with open(conf, "w") as fh:
    for k in order:
        if k in fields:
            fh.write("%s=%s\n" % (k, fields[k]))
    for k in sorted(fields):
        if k not in order:
            fh.write("%s=%s\n" % (k, fields[k]))
PY

CRED="$PDIR/$WHICH.cred"
if [ ! -f "$CRED" ]; then
  printf 'Enter the %s root password (it will be stored 0600, not echoed): ' "$WHICH"
  stty -echo 2>/dev/null; read -r SECRET; stty echo 2>/dev/null; echo
  umask 077
  printf '%s\n' "$SECRET" > "$CRED"
  chmod 0600 "$CRED"
  unset SECRET
fi

cat <<EOF
ENROLL=OK
DEVICE_ID=$DEVICE
PROFILE=$CONF
ENROLLED_OS=$WHICH

Enrol the OTHER OS too before attempting an install: the developer install
reboots into stock and needs its pinned host key, its credential and at least
one known address already recorded. Re-run with --os $([ "$WHICH" = nebulaos ] && echo stock || echo nebulaos).
EOF
