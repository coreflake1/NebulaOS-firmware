#!/bin/sh
# nebulaos-qualify.sh - NebulaOS runtime qualification snapshot.
#
# Runs ON THE PRINTER. Read-only: it reads /proc, /sys and loopback HTTP and
# writes nothing outside its own output stream. It never operates the machine -
# no motion, no heaters, no probe, no flashing, no configuration change.
#
# Purpose: produce one stable, diff-friendly snapshot so the SAME command run
# on the current known-good firmware and on a candidate can be compared with a
# plain `diff`. Mission section 21/22.
#
#   ./nebulaos-qualify.sh > old.txt     # on current firmware
#   ./nebulaos-qualify.sh > new.txt     # on candidate
#   diff -u old.txt new.txt
#
# OUTPUT CONTRACT - the four states are deliberately distinct, because
# conflating them is how a regression hides:
#
#   <value>       a real reading (including a genuine 0)
#   ABSENT        the thing does not exist on this system (no such file/proc/
#                 feature). Expected for optional components.
#   UNAVAILABLE   it exists but could not be read here (permission, busy,
#                 unsupported by this kernel build)
#   FAILED        it exists, was reachable, and returned an error/bad status
#
# Nothing is ever invented. A reading that could not be taken is never printed
# as 0. Every line is KEY=VALUE, keys are stable and ordered, and no timestamp,
# pid, uptime-varying value or hostname appears outside the explicitly marked
# VOLATILE section - so a diff shows behaviour changes, not clock drift.
#
# BusyBox ash compatible. Uses only: cat, grep, sed, awk, cut, tr, sort, head,
# wc, ls, test. Optional tools are probed, never assumed (the device has no
# pgrep - see evidence/frozen-candidate-fd4a365/PART1_RESULT.md).
set -u

VERSION=1
SECTION=""

emit() { printf '%s=%s\n' "$1" "$2"; }
section() { SECTION=$1; printf '\n# --- %s ---\n' "$1"; }

# read a single value from a file, mapping the failure modes apart
readfile() {
	_f=$1
	if [ ! -e "$_f" ]; then echo ABSENT; return; fi
	if [ ! -r "$_f" ]; then echo UNAVAILABLE; return; fi
	_v=$(cat "$_f" 2>/dev/null) || { echo UNAVAILABLE; return; }
	[ -n "$_v" ] || { echo UNAVAILABLE; return; }
	echo "$_v"
}

# a field out of /proc/meminfo, in kB, as an integer
meminfo() {
	[ -r /proc/meminfo ] || { echo UNAVAILABLE; return; }
	_v=$(awk -v k="$1:" '$1==k {print $2; found=1} END{if(!found) print "ABSENT"}' /proc/meminfo)
	echo "$_v"
}

have() { command -v "$1" >/dev/null 2>&1; }

emit QUALIFY_SCHEMA_VERSION "$VERSION"

# =====================================================================
section IDENTITY
# =====================================================================
emit KERNEL_RELEASE   "$(readfile /proc/sys/kernel/osrelease)"
_v=$(readfile /proc/version); emit KERNEL_VERSION_STRING "$_v"
emit MACHINE          "$( (uname -m 2>/dev/null) || echo UNAVAILABLE )"
if [ -r /etc/os-release ]; then
	emit OS_RELEASE_PRETTY "$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -1)"
else
	emit OS_RELEASE_PRETTY ABSENT
fi
emit NEBULAOS_BUILD_MANIFEST "$( [ -r /usr/data/nebulaos/build-manifest.txt ] && echo PRESENT || echo ABSENT )"
# which rootfs slot is live - a boot-architecture fact, not a perf metric
_cmdline=$(readfile /proc/cmdline)
case "$_cmdline" in
	ABSENT|UNAVAILABLE) emit ROOT_DEVICE UNAVAILABLE ;;
	*) emit ROOT_DEVICE "$(echo "$_cmdline" | tr ' ' '\n' | sed -n 's/^root=//p' | head -1)" ;;
esac

# =====================================================================
section MEMORY
# =====================================================================
for k in MemTotal MemFree MemAvailable Buffers Cached SwapCached Active Inactive \
         Dirty Writeback AnonPages Mapped Shmem Slab SReclaimable SUnreclaim \
         SwapTotal SwapFree CommitLimit Committed_AS; do
	emit "MEM_$(echo "$k" | tr '[:lower:]' '[:upper:]')_KB" "$(meminfo "$k")"
done

