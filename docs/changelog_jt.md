# Журнал разработки переноса ztOS (jt)

## Цель
Перенос компонентов ztOS (композитор ztMETRO и сопутствующее ПО) на смартфон LeEco Le 2 (s2, MSM8976) под управлением postmarketOS (Alpine Linux).

## Статус системы
- **Устройство**: LeEco Le 2 (s2, Qualcomm MSM8976).
- **ОС**: Alpine Linux 3.24.1.
- **Ядро**: Mainline 6.18.7-msm8956+ #15 (ADSP/QDSP6, WCNSS, DRM, Freedreno).
- **Композитор**: ztMETRO (wlroots 0.20) работает вместо labwc.
- **Статус**: Работающая графическая оболочка, доступен ввод, работают приложения ztseries. Wi-Fi и Bluetooth поднимаются автоматически, звук через динамик и PipeWire проверен. Требуется доработка оформления (обои, лого), UCM-профиля звука и HFP/SCO.

## Выполненные этапы

### 1. Подготовка среды и зависимостей
- Исследование структуры репозитория ztOS.
- Проверка сетевой связности устройства.
- **Manual Dev Package Installation**: Из-за риска конфликтов пакетов в Alpine (downgrade важных библиотек вроде libvpx), зависимости `wlroots0.20-dev`, `gdk-pixbuf-dev` и `librsvg-dev` были установлены вручную путем распаковки `.apk` файлов в `/tmp` и ручного размещения хедеров и `.pc` файлов. Это позволило собрать компоненты без нарушения целостности основной ОС.

### 2. Портирование и сборка (Compile & Port)
- Копирование исходного кода в `/root/ztos-ztmetro` на устройстве.
- **Musl Compatibility Patch**: Применен патч в `ztmetro.c` для поддержки функции `close_range`, которая отсутствует в стандартной библиотеке musl (реализовано через прямой syscall или цикл закрытия дескрипторов).
- Сборка всех модулей:
  - `ztmetro` (композитор)
  - `ztapps` (сервис приложений)
  - `ztsettings` (настройки)
  - `zrndevtest`, `ztdevices`, `ztpower`, `ztfiles`.
