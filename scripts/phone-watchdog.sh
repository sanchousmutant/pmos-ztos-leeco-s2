#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:$PATH

net_relax() {
	for c in /proc/sys/net/ipv4/conf/*/rp_filter; do
		echo 2 > "$c" 2>/dev/null || true
	done
}

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

asm_errors() {
	dmesg 2>/dev/null | grep -c "q6asm_dai_prepare: q6asm_open_write failed"
}

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
	amixer -c 0 sset 'QUIN_MI2S_RX Audio Mixer MultiMedia1' on \
		>/dev/null 2>&1 || true
	pw_heal_card
	return 0
}

asm_err=$(asm_errors)
last_adsp=$(cut -d. -f1 /proc/uptime)
last_heal=$last_adsp
loops=0
while true; do
	loops=$((loops + 1))
	if [ $((loops % 2)) -eq 0 ]; then
		cur=$(asm_errors)
		if [ "$cur" -lt "$asm_err" ]; then
			asm_err=$cur
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
