#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

if grep -q '^USE=.*nvidia.*' /etc/portage/make.conf ; then
    sed -i '/^USE=/ s/nvidia//' /etc/portage/make.conf
fi
if grep -q '^VIDEO_CARDS=.*nvidia.*' /etc/portage/make.conf ; then
    sed -i '/^VIDEO_CARDS=/ s/nvidia//' /etc/portage/make.conf
fi

emerge -avuDN --with-bdeps=y @world
emerge -C -av nvidia-drivers

# mask all drivers
cat << EOF > /etc/modprobe.d/nvidia-blacklist.conf
blacklist nvidia
blacklist nvidia-drm
blacklist nvidia-modeset
alias nvidia off
alias nvidia-drm off
alias nvidia-modeset off

blacklist nouveau
options nouveau modeset=0
EOF

audio_dev=$(lspci -nn | grep -i "audio.*nvidia" | awk '{print $1}')
cat << EOF > /etc/udev/rules.d/10-remove-nvidia-audio.rules
ACTION=="add", KERNEL=="0000:${audio_dev}", SUBSYSTEM=="pci", RUN+="/bin/sh -c 'echo 1 > /sys/bus/pci/devices/0000:${audio_dev}/remove'"
EOF

video_dev=$(lspci -nn | grep -i "video.*nvidia" | awk '{print $1}')
cat << EOF > /etc/udev/rules.d/10-remove-nvidia-audio.rules
ACTION=="add", KERNEL=="0000:${video_dev}", SUBSYSTEM=="pci", RUN+="/bin/sh -c 'echo 1 > /sys/bus/pci/devices/0000:${video_dev}/remove'"
EOF

cat << EOF > /etc/portage/package.mask/nvidia 
x11-drivers/nvidia-drivers
x11-drivers/xf86-video-nouveau
EOF
