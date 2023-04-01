#!/bin/bash
# script to re-pack Gentoo Minimal CD with installation scripts

DOWNLOAD_DIR="/home/${SUDO_USER}/Downloads"

gen2_commons="$(dirname "$0")/commons.sh"
if ! [ -f "$gen2_commons" ] ; then
    echo "./commons.sh is required to run this script"
    exit 1
fi
# shellcheck source=./commons.sh
source "$gen2_commons"

if ! [ -f "$gen2_config" ] ; then
    echo "./CONFIG is required to run this script"
    exit 1
fi
# shellcheck source=./CONFIG
source "$gen2_config"

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

info "This script will re-pack Gentoo Minimal CD with installation scripts"
info "Select USB disk where Gentoo Minimal CD will be loaded"
if ! select_disk ; then
    exit 1
fi
while read -r part ; do
    if findmnt "$part" -n -o TARGET > /dev/null 2>&1 ; then
        mnt_point=$(findmnt "$part" -n -o TARGET)
        info "Unmounting partition $part"
        umount "$mnt_point" || fatal_error "Unable to unmount partiiton $part"
    fi
done < <(lsblk -o NAME,TYPE "$gen2_disk" -ln | grep part | awk '{print "/dev/" $1}')

info "Preparing data"
find "$(dirname "$0")" -name '*.bz2' -exec rm -rf '{}' \;
tar -czf ./localrepo.tar.bz2 /var/db/repos/localrepo/

iso_mask=install-amd64-minimal
if [ "$(find "$DOWNLOAD_DIR" -type f -name "${iso_mask}*.iso" | wc -l)" -eq 0 ] ; then
    info "Downloading Gentoo Minimal CD"
    download_stage "$iso_mask" "$DOWNLOAD_DIR"
fi

iso=$(find "$DOWNLOAD_DIR" -type f -name "${iso_mask}*.iso" | sort -Vr | head -n1)
if [ -z "$iso" ] ; then
    fatal_error "Unable to download iso to $DOWNLOAD_DIR"
fi
info "Found iso: $iso"

info "Extracting $iso"
iso_mount="/mnt/iso"
mkdir "$iso_mount"
mount -o loop "$iso" "$iso_mount"
if [ ! -f "$iso_mount"/image.squashfs ] ; then
    fatal_error "Unable to find ${iso_mount}/image.squashfs"
fi
mkdir /tmp/iso
cp -a "$iso_mount"/* /tmp/iso

info "Mounting image" 
mkdir /mnt/squashfs 
unsquashfs -d /mnt/squashfs/ -f /tmp/iso/image.squashfs

# minimal cd boots into /root so copy all scripts there 
info "Copying scripts"
cp "$(dirname "$0")"/* /mnt/squashfs/root
chmod +x /mnt/squashfs/root/*.sh
# copy connect-wifi. this script will not be used during installation but will be 
# copied with others to /install-scripts and used to setup network once desktop is installed
ssid="SSID-HERE"
wifi_password=$(nmcli --show-secrets -f 802-11-wireless-security.psk connection show "$ssid" | awk '{print $2}')
if [ -z "$wifi_password" ] ; then
    warn "Unable to retrieve stored wifi password from NetworkManager config"
else
    cp "/home/$SUDO_USER/scripts/connect-wifi.sh" /mnt/squashfs/root/connect-wifi
    chmod +x /mnt/squashfs/root/connect-wifi
    sed -i "s/\(^wifi_password=\)\(.*\)/\1\"$wifi_password\"/" /mnt/squashfs/root/connect-wifi
fi

info "Creating squashfs image"
mksquashfs /mnt/squashfs/ /tmp/image.squashfs
cp -a /tmp/image.squashfs /tmp/iso/

confirm_and_exit "Script will format $gen2_disk and load updated Gentoo image, continue?"

info "Formatting $gen2_disk"
wipefs -a -f "$gen2_disk"
cmd="n;p;1;;;a;t;b;w;"
echo "$cmd" | tr ';' '\n' | fdisk -Walways -walways "$gen2_disk"
gentoo_part="/dev/"$(lsblk -o NAME,TYPE "$gen2_disk" -ln | grep part | awk '{print $1}' | head -n1)
if [ -z "$gentoo_part" ] ; then
    fatal_error "Unable to create partition on $gen2_disk"
fi
# max label length is 11 chars 
mkfs.fat -F32 "$gentoo_part" -n "GentooMinCD"

info "Mounting USB drive"
gentoo_part_mount="${gentoo_part/dev/mnt}"
mkdir "$gentoo_part_mount" 
mount "$gentoo_part" "$gentoo_part_mount"

info "Copying squashfs image"
cp -a /tmp/iso/* "$gentoo_part_mount"

info "Removing temp files"
umount "$iso_mount"
rm -rf "$iso_mount"
rm -rf /mnt/squashfs
umount "$gentoo_part_mount"
rm -rf "$gentoo_part_mount"
rm -rf /tmp/image.squashfs
rm -rf /tmp/iso

find "$(dirname "$0")" -name '*.bz2' -exec rm -rf '{}' \;

info "Gentoo Minimal CD is created"

