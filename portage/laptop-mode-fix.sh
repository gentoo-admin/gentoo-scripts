#!/bin/bash
# to be ran as root

# to enable loggin on acpid
sed -i "s/\(^ACPID_ARGS=\"\)\(.*\)\(\"\)/\1--logevents\3/" /etc/conf.d/acpid

# enable logging
sed -i 's/\"VERBOSE\"/\"MSG\"/' /usr/share/laptop-mode-tools/modules/dpms-standby
# disable logging
# sed -i 's/\"MSG\"/\"VERBOSE\"/' /usr/share/laptop-mode-tools/modules/dpms-standby

# /usr/share/laptop-mode-tools/modules/dpms-standby has outdated command to get X user name for current display: 
# replace 'w -hs' with 'w -hf'
sed -i 's/w -sf/w -hf/' /usr/share/laptop-mode-tools/modules/dpms-standby 

# find class where brightness is set and replace it in /etc/laptop-mode/conf.d/lcd-brightness.conf  
sudo find / -path '*/backlight/*' -name brightness 2>/dev/null
sudo find / -path '*/backlight/*' -name max_brightness 2>/dev/null