- Создание директории порта `E:\Project\postmarketos\ztos-port\` с установочными скриптами и конфигурациями.

### 3. Интеграция с системой (OpenRC Integration)
- Модификация `/etc/init.d/wayland` для добавления кейса `ztmetro`.
- Конфигурация `/etc/conf.d/wayland` с указанием нового композитора.
- Создание кастомного установочного скрипта `install-ztmetro.sh`, адаптированного под UID/GID пользователя `pmos` (1000) и особенности демонов зtOS.
- Деплой бинарников в `/usr/local/bin`, настроек в `/home/pmos/.config/ztmetro/`.

### 4. Тестирование
- Проведен успешный ручной запуск сессии ztMETRO.
- Зафиксирована работоспособность отрисовки (OpenGL ES 3.1, Mesa 26.1.6).
- Проверено наличие интерфейса: App List, Action Centre, Settings.
- Подтверждена корректная работа управления состоянием через control pipe (`/run/user/1000/ztmetro.ctl`).

### 5. Устранение критических проблем (Фаза 1)
- **Сетевой мост nmcli -> wpa_supplicant / rfkill**:
  - Создан автономный bridge-скрипт `scripts/nmcli` и `ztos-port/nmcli`, транслирующий вызовы `nmcli` (radio on/off, device wifi list, device wifi connect, connection show/up/down/delete) в команды `wpa_cli` и `rfkill`.
  - Устранена несовместимость интерфейса ztMETRO и ztSettings с Alpine Linux без необходимости устанавливать тяжелый NetworkManager.
  - Скрипт интегрирован в `ztos-port/install-ztmetro.sh` и `deploy_live.sh`.
- **Стабилизация автозапуска OpenRC (Wayland / ztMETRO)**:
  - В `/etc/init.d/wayland` добавлена передача критических переменных окружения: `PATH` с `/usr/local/bin`, `XDG_DATA_DIRS`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, `USER`, `SHELL`.
  - Добавлено автоматическое создание и установка прав на `$USER_HOME/.config/ztmetro` и `$USER_HOME/.cache/ztmetro` для предотвращения сбоев фонового сервиса `ztapps`.
- **Аудиоподсистема**:
  - По дампу аппаратного Device Tree (`appended.dts`) определена архитектура звукового тракта: кодек Qualcomm WCD9335 / WCD9326 (Tasha) на шине SLIMbus, усилители WSA881x, роутинг QDSP6 через Hexagon DSP.
  - В `kernel/config-6.18.7-leeco-s2` активирован драйвер шины `CONFIG_SLIMBUS=y`, `CONFIG_SLIM_QCOM_CTRL=y`, встроенные драйверы `CONFIG_SND_SOC_QDSP6=y`, `CONFIG_SND_SOC_QCOM=y`, `CONFIG_SND_SOC_WCD9335=y` (монолитная сборка без внешних модулей).
  - В `kernel/build.sh` добавлен экспорт `ARCH=arm64` и `CROSS_COMPILE` для защиты от случайной порчи `.config` при сборке на хосте (BR-011).

### 6. Устранение критических проблем (Фаза 2: Термозащита, GPU-ускорение видео, Аудио)
- **Термозащита и предотвращение аварийного отключения (BR-020)**:
  - Выявлена причина аппаратных перезапусков (`HARDWARE PROTECTION shutdown (Temperature too high)`) — порог критической температуры в 75°C в сочетании с неотзывчивым `performance` governor.
  - Гувернер переведен на `schedutil` (сброс частот в простое до 200–400 МГц), пороги trip point подняты до 95°C (критический) и 80°C/70°C (предупредительный/троттлинг), ток зарядки снижен до 1.2 А.
  - Система работает абсолютно стабильно при рабочих температурах 47–52°C.
- **Аппаратное ускорение видео и Chromium (BR-021)**:
  - Устранена причина слайд-шоу на YouTube: Freedreno разблокирован в Chromium через `--ignore-gpu-blocklist`, активирована растеризация через GPU (`--enable-gpu-rasterization --enable-zero-copy`).
  - Исправлен сбой EGL инициализатора путем перехода на ANGLE GLES (`--use-gl=angle --use-angle=gles`).
  - Настроен мобильный профиль браузера с принудительным User-Agent (автоматическая загрузка легковесного плеера H.264 вместо ресурсоемких VP9/AV1).
  - Конфигурация зафиксирована в `/etc/chromium/chromium.conf` и `/usr/local/bin/launch-chromium`. Нагрузка на процессор при видео снизилась со 100% до 14–20%.
- **Аудиоподсистема и ядро (BR-022, BR-023)**:
  - Собрано монолитное ядро Linux 6.18.7 с встроенными `CONFIG_SND_USB_AUDIO=y`, `CONFIG_SLIMBUS=y`, `CONFIG_SND_SOC_QDSP6=y`, `CONFIG_SND_SOC_WCD9335=y` (устранена зависимость от отсутствующей директории `/lib/modules`).
  - Развернут полнофункциональный стек Bluetooth Audio: установлен `bluez`, `bluez-openrc`, `pipewire-spa-bluez`, кодеки `libldac`, `fdk-aac`, `sbc`. Включен профиль A2DP Audio Sink/Source.
  - Извлечена прошивка `adsp.*` с раздела модема `mmcblk0p1` в `/lib/firmware/qcom/msm8976/`.
  - В драйвер `qcom_q6v5_pas.c` добавлена поддержка сопроцессора MSM8976 (`qcom,msm8976-adsp-pas`). Включен `CONFIG_QCOM_Q6V5_PAS=y` и звуковая карта `CONFIG_SND_SOC_APQ8016_SBC=y`.
  - В `msm8976.dtsi` и `msm8976-leeco-s2.dts` интегрированы узлы `remoteproc@c200000` (GIC SPI 293 / 289), сервисы APR v2 (`q6core`, `q6afe`, `q6asm`, `q6adm`) и звуковая карта `sound: sound`.
  - Собрано ядро сборки #14 и DTB, развернуты на загрузочные разделы `p27` и `p56`.
- **Маршрутизация DPCM и усилитель динамика (BR-024)**:
  - Исправлен баг в `sound/soc/qcom/common.c`, из-за которого backend DAI ссылки без узла кодека ошибочно определялись как frontend DAI (`link->no_pcm = 0`), вызывая сбой `no backend DAIs enabled for MultiMedia1`.
  - В драйвер `sound/soc/qcom/apq8016_sbc.c` добавлена поддержка Quinary MI2S (`QUINARY_MI2S_RX`/`TX`) для внешнего усилителя Snapdragon 652 (`MI2S_QUINARY`).
  - В ядро встроен драйвер `CONFIG_SND_SOC_SIMPLE_AMPLIFIER=y`.
  - В `msm8976-leeco-s2.dts` добавлен узел усилителя `speaker_amp` на GPIO 132 (`wsa-spkr-sd`), DAPM-виджет `Speaker`, связь `Quinary MI2S` и таблица маршрутов `audio-routing`.
  - Собрано монолитное ядро #15 и развернуто на устройство вместе с автозапуском `/etc/local.d/speaker.start`.

### 7. Автозапуск Wi-Fi/Bluetooth и звука (BR-025, BR-026, 2026-11-12)
- **WCNSS и Bluetooth:** `start-sshd.sh` запускал `remoteproc0` (ADSP), а WCNSS на MSM8976 — это `remoteproc1` (`a204000.remoteproc`); исправлено на запуск всех offline remoteproc. После появления `wlan0` запускается `wpa_supplicant`, после `wpa_state=COMPLETED` — `udhcpc`; watchdog поддерживает DHCP-аренду. `hci0` появляется автоматически, `rfkill` разблокируется, BlueZ 5.86 подхватывает адаптер `02:00:56:xx:xx:xx`.
- **Звук:** `pmos` добавлен в группу `audio`; в `start-sshd.sh` и `/etc/local.d/speaker.start` включается маршрут `QUIN_MI2S_RX Audio Mixer MultiMedia1`; `/etc/asound.conf` задаёт `card 0` по умолчанию. Пользовательская сессия D-Bus, PipeWire, WirePlumber и `pipewire-pulse` стартует из `start-sshd.sh`.
- **Профиль карты:** ACP-профиль по умолчанию — `off`; WirePlumber-правило `51-msm8976.conf` автоматически выбирает `pro-audio`, default sink — `alsa_output.platform-c051000.sound.pro-output-0`. Проверено `paplay` (rc=0) и `speaker-test`.
- **Deploy и ядро:** `deploy_live.sh`, `deploy_switch.sh`, `twrp_deploy_switch.sh` устанавливают `asound.conf`, `speaker.start`, WirePlumber-правило и runlevel-ссылки `local`/`bluetooth`. `kernel/config-6.18.7-leeco-s2` синхронизирован с WSL `.config`, `kernel/leeco-s2-6.18.7.patch` регенерирован.
- **Проверка:** WCNSS остановлен и снова запущен через `start-sshd.sh`: `remoteproc1 = running`, `wlan0 = COMPLETED`, IP `<wifi-ip>/24`, `hci0` доступен, маршрут `[on]`, sink `pro-audio` воспроизводит.

### 7. Управление питанием и аппаратные клавиши (Power / Reboot)
- **Графическое меню питания в композиторе ztMETRO:**
  - Реализовано распознавание короткого и длинного нажатия аппаратной кнопки питания (`KEY_POWER`, code 116):
    - **Короткое нажатие** (< 850 мс): штатное включение/выключение подсветки и блокировка/разблокировка экрана.
    - **Долгое удержание** (>= 850 мс): срабатывает виброотклик (`hap`), экран принудительно просыпается (если спал) и выезжает модальное меню в стиле Metro с кнопками `Выключение` (`poweroff`) и `Перезагрузка` (`reboot`).
  - **Управление меню**: выбор действия возможен как касанием по сенсорному экрану, так и аппаратными клавишами телефона:
    - Кнопка **Громкость вверх** (`KEY_VOLUMEUP`) активирует `Выключение`.
    - Кнопка **Громкость вниз** (`KEY_VOLUMEDOWN`) активирует `Перезагрузку`.
    - Кнопка **Назад** (`KEY_BACK`) или повторное нажатие **Power** либо тап по затемненной области закрывают меню без выполнения действия.
- **Аварийный фоновый демон клавиш (`phone-keyd`):**
  - Разработан и скомпилирован нативный C-демон `/usr/local/bin/phone-keyd` и OpenRC-сервис `/etc/init.d/phone-keyd` (добавлен в `default` runlevel).
  - Работает на уровне ядра напрямую через evdev (`/dev/input/event0` и `/dev/input/event1`), потребляет 0% CPU благодаря `poll()`.
  - Обеспечивает безопасное выключение и перезагрузку даже в случае полного зависания графической оболочки Wayland:
    - **Power + Volume Down** (удержание 3 секунды) — аварийная перезагрузка (`sync; /sbin/reboot`).
    - **Power** (удержание 6 секунд) — аварийное выключение (`sync; /sbin/poweroff`).
  - Демон и скрипт инициализации интегрированы в скрипты деплоя `deploy_live.sh` и `twrp_deploy_switch.sh`.

### 8. Восстановление звука на встроенный динамик (NXP TFA9890 SmartPA, BR-029)
- **Аппаратная архитектура звукового тракта LeEco Le 2:**
  - В отличие от референсного Qualcomm WSA881x, на плате `s2` применен интеллектуальный цифровой I2S усилитель **NXP TFA9890** с управлением по I2C на шине `blsp2_i2c4` (`i2c@7af8000`, адрес `0x34`).
  - Аудиоданные подаются из Hexagon QDSP6 через интерфейс **Quinary MI2S** на физические TLMM-пины 123, 124, 125, 127 (функция `pri_mi2s`).
  - Маршрутизация Quinary MI2S внутри LPASS активируется записью бита 0 в регистр `csr_gp_io_mux_quin_ctl` (`0xc052000`).
- **Исправление сброса и шины I2C:**
  - В `msm8976-leeco-s2.dts` исправлена полярность сброса TFA9890: вход `RST` микросхемы является **active-high**, поэтому фиксация в `output-high` держала чип в постоянном сбросе. Установлен уровень `output-low;` для нормальной работы.
  - Активирована шина `blsp2_i2c4` (`status = "okay"`), узел `tfa9890@34` и pinctrl `quin_mi2s_default`.
  - Монолитное ядро #17 (`CONFIG_SND_SOC_TFA989X=y`, `apq8016_sbc.c` с Quinary MI2S) и обновленный DTB развернуты на загрузочный раздел `p27` (`/mnt/system`), `p56` (`/boot` и `/`).
- **Результаты проверки:**
  - Драйвер ядра `tfa989x` на шине `1-0034` опознает чип, считывает ревизию и активирует режим байпаса DSP.
  - Компонент `tfa989x.1-0034` и DAI `tfa989x-hifi` связаны в звуковую карту `msm8976-leeco-s2`.
  - DAPM-цепочка: `MultiMedia1` → `QUIN_MI2S_RX` → `Quinary MI2S Playback` → `HiFi Playback` → `Amp Input` (Left) → `AMPE` → `OUT` → `Internal Speaker` активна (`On`).
  - Звуковые потоки PipeWire и тестовые WAV-файлы через `paplay` воспроизводятся без ошибок на полную громкость (100%).

## Известные проблемы и задачи
- [ ] **Визуальное оформление**: Отсутствуют обои ztOS и логотип загрузки (виден пустой квадрат).
- [x] **Сеть (Wi-Fi)**: WCNSS (`remoteproc1`) и `wlan0` поднимаются автоматически при boot; работает подключение к сетям (2.4/5 ГГц), отображение списков сетей в ztSettings через bridge-скрипт `nmcli`, автополучение IP по DHCP (`udhcpc`).
- [x] **Bluetooth**: Стек BlueZ 5.86 + PipeWire SPA BlueZ (A2DP Sink/Source); `hci0` появляется после автозапуска WCNSS. Требуется проверка A2DP с реальной гарнитурой; HFP/SCO не включён.
- [x] **Перегрев / Перезагрузки**: Регулятор частоты `schedutil`, безопасные пороги thermal trip points (95°C).
- [x] **Воспроизведение видео**: Аппаратное ускорение Adreno 510 GPU через ANGLE GLES в Chromium, сброс загрузки CPU до ~18%.
- [x] **Внутренний звук и динамики**: Аппаратный SmartPA NXP TFA9890 инициализирован по I2C, пины Quinary MI2S скоммутированы в TLMM, DAPM-цепочка активна, звук воспроизводится через PipeWire и ALSA на полную громкость (BR-029).
- [ ] **UCM-профиль звука**: Добавить `/usr/share/alsa/ucm2/conf.d/...` для `msm8976-leeco-s2`, чтобы заменить `pro-audio`-workaround штатными портами/громкостью.
- [ ] **HFP/SCO**: Включить `CONFIG_SND_SOC_BT_SCO` и проверить микрофон/динамик в Bluetooth-гарнитуре.
- [x] **Автозапуск**: Подготовлен и стабилизирован OpenRC-сервис для ztMETRO со всеми переменными окружения и директориями кэша.
- [x] **Управление питанием на аппаратные клавиши**: Добавлено графическое меню выключения/перезагрузки по долгому нажатию клавиши питания в ztMETRO с управлением тачем и кнопками громкости, а также системный аварийный демон `phone-keyd` (Power+VolDown = reboot 3s, Power = poweroff 6s).
- [x] **Документация**: Актуализация `bug_report.md` (BR-020..BR-026) и `changelog_jt.md`; регенерированы `kernel/config-6.18.7-leeco-s2` и `kernel/leeco-s2-6.18.7.patch`.
