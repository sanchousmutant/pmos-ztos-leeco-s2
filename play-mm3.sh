#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/1000
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
i=0
while [ "$i" -lt 10 ]; do
	pw-play --target alsa_output.platform-c051000.sound.pro-output-2 /tmp/tone-stereo.wav
	i=$((i + 1))
done
