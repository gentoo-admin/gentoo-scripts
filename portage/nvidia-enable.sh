#!/bin/bash

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi

echo "Configuring nvidia"

if [ -f /etc/portage/package.mask/nvidia ] ; then
    rm -f /etc/portage/package.mask/nvidia
fi

find /etc/udev/rules.d/ -name '*remove*nvidia*' -exec rm -rf {} \;

if [ -f /etc/modprobe.d/nvidia-blacklist.conf ] ; then
    rm -f /etc/modprobe.d/nvidia-blacklist.conf
fi

# add nvidia global flag
if ! grep -q '^USE=.*nvidia.*' /etc/portage/make.conf ; then
    sed -i '/^USE=/ s/\"$/ nvidia\"/' /etc/portage/make.conf
fi
if ! grep -q '^VIDEO_CARDS=.*nvidia.*' /etc/portage/make.conf ; then
    sed -i '/^VIDEO_CARDS=/ s/\"$/ nvidia\"/' /etc/portage/make.conf
fi

# disable nouveau
if [ ! -f /etc/modprobe.d/nouveau-blacklist.conf ] ; then
cat << EOF > /etc/modprobe.d/nouveau-blacklist.conf
blacklist nouveau
options nouveau modeset=0
EOF
fi

bash -c 'echo "nvidia" > /etc/modules-load.d/nvidia.conf'
cat << EOF > /etc/portage/package.use/nvidia
media-video/ffmpeg -video_cards_nvidia
x11-drivers/nvidia-drivers tools
EOF

if [ ! -d /etc/dracut.conf.d ] ; then
    mkdir /etc/dracut.conf.d
fi
echo 'omit_drivers+=" nvidia nvidia-drm nvidia-modeset nvidia-uvm "' > /etc/dracut.conf.d/nvidia.conf

if ! groups "$SUDO_USER" | grep -q video ; then
    gpasswd -a "$SUDO_USER" video
fi

echo "Configuration is complete"

emerge -avuDN --with-bdeps=y @world
emerge -av x11-apps/mesa-progs

# load modules
if lsmod | grep -iq nvidia ; then
    rmmod nvidia
fi
modprobe nvidia

cat << EOF > /etc/sddm.conf
[X11]
DisplayCommand=/etc/sddm/scripts/Xsetup
EOF
mkdir -p /etc/sddm/scripts

# 
# Nvidia config
# https://download.nvidia.com/XFree86/Linux-x86_64/515.65.01/README/randr14.html
# 
# admin@gentoo ~ $ xrandr --listproviders 
# Providers: number : 2
# Provider 0: id: 0x55 cap: 0xf, Source Output, Sink Output, Source Offload, Sink Offload crtcs: 4 
# outputs: 3 associated providers: 1 name:Unknown AMD Radeon GPU @ pci:0000:06:00.0
# Provider 1: id: 0x1f7 cap: 0x2, Sink Output crtcs: 4 outputs: 5 associated providers: 1 name:NVIDIA-G0

cat << EOF > /etc/sddm/scripts/Xsetup
#!/bin/sh
xrandr --setprovideroutputsource 1 0 
xrandr --auto
EOF
chmod a+x /etc/sddm/scripts/Xsetup

cat << EOF > /etc/X11/xorg.conf
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "AMDgpu" 0 0
    Inactive       "nvidia"
    InputDevice    "Keyboard0" "CoreKeyboard"
    InputDevice    "Mouse0" "CorePointer"
    Option         "AllowNVIDIAGPUScreens"
EndSection

Section "Files"
EndSection

Section "InputDevice"

    # generated from data in "/etc/conf.d/gpm"
    Identifier     "Mouse0"
    Driver         "mouse"
    Option         "Protocol"
    Option         "Device" "/dev/input/mice"
    Option         "Emulate3Buttons" "no"
    Option         "ZAxisMapping" "4 5"
EndSection

Section "InputDevice"

    # generated from default
    Identifier     "Keyboard0"
    Driver         "kbd"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    VendorName     "Unknown"
    ModelName      "Unknown"
    Option         "DPMS"
EndSection

Section "Device"
    Identifier     "AMDgpu"
    Driver         "amdgpu"
    VendorName     "AMD"
    BusID          "PCI:6:0:0"
EndSection

Section "Device"
    Identifier     "nvidia"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    BusID          "PCI:1:0:0"
EndSection

Section "Screen"
    Identifier     "AMDgpu"
    Device         "AMDgpu"
    Monitor        "Monitor0"
    DefaultDepth    24
    SubSection     "Display"
        Depth       24
    EndSubSection
EndSection 
EOF

 
# __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo
