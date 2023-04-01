#!/bin/bash

interface="wlp3s0"
wpa_supplicant -i$interface -c/mnt/sdc2/wpa.conf -B
sleep 5
dhcpcd $interface
ifconfig