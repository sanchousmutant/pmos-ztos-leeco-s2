#!/bin/sh
# LeEco Le 2 (s2) - first sysinit stage inside the Alpine rootfs on p56.
#
#   * verifies and, if needed, repairs the USB gadget (RNDIS network + adb)
#   * brings up 172.16.42.1/24 and the default route through the host
#   * starts sshd
#   * writes /.boot-ok so the initramfs knows userspace came up healthy
#
# The GUI is NOT started here: it belongs to the OpenRC services fb-setup and
# gui, which run in the correct order and log their own output.

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH

mkdir -p /var/log
exec >> /var/log/start-sshd.log 2>&1

# Ensure system date is reasonably current to avoid OpenRC clock skew errors
YEAR=$(date +%Y 2>/dev/null || echo 1970)
if [ "$YEAR" -lt 2026 ]; then
	date -s "2026-11-08 14:47:00" 2>/dev/null || true
	hwclock -w -u 2>/dev/null || true
fi
rm -f /var/cache/rc/deptree /var/cache/rc/depconfig 2>/dev/null || true

echo "=== start-sshd.sh started at $(date) ==="

AUD=/sys/class/android_usb/android0

usb_state() { cat "$AUD/state" 2>/dev/null; }

usb_broken() {
	case "$(usb_state)" in
		""|DISCONNECTED|NOT_ATTACHED|UNDEFINED) return 0 ;;
		*) return 1 ;;
	esac
}

