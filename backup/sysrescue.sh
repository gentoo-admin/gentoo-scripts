#!/bin/bash
# script to add custom scripts to SystemRescueCD
# 

# download latest iso from https://www.system-rescue.org/Download/ and put it int the folder below
DOWNLOAD_DIR=/wdhdd

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
        printf "%s [yn] " "$1"
        read -r key
        if [[ "$key" =~ ^(Y|y) ]] || [[ "$key" == $'\0a' ]] ; then
            echo ''
            return 0
        elif [[ "$key" =~ ^(N|n) ]] ; then
            echo ''
            return 1
        fi
        echo "Please select Y/y/N/n/<-"
    done

}

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

set -e 

IFS=$'\n'
c=0
while read -r line; do
    if [[ "$line" =~ ^[a-z]+.*disk.* ]] ; then
        c=$((c+1))
        printf '%-4s' "[$c]"
    else
        printf '%-4s' ''
    fi
    echo "$line"
done < <(lsblk)

disk_count=$(lsblk -ln -o NAME,TYPE | grep -c 'disk$')
read -p "Select recovery USB: " index
if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
    fatal_error "Numeric value expected"
fi
if [ "$index" -lt 1 ] || [ "$index" -gt "${disk_count}" ] ; then
    fatal_error "Invalid disk index: $index"
fi
disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$index" | tail -n1 | awk '{print "/dev/" $1}')
if [ -z "$disk" ] ; then 
    fatal_error "Selected disk is invalid"
fi
while read -r part ; do
    if findmnt "$part" -n -o TARGET > /dev/null 2>&1 ; then
        mnt_point=$(findmnt "$part" -n -o TARGET)
        info "Unmounting partition $part"
        umount "$mnt_point" || fatal_error "Unable to unmount partiiton $part"
    fi
done < <(lsblk -o NAME,TYPE "$disk" -ln | grep part | awk '{print "/dev/" $1}')

iso=$(find "$DOWNLOAD_DIR" -type f -name 'systemrescue*.iso' | sort -Vr | head -n1)
if [ -z "$iso" ] ; then
    fatal_error "Unable to find system rescue iso in $DOWNLOAD_DIR"
fi
ver=$(echo "$iso" | sed 's|^.*/||' | cut -d- -f2 | sed 's/[^0-9]//g')
info "Found iso: $iso"
if ! confirm "Load iso to $disk?" ; then
    exit 1
fi

info "Extracting .iso image"
echo "  $iso"
mkdir /mnt/iso
mount -o loop "$iso" /mnt/iso/
if [ ! -f /mnt/iso/sysresccd/x86_64/airootfs.sfs ] ; then
    fatal_error "Unable to find sysresccd/x86_64/airootfs.sfs"
fi
mkdir /tmp/iso
cp -r /mnt/iso/* /tmp/iso

info "Mounting airootfs" 
mkdir /mnt/squashfs 
unsquashfs -d /mnt/squashfs/ -f /tmp/iso/sysresccd/x86_64/airootfs.sfs

info "Copying scripts"
cp "/home/$SUDO_USER/scripts/sysbackup.sh" /mnt/squashfs/usr/sbin/sysbackup
chmod +x /mnt/squashfs/usr/sbin/sysbackup

cp "/home/$SUDO_USER/scripts/dd-backup.sh" /mnt/squashfs/usr/sbin/dd-backup
chmod +x /mnt/squashfs/usr/sbin/dd-backup

cp "/home/$SUDO_USER/scripts/dd-restore.sh" /mnt/squashfs/usr/sbin/dd-restore
chmod +x /mnt/squashfs/usr/sbin/dd-restore

cp "/home/$SUDO_USER/scripts/fstab-fix.sh" /mnt/squashfs/usr/sbin/fstab-fix
chmod +x /mnt/squashfs/usr/sbin/fstab-fix

cp "/home/$SUDO_USER/scripts/boot-fix.sh" /mnt/squashfs/usr/sbin/boot-fix
chmod +x /mnt/squashfs/usr/sbin/boot-fix

cp "/home/$SUDO_USER/scripts/enable-systemrescue-ssh.sh" /mnt/squashfs/usr/sbin/enable-ssh
chmod +x /mnt/squashfs/usr/sbin/enable-ssh

cp "/home/$SUDO_USER/scripts/reinstall-kernel.sh" /mnt/squashfs/usr/sbin/reinstall-kernel
chmod +x /mnt/squashfs/usr/sbin/reinstall-kernel

cp "/home/$SUDO_USER/scripts/partition-disk.sh" /mnt/squashfs/usr/sbin/partition-disk
chmod +x /mnt/squashfs/usr/sbin/partition-disk

cp "/home/$SUDO_USER/scripts/connect-wifi.sh" /mnt/squashfs/usr/sbin/connect-wifi
chmod +x /mnt/squashfs/usr/sbin/connect-wifi
ssid="SSID-HERE"
wifi_password=$(nmcli --show-secrets -f 802-11-wireless-security.psk connection show "$ssid" | awk '{print $2}')
if [ -n "$wifi_password" ] ; then
    sed -i "s/\(^wifi_password=\)\(.*\)/\1\"$wifi_password\"/" /mnt/squashfs/usr/sbin/connect-wifi
fi

cat << EOF > /mnt/squashfs/root/.bash_history
dd-restore
dd-backup
sysbackup --format --restore --disk=sdb --backup-loc=sda1
sysbackup --format --restore --disk=nvme0n1 --backup-loc=sda1
sysbackup --format --restore --disk=nvme1n1 --backup-loc=sda1
sysbackup --backup --encrypt --disk=sdb --backup-loc=sda1
sysbackup --backup --encrypt --disk=nvme0n1 --backup-loc=sda1
sysbackup --backup --encrypt --disk=nvme1n1 --backup-loc=sda1
EOF

info "Creating squashfs image"
mksquashfs /mnt/squashfs/ /tmp/airootfs.sfs
sha512sum /tmp/airootfs.sfs | sed 's|/.*/||g' > /tmp/airootfs.sha512

