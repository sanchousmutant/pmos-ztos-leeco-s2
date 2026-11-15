#!/bin/sh
# usb-adb-rearm.sh - repair the composite USB gadget (RNDIS + ADB) on s2.
#
# Runs ON the device (Alpine rootfs on p56), normally over SSH:
#
#     ssh -i id_rsa root@172.16.42.1 'sh /usr/local/bin/usb-adb-rearm.sh'
#
# WHY THIS IS NEEDED
# ------------------
# The gadget is configured as `rndis,ffs`.  For the FunctionFS part to work,
# adbd MUST open /dev/usb-ffs/adb/ep0 and write its descriptors BEFORE the
# gadget is enabled:
#
#     enable=0 -> mount functionfs -> functions=rndis,ffs -> start adbd
#              -> wait until adbd wrote ep0 -> enable=1
#
# During boot the initramfs adbd is killed by switch_root (its binary lives in
# the deleted old root, so it dies with SIGBUS).  The rootfs adbd is then
# started while the gadget is ALREADY enabled, so it never re-arms the ffs
# function: the composite gadget enumerates with a dead ADB interface and
# `adb devices` stays empty for the whole boot.
#
# RNDIS keeps working, which is why the existing `usb_broken` fallback never
# fires - it only checks /sys/class/android_usb/android0/state, and that is
# CONFIGURED as soon as RNDIS is up.
#
# This script performs the correct re-arm order, verifies the result, and falls
# back to rndis-only (network is the real lifeline - sshd runs over it) if the
# composite gadget does not come back within REARM_WAIT seconds.

PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH
export PATH

AUD=/sys/class/android_usb/android0
[ -d "$AUD" ] || AUD=/sys/devices/virtual/android_usb/android0

REARM_WAIT=${REARM_WAIT:-8}
LOG=${LOG:-/var/log/usb-adb-rearm.log}

mkdir -p /var/log
: > "$LOG"

say() { echo "$*" | tee -a "$LOG"; }

usb_state() { cat "$AUD/state" 2>/dev/null; }
usb_funcs() { cat "$AUD/functions" 2>/dev/null; }

# Run a command with a hard timeout, without depending on `timeout(1)`.
# Writing 1 to $AUD/enable blocks in the kernel until every function is ready;
# if adbd never writes its descriptors this would hang the caller forever.
bounded() {
	limit="$1"; shift
	sh -c "$*" &
	p=$!
	i=0
	while [ "$i" -lt "$limit" ]; do
		kill -0 "$p" 2>/dev/null || { wait "$p"; return $?; }
		sleep 1
		i=$((i + 1))
	done
	kill -9 "$p" 2>/dev/null
	say "WARN: '$*' still running after ${limit}s - killed"
	return 124
}

wait_configured() {
	limit="$1"
	i=0
	while [ "$i" -lt "$limit" ]; do
		case "$(usb_state)" in
			CONFIGURED) return 0 ;;
		esac
		i=$((i + 1))
		sleep 1
	done
	return 1
}

say "=== usb-adb-rearm $(date) ==="
say "sysfs    : $AUD"
say "before   : state=$(usb_state) functions=$(usb_funcs)"
say "adbd pid : $(pidof adbd 2>/dev/null || echo none)"
say ""

# ---------------------------------------------------------------- functionfs
mkdir -p /dev/usb-ffs/adb 2>/dev/null
if grep -q ' /dev/usb-ffs/adb ' /proc/mounts 2>/dev/null; then
	say "functionfs: already mounted at /dev/usb-ffs/adb"
else
	if mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null; then
		say "functionfs: mounted at /dev/usb-ffs/adb"
	else
		say "ERROR: cannot mount functionfs - adb is impossible on this boot"
		say "       (network stays as it is; nothing changed)"
		exit 2
	fi
fi

[ -e /dev/usb-ffs/adb/ep0 ] && say "ep0: present" || say "WARN: ep0 missing"

# ------------------------------------------------------------------- re-arm
say ""
say "--- re-arm sequence: enable=0 -> adbd -> enable=1 ---"

bounded 5 "echo 0 > $AUD/enable"
sleep 1
say "after disable: state=$(usb_state)"

killall adbd 2>/dev/null
sleep 1
say "old adbd killed"

# Keep the composition and the RNDIS identity intact.
[ -f "$AUD/f_rndis/wceis" ]   && echo 0 > "$AUD/f_rndis/wceis" 2>/dev/null
[ -f "$AUD/f_rndis/ethaddr" ] && echo '42:16:d0:00:00:01' > "$AUD/f_rndis/ethaddr" 2>/dev/null
echo 12D1 > "$AUD/idVendor"  2>/dev/null
echo 1039 > "$AUD/idProduct" 2>/dev/null

echo "rndis,ffs" > "$AUD/functions" 2>/dev/null
say "functions set to: $(usb_funcs)"

if [ -x /sbin/adbd ]; then
	/sbin/adbd &
	ADBD_PID=$!
	say "adbd started pid=$ADBD_PID"
	# give adbd time to open ep0 and write the descriptor set
	sleep 3
	if pidof adbd >/dev/null 2>&1; then
		say "adbd is alive - descriptors should be written"
	else
		say "WARN: adbd exited immediately"
	fi
else
	say "WARN: /sbin/adbd not executable - adb cannot work"
fi

bounded "$REARM_WAIT" "echo 1 > $AUD/enable"
say "after enable: state=$(usb_state)"

if wait_configured "$REARM_WAIT"; then
	say "RESULT: gadget CONFIGURED (rndis + adb)"
	say "        check the host side now:  adb devices"
else
	say "RESULT: gadget did NOT reach CONFIGURED - falling back to rndis only"
	killall adbd 2>/dev/null
	bounded 5 "echo 0 > $AUD/enable"
	sleep 1
	echo rndis > "$AUD/functions" 2>/dev/null
	bounded "$REARM_WAIT" "echo 1 > $AUD/enable"
	sleep 2
	say "fallback: state=$(usb_state) functions=$(usb_funcs)"
	[ "$(usb_state)" = "CONFIGURED" ] || say "ERROR: even rndis-only did not come up"
fi

# ------------------------------------------------------------------ network
for iface in rndis0 usb0 ncm0; do
	[ -d "/sys/class/net/$iface" ] || continue
	ifconfig "$iface" 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null
	# Fallback uplink only: metric 700 must stay above the wlan0 DHCP route.
	ip route add default via 172.16.42.2 dev "$iface" metric 700 2>/dev/null
	say "network: $iface -> 172.16.42.1/24"
done

say ""
say "final: state=$(usb_state) functions=$(usb_funcs) adbd=$(pidof adbd 2>/dev/null || echo none)"
say "log  : $LOG"
exit 0
