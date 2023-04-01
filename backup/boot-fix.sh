#!/bin/bash
# ###################################################################################
# script to reinstall /boot partition from sysrescue cd   
# assuming target disk has the following setup:
# /dev/nvme0n1p1    /boot
# /dev/nvme0n1p2    swap
# /dev/nvme0n1p3    /
# /dev/nvme0n1p4    /home
# ###################################################################################

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

lsblk
cat << EOF

Target disk: $disk
> boot partition : $boot_part
> swap partition : $swap_part
> root partition : $root_part
> home partition : $home_part

Script will perform the following changes:
-- format boot partition
-- reinstall kernel
-- reinstall initramfs
-- reinstall grub

EOF

if ! confirm "Execute the script?" ; then
    exit 1
fi

# info "Formatting boot partition"
# mkfs.fat -F32 "$boot_part" || fatal_error "Unable to format /boot"

info "Mounting filesystems"
if [ ! -d /mnt/gentoo ] ; then
    mkdir /mnt/gentoo
fi
mount "$root_part" /mnt/gentoo || fatal_error "Unable to mount root partition"
{
    mount --types proc /proc /mnt/gentoo/proc
    mount --rbind /sys /mnt/gentoo/sys
    mount --rbind /dev /mnt/gentoo/dev
    mount --bind /run /mnt/gentoo/run
    mount --make-rslave /mnt/gentoo/sys
    mount --make-rslave /mnt/gentoo/dev
    mount --make-slave /mnt/gentoo/run
} || fatal_error "Unable to mount filesystems"

if [ ! -f /usr/sbin/reinstall-kernel ] ; then
    fatal_error "Unable to find script /usr/sbin/reinstall-kernel"
fi
cp /usr/sbin/reinstall-kernel /mnt/gentoo 
chmod +x /mnt/gentoo/reinstall-kernel
chroot /mnt/gentoo /bin/bash reinstall-kernel

info "Close all ssh connections before unmounting filesystems"
if confirm "Unmount filesystems?" ; then
    rm -f /mnt/gentoo/reinstall-kernel
    umount -l /mnt/gentoo/dev{/shm,/pts,}
    umount -R /mnt/gentoo
fi

