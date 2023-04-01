#!/bin/bash
# script to connect to wifi from live cd or pc

ssid="SSID-HERE"
# set password below if this script is loaded into live/rescue cd 
# when its used from host pc passwor dwill be retrieved from nmcli config
wifi_password=""

function info() {
    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" INFO "$1"
}

function warn() {
    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" WARN "$1"
}

function error() {
    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" ERROR "$1" >&2
}

function fatal_error() {
    error "$1"
    exit 1
}

# check NetworkManager status
if pidof systemd > /dev/null 2>&1 ; then
    status="$(systemctl status NetworkManager > /dev/null 2>&1; echo $?)"
    if [ "$status" -eq 3 ] || [ "$status" -eq 8 ] ; then
        info "Starting NetworkManager"
        sudo systemctl start NetworkManager
    fi
else
    # use OpenRC by default
    status="$(rc-service NetworkManager status > /dev/null 2>&1; echo $?)"
    if [ "$status" -eq 3 ] || [ "$status" -eq 8 ] ; then
        info "Starting NetworkManager"
        sudo rc-service NetworkManager start
    fi
fi

info "Initializing $ssid"
count=60
for (( i=1; i<=count; i++ )); do
    if ! nmcli -f SSID device wifi | awk '{print $1}' | grep -q "^${ssid}$" ; then
        if [ "$i" -eq "$count" ] ; then
            fatal_error "$ssid is not available"
        fi
    else
        info "$ssid is ready"
        break
    fi
    sleep 0.5
done

if [ "$(nmcli dev status | grep ".*wifi.*${ssid}" | awk '{print $3}')" == "connected" ] ; then
    info "Connected to $ssid"
    exit 0
fi

if [ -z "$wifi_password" ] ; then
    if ! nmcli --show-secrets -f 802-11-wireless-security.psk connection show "$ssid" > /dev/null 2>&1  ; then
        fatal_error "Unable to retrieve wifi password for $ssid"
    fi
else
    if ! nmcli con show | grep -q "${ssid}.*wifi.*" ; then
        info "Configuring $ssid"
        # ifname wlan0 
        nmcli con add type wifi con-name "$ssid" ssid "$ssid"
        nmcli con modify "$ssid" 802-11-wireless-security.key-mgmt wpa-psk
        nmcli con modify "$ssid" 802-11-wireless-security.psk "$wifi_password"
        nmcli con modify "$ssid" connection.autoconnect no
    fi
fi

info "Connecting to $ssid"
nmcli device wifi connect "$ssid"

echo ''
ifconfig

