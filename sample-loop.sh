#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
i=0
while [ "$i" -lt 60 ]; do
	for f in Front_Left Front_Right Front_Center; do
		[ -f "/usr/share/sounds/alsa/$f.wav" ] || continue
		paplay "/usr/share/sounds/alsa/$f.wav"
	done
	i=$((i + 1))
done
