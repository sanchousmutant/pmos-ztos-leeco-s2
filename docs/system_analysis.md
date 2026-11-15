# 🔬 Анализ системы ztOS на LeEco Le 2 (s2) — План устранения багов

> Анализ выполнен на основе `changelog_jt.md`, `bug_report.md`, скриптов `start-sshd.sh`, `deploy_live.sh`, `install-ztmetro.sh` и конфигурации `ztos-port/`.

---

## 📊 Обзор системы

| Параметр | Значение |
|---|---|
| **Устройство** | LeEco Le 2 (s2, Qualcomm MSM8976) |
| **ОС** | Alpine Linux 3.24.1 (postmarketOS) |
| **Ядро** | Mainline 6.18.7-msm8956+ (сборки до #12) |
| **Композитор** | ztMETRO (wlroots 0.20) + cage (kiosk) |
| **GPU** | Adreno 510, OpenGL ES 3.1 (Mesa 26.1.6, freedreno) |
| **Wi-Fi** | Qualcomm WCN3680, wcn36xx, dual-band 802.11ac |
| **USB** | RNDIS (configfs), SSH 172.16.42.1 |

---

## 📈 Сводка по багам

| Статус | Баги | Кол-во |
|---|---|---|
| ✅ **fixed** | BR-002, BR-004, BR-007, BR-008, BR-010, BR-013, BR-014, BR-015, BR-016, BR-017, BR-018, BR-019, BR-020 | 13 |
| 🟡 **mitigated** | BR-001, BR-003, BR-011 | 3 |
| 🔴 **known** | BR-005, BR-006, BR-012 | 3 |
| 🟠 **workaround** | BR-009 | 1 |

---

## 🔴 Открытые проблемы из `changelog_jt.md`

Из раздела «Известные проблемы и задачи» в changelog:

| # | Проблема | Приоритет | Текущий статус |
|---|---|---|---|
| **C-1** | Визуальное оформление: нет обоев ztOS и логотипа загрузки | Medium | ❌ Открыт |
| **C-2** | Сеть: кнопка Wi-Fi вызывает `nmcli` вместо `wpa_supplicant`/`rfkill` | High | ✅ Исправлен (создан мост `scripts/nmcli` + `ztos-port/nmcli`) |
| **C-3** | Звук/Громкость: аппаратный аудио-кодек (WCD9335) | High | 🔄 В работе (включен монолитный SLIMBUS/QDSP6 в ядре) |
| **C-4** | Автозапуск: сервис OpenRC для ztMETRO | Medium | ✅ Исправлен (добавлены переменные окружения и автосоздание директорий) |
| **C-5** | Документация: актуализация README.md и bug_report.md | Low | ❌ Открыт |

---

## 🟡 Нерешённые баги из `bug_report.md`

### BR-001 — mainline KMS не полностью закрыт (mitigated)

- **Проблема:** `modetest` отсутствует, визуальное подтверждение куба/рабочего стола и чистой перезагрузки не проведено формально.
- **Риск:** Низкий. KMS фактически работает (kmscube, Weston, Cage, Adreno 510).
- **Действие:** Закрыть тикет после визуального подтверждения и чистого `reboot → boot → display OK`.

### BR-003 — configfs RNDIS без adb/ffs (mitigated)

- **Проблема:** На mainline нет adb; при сбое configfs единственный путь — TWRP или legacy.
- **Риск:** Средний. RNDIS/SSH работают стабильно, но нет аварийного fallback.
- **Действие:** Рассмотреть минимальный `telnetd` или `dropbear` в initramfs для safe-mode.

### BR-005 — safe mode без shell (known)

- **Проблема:** После `MAXFAIL=2` initramfs переходит в safe mode, но без sshd/adbd shell недоступен.
- **Риск:** Средний. Требует физического вмешательства через TWRP.
- **Действие:** Встроить `dropbear` (компактный SSH) в initramfs.

### BR-006 — reboot → Qualcomm 900E (known)

- **Проблема:** Программный `reboot` уводит SoC в диагностический режим 900E.
- **Риск:** Средний. Повседневная перезагрузка невозможна через софт.
- **Действие:** Исследовать `psci` / `scm-call` альтернативы; попробовать `reboot -f` или `echo b > /proc/sysrq-trigger`.

### BR-009 — Windows RNDIS INF без подписи (workaround)

- **Проблема:** Работает только с testsigning и импортированным self-signed сертификатом.
- **Риск:** Низкий (разработческая среда).
- **Действие:** Оставить как есть; при необходимости подписать через доверенный CA.

### BR-011 — make без ARCH=arm64 (mitigated)

- **Проблема:** .config был испорчен, восстановлен.
- **Риск:** Низкий. Зафиксирован в документации.
- **Действие:** Добавить проверку `ARCH` в `build.sh`, закрыть тикет.

### BR-012 — TWRP adb push обрезает имя (known)

- **Проблема:** Баг в TWRP adbd — отсечение последнего символа.
- **Риск:** Низкий.
- **Действие:** Добавить в deploy-скрипт автоматическое переименование; или push файлы с суффиксом `_`.

---

## 🔧 ПЛАН УСТРАНЕНИЯ БАГОВ

### Фаза 1 — Критичные (High Priority)

#### 🎯 1.1 Аудиоподсистема — реальный аппаратный выход (C-3)

**Проблема:** PipeWire работает, но выводит звук в `Dummy Output` — нет реального аудио-кодека.

**Действия:**
1. Проверить наличие узлов аудио-кодека в DTS:
   ```sh
   cat /proc/asound/cards
   aplay -l
   ls /sys/bus/platform/devices/ | grep -i audio
   dmesg | grep -iE "codec|wcd|msm-dai|afe|alsa"
   ```
2. В `msm8976-leeco-s2.dts` активировать узлы:
   - `&slim_msm` (SLIMbus)
   - `&wcd_codec` (WCD9335 или WCD9326)
   - `&lpass` / `&q6afe` / `&q6asm` / `&q6adm` (Audio DSP, если доступен в mainline)
3. Установить `alsa-utils` и `alsa-ucm-conf` для правильной маршрутизации.
4. Обновить конфигурацию PipeWire/WirePlumber для нового sink.
5. Проверить воспроизведение через динамик и наушники.

**Ожидаемый результат:** Реальный аудиовыход через кодек, а не Dummy.

---

#### 🎯 1.2 Wi-Fi UI в ztMETRO — замена nmcli (C-2)

**Проблема:** Композитор ztMETRO может вызывать `nmcli`, который отсутствует в Alpine.

**Действия:**
1. Найти все вызовы `nmcli` в исходниках ztMETRO:
   ```sh
   grep -rn "nmcli" /root/ztos-ztmetro/
   ```
2. Заменить на обёртку через `wpa_cli` + `rfkill`:
   - **Сканирование:** `wpa_cli -i wlan0 scan && wpa_cli -i wlan0 scan_results`
   - **Подключение:** `wpa_cli -i wlan0 add_network` → `set_network` → `enable_network`
   - **Отключение:** `wpa_cli -i wlan0 disconnect`
   - **Включение/Выключение Wi-Fi:** `rfkill block/unblock wlan`
3. Создать обёртку `/usr/local/bin/wifi-ctl` с унифицированным API.
4. Пересобрать ztMETRO `settings/ztsettings` с новыми вызовами.

**Ожидаемый результат:** Кнопка Wi-Fi в ztMETRO работает через wpa_supplicant.

---

#### 🎯 1.3 Автозапуск после reboot — верификация (C-4)

**Проблема:** Не проверена полная цепочка `power on → lk2nd → mainline → initramfs → rootfs → OpenRC → seatd → wayland → ztMETRO`.

**Действия:**
1. Выполнить холодную перезагрузку кнопкой питания (не `reboot`).
2. Проверить лог:
   ```sh
   cat /var/log/start-sshd.log
   rc-status -a
   cat /var/log/wayland.log
   cat /var/log/wayland.err
   ```
3. Убедиться что `.bootcount` сбрасывается при успехе.
4. Проверить таймеры: `seatd` → `wayland` → ztMETRO/cage.
5. Протестировать восстановление после 2 неудачных загрузок (safe mode).

**Ожидаемый результат:** Автозапуск стабилен, документирован.

---

### Фаза 2 — Средний приоритет

#### 🎯 2.1 Safe mode с SSH-доступом (BR-005)

**Действия:**
1. Собрать статический `dropbear` (или `busybox` с `telnetd`) для aarch64.
2. Включить его в `initramfs-tiny.switch` (CPIO).
3. В safe-mode блоке initramfs запускать:
   ```sh
   dropbear -R -p 22 -B  # или telnetd -l /bin/sh
   ```
4. Пересобрать initramfs, обновить размер и MD5 в документации.

**Ожидаемый результат:** В safe mode доступен SSH на `172.16.42.1:22`.

---

#### 🎯 2.2 Программная перезагрузка (BR-006)

**Действия:**
1. Протестировать альтернативные механизмы:
   ```sh
   echo b > /proc/sysrq-trigger          # emergency reboot
   reboot -f                              # force reboot
   echo 1 > /sys/kernel/reboot_reason     # если поддерживается
   watchdog -T 1 -t 1 /dev/watchdog       # hw watchdog timeout
   ```
2. Проверить, не связана ли проблема с `psci` или SCM-вызовом в DTS:
   ```sh
   dmesg | grep -i "psci\|scm\|reboot"
   ```
3. Если найдётся рабочий вариант — обернуть в `/usr/local/bin/safe-reboot`.

**Ожидаемый результат:** Рабочая команда перезагрузки без 900E.

---

#### 🎯 2.3 Визуальное оформление ztOS (C-1)

**Действия:**
1. Найти ассеты обоев и логотипа в исходниках ztOS:
   ```sh
   find /root/ztos-ztmetro/ -iname "*.png" -o -iname "*.svg" -o -iname "wallpaper*" -o -iname "logo*"
   ```
2. Скопировать обои в `~/.config/ztmetro/wallpaper.png` (или путь из конфига).
3. Для splash-логотипа проверить `ztOS/ztmetro/splash/ztos-splash.c`:
   - Найти путь к изображению логотипа.
   - Установить SVG/PNG ассет по нужному пути.
4. Пересобрать `ztos-splash` при необходимости.

**Ожидаемый результат:** Обои и логотип загрузки отображаются.

---

#### 🎯 2.4 Защита build.sh от ошибки ARCH (BR-011)

**Действия:**
1. В `kernel/build.sh` добавить проверку:
   ```sh
   if [ "$(uname -m)" != "aarch64" ] && [ -z "$ARCH" ]; then
       echo "ERROR: cross-compiling requires ARCH=arm64"
       exit 1
   fi
   export ARCH=${ARCH:-arm64}
   export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
   ```
2. Закрыть тикет BR-011 как fixed.

---

### Фаза 3 — Низкий приоритет

#### 🎯 3.1 TWRP adb push workaround (BR-012)

**Действия:**
1. В `twrp_deploy_switch.sh` добавить автокоррекцию имён:
   ```sh
   for f in /tmp/deploy/*; do
       base=$(basename "$f")
       expected="${base}X"
       [ "${#base}" -lt "${#expected}" ] && mv "$f" "${f}$(echo "$expected" | tail -c 2)"
   done
   ```
   Или проще: документировать push с добавленным символом `_`.

---

#### 🎯 3.2 Документация (C-5)

**Действия:**
1. Обновить `README.md`:
   - Актуальная версия ядра (#12).
   - Список рабочих функций (Wi-Fi, GPU, OSK, Lockscreen, Volume, Chromium).
   - Инструкция по установке ztMETRO.
2. Обновить `bug_report.md`:
   - Закрыть BR-001 (KMS подтверждён через Adreno 510).
   - Добавить дату последней ревизии.
3. Обновить `changelog_jt.md`:
   - Пометить решённые задачи.
   - Уточнить оставшиеся проблемы.

---

## 📋 Сводная таблица плана

| # | Задача | Приоритет | Сложность | Зависимости |
|---|---|---|---|---|
| 1.1 | Аудио-кодек (реальный выход) | 🔴 High | Высокая | DTS, ядро, ALSA |
| 1.2 | Wi-Fi: nmcli → wpa_cli | 🔴 High | Средняя | Исходники ztMETRO |
| 1.3 | Верификация автозапуска | 🔴 High | Низкая | Доступ к устройству |
| 2.1 | Safe mode SSH (dropbear) | 🟡 Medium | Средняя | Initramfs пересборка |
| 2.2 | Исправить reboot → 900E | 🟡 Medium | Высокая | DTS/ядро, тесты |
| 2.3 | Обои и логотип ztOS | 🟡 Medium | Низкая | Ассеты ztOS |
| 2.4 | Защита build.sh (ARCH) | 🟡 Medium | Низкая | — |
| 3.1 | TWRP push workaround | 🟢 Low | Низкая | — |
| 3.2 | Документация | 🟢 Low | Низкая | — |
