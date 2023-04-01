#!/bin/bash
# ##############################################################################
# script to partition hdd and install stage3 tarball
# ##############################################################################

# validate  
gen2_commons="$(dirname "$0")/commons.sh"
if ! [ -f "$gen2_commons" ] ; then
    echo "./commons.sh is required to run this script"
    exit 1
fi
# shellcheck source=./commons.sh
source "$gen2_commons"
validate_config

chroot_script="$(dirname "$0")/openrc-kde-chroot.sh"
if ! [ -f "$chroot_script" ] ; then
    fatal_error "./openrc-kde-chroot.sh is required to run this script"
fi

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

cat << EOF
#
# ##############################################################################"
# 
# Gentoo installation script
# Sysinit:     OpenRC
# Display:     Xorg
# Desktop:     KDE
# 
# Executables
EOF
while read -r f; do
    echo "# $f"
done < <(find "$(dirname "$0")" -type f -name "$(basename "$0" | cut -d. -f1)*.sh") | sort -r
echo "#"
echo "# Config"
echo "# $gen2_config"
echo "# $(find "$(dirname "$0")" -type f -name "$(basename "$0" | cut -d. -f1)*.kernel*")"
cat << EOF
#
# Processor:    ${gen2_processor_model} $(nproc) threads
# Video card:   $gen2_video_card
# Wifi card:    $gen2_wifi_card
# 
# ##############################################################################"
# 

EOF

# select and partition disk
info "Select a disk where Gentoo will be installed"
if ! select_disk ; then exit 1; fi
gen2_boot_partition="${gen2_disk}"$([[ "$gen2_disk" == /dev/nvme* ]] && printf 'p')1
gen2_swap_partition="${gen2_disk}"$([[ "$gen2_disk" == /dev/nvme* ]] && printf 'p')2
gen2_root_partition="${gen2_disk}"$([[ "$gen2_disk" == /dev/nvme* ]] && printf 'p')3
gen2_home_partition="${gen2_disk}"$([[ "$gen2_disk" == /dev/nvme* ]] && printf 'p')4    

replace_value "$gen2_config" gen2_boot_partition "$gen2_boot_partition"
replace_value "$gen2_config" gen2_swap_partition "$gen2_swap_partition"
replace_value "$gen2_config" gen2_root_partition "$gen2_root_partition"
replace_value "$gen2_config" gen2_home_partition "$gen2_home_partition"

# shellcheck source=./CONFIG
source "$gen2_config"

echo ''
echo "# #########################################################################"
printf '\n'
echo "# Disk: $gen2_disk"
echo "# Script will create the folowing partitions:"
printf '\n'
printf ' %-20s%-10s%-10s%s\n' "$gen2_boot_partition" "/boot"  "${gen2_boot_partition_size}" "fat32 grub"
printf ' %-20s%-10s%-10s%s\n' "$gen2_swap_partition" "swap"   "${gen2_swap_partition_size}" "swap"
printf ' %-20s%-10s%-10s%s\n' "$gen2_root_partition" "/"      "${gen2_root_partition_size}" "ext4"
printf ' %-20s%-10s%-10s%s\n' "$gen2_home_partition" "/home"  ""                            "ext4"
printf '\n'
echo "# #########################################################################"

attempts=2
for (( i=1; i<=attempts; i++ )) ; do
    confirm_and_exit "[${i}/${attempts}]  - Proceed with installation?"
done

echo ''
info "Formatting $gen2_disk"
if [ "$(lsblk "$gen2_disk" -ln | grep -c part)" -gt 0 ] ; then
    confirm_and_exit "Disk $gen2_disk is not empty, wipe all data?"
    wipefs -a -f "$gen2_disk"
fi
format_str="g;"
format_str+="n;1;;+${gen2_boot_partition_size};t;1;"
format_str+="n;2;;+${gen2_swap_partition_size};t;2;19;"
format_str+="n;3;;+${gen2_root_partition_size};"
format_str+="n;4;;;"
format_str+="w;"
echo "$format_str" | tr ';' '\n' | fdisk "$gen2_disk"

