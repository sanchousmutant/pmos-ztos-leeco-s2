#!/bin/sh
# deploy_switch.sh - run ON THE DEVICE from TWRP recovery.
# Expects the new files staged in $D (default /data/.deploy).
#
# Deploys the kernel + DTB + initramfs to BOTH boot partitions (p27 system and
# p56 userdata) because lk2nd may pick either one, and installs the rootfs boot
# scripts.  Resets the boot-failure counter so the next boot gets a full set of
# attempts before the initramfs falls back into safe mode.

set -e

D=${D:-/data/.deploy}
SYS=/mnt/system
USR=/data

echo "=== mounting $SYS (p27) ==="
mkdir -p $SYS
mount | grep -q " $SYS " || mount -t ext4 /dev/block/mmcblk0p27 $SYS

echo "=== boot files -> p27 and p56 ==="
mkdir -p $SYS/extlinux
for part in "$SYS" "$USR"; do
    echo "  -> $part"
    cp "$D/extlinux.conf"         "$part/extlinux/extlinux.conf"
    cp "$D/Image"                 "$part/Image"
    cp "$D/msm8976-leeco-s2.dtb"  "$part/msm8976-leeco-s2.dtb"
    cp "$D/vmlinuz"               "$part/vmlinuz"
    cp "$D/s2.dtb"                "$part/s2.dtb"
    cp "$D/initramfs-tiny.switch" "$part/initramfs-tiny.switch"
    sed -i 's/\r$//'              "$part/extlinux/extlinux.conf"
    chmod 644 "$part/extlinux/extlinux.conf" "$part/Image" \
              "$part/msm8976-leeco-s2.dtb" "$part/vmlinuz" "$part/s2.dtb" \
              "$part/initramfs-tiny.switch"
done

echo "=== rootfs boot scripts -> p56 ==="
cp "$D/start-sshd.sh" "$USR/start-sshd.sh"
sed -i 's/\r$//' "$USR/start-sshd.sh"
chmod 755 "$USR/start-sshd.sh"

mkdir -p "$USR/usr/local/bin"
cp "$D/start-gui.sh" "$USR/usr/local/bin/start-gui.sh"
sed -i 's/\r$//' "$USR/usr/local/bin/start-gui.sh"
chmod 755 "$USR/usr/local/bin/start-gui.sh"

# live diagnostic helpers - run them over SSH on the booted system
for s in fb-probe.sh usb-adb-rearm.sh; do
    if [ -f "$D/$s" ]; then
        cp "$D/$s" "$USR/usr/local/bin/$s"
        sed -i 's/\r$//' "$USR/usr/local/bin/$s"
        chmod 755 "$USR/usr/local/bin/$s"
        echo "  installed /usr/local/bin/$s"
    fi
done

cp "$D/inittab.s2" "$USR/etc/inittab"
sed -i 's/\r$//' "$USR/etc/inittab"
chmod 644 "$USR/etc/inittab"

cp "$D/fb-setup" "$USR/etc/init.d/fb-setup"
sed -i 's/\r$//' "$USR/etc/init.d/fb-setup"
chmod 755 "$USR/etc/init.d/fb-setup"

cp "$D/gui.init" "$USR/etc/init.d/gui"
sed -i 's/\r$//' "$USR/etc/init.d/gui"
chmod 755 "$USR/etc/init.d/gui"

if [ -f "$D/wayland.init" ]; then
    cp "$D/wayland.init" "$USR/etc/init.d/wayland"
    sed -i 's/\r$//' "$USR/etc/init.d/wayland"
    chmod 755 "$USR/etc/init.d/wayland"
fi

if [ -f "$D/wayland.confd" ]; then
    cp "$D/wayland.confd" "$USR/etc/conf.d/wayland"
    sed -i 's/\r$//' "$USR/etc/conf.d/wayland"
    chmod 644 "$USR/etc/conf.d/wayland"
fi

echo "=== audio / bluetooth config ==="
if [ -f "$D/asound.conf" ]; then
    cp "$D/asound.conf" "$USR/etc/asound.conf"
    sed -i 's/\r$//' "$USR/etc/asound.conf"
    chmod 644 "$USR/etc/asound.conf"
fi
mkdir -p "$USR/etc/local.d" "$USR/etc/wireplumber/wireplumber.conf.d"
if [ -f "$D/speaker.start" ]; then
    cp "$D/speaker.start" "$USR/etc/local.d/speaker.start"
    sed -i 's/\r$//' "$USR/etc/local.d/speaker.start"
    chmod 755 "$USR/etc/local.d/speaker.start"
fi
if [ -f "$D/clock.start" ]; then
    cp "$D/clock.start" "$USR/etc/local.d/clock.start"
    sed -i 's/\r$//' "$USR/etc/local.d/clock.start"
    chmod 755 "$USR/etc/local.d/clock.start"
fi
if [ -f "$D/zram.start" ]; then
    cp "$D/zram.start" "$USR/etc/local.d/zram.start"
    sed -i 's/\r$//' "$USR/etc/local.d/zram.start"
    chmod 755 "$USR/etc/local.d/zram.start"
fi
if [ -f "$D/wireplumber.conf" ]; then
    cp "$D/wireplumber.conf" \
        "$USR/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf"
    sed -i 's/\r$//' \
        "$USR/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf"
    chmod 644 "$USR/etc/wireplumber/wireplumber.conf.d/51-msm8976.conf"
fi

echo "=== runlevels: drop the duplicated networking service ==="
rm -f "$USR/etc/runlevels/default/networking"
# RTC is dead (RTC_SET_TIME -> ENODEV) and would reset the clock to 1970.
rm -f "$USR/etc/runlevels/boot/hwclock"
mkdir -p "$USR/etc/runlevels/default"
[ -f "$USR/etc/init.d/seatd" ] && ln -sf /etc/init.d/seatd "$USR/etc/runlevels/default/seatd"
[ -f "$USR/etc/init.d/wayland" ] && ln -sf /etc/init.d/wayland "$USR/etc/runlevels/default/wayland"
[ -f "$USR/etc/init.d/local" ] && ln -sf /etc/init.d/local "$USR/etc/runlevels/default/local"
[ -f "$USR/etc/init.d/bluetooth" ] && ln -sf /etc/init.d/bluetooth "$USR/etc/runlevels/default/bluetooth"

# Display bring-up is currently broken (SMMU TLB sync timeout on mdp_ns makes
# any /dev/fb0 access block forever).  While that is being investigated the GUI
# and the fb bring-up stay off, so the boot completes and the kernel log is not
# overrun by MDSS register dumps.  Remove these two files to re-enable.
echo "=== display bring-up toggles ==="
touch "$USR/.no-fb" "$USR/.no-gui"
echo "  /.no-fb  and /.no-gui created (display + GUI disabled)"

echo "=== reset boot-failure counter ==="
rm -f "$USR/.boot-ok"
echo 0 > "$USR/.bootcount"

echo "=== clear stale pstore ==="
rm -f /sys/fs/pstore/* 2>/dev/null || true

sync
umount "$SYS" 2>/dev/null || true
echo "=== DONE ==="