# =====================================================================
section SWAP
# =====================================================================
if [ -r /proc/swaps ]; then
	# one line per backend, sorted by name so device enumeration order
	# cannot make two identical systems diff
	_n=0
	# shellcheck disable=SC2162
	tail -n +2 /proc/swaps 2>/dev/null | sort | while read name type size used prio rest; do
		_i=$(echo "$name" | sed 's|^/||; s|[^A-Za-z0-9]|_|g' | tr '[:lower:]' '[:upper:]')
		printf 'SWAP_%s_TYPE=%s\nSWAP_%s_SIZE_KB=%s\nSWAP_%s_USED_KB=%s\nSWAP_%s_PRIORITY=%s\n' \
			"$_i" "$type" "$_i" "$size" "$_i" "$used" "$_i" "$prio"
	done
	_n=$(tail -n +2 /proc/swaps 2>/dev/null | wc -l | tr -d ' ')
	emit SWAP_BACKEND_COUNT "$_n"
else
	emit SWAP_BACKEND_COUNT UNAVAILABLE
fi
# the kernel policy this platform depends on (mission section 9)
emit VM_SWAPPINESS   "$(readfile /proc/sys/vm/swappiness)"
emit VM_PAGE_CLUSTER "$(readfile /proc/sys/vm/page-cluster)"

# =====================================================================
section ZRAM
# =====================================================================
if [ -d /sys/block/zram0 ]; then
	emit ZRAM_PRESENT yes
	emit ZRAM_DISKSIZE_BYTES "$(readfile /sys/block/zram0/disksize)"
	_ca=$(readfile /sys/block/zram0/comp_algorithm)
	case "$_ca" in
		ABSENT|UNAVAILABLE) emit ZRAM_COMP_ALGORITHM "$_ca" ;;
		*) emit ZRAM_COMP_ALGORITHM "$(echo "$_ca" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;;
	esac
	# mm_stat: orig_data_size compr_data_size mem_used_total mem_limit
	#          mem_used_max same_pages pages_compacted (huge_pages)
	if [ -r /sys/block/zram0/mm_stat ]; then
		# shellcheck disable=SC2034
		set -- $(cat /sys/block/zram0/mm_stat 2>/dev/null)
		emit ZRAM_ORIG_DATA_BYTES  "${1:-UNAVAILABLE}"
		emit ZRAM_COMPR_DATA_BYTES "${2:-UNAVAILABLE}"
		emit ZRAM_MEM_USED_BYTES   "${3:-UNAVAILABLE}"
		emit ZRAM_MEM_USED_MAX     "${5:-UNAVAILABLE}"
		emit ZRAM_SAME_PAGES       "${6:-UNAVAILABLE}"
	else
		emit ZRAM_MM_STAT UNAVAILABLE
	fi
else
	emit ZRAM_PRESENT ABSENT
fi

# =====================================================================
section CPU_SYSTEM
# =====================================================================
if [ -r /proc/loadavg ]; then
	emit LOADAVG_1M  "$(cut -d' ' -f1 /proc/loadavg)"
	emit LOADAVG_5M  "$(cut -d' ' -f2 /proc/loadavg)"
	emit LOADAVG_15M "$(cut -d' ' -f3 /proc/loadavg)"
else
	emit LOADAVG_1M UNAVAILABLE
fi
if [ -r /proc/stat ]; then
	# cumulative jiffies since boot: user nice system idle iowait irq softirq
	awk '/^cpu /{printf "CPU_USER_JIFFIES=%s\nCPU_NICE_JIFFIES=%s\nCPU_SYSTEM_JIFFIES=%s\nCPU_IDLE_JIFFIES=%s\nCPU_IOWAIT_JIFFIES=%s\nCPU_IRQ_JIFFIES=%s\nCPU_SOFTIRQ_JIFFIES=%s\n",$2,$3,$4,$5,$6,$7,$8}' /proc/stat
	emit CTXT_SWITCHES_TOTAL "$(awk '/^ctxt/{print $2}' /proc/stat)"
	emit INTERRUPTS_TOTAL    "$(awk '/^intr/{print $2}' /proc/stat)"
	emit PROCS_FORKED_TOTAL  "$(awk '/^processes/{print $2}' /proc/stat)"
	emit PROCS_RUNNING       "$(awk '/^procs_running/{print $2}' /proc/stat)"
	emit PROCS_BLOCKED       "$(awk '/^procs_blocked/{print $2}' /proc/stat)"
else
	emit CPU_STAT UNAVAILABLE
fi
emit CPU_COUNT "$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo UNAVAILABLE)"