mkfs.vfat -F32 "$gen2_boot_partition"
mkswap "$gen2_swap_partition"
swapon "$gen2_swap_partition"
mkfs.ext4 "$gen2_root_partition"
mkfs.ext4 "$gen2_home_partition"

# print partitions
printf '\n'
echo "# #########################################################################"
echo "The following partitions are created on disk ${gen2_disk}:"
printf '\n'
fdisk "$gen2_disk" -l
# parted "$gen2_disk" print
printf '\n'
printf '%s UUID: %s\n' "$gen2_boot_partition" "$(lsblk -o UUID -ln "$gen2_boot_partition")"
printf '%s UUID: %s\n' "$gen2_swap_partition" "$(lsblk -o UUID -ln "$gen2_swap_partition")"
printf '%s UUID: %s\n' "$gen2_root_partition" "$(lsblk -o UUID -ln "$gen2_root_partition")"
printf '%s UUID: %s\n' "$gen2_home_partition" "$(lsblk -o UUID -ln "$gen2_home_partition")"
printf '\n'
echo "# #########################################################################"
printf '\n'

sleep 1
mount "$gen2_root_partition" /mnt/gentoo || fatal_error "Unable to mount /mnt/gentoo"

info "Setting time"
ntpd -q -g

info "Downloading stage tarball"
cd /mnt/gentoo || fatal_error "Unable to cd /mnt/gentoo"
download_stage stage3-amd64-openrc

info "Extracting stage tarball"
tar xpf "$gen2_stage_iso" --xattrs-include='*.*' --numeric-owner --exclude=".keep"

info "Configuring make.conf"
replace_value /mnt/gentoo/etc/portage/make.conf COMMON_FLAGS          "-march=${gen2_processor_model} -O2 -pipe"
merge_values  /mnt/gentoo/etc/portage/make.conf USE                   "X icu alsa bluetooth -semantic-desktop xinerama -cdrom elogind networkmanager pulseaudio"
replace_value /mnt/gentoo/etc/portage/make.conf MAKEOPTS              "-j$(nproc)"
replace_value /mnt/gentoo/etc/portage/make.conf VIDEO_CARDS           "$gen2_video_card"
replace_value /mnt/gentoo/etc/portage/make.conf ACCEPT_LICENSE        "*"
replace_value /mnt/gentoo/etc/portage/make.conf PORTAGE_ELOG_CLASSES  "log warn error"
replace_value /mnt/gentoo/etc/portage/make.conf PORTAGE_ELOG_SYSTEM   "save"
replace_value /mnt/gentoo/etc/portage/make.conf INPUT_DEVICES         "libinput"
if [[ "$gen2_video_card" == *nvidia* ]] ; then
    merge_values /mnt/gentoo/etc/portage/make.conf USE nvidia
fi
cat /mnt/gentoo/etc/portage/make.conf
printf '\n\n'

info "Configuring repositories"
if ! [ -d /mnt/gentoo/etc/portage/repos.conf ] ; then
    mkdir -p /mnt/gentoo/etc/portage/repos.conf
fi
cp /mnt/gentoo/usr/share/portage/config/repos.conf /mnt/gentoo/etc/portage/repos.conf/gentoo.conf

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

info "Mounting filesystem"
{
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --make-rslave /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-slave /mnt/gentoo/run
} || fatal_error "Unable to mount gentoo filesystem"

# copy all scripts to /mnt/gentoo/install-scripts
mkdir /mnt/gentoo/install-scripts
cp /root/* /mnt/gentoo/install-scripts
chmod +x /mnt/gentoo/install-scripts/*.sh
chmod 755 /mnt/gentoo/install-scripts/*.sh

info "Switching to chroot"
chroot /mnt/gentoo /bin/bash /install-scripts/openrc-kde-chroot.sh

rm "${gen2_stage_iso}"*

if confirm "Unmount filesystems?" ; then
    umount -l /mnt/gentoo/dev{/shm,/pts}
    umount -R /mnt/gentoo
fi

info "Base system is installed"
