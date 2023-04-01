#!/bin/bash
# script to backup a disk drive using dd utility
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
        printf "%s [yn] " "$1"
        read -r key
        if [[ "$key" =~ ^(Y|y) ]] || [[ "$key" == $'\0a' ]] ; then
            return 0
        elif [[ "$key" =~ ^(N|n) ]] ; then
            return 1
        fi
        echo "Please select Y/y/N/n/<-"
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
read -p "Select a disk to backup: " index
if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
    fatal_error "Numeric value expected"
fi
if [ "$index" -lt 1 ] || [ "$index" -gt "${disk_count}" ] ; then
    fatal_error "Invalid disk index: $index"
fi
backup_disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$index" | tail -n1 | awk '{print "/dev/" $1}')
if [ -z "$backup_disk" ] ; then 
    fatal_error "Backup disk is invalid"
fi
while read -r part ; do
    if findmnt "$part" -n -o TARGET > /dev/null 2>&1 ; then
        info "Unmounting partiiton $part"
        mnt=$(findmnt "$part" -n -o TARGET)
        umount "$mnt" || fatal_error "Unable to unmount partition $part"
    fi
done < <(lsblk -o NAME,TYPE "$backup_disk" -ln | grep part | awk '{print "/dev/" $1}')

read -p "Select a disk to store backup: " index
if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
    fatal_error "Numeric value expected"
fi
if [ "$index" -lt 1 ] || [ "$index" -gt "${disk_count}" ] ; then
    fatal_error "Invalid disk index: $index"
fi
store_disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$index" | tail -n1 | awk '{print "/dev/" $1}')
if [ -z "$store_disk" ] ; then 
    fatal_error "Backup disk is invalid"
fi
# assuming that selected disk has 1 partition and dir /Backup
part1="${store_disk}"$([[ "$store_disk" == /dev/nvme* ]] && printf 'p')1
part1_mount=$(findmnt "$part1" -n -o TARGET)
if [ -z "$part1_mount" ] ; then
    part1_mount="${part1/dev/mnt}"
    info "Mounting partiiton $part1 at $part1_mount"
    if [ ! -d "$part1_mount" ] ; then
        mkdir "$part1_mount"
    fi
    mount "$part1" "$part1_mount" || fatal_error "Unable to mount $part1"
fi

backup_dir="${part1_mount}/Backup"
if [ ! -d "$backup_dir" ] ; then
    fatal_error "Could not find dir ${backup_dir}"
fi

backup_dir+="/dd-backup-"$(date +%Y%m%d-%H%M)
mkdir "$backup_dir"

info "Script will make the following backup:"
printf "%-20s%s\n" "Backup disk:" "$backup_disk"
printf "%-20s%s\n" "Backup loc:" "$backup_dir"
printf "%-20s%s\n" "Type:" "dd"
printf "%-20s%s\n" "Compression:" "bzip2"
if ! confirm "Start backup?" ; then
    exit 1
fi

# /mnt/sda1/Backup/dd-backup-20170109-1456/nvme0n1.dd.bz2.aa.gpg
dd if="$backup_disk" conv=sparse status=progress | bzip2 --compress | split -b3G - "${backup_dir}/${backup_disk/\/dev\//}".dd.bz2.

if confirm "Encrypt backup?" ; then

    while true; do
        pass1=''
        pass2=''
        printf "%s" "Enter password:  "; read -s pass1; printf '\n'
        printf "%s" "Repeat password: "; read -s pass2; printf '\n'
        if [ "$pass1" == "$pass2" ] ; then
            break
        fi
        error "Passwords do not match"
    done
    unset pass2

    password_file="${backup_dir}/backup.key"
    tr -dc 'A-Za-z0-9!@#$%^&*()-=_+:<>?,./;[]\{}|' < /dev/urandom | head -c 512 > "$password_file"
    while read -r f; do
        info "Encrypting $(basename "$f")"
        if ! pv < "$f" | gpg -c --cipher-algo AES256 --passphrase-file "$password_file" --batch -o "${f}.gpg" ; then
            fatal_error "Unable to encrypt $f"
        fi
    done < <(find "$backup_dir" -type f -name '*.dd.bz2.*')
    find "$backup_dir" -type f -name '*.dd.bz2.*' -and -not -name '*.gpg' -exec rm '{}' \;

    if ! echo "$pass1" | gpg -c --passphrase-fd 0 --batch --cipher-algo AES256 "$password_file" ; then
        fatal_error "Unable to encrypt backup.key"
    fi
    unset "$pass1"
    rm "$password_file"

fi

if confirm "Unmount ${part1}?" ; then
    umount "${part1_mount}" || error "Unable to unmount ${part1_mount}"
fi

info "Backup is complete"

