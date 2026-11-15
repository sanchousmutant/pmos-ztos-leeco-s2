#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <syslog.h>
#include <signal.h>
#include <dirent.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/stat.h>

#define POWER_HOLD_MS 6000
#define COMBO_HOLD_MS 3000

#define MAX_DEVS 8

struct input_dev {
    int fd;
    char path[64];
    bool has_power;
    bool has_voldown;
};

static struct input_dev devs[MAX_DEVS];
static int num_devs = 0;
static volatile sig_atomic_t running = 1;

static void sig_handler(int sig) {
    (void)sig;
    running = 0;
}

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static bool test_bit(int nr, const uint8_t *addr) {
    return (addr[nr / 8] & (1 << (nr % 8))) != 0;
}

static void close_devs(void) {
    for (int i = 0; i < num_devs; i++) {
        if (devs[i].fd >= 0) {
            close(devs[i].fd);
            devs[i].fd = -1;
        }
    }
    num_devs = 0;
}

static void scan_devs(void) {
    close_devs();
    DIR *d = opendir("/dev/input");
    if (!d) return;

    struct dirent *de;
    while ((de = readdir(d)) != NULL && num_devs < MAX_DEVS) {
        if (strncmp(de->d_name, "event", 5) != 0) continue;

        char path[64];
        snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);

        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;

        unsigned long evbits = 0;
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), &evbits) < 0 || !(evbits & (1UL << EV_KEY))) {
            close(fd);
            continue;
        }

        uint8_t keybits[(KEY_MAX + 7) / 8] = {0};
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) < 0) {
            close(fd);
            continue;
        }

        bool has_power = test_bit(KEY_POWER, keybits);
        bool has_voldown = test_bit(KEY_VOLUMEDOWN, keybits);

        if (has_power || has_voldown) {
            char name[128] = "Unknown";
            ioctl(fd, EVIOCGNAME(sizeof(name)), name);
            syslog(LOG_INFO, "phone-keyd: found %s (%s) power=%d voldown=%d", path, name, has_power, has_voldown);

            devs[num_devs].fd = fd;
            snprintf(devs[num_devs].path, sizeof(devs[num_devs].path), "%s", path);
            devs[num_devs].has_power = has_power;
            devs[num_devs].has_voldown = has_voldown;
            num_devs++;
        } else {
            close(fd);
        }
    }
    closedir(d);
}

int main(int argc, char **argv) {
    openlog("phone-keyd", LOG_PID | LOG_CONS, LOG_DAEMON);
    syslog(LOG_INFO, "phone-keyd starting: hardware button shutdown/reboot monitor");

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);
    signal(SIGHUP, sig_handler);

    scan_devs();
    if (num_devs == 0) {
        syslog(LOG_WARNING, "phone-keyd: no key input devices found, will retry in loop");
    }

    bool power_down = false;
    bool voldown_down = false;
    uint64_t power_down_time = 0;
    uint64_t combo_down_time = 0;

    struct pollfd pfd[MAX_DEVS];

    while (running) {
        if (num_devs == 0) {
            sleep(2);
            scan_devs();
            continue;
        }

        for (int i = 0; i < num_devs; i++) {
            pfd[i].fd = devs[i].fd;
            pfd[i].events = POLLIN;
            pfd[i].revents = 0;
        }

        // Poll timeout: if any key is pressed, check every 100ms. Otherwise wait indefinitely.
        int timeout_ms = (power_down || voldown_down) ? 100 : -1;
        int ret = poll(pfd, num_devs, timeout_ms);

        uint64_t now = now_ms();

        if (ret > 0) {
            bool need_rescan = false;
            for (int i = 0; i < num_devs; i++) {
                if (pfd[i].revents & (POLLERR | POLLHUP | POLLNVAL)) {
                    need_rescan = true;
                    continue;
                }
                if (pfd[i].revents & POLLIN) {
                    struct input_event ev[16];
                    int rd = read(devs[i].fd, ev, sizeof(ev));
                    if (rd < 0) {
                        if (errno != EAGAIN && errno != EINTR) need_rescan = true;
                        continue;
                    }
                    int n = rd / sizeof(struct input_event);
                    for (int j = 0; j < n; j++) {
                        if (ev[j].type != EV_KEY) continue;

                        if (ev[j].code == KEY_POWER) {
                            if (ev[j].value == 1) { // pressed
                                power_down = true;
                                power_down_time = now;
                                syslog(LOG_DEBUG, "phone-keyd: KEY_POWER pressed");
                            } else if (ev[j].value == 0) { // released
                                power_down = false;
                                power_down_time = 0;
                                syslog(LOG_DEBUG, "phone-keyd: KEY_POWER released");
                            }
                        } else if (ev[j].code == KEY_VOLUMEDOWN) {
                            if (ev[j].value == 1) { // pressed
                                voldown_down = true;
                                syslog(LOG_DEBUG, "phone-keyd: KEY_VOLUMEDOWN pressed");
                            } else if (ev[j].value == 0) { // released
                                voldown_down = false;
                                syslog(LOG_DEBUG, "phone-keyd: KEY_VOLUMEDOWN released");
                            }
                        }
                    }
                }
            }
            if (need_rescan) {
                syslog(LOG_WARNING, "phone-keyd: input device error, rescanning...");
                scan_devs();
                power_down = false;
                voldown_down = false;
                continue;
            }
        }

        now = now_ms();

        // 1. Check Power + Volume Down combo (reboot)
        if (power_down && voldown_down) {
            if (combo_down_time == 0) {
                combo_down_time = now;
            } else if (now - combo_down_time >= COMBO_HOLD_MS) {
                syslog(LOG_CRIT, "phone-keyd: Emergency Reboot triggered (Power + VolDown held for %d ms)!", (int)(now - combo_down_time));
                sync();
                int r = system("/sbin/reboot");
                (void)r;
                exit(0);
            }
        } else {
            combo_down_time = 0;
        }

        // 2. Check Power long press alone (poweroff)
        if (power_down && !voldown_down) {
            if (power_down_time > 0 && (now - power_down_time >= POWER_HOLD_MS)) {
                syslog(LOG_CRIT, "phone-keyd: Emergency Poweroff triggered (Power key held for %d ms)!", (int)(now - power_down_time));
                sync();
                int r = system("/sbin/poweroff");
                (void)r;
                exit(0);
            }
        }
    }

    close_devs();
    syslog(LOG_INFO, "phone-keyd stopping");
    closelog();
    return 0;
}