# The gadget re-enumerates after switch_root restarted adbd, so give the host
# a few seconds before deciding that it is really down.
wait_usb() {
	i=0
	while [ $i -lt 10 ]; do
		usb_broken || return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

start_adbd() {
	[ -x /sbin/adbd ] || return 0
	pidof adbd >/dev/null 2>&1 && return 0
	mkdir -p /dev/usb-ffs/adb 2>/dev/null
	if ! grep -q ' /dev/usb-ffs/adb ' /proc/mounts 2>/dev/null; then
		mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null || \
			echo "WARN: cannot mount functionfs - adb unavailable"
	fi
	/sbin/adbd &
	echo "adbd started pid=$!"
	sleep 1
}

if [ -d "$AUD" ]; then
	echo "usb: state=$(usb_state) func=$(cat $AUD/functions 2>/dev/null)"
	start_adbd

	# A composite gadget containing ffs stays DISCONNECTED if adbd never binds
	# the ffs function - and that takes the rndis network down with it.  Repair
	# by falling back to rndis only: the network matters more than adb, because
	# sshd is the real lifeline to this device.
	if ! wait_usb; then
		echo "gadget stayed down - reconfiguring as rndis only"
		killall adbd 2>/dev/null
		echo 0 > "$AUD/enable" 2>/dev/null
		sleep 1
		[ -f "$AUD/f_rndis/wceis" ]   && echo 0 > "$AUD/f_rndis/wceis" 2>/dev/null
		[ -f "$AUD/f_rndis/ethaddr" ] && echo '42:16:d0:00:00:01' > "$AUD/f_rndis/ethaddr" 2>/dev/null
		echo 12D1 > "$AUD/idVendor" 2>/dev/null
		echo 1039 > "$AUD/idProduct" 2>/dev/null
		echo rndis > "$AUD/functions" 2>/dev/null
		echo 1 > "$AUD/enable" 2>/dev/null
		sleep 2
		echo "usb(rndis only): state=$(usb_state)"
	fi
fi

sleep 1
for iface in rndis0 usb0 ncm0; do
	if [ -d "/sys/class/net/$iface" ]; then
		echo "Found network iface $iface, configuring 172.16.42.1..."
		ifconfig $iface 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null || true
		# USB is only a fallback uplink: metric 700 keeps it behind the
		# wlan0 DHCP route (metric 303).  A metric-0 default here would
		# silently hijack every packet Wi-Fi is supposed to carry.
		ip route add default via 172.16.42.2 dev $iface metric 700 \
			2>/dev/null || true
	fi
done

# Allow all network traffic and respond to ARP
iptables -F 2>/dev/null || true
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P OUTPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
echo 1 > /proc/sys/net/ipv4/conf/all/arp_accept 2>/dev/null || true

# This phone has two uplinks (Wi-Fi + USB RNDIS), so strict reverse-path
# filtering breaks the data path: replies from off-link peers arrive on wlan0
# while the reverse route for the same source points at usb0, and the kernel
# silently drops every one of them.  The symptom is a Wi-Fi link that reports
# COMPLETED, holds a valid DHCP lease and pings the gateway, yet cannot reach
# anything beyond it.  Loose mode (2) still rejects martian sources.
net_relax() {
	for c in all default; do
		echo 2 > /proc/sys/net/ipv4/conf/$c/rp_filter 2>/dev/null || true
	done
	# wlan0 is (re)created by WCNSS after this script, so it inherits
	# conf/default and gets re-applied on every watchdog pass too.
	for c in /proc/sys/net/ipv4/conf/*/rp_filter; do
		echo 2 > "$c" 2>/dev/null || true
	done
}
net_relax

# USB charging current limit (1.2A - balanced for charging without PMIC overheat)
echo 1200000 > /sys/class/power_supply/qcom-smbchg-usb/input_current_limit 2>/dev/null || true

# Set CPU governor to schedutil (prevents A72 thermal runaway)
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
	[ -w "$gov" ] && echo schedutil > "$gov" 2>/dev/null || true
done
chgrp -R wheel /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
chmod -R 664 /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true

# Avoid Transparent Hugepage compaction stalls on 3GB RAM (eliminates UI micro-stutters)
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

# Thermal trip points: adjust conservative 75C shutdown to realistic 95C
for z in /sys/class/thermal/thermal_zone*; do
	for t in $z/trip_point_*_type; do
		if [ -f "$t" ] && [ "$(cat $t 2>/dev/null)" = "critical" ]; then
			echo 95000 > "${t%_type}_temp" 2>/dev/null || true
		elif [ -f "$t" ] && [ "$(cat $t 2>/dev/null)" = "hot" ]; then
			echo 80000 > "${t%_type}_temp" 2>/dev/null || true
		elif [ -f "$t" ] && [ "$(cat $t 2>/dev/null)" = "passive" ]; then
			echo 70000 > "${t%_type}_temp" 2>/dev/null || true
		fi
	done
done

# Start Qualcomm remote processors: ADSP (audio) and WCNSS (Wi-Fi/Bluetooth).
# ADSP is usually booted by the driver itself once the rootfs firmware is
# available; WCNSS has to be started explicitly.  Do not hardcode rproc0:
# on msm8976 ADSP is remoteproc0 and WCNSS is the a204000.remoteproc one.
for rp in /sys/class/remoteproc/remoteproc*; do
	[ -e "$rp/state" ] || continue
	rp_state=$(cat "$rp/state" 2>/dev/null)
	rp_name=$(cat "$rp/name" 2>/dev/null)
	if [ "$rp_state" != "running" ]; then
		echo "Starting remoteproc $rp_name ($rp)..."
		echo start > "$rp/state" 2>/dev/null || \
			echo "WARN: could not start $rp_name"
	fi
done

# PipeWire runs as pmos and needs access to /dev/snd.
addgroup pmos audio 2>/dev/null || true

# Select the speaker backend: Quinary MI2S -> external amplifier (GPIO 132).
# Without this route QDSP6 rejects playback with
# "no backend DAIs enabled for MultiMedia1".
if [ ! -f /etc/asound.conf ]; then
	cat > /etc/asound.conf <<'EOF'
pcm.!default {
	type hw
	card 0
}
ctl.!default {
	type hw
	card 0
}
EOF
fi
# Do not block the sysinit stage if the card is not probed yet: the watchdog
# below and /etc/local.d/speaker.start will retry later.
if amixer -c 0 controls >/dev/null 2>&1; then
	amixer -c 0 sset 'QUIN_MI2S_RX Audio Mixer MultiMedia1' on \
		>/dev/null 2>&1 || true
fi

rfkill unblock all 2>/dev/null || true
chmod 666 /dev/rfkill 2>/dev/null || true

wifi_bringup() {
	[ -d /sys/class/net/wlan0 ] || return 1
	rfkill unblock all 2>/dev/null || true
	chmod 666 /dev/rfkill 2>/dev/null || true
	ip link set wlan0 up 2>/dev/null || true
	net_relax
	mkdir -p /var/run/wpa_supplicant
	chgrp wheel /var/run/wpa_supplicant 2>/dev/null || true
	chmod 775 /var/run/wpa_supplicant 2>/dev/null || true
	if ! pidof wpa_supplicant >/dev/null 2>&1; then
		wpa_supplicant -B -i wlan0 \
			-c /etc/wpa_supplicant/wpa_supplicant.conf \
			>/dev/null 2>&1 || true
	fi
	return 0
}

# Asynchronously wait for wlan0, associate and obtain a DHCP lease.
(
	for i in $(seq 1 30); do
		[ -d /sys/class/net/wlan0 ] && break
		sleep 1
	done
	wifi_bringup || exit 0
	wpa_state=""
	for i in $(seq 1 30); do
		wpa_state=$(wpa_cli -i wlan0 status 2>/dev/null | \
			awk -F= '/^wpa_state=/{print $2}')
		[ "$wpa_state" = "COMPLETED" ] && break
		sleep 1
	done
	if [ "$wpa_state" = "COMPLETED" ] && \
	   ! ip addr show wlan0 2>/dev/null | grep -q 'inet '; then
		udhcpc -i wlan0 -b -p /run/udhcpc.wlan0.pid \
			>/dev/null 2>&1 || true
	fi
	echo "wlan0 state: $wpa_state"
) &

# Bluetooth: hci0 appears only after WCNSS has booted.  bluetoothd is started
# later by OpenRC; BlueZ handles the adapter appearing after the daemon.
(
	for i in $(seq 1 30); do
		[ -e /sys/class/bluetooth/hci0 ] && break
		sleep 1
	done
	if [ -e /sys/class/bluetooth/hci0 ]; then
		rfkill unblock bluetooth 2>/dev/null || true
		echo "bluetooth hci0 ready"
	fi
) &

echo "Starting sshd..."
mkdir -p /var/run/sshd
/usr/sbin/sshd &
sleep 1
if pidof sshd >/dev/null 2>&1; then
	echo "sshd is up on port 22"
	# userspace came up far enough to give us a remote shell: tell the
	# initramfs that the next boot can reset the failure counter
	touch /.boot-ok 2>/dev/null || true
	echo "boot confirmed: /.boot-ok written"
else
	echo "WARNING: sshd did not start"
fi

# Ensure user session dbus, PipeWire, WirePlumber and pipewire-pulse are active.
# They must be started as pmos: PipeWire rejects a second instance with another
# uid, and root cannot open the pmos session sockets.
(
	sleep 2
	mkdir -p /run/user/1000
	chown 1000:1000 /run/user/1000
	chmod 700 /run/user/1000
	addgroup pmos audio 2>/dev/null || true
	su -s /bin/sh pmos -c '
		export XDG_RUNTIME_DIR=/run/user/1000
		export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
		if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
			dbus-daemon --session \
				--address="$DBUS_SESSION_BUS_ADDRESS" \
				--fork --nopidfile 2>/dev/null || true
		fi
		sleep 1
		if ! pidof pipewire >/dev/null 2>&1; then
			pipewire >/tmp/pipewire.log 2>&1 &
		fi
		sleep 1
		if ! pidof wireplumber >/dev/null 2>&1; then
			wireplumber >/tmp/wireplumber.log 2>&1 &
		fi
		sleep 1
		if ! pidof pipewire-pulse >/dev/null 2>&1; then
			pipewire-pulse >/tmp/pipewire-pulse.log 2>&1 &
		fi
		for i in $(seq 1 15); do
			pactl info >/dev/null 2>&1 && break
			sleep 1
		done
		# The ACP default profile for this board is "off"; pro-audio is
		# the only profile that exposes a working playback sink.
		pactl set-card-profile \
			alsa_card.platform-c051000.sound pro-audio \
			>/dev/null 2>&1 || true
		pactl set-default-sink \
			alsa_output.platform-c051000.sound.pro-output-0 \
			>/dev/null 2>&1 || true
	'
) &

# The QDSP6 ASM stays wedged after any client is killed while a stream is open
# ("private data null or audio client freed", then "DSP returned error[9]"):
# every later open, even a plain `aplay -D hw:0,0`, fails and the phone goes
# silent.  The ASM session is only cleared by restarting the ADSP, so watch the
# kernel log and do it when the counter jumps.
# Only real ASM wedges count.  WirePlumber's format probing produces a burst of
# "private data null or audio client freed" lines at boot (400+ on a slow ADSP
# start-up) that heal by themselves - they must not trigger an ADSP restart.
asm_errors() {
	dmesg 2>/dev/null | grep -c "q6asm_dai_prepare: q6asm_open_write failed"
}

# WirePlumber discards the pro-audio node once its open fails and silently
# falls back to a "Dummy Output" sink: every application (Chromium/YouTube,
# Decibels, ...) then plays into nothing while reporting success.  Bouncing the
# card profile makes WirePlumber recreate pro-output-0 and restore it as the
# default sink.
pw_heal_card() {
	[ -S /run/user/1000/pipewire-0 ] || return 1
	su -s /bin/sh pmos -c '
		export XDG_RUNTIME_DIR=/run/user/1000
		export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"
		c=alsa_card.platform-c051000.sound
		pactl set-card-profile "$c" off
		sleep 2
		pactl set-card-profile "$c" pro-audio
		sleep 2
		pactl set-default-sink \
			alsa_output.platform-c051000.sound.pro-output-0
	' >/dev/null 2>&1
}

pw_dummy_sink() {
	su -s /bin/sh pmos -c '
		export XDG_RUNTIME_DIR=/run/user/1000
		pactl info 2>/dev/null | grep -q "Default Sink: auto_null"
	' >/dev/null 2>&1
}

restart_adsp() {
	rp=/sys/class/remoteproc/remoteproc0
	[ -e "$rp/state" ] || return 1
	[ "$(cat $rp/name 2>/dev/null)" = "adsp" ] || return 1
	echo "audio: restarting ADSP (ASM wedged)"
	echo stop > "$rp/state" 2>/dev/null || return 1
	sleep 2
	echo start > "$rp/state" 2>/dev/null || return 1
	sleep 3
	# The Quinary MI2S route and the ALSA node do not survive the restart.
	amixer -c 0 sset 'QUIN_MI2S_RX Audio Mixer MultiMedia1' on \
		>/dev/null 2>&1 || true
	pw_heal_card
	return 0
}

# Keep the link address and Wi-Fi subsystem alive - but never call fb0/blank
# again: a repeated unblank desynchronises the DSI PLL and drops the SoC into
# Qualcomm CrashDump (900E).
if [ -x /usr/local/bin/phone-watchdog.sh ]; then
	/usr/local/bin/phone-watchdog.sh >/var/log/phone-watchdog.log 2>&1 &
else
(
	asm_err=$(asm_errors)
	last_adsp=$(cut -d. -f1 /proc/uptime)
	last_heal=$last_adsp
	loops=0
	while true; do
		loops=$((loops + 1))
		# Every ~60 s (2 x 30 s): heal the audio graph.
		#  * new q6asm prepare failures = wedged ASM -> restart ADSP, and the
		#    card profile bounce that recreates pro-output-0;
		#  * applications silently playing into "Dummy Output" -> bounce.
		if [ $((loops % 2)) -eq 0 ]; then
			cur=$(asm_errors)
			if [ "$cur" -lt "$asm_err" ]; then
				asm_err=$cur   # dmesg ring rotated
			elif [ "$cur" -gt "$asm_err" ]; then
				now=$(cut -d. -f1 /proc/uptime)
				if [ "$((now - last_adsp))" -gt 300 ]; then
					restart_adsp && last_adsp=$now
					asm_err=$(asm_errors)
				fi
			elif pw_dummy_sink; then
				now=$(cut -d. -f1 /proc/uptime)
				if [ "$((now - last_heal))" -gt 120 ]; then
					echo "audio: no real sink, bouncing card profile"
					pw_heal_card && last_heal=$now
				fi
			fi
		fi
		for iface in rndis0 usb0 ncm0; do
			if [ -d "/sys/class/net/$iface" ]; then
				if ! ip addr show dev $iface 2>/dev/null | grep -q '172.16.42.1'; then
					ifconfig $iface 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null
				fi
			fi
		done
		# USB stays a fallback uplink: drop any metric-0 default an older
		# revision (or usb-adb-rearm.sh) may have installed.
		for iface in rndis0 usb0 ncm0; do
			if [ -d "/sys/class/net/$iface" ] && \
			   ! ip route show default | \
			     grep -q "via 172.16.42.2 dev $iface metric 700"; then
				ip route del default via 172.16.42.2 \
					dev $iface metric 0 2>/dev/null || true
				ip route add default via 172.16.42.2 \
					dev $iface metric 700 2>/dev/null || true
			fi
		done
		# Ensure wlan0, wpa_supplicant and the DHCP lease stay healthy.
		if [ -d "/sys/class/net/wlan0" ]; then
			wifi_bringup || true
			wpa_state=$(wpa_cli -i wlan0 status 2>/dev/null | \
				awk -F= '/^wpa_state=/{print $2}')
			if [ "$wpa_state" = "COMPLETED" ] && \
			   ! ip addr show wlan0 2>/dev/null | grep -q 'inet '; then
				if ! pidof udhcpc >/dev/null 2>&1; then
					udhcpc -i wlan0 -b -p /run/udhcpc.wlan0.pid \
						>/dev/null 2>&1 || true
				fi
			fi
		fi
		sleep 30
	done
) &
fi
echo "keep-alive watchdog started in background"
sync
