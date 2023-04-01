#!/bin/bash
#################################################################################
# script to continue with gentoo installation from chroot
#################################################################################

gen2_commons="$(dirname "$0")/commons.sh"
if ! [ -f "$gen2_commons" ] ; then
    echo "./commons.sh is required to run this script"
    exit 1
fi
# shellcheck source=./commons.sh
source "$gen2_commons"

if ! [ -f "$gen2_config" ] ; then
    fatal_error "./CONFIG is required to run this script"
fi
# shellcheck source=./CONFIG
source "$gen2_config"

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

# continue with gentoo installation from chroot
source /etc/profile
printf '\n\n'

export PS1="(chroot) ${PS1}"

mount "$gen2_boot_partition" /boot || fatal_error "Unable to mount /boot"

info "Synchronizing emerge"
emerge-webrsync || fatal_error "emerge-webrsync failed"
printf '\n\n'

info "Setting system profile"
profile=$(eselect profile list | grep 'desktop/plasma.*stable' | grep -v systemd | awk -F'[][]' '{print $2}')
if [ -z "$profile" ] ; then
    fatal_error "Unable to find profile plasma profile"
fi
eselect profile set "$profile"
eselect profile list
printf '\n\n'

# if --ask not used, portage will not create temp config files 
info "Updating @world set"
while true; do
    emerge --ask --update --deep --newuse @world
    if ! update_conf_files ; then
        break
    fi
done

info "Setting cpu flags" && show_count
emerge app-portage/cpuid2cpuflags
# cpu flags will be printed in format:
# CPU_FLAGS_X86: aes avx avx2 f16c
# convert it to key="value" format
cpu_flags=$(cpuid2cpuflags | cut -d: -f2)
add_value /etc/portage/make.conf CPU_FLAGS_X86 "$cpu_flags"

info "Setting timezone" && show_count
echo "America/New_York" > /etc/timezone
emerge --config sys-libs/timezone-data

info "Setting locale" && show_count
if grep -q en_US /etc/locale.gen ; then
    sed -i '/en_US/ s/^#//' /etc/locale.gen
fi
locale-gen
locale_profile=$(eselect locale list | grep -i en_US.utf8 | awk -F'[][]' '{print $2}')
if [ -z "$locale_profile" ] ; then
    fatal_error "Unable to find en_US.utf8 locale profile"
fi
eselect locale set "$locale_profile"

env-update && source /etc/profile && export PS1="(chroot) ${PS1}"

emerge sys-apps/pciutils || fatal_error "Unable to emerge pciutils"

info "Installing firmware" && show_count
emerge sys-kernel/linux-firmware

# #################################################################################
# installing dist kernel
# #################################################################################
info "Installing genkernel" && show_count
emerge sys-kernel/genkernel sys-kernel/installkernel-gentoo || fatal_error "Unable to emerge genkernel"

if ! [ -d /etc/kernel/config.d/ ] ; then
    mkdir -p /etc/kernel/config.d/
fi

# #################################################################################
# Ryzen 9 firmware
# #################################################################################
# {
#     echo 'CONFIG_FW_LOADER=y'
#     echo 'CONFIG_EXTRA_FIRMWARE="amd-ucode/microcode_amd_fam17h.bin"'
#     echo 'CONFIG_EXTRA_FIRMWARE_DIR="/lib/firmware"'
# } >> /etc/kernel/config.d/hardware.config
# #################################################################################

# #################################################################################
# Ryzen 7 firmware
# #################################################################################
amdgpu_blobs=$(find /lib/firmware -name '*green_sardine*' -printf '%p ' | sed 's|/lib/firmware/||g')
{
    echo 'CONFIG_FW_LOADER=y'
    echo 'CONFIG_EXTRA_FIRMWARE_DIR="/lib/firmware"'
    echo "CONFIG_EXTRA_FIRMWARE=\"${amdgpu_blobs}\""
} >> /etc/kernel/config.d/hardware.config
# #################################################################################

# #################################################################################
# configure dist kernel
# #################################################################################
# ideally would do: 
# fetch -> unpack -> update kernel params -> compile
# but sys-kernel/gentoo-kernel does all in one 'prepare' function
# #################################################################################
info "Installing gentoo kernel" && show_count
emerge sys-kernel/gentoo-kernel || fatal_error "Unable to emerge gentoo kernel"
if configure_kernel ; then
    emerge sys-kernel/gentoo-kernel || fatal_error "Unable to emerge gentoo kernel"
fi

# #################################################################################
# configure gentoo-sources
# #################################################################################
# emerge --ask sys-kernel/gentoo-sources
# make modules_prepare
# make prepare
# make
# make modules_install
# make install
# emerge -v @module-rebuild 
# #################################################################################

# record kernel in world (best practice to avoid accidental kernel deletion)
# gentoo-4.14.14-dist-kernel-r1 -> gentoo-kernel:4.14.14.-r1
kernel_ver=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name '*linux*gentoo*' | sort -Vr | head -n1 | sed 's|^.*/||' | cut -d- -f2,5)
emerge -v --noreplace sys-kernel/gentoo-kernel:"$kernel_ver"

# configure modules
if ! [ -d /etc/modules-load.d/ ] ; then
    mkdir -p /etc/modules-load.d
fi

# #################################################################################
# load wifi module (if dist kernel is used, modules already loaded)
# #################################################################################
# if [ "$gen2_wifi_card" == intel ] ; then
#     echo "iwlwifi" >> /etc/modules-load.d/wifi.conf
# elif [ "$gen2_wifi_card" == mediatek ] ; then
#     printf '%s\n' mt7{6,921} >> /etc/modules-load.d/wifi.conf
# fi
# #################################################################################

info "Installing initramfs" && show_count
genkernel --install initramfs || fatal_error "Unable to emerge initramfs"

