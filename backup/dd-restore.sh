#!/bin/bash
# script to restore a disk drive using dd utility
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
read -p "Select a disk to restore: " index
if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
    fatal_error "Numeric value expected"
fi
if [ "$index" -lt 1 ] || [ "$index" -gt "${disk_count}" ] ; then
    fatal_error "Invalid disk index: $index"
fi
restore_disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$index" | tail -n1 | awk '{print "/dev/" $1}')
if [ -z "$restore_disk" ] ; then 
    fatal_error "Restore disk is invalid"
fi
while read -r part ; do
    if findmnt "$restore_disk" -n -o TARGET > /dev/null 2>&1 ; then
        fatal_error "Partition $part is mounted"
    fi
done < <(lsblk -o NAME,TYPE "$restore_disk" -ln | grep part | awk '{print "/dev/" $1}')

read -p "Select a disk where backup in located: " index
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
    fatal_error "Dir $backup_dir does not exist"
fi

c=0
while read -r dir; do 
    c=$((c+1))
    printf " [%d] %s\n" "$c" "$dir"
done < <(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '*dd-backup*' | sort -r)

if [ "$c" -eq 0 ] ; then
    fatal_error "No stored backups found at $backup_dir"
elif [ "$c" -eq 1 ] ; then
    index=$c
else
    read -p "Select a backup to restore: " index
    if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
        fatal_error "Numeric value expected"
    fi
    if [ "$index" -lt 1 ] || [ "$index" -gt "$c" ] ; then
        fatal_error "Invalid backup number: $index"
    fi
fi
backup_path=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -type d -name '*dd-backup*' | sort -r | head -n"$index" | tail -n1)
files_count=$(find "$backup_path" -type f -name '*.dd.bz2.*' | wc -l)
if [ "$files_count" -eq 0 ] ; then
    fatal_error "Selected dir does not have backup files"
fi

info "Script will restore the following backup:"
printf "%-20s%s\n" "Restore disk:" "$restore_disk"
printf "%-20s%s\n" "Backup:" "$backup_path"
if ! confirm "Restore backup on $restore_disk?" ; then
    exit 1
fi

gpg_files_count="$(find "$backup_path" -name '*.gpg' | wc -l)"

if [ "$gpg_files_count" -gt 0 ] ; then

    password_file="${backup_path}/backup.key"
    password_file_gpg="${password_file}.gpg"
    if [ ! -f "$password_file_gpg" ] ; then
        fatal_error "backup.key is missing"
    fi

    attempts=3
    for (( i=1; i<=attempts; i++ )); do
        if [ -z "$password" ] ; then
            printf %s "Enter password: "; read -s password; printf '\n'
            if [ -z "$password" ] ; then
                print_error "Password cannot be empty"
                continue
            fi
        fi
        echo "$password" | gpg --no-tty -q --passphrase-fd 0 --batch -o "$password_file" -d "$password_file_gpg"
        exit_code="$?"
        if [ "$exit_code" -eq 0 ] ; then
            break
        # wrong password
        elif [ "$exit_code" -eq 2 ] ; then
            password=''
        else
            fatal_error "Unable to decrypt backup.key"
        fi
        if [ "$i" -eq $attempts ] ; then
            fatal_error "Reached max number of retries"
        fi
    done
    if [ ! -f "$password_file" ] ; then
        fatal_error "backup.key was not decrypted"
    fi
    unset "$password"

    while read -r file; do
        info "Decrypting $(basename "$file")"
        if ! pv < "$file" | gpg --passphrase-file "$password_file" --no-tty --batch -d -o "${file/.gpg/}" ; then
            fatal_error "Unable to decrypt $file"
        fi

    done < <(find "$backup_path" -type f -name '*.dd.bz2.*.gpg')

    rm "$password_file"

fi

# /mnt/sda1/Backup/dd-backup-20170109-1456/nvme0n1.dd.bz2.aa.gpg
# *.aa must be first in list
find "$backup_path" -type f -name "*.dd.bz2.*" -and -not -name '*.gpg' -printf "%p\n" \
| sort | xargs cat | bzip2 --decompress | dd of="$restore_disk" status=progress  

if [ "${gpg_files_count}" -gt 0 ] ; then
    find "$backup_path" -type f -name '*.dd.*' -and -not -name '*.gpg' -exec rm '{}' \;
fi

info "Restore is complete"

