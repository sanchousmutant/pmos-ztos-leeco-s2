#!/bin/sh
# start-gui.sh - bring up X + the phone desktop on the LeEco Le 2 (s2).
#
# Deployed to: /usr/local/bin/start-gui.sh
# Called by:   /etc/init.d/gui   (OpenRC)
#
# Desktop: SXMO on dwm (X11).
#   Session entry : /usr/share/xsessions/sxmo.desktop -> sxmo_dwminit.sh
#   Our config    : /root/.config/sxmo/xinit, /root/.config/sxmo/profile,
#                   /root/.Xresources
#   Deviceprofile : /usr/local/bin/sxmo_deviceprofile_leeco-s2.sh
#   sxmobar shim  : /usr/local/bin/sxmobar  (see that file for why)
#
# Why not Phosh / Plasma Mobile / Sway: the kernel is built with
# "# CONFIG_DRM is not set", so there is no /dev/dri and no KMS.  Every Wayland
# compositor needs DRM+GBM; only X11 works here.  SXMO/dwm needs no GL at all,
# which also makes it the fastest option on this hardware.

export DISPLAY=:0
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export XDG_CONFIG_HOME=/root/.config

# SXMO derives its device name from /proc/device-tree/compatible, which on this
# board yields "qcom,msm8976-qrd-skun".  Pin a friendlier one so that
# _sxmo_load_environments() finds our deviceprofile instead of warning.
export SXMO_DEVICE_NAME=leeco-s2

# SXMO caches the session bus address in $XDG_RUNTIME_DIR/dbus.bus and keeps
# its job and status state there, so this must be writable and private.
export XDG_RUNTIME_DIR=/run/user/0

mkdir -p /var/log /var/run

# Single-instance guard: the OpenRC "gui" service and any manual launch must not
# end up racing two X servers onto the same /dev/fb0.
if [ -f /var/run/start-gui.pid ]; then
    old=$(cat /var/run/start-gui.pid 2>/dev/null)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "start-gui.sh already running as pid $old, nothing to do" \
            >> /var/log/start-gui.log 2>&1
        exit 0
    fi
fi
echo $$ > /var/run/start-gui.pid

exec >> /var/log/start-gui.log 2>&1
echo "=== start-gui.sh started at $(date) (pid $$) ==="

# 1. Turn on backlight.  Writing the LED class devices and the fb "blank"
#    sysfs attribute does NOT open /dev/fb0, so neither can power the panel
#    down.  (The fb "blank" write is a no-op while the panel is already on.)
echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null || true
echo 255 > /sys/class/leds/lcd-backlight/brightness 2>/dev/null || true
echo 2048 > /sys/class/leds/wled/brightness 2>/dev/null || true

# 2. NO test_fb / fb_pan0 BEFORE Xorg.
#    Those helpers open() and close() /dev/fb0.  Closing the last descriptor on
#    fb0 makes mdss_fb_release_all() blank the panel to FB_BLANK_POWERDOWN,
#    which asserts the panel reset and drops the LAB/IBB regulators.  With
#    cont_splash_enabled set, mdss_fb_set_backlight() returns early and never
#    programs the WLED, so the panel cannot be brought back - result: a live
#    framebuffer and a black screen.
#    Xorg must therefore be the one and only opener of /dev/fb0.

# 3. Mount devpts if not mounted (needed for st/xterm and sxmo's menus)
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true

# 4. Prepare X11 unix socket directory and SXMO's runtime dir
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# 5. Remove any old X lock files
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true

# 6. Start Xorg with -noreset -novtswitch
echo "Starting Xorg..."
/usr/bin/Xorg :0 -noreset -novtswitch -verbose 3 &
X_PID=$!

# 7. Actively wait for X server to be ready and accept connections (up to 30 s)
x_ready=0
for i in $(seq 1 60); do
    if DISPLAY=:0 /usr/bin/xsetroot -solid '#1a5fb4' >/dev/null 2>&1; then
        echo "X server is READY! Background set to blue after $((i * 500)) ms"
        x_ready=1
        break
    fi
    sleep 0.5
done

if [ $x_ready -eq 0 ]; then
    echo "WARNING: X server did not respond to xsetroot within 30s!"
fi

# Ensure pan is 0,0 once Xorg has initialized.
# Guarded on purpose: only run this while Xorg actually holds /dev/fb0 open.
# If Xorg were not running, fb_pan0 would be the only opener and its close()
# would power the panel down (mdss_fb_release_all -> FB_BLANK_POWERDOWN).
if pidof Xorg >/dev/null 2>&1; then
    /usr/local/bin/fb_pan0 2>/dev/null || true
fi

# Allow any local user to connect to X display
/usr/bin/xhost + 2>/dev/null || true

# 8. Start a D-Bus SESSION bus  <<< REQUIRED BY SXMO AND EVERYTHING ELSE
#    Only the SYSTEM bus runs by default.  SXMO caches this address in
#    $XDG_RUNTIME_DIR/dbus.bus so that later shells can rejoin the same bus.
DBUS_ENV=/var/run/dbus-session.env
if [ -f "$DBUS_ENV" ]; then
    . "$DBUS_ENV"
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    dbus-launch --sh-syntax > "$DBUS_ENV" 2>/dev/null
    if [ -s "$DBUS_ENV" ]; then
        . "$DBUS_ENV"
        export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
        echo "session bus started: $DBUS_SESSION_BUS_ADDRESS"
    else
        echo "WARNING: could not start a D-Bus session bus"
    fi
else
    echo "reusing session bus: $DBUS_SESSION_BUS_ADDRESS"
fi

# 9. Desktop: the SXMO dwm session.
#
#    Chain: sxmo_dwminit.sh -> sxmo_init.sh -> init() -> start() -> with_dbus()
#           -> ~/.config/sxmo/xinit -> exec dwm
#
#    SXMO_WM=dwm is set by sxmo_dwminit.sh itself.  sxmo_dwminit.sh blocks (it
#    waits for the session), so it goes in the background.  ~/.config/sxmo/xinit
#    starts sxmo_hook_start.sh from inside the session, where the SXMO
#    environment actually exists.
echo "Starting SXMO (dwm) session..."
sxmo_dwminit.sh &
SXMO_PID=$!

#    Give dwm time to map its bar before deciding whether we need a fallback.
sleep 8

if pidof dwm >/dev/null 2>&1; then
    echo "dwm is running (pid $(pidof dwm)) - SXMO session up"
else
    echo "WARNING: dwm did not start - falling back to openbox + tint2"
    openbox &
    tint2 &
fi

# 10. Keep backlight brightness on without calling blank repeatedly.
(
    while true; do
        sleep 5
        echo 255 > /sys/class/leds/lcd-backlight/brightness 2>/dev/null || true
        echo 2048 > /sys/class/leds/wled/brightness 2>/dev/null || true
    done
) &

wait $X_PID