info "Installing grub" && show_count
emerge sys-boot/grub
# add GRUB_PLATFORMS="efi-64" to /etc/portage/make.conf
add_value /etc/portage/make.conf GRUB_PLATFORMS efi-64
grub-install --target=x86_64-efi --efi-directory=/boot 2>&1 || fatal_error "Unable to install grub"
# keep old interface names
if grep -q 'net.ifnames=0' /etc/default/grub ; then
    sed -i '/net.ifnames=0/ s/^#[[:space:]]\+//' /etc/default/grub
else
    add_value /etc/default/grub GRUB_CMDLINE_LINUX net.ifnames=0
fi
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 || fatal_error "Unable to configure grub"

info "Configuring fstab"
{
    printf '\n'
    printf "UUID=%-40s  /boot   vfat    defaults,noatime    0 2 \n" "$(lsblk -o UUID "$gen2_boot_partition" -ln)"
    printf "UUID=%-40s  none    swap    defaults            0 0 \n" "$(lsblk -o UUID "$gen2_swap_partition" -ln)"
    printf "UUID=%-40s  /       ext4    noatime             0 1 \n" "$(lsblk -o UUID "$gen2_root_partition" -ln)"
    printf "UUID=%-40s  /home   ext4    noatime             0 0 \n" "$(lsblk -o UUID "$gen2_home_partition" -ln)"
    printf '\n'
    printf "tmpfs	    /var/tmp/portage    tmpfs   size=%s,uid=portage,gid=portage,mode=775,nosuid,noatime,nodev	0 0 \n" \
           "$(printf %s "$gen2_swap_partition_size" | sed 's/iB$//')"
    printf '\n'
} >> /etc/fstab
cat /etc/fstab

info "Setting hostname"
echo 'hostname="gentoo"' > /etc/conf.d/hostname
echo 'dns_domain_lo="homenetwork"' > /etc/conf.d/net

info "Configuring wifi" && show_count
emerge net-wireless/{iw,wpa_supplicant} net-misc/dhcpcd || fatal_error "Unable to emerge wireless tools"
echo "127.0.0.1     homenetwork localhost" > /etc/hosts

info "Setting root password"
passwd

info "Setting clock"
sed -i 's/\(^clock=\)\(.*\)/\1\"local\"/' /etc/conf.d/hwclock

info "Configuring sound"
while true ; do
    emerge --ask alsa-utils alsa-plugins alsa-lib pulseaudio
    if ! update_conf_files ; then
        break
    fi
done
rc-update add alsasound boot

info "Configuring plugd" && show_count
emerge sys-apps/ifplugd
# add ifplugd_eth0="..." to /etc/conf.d/net
add_value /etc/conf.d/net ifplugd_eth0 '...'

info "Configuring syslog" && show_count
emerge app-admin/sysklogd || fatal_error "Unable to emerge syslog"
rc-update add sysklogd default

if [ -f /etc/portage/package.use ] ; then
    rm -f /etc/portage/package.use
fi
if ! [ -d /etc/portage/package.use ] ; then
    mkdir /etc/portage/package.use
fi

info "Installing ACPI" && show_count
emerge sys-power/acpi sys-power/acpid 
rc-update add acpid default

info "Installing laptop utils" && show_count
emerge app-laptop/laptop-mode-tools app-laptop/tuxedo-keyboard
rc-update add laptop_mode default
bash -c 'echo "options tuxedo_keyboard mode=0 color_left=0xFF00FF" > /etc/modprobe.d/tuxedo_keyboard.conf'

info "Configuring bluetooth" && show_count
echo "net-wireless/bluez deprecated" >> /etc/portage/package.use/bluetooth
emerge net-wireless/bluez || fatal_error "Unable to emerge bluetooth"
rc-update add bluetooth default
# change device name
# hciconfig hci0 name 'Gentoo Box'
sed -i 's/^#Name =.*/Name = Gentoo Box/' /etc/bluetooth/main.conf

info "Installing gentoo tools" && show_count
emerge app-portage/{gentoolkit,eix,elogviewer,genlop,layman,portage-utils} app-admin/eclean-kernel || fatal_error "Unable to emerge gentoo tools"

info "Installing system tools" && show_count
{
    echo "# enable all compression types for squashfs"
    echo "sys-fs/squashfs-tools lz4 lzma lzo xattr zstd" 
} >> /etc/portage/package.use/squashfs
emerge sys-apps/{dmidecode,usbutils,hdparm} \
sys-fs/{squashfs-tools,dosfstools,fuse-exfat,exfat-utils,e2fsprogs} \
app-editors/nano app-arch/xz-utils \
app-misc/screenfetch \
x11-apps/xrandr x11-misc/{xclip,xdotool} \
app-misc/tmux \
|| fatal_error "Unable to emerge system tools"

info "Installing clang" && show_count
emerge sys-devel/clang || fatal_error "Unable to install clang"

if [[ "$gen2_video_card" == *nvidia* ]] ; then
    info "Installing nvidia tools" && show_count
    {
        echo "# Disabling the video_cards_nvidia USE flag for ffmpeg"
        echo "media-video/ffmpeg -video_cards_nvidia"
        echo "x11-drivers/nvidia-drivers tools"
    } >> /etc/portage/package.use/nvidia
    emerge x11-drivers/nvidia-drivers media-video/ffmpeg x11-apps/mesa-progs || fatal_error "Unable to emerge nvidia tools"
fi

if grep -q "^INPUT_DEVICES=.*libinput.*" /etc/portage/make.conf ; then
    info "Installing libinput packages" && show_count
    emerge x11-misc/wmctrl || fatal_error "Unable to emerge additional packages for libinput"
fi

rc-update add elogind boot
rc-update add sshd default

