#!/bin/sh
# Install the ztMETRO port (built from /root/ztos-ztmetro) on the LeEco Le 2.
# Run as root on the phone: sh install-ztmetro.sh
set -e
SRC=${SRC:-/root/ztos-ztmetro}
HERE=$(dirname "$0")
USER_HOME=/home/pmos

for b in ztmetro sounds/ztos-sounds settings/ztsettings devtest/zrndevtest \
	devices/ztdevices power/ztpower files/ztfiles apps/ztapps; do
	name=$(basename "$b")
	install -D -m 755 "$SRC/$b" "/usr/local/bin/$name"
done

if [ -f "$HERE/nmcli" ]; then
	install -D -m 755 "$HERE/nmcli" /usr/local/bin/nmcli
fi

install -D -m 644 "$HERE/desktop/ztsettings.desktop" /usr/local/share/applications/ztsettings.desktop
install -D -m 644 "$HERE/desktop/zrndevtest.desktop" /usr/local/share/applications/zrndevtest.desktop
install -D -m 644 "$SRC/devices/ztdevices.desktop" /usr/local/share/applications/ztdevices.desktop
install -D -m 644 "$SRC/files/ztfiles.desktop" /usr/local/share/applications/ztfiles.desktop
install -D -m 644 "$SRC/power/ztpower.desktop" /usr/local/share/applications/ztpower.desktop

install -D -m 644 "$SRC/devices/ztdevices.svg" /usr/local/share/icons/hicolor/scalable/apps/ztdevices.svg
install -D -m 644 "$SRC/files/ztfiles.svg" /usr/local/share/icons/hicolor/scalable/apps/ztfiles.svg
install -D -m 644 "$SRC/power/ztpower.svg" /usr/local/share/icons/hicolor/scalable/apps/ztpower.svg

install -d -o pmos -g 1000 -m 755 "$USER_HOME/.config/ztmetro" "$USER_HOME/.cache/ztmetro"
install -m 644 "$HERE/config/config" "$USER_HOME/.config/ztmetro/config"
install -m 644 "$HERE/config/tiles" "$USER_HOME/.config/ztmetro/tiles"
chown -R pmos:1000 "$USER_HOME/.config/ztmetro" "$USER_HOME/.cache/ztmetro"

# the application list and its glyphs, as the pmos user (--once: no watcher)
su -s /bin/sh pmos -c "HOME=$USER_HOME XDG_CACHE_HOME=$USER_HOME/.cache ztapps --once" || true

echo "ztMETRO installed: ztmetro, ztos-sounds, ztapps, ztsettings, zrndevtest, ztdevices, ztpower, ztfiles"