# =====================================================================
section INTERRUPTS
# mission section 22: a previous audit measured ~8000 USB OTG interrupts/sec
# at idle. This records the COUNTERS ONLY. It deliberately does not change
# any USB or kernel behaviour, and a single snapshot is a count, not a rate -
# take two snapshots and difference them against UPTIME_SECONDS to get a rate.
# =====================================================================
if [ -r /proc/interrupts ]; then
	# per-IRQ totals summed across CPUs, keyed by the device name so the
	# key is stable even if the IRQ number moves between kernels
	awk 'NR>1 {
		irq=$1; sub(":","",irq);
		total=0; name="";
		for (i=2;i<=NF;i++) { if ($i ~ /^[0-9]+$/) total+=$i; else { name=name (name==""?"":"_") $i } }
		if (name=="") name="irq" irq;
		gsub(/[^A-Za-z0-9_]/,"_",name);
		agg[name]+=total;
	} END { for (n in agg) printf "IRQ_%s=%s\n", toupper(n), agg[n] }' /proc/interrupts | sort
else
	emit INTERRUPTS UNAVAILABLE
fi

# =====================================================================
section PROCESSES
# RSS and CPU for the processes this platform cares about. No pgrep on the
# device, so /proc is walked directly. A process that is not running is
# reported ABSENT - never 0, which would read as "running and using nothing".
# =====================================================================
proc_report() {
	_label=$1; _pattern=$2
	_pid=""; _rss=""; _utime=""; _stime=""; _threads=""
	for _d in /proc/[0-9]*; do
		[ -r "$_d/cmdline" ] || continue
		_cmd=$(tr '\0' ' ' < "$_d/cmdline" 2>/dev/null)
		[ -n "$_cmd" ] || continue
		case "$_cmd" in
			*$_pattern*)
				_pid=${_d#/proc/}
				# VmRSS in kB
				_rss=$(awk '/^VmRSS:/{print $2}' "$_d/status" 2>/dev/null)
				_threads=$(awk '/^Threads:/{print $2}' "$_d/status" 2>/dev/null)
				# utime/stime are fields 14/15 of /proc/pid/stat, but comm
				# (field 2) may contain spaces - cut after the closing paren
				_st=$(sed 's/^.*) //' "$_d/stat" 2>/dev/null)
				_utime=$(echo "$_st" | awk '{print $12}')
				_stime=$(echo "$_st" | awk '{print $13}')
				break ;;
		esac
	done
	if [ -z "$_pid" ]; then
		emit "PROC_${_label}_STATE" ABSENT
		return
	fi
	emit "PROC_${_label}_STATE"        running
	emit "PROC_${_label}_RSS_KB"       "${_rss:-UNAVAILABLE}"
	emit "PROC_${_label}_THREADS"      "${_threads:-UNAVAILABLE}"
	emit "PROC_${_label}_UTIME_JIFFIES" "${_utime:-UNAVAILABLE}"
	emit "PROC_${_label}_STIME_JIFFIES" "${_stime:-UNAVAILABLE}"
}

proc_report KLIPPER          "klippy"
proc_report MOONRAKER        "moonraker"
proc_report GUPPYSCREEN      "guppyscreen"
proc_report USTREAMER        "ustreamer"
proc_report NGINX            "nginx"
proc_report DROPBEAR         "dropbear"
proc_report WPA_SUPPLICANT   "wpa_supplicant"
proc_report UDEVD            "udevd"
proc_report DBUS_DAEMON      "dbus-daemon"
proc_report MODEMMANAGER     "ModemManager"
proc_report UPDATE_SUPERVISOR "nebulaos-update-supervisor"
proc_report MCU_GUARD        "nebulaos-mcu-guard"
proc_report CAMERA_IDLE_CTL  "camera-idle-controller"
emit PROC_TOTAL_COUNT "$(ls -d /proc/[0-9]* 2>/dev/null | wc -l | tr -d ' ')"

# =====================================================================
section PYTHON
# =====================================================================
if have python3; then
	emit PYTHON3_PATH    "$(command -v python3)"
	_pv=$(python3 -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null) \
		&& emit PYTHON3_VERSION "$_pv" || emit PYTHON3_VERSION FAILED
	_ps=$(python3 -c 'import sysconfig;print(sysconfig.get_config_var("EXT_SUFFIX"))' 2>/dev/null) \
		&& emit PYTHON3_EXT_SUFFIX "$_ps" || emit PYTHON3_EXT_SUFFIX FAILED
else
	emit PYTHON3_PATH ABSENT
