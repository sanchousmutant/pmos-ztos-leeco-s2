#!/bin/sh
# twrp_deploy_switch.sh - deploy boot files to BOTH partitions (p27 system, p56 userdata)

set -e

D=/tmp/deploy

mkdir -p /mnt/system /mnt/userdata
mount | grep -q '/mnt/system' || mount -t ext4 /dev/block/mmcblk0p27 /mnt/system 2>/dev/null || mount -t ext2 /dev/block/mmcblk0p27 /mnt/system || true
mount | grep -q '/mnt/userdata' || mount -t ext4 /dev/block/mmcblk0p56 /mnt/userdata 2>/dev/null || true

for part in /mnt/system /mnt/userdata; do
	echo "Deploying to $part..."
	mkdir -p $part/extlinux

	cp "$D/extlinux.conf"         "$part/extlinux/extlinux.conf"
	sed -i 's/\r//g'              "$part/extlinux/extlinux.conf"
	cp "$D/Image"                 "$part/Image"
	cp "$D/msm8976-leeco-s2.dtb"  "$part/msm8976-leeco-s2.dtb"
	cp "$D/vmlinuz"               "$part/vmlinuz"
	cp "$D/s2.dtb"                "$part/s2.dtb"
	[ -f "$D/initramfs-tiny" ] && cp "$D/initramfs-tiny" "$part/initramfs-tiny" || true
	cp "$D/initramfs-tiny.switch" "$part/initramfs-tiny.switch"

	chmod 644 "$part/extlinux/extlinux.conf"
	chmod 644 "$part/Image" "$part/msm8976-leeco-s2.dtb" \
		"$part/vmlinuz" "$part/s2.dtb" "$part/initramfs-tiny.switch"
	[ -f "$part/initramfs-tiny" ] && chmod 644 "$part/initramfs-tiny" || true
done

echo "Deploying runtime scripts to userdata (p56)..."
if [ -f "$D/start-sshd.sh" ]; then
	cp "$D/start-sshd.sh" /mnt/userdata/start-sshd.sh
	chmod 755 /mnt/userdata/start-sshd.sh
	sed -i 's/\r//g' /mnt/userdata/start-sshd.sh
fi

if [ -f "$D/start-gui.sh" ]; then
	mkdir -p /mnt/userdata/usr/local/bin
	cp "$D/start-gui.sh" /mnt/userdata/usr/local/bin/start-gui.sh
	chmod 755 /mnt/userdata/usr/local/bin/start-gui.sh
	sed -i 's/\r//g' /mnt/userdata/usr/local/bin/start-gui.sh
fi

if [ -f "$D/wayland.init" ]; then
	cp "$D/wayland.init" /mnt/userdata/etc/init.d/wayland
	chmod 755 /mnt/userdata/etc/init.d/wayland
	sed -i 's/\r//g' /mnt/userdata/etc/init.d/wayland
	mkdir -p /mnt/userdata/etc/runlevels/default
	ln -sf /etc/init.d/seatd /mnt/userdata/etc/runlevels/default/seatd
	ln -sf /etc/init.d/wayland /mnt/userdata/etc/runlevels/default/wayland
fi

if [ -f "$D/wayland.confd" ]; then
	cp "$D/wayland.confd" /mnt/userdata/etc/conf.d/wayland
	chmod 644 /mnt/userdata/etc/conf.d/wayland
	sed -i 's/\r//g' /mnt/userdata/etc/conf.d/wayland
fi

if [ -f "$D/phone-keyd" ]; then
	cp "$D/phone-keyd" /mnt/userdata/usr/local/bin/phone-keyd
	chmod 755 /mnt/userdata/usr/local/bin/phone-keyd
fi

if [ -f "$D/phone-keyd.init" ]; then
	cp "$D/phone-keyd.init" /mnt/userdata/etc/init.d/phone-keyd
	chmod 755 /mnt/userdata/etc/init.d/phone-keyd
	sed -i 's/\r//g' /mnt/userdata/etc/init.d/phone-keyd
	ln -sf /etc/init.d/phone-keyd /mnt/userdata/etc/runlevels/default/phone-keyd
fi

echo "Deploying audio / bluetooth config..."
if [ -f "$D/asound.conf" ]; then
	cp "$D/asound.conf" /mnt/userdata/etc/asound.conf
	chmod 644 /mnt/userdata/etc/asound.conf
	sed -i 's/\r//g' /mnt/userdata/etc/asound.conf
fi
mkdir -p /mnt/userdata/etc/local.d \
	/mnt/userdata/etc/wireplumber/wireplumber.conf.d
if [ -f "$D/speaker.start" ]; then
	cp "$D/speaker.start" /mnt/userdata/etc/local.d/speaker.start
	chmod 755 /mnt/userdata/etc/local.d/speaker.start
	sed -i 's/\r//g' /mnt/userdata/etc/local.d/speaker.start
fi
if [ -f "$D/clock.start" ]; then
	cp "$D/clock.start" /mnt/userdata/etc/local.d/clock.start
	chmod 755 /mnt/userdata/etc/local.d/clock.start
	sed -i 's/\r//g' /mnt/userdata/etc/local.d/clock.start
fi
if [ -f "$D/zram.start" ]; then
	cp "$D/zram.start" /mnt/userdata/etc/local.d/zram.start
	chmod 755 /mnt/userdata/etc/local.d/zram.start
	sed -i 's/\r//g' /mnt/userdata/etc/local.d/zram.start
fi
if [ -f "$D/wireplumber.conf" ]; then
	cp "$D/wireplumber.conf" \
		/mnt/userdata/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf
	chmod 644 \
		/mnt/userdata/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf
	sed -i 's/\r//g' \
		/mnt/userdata/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf
fi

mkdir -p /mnt/userdata/etc/runlevels/default
# RTC is dead (RTC_SET_TIME -> ENODEV) and would reset the clock to 1970.
rm -f /mnt/userdata/etc/runlevels/boot/hwclock
[ -f /mnt/userdata/etc/init.d/local ] && \
	ln -sf /etc/init.d/local /mnt/userdata/etc/runlevels/default/local
[ -f /mnt/userdata/etc/init.d/bluetooth ] && \
	ln -sf /etc/init.d/bluetooth /mnt/userdata/etc/runlevels/default/bluetooth

# Fix /etc/network/interfaces to prevent networking service hanging on ncm0
if [ -f /mnt/userdata/etc/network/interfaces ]; then
	printf 'auto lo\niface lo inet loopback\n\nauto rndis0\niface rndis0 inet static\n    address 172.16.42.1\n    netmask 255.255.255.0\n    gateway 172.16.42.2\n' > /mnt/userdata/etc/network/interfaces
fi

# Clear pstore ramoops so the next boot has clean logs
rm -f /sys/fs/pstore/* 2>/dev/null || true

sync
umount /mnt/system 2>/dev/null || true
umount /mnt/userdata 2>/dev/null || true
echo "=== DONE ==="
echo "Files deployed to p27 and p56 successfully."
