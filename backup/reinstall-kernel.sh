#!/bin/bash
# script to reinstall latest sys-kernel/gentoo-kernel
# 

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

function confirm() {
    while true; do 
        read -r -p "$1 [Y/n] " input
        if [[ "$input" =~ ^([yY][eE][sS]|[yY])$ ]] || [[ "$input" == "" ]] ; then
            return 0
        elif [[ "$input" =~ ^([nN][oO]|[nN])$ ]] ; then
            return 1
        else 
            echo "Invalid input, selection allowed [Y/n]"        
        fi
    done
}

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

# set nameserver is script ran after OS install 
if ! grep -q "^nameserver" /etc/resolv.conf ; then
    bash -c "echo 'nameserver 8.8.8.8' >> /etc/resolv.conf"
    bash -c "echo 'nameserver 8.8.4.4' >> /etc/resolv.conf"
fi

# find boot partition and mount if this script is called from live cd
if ! [ -f /etc/fstab ] ; then
    fatal_error "Unable to find /etc/fstab on this partition"
fi

boot_col1=$(grep "^[^#].*/boot" /etc/fstab | awk '{print $1}')
if [ -z "$boot_col1" ] ; then
    fatal_error "Unable to find /boot entry in /etc/fstab"
fi
if [[ "$boot_col1" =~ ^UUID=[0-9A-Za-z-]+$ ]] ; then
    uuid=$(cut -d= -f2 <<< "$boot_col1")
else
    fatal_error "Expected UUID=value for /boot partition"
fi
boot_part=$(lsblk -ln -o NAME,TYPE,UUID | grep "part.*$uuid" | awk '{print $1}')
if [ -z "$boot_part" ] ; then
    fatal_error "Unable to find partition with UUID $uuid"
fi
if ! [[ "$boot_part" == /dev/* ]] ; then
    boot_part="/dev/$boot_part"
fi
if ! findmnt "$boot_part" -ln -o TARGET > /dev/null 2>&1 ; then
    info "Mounting $boot_part on /boot"
    mount "$boot_part" /boot || fatal_error "Unable to mount $boot_part on /boot"
fi

source /etc/profile

# check UUID if boot-fix.sh formatted /boot partition
old_uuid=$(grep "^UUID=.*/boot" /etc/fstab | awk '{print $1}' | cut -d'=' -f2)
new_uuid=$(blkid "$boot_part" -s UUID -o value)
if [ "$old_uuid" != "$new_uuid" ] ; then
    info "Updating UUID of /boot"
    sed -i "s/^UUID=${old_uuid}/UUID=${new_uuid}/" /etc/fstab
fi

# check if sys-kernel/gentoo-kernel is installed
if [ -f /var/lib/portage/world ] && ! grep -q "sys-kernel/gentoo-kernel" /var/lib/portage/world ; then
    fatal_error "This script works with sys-kernel/gentoo-kernel only"
fi

echo "Found the following installed kernels:"
curr_kernel=$(readlink /usr/src/linux | sed 's|^.*/||g')
while read -r line; do
    if [ "$line" == "$curr_kernel" ] ; then
        echo " > $line *"
    else
        echo " > $line"
    fi
done < <(find /usr/src/ -mindepth 1 -maxdepth 1 -type d -name '*linux*' | sort -Vr | sed 's|^.*/||g')

if ! confirm "Reinstall latest kernel?" ; then
    exit 1
fi

emerge sys-kernel/gentoo-kernel || fatal_error "Unable to emerge kernel"

info "Installing initramfs"
genkernel --install initramfs || fatal_error "Unable to reinstall initramfs"

info "Configuring grub"
grub-install --target=x86_64-efi --efi-directory=/boot 2>&1 || fatal_error "Unable to reinstall grub"
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 || fatal_error "Unable to configure grub"

emerge -a @module-rebuild

info "Latest kernel reinstalled"

