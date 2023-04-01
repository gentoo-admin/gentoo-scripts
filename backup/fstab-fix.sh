#!/bin/bash
# script to update UUIDs in /etc/fstab
# expected that disk has 4 partitions:
# boot_partition="/dev/sdb1"
# swap_partition="/dev/sdb2"
# root_partition="/dev/sdb3"
# home_partition="/dev/sdb4"
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

function replace_uuid() {

    if [ -z "$1" ] ; then
        error "Partition name is required"
        return 1
    fi
    if [ -z "$2" ] ; then
        error "Mount point is required"
        return 1
    fi

    local part_name="$1"
    local mount_point="$2"
    local uuid_fstab
    local uuid_system

    info "Checking partition $part_name"
    uuid_fstab=$(grep "^UUID=.*[[:space:]]\+${mount_point}[[:space:]]\+.*" "$fstab_path" | awk '{print $1}' | cut -d= -f2)
    uuid_system=$(lsblk -o UUID -ln "$part_name")
    if [ -z "$uuid_fstab" ] ; then
        warn "UUID for partition $part_name is not set in /etc/fstab"
        return 1
    fi 
    if [ "$uuid_fstab" != "$uuid_system" ] ; then
        warn "UUID for partition $part_name does not match, replacing"
        sed -i "s/${uuid_fstab}/${uuid_system}/" "$fstab_path"
    fi

}
 
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
read -p "Select a disk: " index
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
if [ "$(lsblk -o NAME,TYPE -ln "$disk" | grep "^${disk/\/dev\//}\(p\)\?[0-9]\+[[:space:]]\+part$" -c)" -ne 4 ] ; then
    fatal_error "Disk must have 4 partitions"
fi
while read -r part ; do
    if findmnt "$part" -n -o TARGET > /dev/null 2>&1 ; then
        mnt_point=$(findmnt "$part" -n -o TARGET)
        info "Unmounting partition $part"
        umount "$mnt_point" || fatal_error "Unable to unmount partiiton $part"
    fi
done < <(lsblk -o NAME,TYPE "$disk" -ln | grep part | awk '{print "/dev/" $1}')

boot_part="${disk}"$([[ "$disk" == /dev/nvme* ]] && printf 'p')1
swap_part="${disk}"$([[ "$disk" == /dev/nvme* ]] && printf 'p')2
root_part="${disk}"$([[ "$disk" == /dev/nvme* ]] && printf 'p')3
home_part="${disk}"$([[ "$disk" == /dev/nvme* ]] && printf 'p')4

root_part_mount=$(findmnt "$root_part" -n -o TARGET)
if [ -z "$root_part_mount" ] ; then
    root_part_mount=${root_part/dev/mnt}
    if [ ! -d "$root_part_mount" ] ; then
        mkdir "$root_part_mount"
    fi
    info "Mounting $root_part on $root_part_mount"
    if ! mount "$root_part" "$root_part_mount" ; then
        fatal_error "Unable to mount $root_part"
    fi     
fi

fstab_path="${root_part_mount}/etc/fstab"
if [ ! -f "$fstab_path" ] ; then
    fatal_error "Partition $root_part does not have /etc/fstab"
fi

replace_uuid "$boot_part" "/boot"
replace_uuid "$swap_part" "swap"
replace_uuid "$root_part" "/"
replace_uuid "$home_part" "/home"
# replace_uuid "/dev/sda1" "/wdhdd"

info "Unmounting $root_part"
umount "$root_part_mount" && rm -rf "$root_part_mount"