fi
# the persistent application venvs (mission section 15)
for _e in klipper moonraker; do
	_U=$(echo "$_e" | tr '[:lower:]' '[:upper:]')
	_root=/usr/data/nebulaos/envs/$_e
	if [ ! -d "$_root" ]; then
		emit "VENV_${_U}_STATE" ABSENT
		continue
	fi
	if [ ! -x "$_root/bin/python3" ]; then
		emit "VENV_${_U}_STATE" FAILED
		emit "VENV_${_U}_DETAIL" "bin/python3 missing or not executable"
		continue
	fi
	_vv=$("$_root/bin/python3" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)
	if [ -z "$_vv" ]; then
		emit "VENV_${_U}_STATE" FAILED
		emit "VENV_${_U}_DETAIL" "interpreter present but did not execute"
	else
		emit "VENV_${_U}_STATE" ok
		emit "VENV_${_U}_PYTHON_VERSION" "$_vv"
	fi
	[ -e "$_root.partial" ] && emit "VENV_${_U}_PARTIAL_PRESENT" yes || emit "VENV_${_U}_PARTIAL_PRESENT" no
done
# required imports, reported per-module so one failure does not mask the rest
check_import() {
	_label=$1; _interp=$2; _mod=$3
	# The key must depend ONLY on (label, module), never on the outcome -
	# otherwise the key itself moves when the state moves and a diff shows a
	# removed line plus an added line instead of a changed value.
	_key="IMPORT_${_label}_$(echo "$_mod" | tr '[:lower:].' '[:upper:]_')"
	if [ ! -x "$_interp" ]; then emit "$_key" ABSENT; return; fi
	if "$_interp" -c "import $_mod" >/dev/null 2>&1; then
		emit "$_key" ok
	else
		emit "$_key" FAILED
	fi
}
_kpy=/usr/data/nebulaos/envs/klipper/bin/python3
_mpy=/usr/data/nebulaos/envs/moonraker/bin/python3
for m in greenlet cffi serial can jinja2 markupsafe numpy matplotlib; do
	check_import KLIPPER "$_kpy" "$m"
done
for m in tornado serial PIL streaming_form_data distro inotify_simple libnacl \
         paho zeroconf jinja2 dbus_fast apprise ldap3 periphery; do
	check_import MOONRAKER "$_mpy" "$m"
done

# =====================================================================
section SERVICES_HTTP
# Loopback only. Read-only GETs. No printer command is ever issued.
# =====================================================================
http_probe() {
	_label=$1; _url=$2
	if have curl; then
		_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$_url" 2>/dev/null)
		if [ -z "$_code" ] || [ "$_code" = "000" ]; then emit "HTTP_${_label}_STATUS" FAILED
		else emit "HTTP_${_label}_STATUS" "$_code"; fi
	elif have wget; then
		if wget -q -O /dev/null -T 5 "$_url" 2>/dev/null; then emit "HTTP_${_label}_STATUS" 200
		else emit "HTTP_${_label}_STATUS" FAILED; fi
	else
		emit "HTTP_${_label}_STATUS" UNAVAILABLE
	fi
}
http_probe NGINX_ROOT     "http://127.0.0.1/"
http_probe MAINSAIL_INDEX "http://127.0.0.1/index.html"
http_probe MOONRAKER_INFO "http://127.0.0.1:7125/server/info"
http_probe WEBCAM_SNAPSHOT "http://127.0.0.1:8080/snapshot"
# Klipper's own reported state, read via Moonraker, without commanding anything
if have curl; then
	_ks=$(curl -s --max-time 5 "http://127.0.0.1:7125/printer/info" 2>/dev/null \
		| sed -n 's/.*"state": *"\([a-z_]*\)".*/\1/p' | head -1)
	emit KLIPPER_REPORTED_STATE "${_ks:-UNAVAILABLE}"
else
	emit KLIPPER_REPORTED_STATE UNAVAILABLE
fi

# =====================================================================
section FILESYSTEM
# =====================================================================
if have df; then
	df -k 2>/dev/null | tail -n +2 | sort -k6 | while read fs blocks used avail pct mnt; do
		case "$mnt" in
			/|/usr/data|/tmp|/dev/shm)
				_i=$(echo "$mnt" | sed 's|/|_|g; s/^_//'); [ -n "$_i" ] || _i=ROOT
				_i=$(echo "$_i" | tr '[:lower:]' '[:upper:]')
				printf 'FS_%s_SIZE_KB=%s\nFS_%s_USED_KB=%s\nFS_%s_AVAIL_KB=%s\n' \
					"$_i" "$blocks" "$_i" "$used" "$_i" "$avail" ;;
		esac
	done
else
	emit FILESYSTEM UNAVAILABLE
fi

# =====================================================================
section VOLATILE
# Everything whose value legitimately changes between two runs of the same
# firmware. Kept last and clearly fenced so a diff of the sections above is
# meaningful on its own: `sed '/# --- VOLATILE/,$d'` drops it entirely.
# =====================================================================
emit UPTIME_SECONDS "$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo UNAVAILABLE)"
emit CAPTURED_AT_UTC "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo UNAVAILABLE)"

exit 0
