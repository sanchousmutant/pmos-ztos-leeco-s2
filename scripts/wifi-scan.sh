#!/bin/sh
# WiFi scanner helper for postmarketOS on LeEco Le 2
wpa_cli scan >/dev/null 2>&1
sleep 2
wpa_cli scan_results