cat <<EOF

Script will format $disk and create 2 partitions:

 [1]: System Rescue (3GB) 
 [2]: Backup partition on the remaining disk space

If No is selected, script will load updated image into partition #1
of the selected disk assuming that partition is bootable and FAT32.
!!! ALL DATA WILL BE LOST !!!

EOF

if confirm "Format ${disk}?" ; then

    info "Formatting $disk"

    cmd="n;p;1;;+3G;a;t;b;"
    cmd+="n;p;2;;;w;"
    wipefs -a -f "$disk"
    echo "$cmd" | tr ';' '\n' | fdisk -Walways -walways "$disk"
    if [ "$(lsblk -o NAME,TYPE "$disk" -ln | grep -c part)" -ne 2 ] ; then
        fatal_error "Unable to create 2 partitions on $disk"
    fi
    part1=$(lsblk -o NAME,TYPE "$disk" -ln | grep part | awk '{print "/dev/" $1}' | head -n1)
    part2=$(lsblk -o NAME,TYPE "$disk" -ln | grep part | awk '{print "/dev/" $1}' | head -n2 | tail -n1)

    # archisolabel value should match RESCUE501 in 
    # /boot/grub/grubsrcd.cfg and /sysresccd/boot/syslinux/sysresccd_sys.cfg

    mkfs.fat -F32 "$part1" -n "RESCUE${ver}"
    mkfs.ext4 -L Backup "$part2"

fi

# loading image to partition #1 of $disk
if [ -z "$part1" ] ; then
    if [ "$(lsblk -o NAME,TYPE "$disk" -ln | grep -c part)" -lt 1 ] ; then
        fatal_error "Unable to find partition 1 on $disk"
    fi
    part1=$(lsblk -o NAME,TYPE "$disk" -ln | grep part | awk '{print "/dev/" $1}' | head -n1)
    part1_fstype=$(lsblk "$disk" -o NAME,TYPE,FSTYPE -ln | grep part | awk '{print $3}' | head -n1)
    if [ -z "$part1_fstype" ] ; then
        fatal_error "Unable to get fstype for partiton #1"
    fi
    if ! [[ "$part1_fstype" == *fat* ]] ; then
        fatal_error "Partition #1 must have fat filesystem"
    fi
    fatlabel "$part1" "RESCUE${ver}"
fi

info "Mounting $part1"
part1_mount="${part1/dev/mnt}"
if [ ! -d "$part1_mount" ] ; then
    mkdir "$part1_mount"
fi
mount "$part1" "$part1_mount" || fatal_error "Unable to mount $part1 at $part1_mount"

info "Copying squashfs image"
cp -r /tmp/iso/* "${part1_mount}"
cp /tmp/airootfs.sfs "${part1_mount}/sysresccd/x86_64/"
cp /tmp/airootfs.sha512 "${part1_mount}/sysresccd/x86_64/"

info "Unmounting iso"
umount /mnt/iso
umount "$part1_mount"
# umount /mnt/squashfs

info "Removing temp files"
rm -rf /mnt/iso
rm -rf /mnt/squashfs
rm -rf /tmp/airootfs*
rm -rf /tmp/iso
rm -rf "$part1_mount"

info "Rescue USB is created"

