#!/bin/bash
# script to enable ssh access on System Rescue CD

if [ "$(systemctl status NetworkManager >/dev/null 2>&1; echo $?)" -ne 0 ]; then
    echo "Starting NetworkManager"
    systemctl start NetworkManager
fi

if ! nmcli dev status | awk '{print $3}' | grep -q -w connected ; then
    echo "Connect to network first"
    exit 1
fi

if [ "$(systemctl status iptables >/dev/null 2>&1; echo $?)" -eq 0 ]; then
    echo "Stopping iptables"
    systemctl stop iptables
fi

echo "Setting root password"
passwd root

if [ "$(systemctl status sshd >/dev/null 2>&1; echo $?)" -ne 0 ]; then
    echo "Starting ssh"
    systemctl start sshd
fi

ifconfig 

