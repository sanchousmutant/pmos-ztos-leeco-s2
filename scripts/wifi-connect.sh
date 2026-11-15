#!/bin/sh
# WiFi connection helper for postmarketOS on LeEco Le 2
if [ $# -lt 1 ]; then
    echo "Использование: wifi-connect <SSID> [пароль]"
    exit 1
fi
SSID="$1"
PASS="$2"

echo "Подключение к сети: $SSID"
ID=$(wpa_cli add_network | tail -n 1)
wpa_cli set_network "$ID" ssid "\"$SSID\"" >/dev/null

if [ -n "$PASS" ]; then
    wpa_cli set_network "$ID" psk "\"$PASS\"" >/dev/null
else
    wpa_cli set_network "$ID" key_mgmt NONE >/dev/null
fi

wpa_cli enable_network "$ID" >/dev/null
wpa_cli select_network "$ID" >/dev/null
wpa_cli save_config >/dev/null

echo "Ожидание ассоциации с точкой доступа..."
for i in $(seq 1 10); do
    STATE=$(wpa_cli status | grep 'wpa_state=' | cut -d= -f2)
    if [ "$STATE" = "COMPLETED" ]; then
        echo "Связь установлена! Запрос IP-адреса через DHCP..."
        udhcpc -i wlan0 -q -n
        exit 0
    fi
    sleep 1
done

echo "Текущее состояние: $STATE (проверьте пароль или уровень сигнала)"
