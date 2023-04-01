#!/bin/bash
# script to backup/restore/format disk devices
# supported filesystems: fat32, ext4
#
# v1.0.0 :  initial impl
# v1.1.0 :  implemented partitions
# v1.2.0 :  added restore to local dir
# v1.3.0 :  added integrity check
# v1.3.1 :  added signal processing
# v1.4.0 :  migrate (rename) backup files to install on another disk
# v1.4.1 :  process BACKUP_LOCATION as backup folder
# v1.4.2 :  add print backups option
# v1.4.3 :  added --last option
# v1.4.4 :  added simplified syntax: --disk=sda --partiiton=1,3,5
# v1.4.5 :  combine --format and --restore
# v1.5.0 :  implemented disk discard
# v1.5.1 :  check installed applications
# v1.5.2 :  auto-mount backup location if passed as [partition]:[path]
# v1.5.3 :  added support for nvme disks

VER=1.5.3

# dir where backups are saved/stored
BACKUP_LOCATION=
# disk device
DISK=
# name of backup
NAME=
# encrypt backup with gpg
ENCRYPT=
# restore backup locally instead of backup device
LOCAL=
# validate sha256 for backup files
INTEGRITY_CHECK=Y
# number of backups to display before restore
PRINT_BACKUPS=
# remove unused blocks on backup disk
DISCARD=

# array to store partitions in format 'partition fstype'
# sda1 ext4
# sda2 fat32
declare -a partitions

# partitions from argument -p=sda1 -p=sda2
partitions_arg=


function print() {
    printf '%s [%s] %s  - %s \n' "$(date '+%F %T.%3N')" "$(basename "$0")" "$1" "$2"
}

function print_info() {
    print "INFO " "$1"
}

function print_error() {
    print "ERROR" "$1"
}

function fatal_error() {
    print_error "$1"
    exit 1
}

function is_encrypt() {
    [[ "$ENCRYPT" == "Y" ]]
}

function is_backup() {
    [[ "$BACKUP" == 'Y' ]]
}

function is_restore() {
    [[ "$RESTORE" == 'Y' ]]
}

function is_migrate() {
    [[ "$MIGRATE" == 'Y' ]]
}

function is_local() {
    [[ "$LOCAL" == "Y" ]]
}

function is_format() {
    [[ "$FORMAT" == 'Y' ]]
}

function is_discard() {
    [[ "$DISCARD" == 'Y' ]]
}

function is_validate_integrity() {
    [[ "$INTEGRITY_CHECK" == "Y" ]]
}

function print_help() {

    echo "$(basename "$0") v$VER : Script to backup/restore/format disk devices"
    echo "Script args:"
    echo " -b, --backup                           backup disk or partition(s)"
    echo " -e, --encrypt                          encrypt backup with gpg symmetric key"
    echo "     --discard                          clear unused blocks on disk"
    echo " -r, --restore                          restore backup to disk or partition(s)"
    echo "     --local                            restore backup to local directory"
    echo "     --no-integrity-check               do not validate backup sha256 (default: true)"
    echo "     --print-backups          [count]   number of backups to display before restore"
    echo "     --last                             select last backup (equal to --print-backups=1)"
    echo " -f, --format                           format disk from sgdisk backup"
    echo " -m, --migrate                          migrate (rename) backup to be used on disk with different label"
    echo " -l, --backup-loc             [path]    backup dir, script dir if ommitted"
    echo " -d, --disk                   [label]   disk to backup, restore or format (all partitions if -p omitted)"
    echo " -p, --partition              [label]   partition to backup/restore"
    echo " -n, --name                   [name]    backup name"
    echo ""
    echo "To backup and encrypt all partitions on /dev/sda:"
    echo "  sudo ./$(basename "$0") --backup --encrypt --backup-loc=/wdhdd/Backup --disk=sda"
    echo "To restore all partitions on /dev/sda:"
    echo "  sudo ./$(basename "$0") --restore --backup-loc=/wdhdd/Backup --disk=sda"
    echo "To restore partitions sda1 and sda3:"
    echo "  sudo ./$(basename "$0") --restore --backup-loc=/wdhdd/Backup --partition=sda1 --partition=sda3"
    echo "  sudo ./$(basename "$0") --restore --backup-loc=/wdhdd/Backup --disk=sda --partition=1,3"
    echo "To restore partition sda1 to local (/mnt/restore-sda1):"
    echo "  sudo ./$(basename "$0") --restore --local --backup-loc=/wdhdd/Backup --partition=sda1"
    echo "To format /dev/sda from sgdisk backup:"
    echo "  sudo ./$(basename "$0") --format --backup-loc=/wdhdd/Backup --disk=sda"
    echo "To migrate (rename) /dev/sda backup to use on disk /dev/sdb:"
    echo "  sudo ./$(basename "$0") --migrate --backup-loc=/wdhdd/Backup --disk=sdb"
    echo ""
    exit 0
}

function validate_apps() {

    if ! is_installed parted ; then exit 1; fi
    if ! is_installed fsck ; then exit 1; fi
    if is_encrypt && ! is_installed gpg ; then exit 1; fi
    

}

function is_installed() {

    if [ -z "$1" ] ; then fatal_error "Application name must be provided" ; fi

    if [ "$(find /usr/{bin,share} -type f -name "$1" | wc -l)" -eq 0 ] ; then
        print_error "$1 not installed"
        return 1
    fi

    return 0

}

function discard_disk() {

    if ! is_discard ; then return 1; fi

    if [ -z "$DISK" ] ; then return 1; fi

    if ! is_installed fstrim ; then return 1; fi

    local gran
    local max
    while read -r line; do
        gran=$(awk '{print $3}' <<< "$line" | sed 's/[^0-9]//g')
        max=$(awk '{print $4}' <<< "$line" | sed 's/[^0-9]//g')
        if [ "$gran" -eq 0 ] || [ "$max" -eq 0 ] ; then
            print_error "Discard not supported on disk /dev/$DISK"
            return 1
        fi
    done < <(lsblk --discard /dev/"$DISK" -ln)

    while read -r part fs; do
        print_info "Discarding partition /dev/$part"
        validate_partition "$part"
        if [ -d /mnt/"$part" ] ; then
            fatal_error "Folder /mnt/$part already exists"
        fi
        mkdir /mnt/"$part"
        mount /dev/"$part" /mnt/"$part" || fatal_error "Unable to mount /mnt/$part"
        fstrim -v /mnt/"$part"/
        umount /mnt/"$part" || fatal_error "Unable to unmount /mnt/$part"
        rm -rf /mnt/"${part:?}"
        validate_partition "$part"
    done < <(printf "%s\n" "${partitions[@]}")
    
}

function cleanup() {

    echo ''
    print_error "Caught signal on line $LINENO"
    
    if [ -f "$password_file" ] && [ -f "${password_file}.gpg" ] ; then
        rm -f "$password_file"
    fi
    exit 1
}

function confirm() {

    while true; do
        read -p "$1 [yn] " yn
        case $yn in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please select yes or no";;
        esac
    done

    return 1

}

function check_fs() {

    print_info "Checking filesystem on /dev/$1"
    fsck -p -t "$2" -V "/dev/$1"
    exit_code="$?"

    #   0      No errors
    #   1      Filesystem errors corrected
    #   2      System should be rebooted
    #   4      Filesystem errors left uncorrected
    #   8      Operational error
    #   16     Usage or syntax error
    #   32     Checking canceled by user request
    #   128    Shared-library error

    if [ "$exit_code" -eq 0 ] ; then
        print_info "Status: No errors"
    elif [ "$exit_code" -eq 1 ] ; then
        print_info "Status: Filesystem errors corrected"
    elif [ "$exit_code" -eq 2 ] ; then
        fatal_error "Status: System should be rebooted"
    elif [ "$exit_code" -eq 4 ] ; then
        fatal_error "Status: Filesystem errors left uncorrected"
    elif [ "$exit_code" -eq 8 ] ; then
        fatal_error "Status: Operational error"
    else
        fatal_error "Status: Error $exit_code"
    fi

}

function validate_partition() {

    if ! [[ "$1" =~ ^(nvme[0-9]n[0-9]p|sd[a-z])[0-9]+$ ]] ; then
        fatal_error "Invalid partition format: $1"
    fi
    if ! lsblk "/dev/$1" -o NAME,TYPE -ln 2>/dev/null | grep -q "^$1[[:space:]]\+part$" ; then
        fatal_error "Invalid partition: /dev/$1"
    fi
    if findmnt -n "/dev/$1" 1>&2 >/dev/null ; then
        fatal_error "Partition /dev/$1 is mounted"
    fi

}

function is_valid_fs() {
    [[ "$1" == "ext4" ]] || [[ "$1" == "fat32" ]]
}

function is_valid_format_fs() {
    is_valid_fs "$1" || [[ "$1" == "swap" ]]
}

function validate_disk() {

    if [ -z "$DISK" ] ; then
        fatal_error "Disk device must be set"
    fi
    if ! lsblk -o NAME,TYPE "/dev/$DISK" -ln 2>/dev/null | grep -q "^${DISK}[[:space:]]\+disk$" ; then
        fatal_error "Invalid disk: /dev/$DISK"
    fi
    if ! is_format ; then
        if ! lsblk -o NAME,TYPE "/dev/$DISK" -ln | grep -q "^${DISK}\(p\)\?[0-9]\+[[:space:]]\+part$" ; then
            fatal_error "Disk /dev/$DISK does not have partitions"
        fi
    fi

}

function validate_backup_location() {

    if [ -z "$BACKUP_LOCATION" ] ; then
        BACKUP_LOCATION=$(pwd)
        return 0
    fi

    if [[ "$BACKUP_LOCATION" =~ ^(nvme[0-9]n[0-9]p|sd[a-z])[0-9]+ ]] ; then
        local part
        local path
        # mount backup loc as sda1:Backup -> /mnt/sda1/Backup
        if [[ "$BACKUP_LOCATION" == *:* ]] ; then
            part="$(printf %s "$BACKUP_LOCATION" | cut -d: -f1)"
            path="$(printf %s "$BACKUP_LOCATION" | cut -d: -f2)"
        else
            part="$BACKUP_LOCATION"
        fi
        if ! lsblk "/dev/$part" -o NAME,TYPE -ln 2>/dev/null | grep -q "^${part}[[:space:]]\+part$" ; then
            fatal_error "Invalid partition: /dev/$part"
        fi
        backup_loc_mnt=$(findmnt -n "/dev/$part" | awk '{print $1}')
        if [ -z "$backup_loc_mnt" ] ; then
            backup_loc_mnt="/mnt/$part"
            if [ ! -d "$backup_loc_mnt" ] ; then
                mkdir "$backup_loc_mnt"
            fi
            print_info "Mounting backup location to $backup_loc_mnt"
            mount "/dev/$part" "$backup_loc_mnt" || fatal_error "Unable to mount partition $part to $backup_loc_mnt"
        fi
        # if path is missing look for '*Backup*' folder in mounted dir
        if [ -z "$path" ] ; then
            if [ "$(find "$backup_loc_mnt" -maxdepth 1 -mindepth 1 -type d -iname '*backup*' | wc -l)" -ne 1 ] ; then
                fatal_error "Backup location has multiple '*backup*' folders, specify it as '${part}:dir'"
            fi
            BACKUP_LOCATION="$(find "$backup_loc_mnt" -maxdepth 1 -mindepth 1 -type d -iname '*backup*')"
        else
            BACKUP_LOCATION="${backup_loc_mnt}/${path}"
        fi
    fi
    BACKUP_LOCATION=$(printf %s "$BACKUP_LOCATION" | sed 's|/$||;s|/\+|/|g')
    if [ ! -d "$BACKUP_LOCATION" ] ; then
        fatal_error "Backup location is invalid"
    fi

}

function validate_integrity() {

    if ! is_validate_integrity ; then
        return 1
    fi

    if [ -z "$backup_to_restore" ] ; then
        return 1
    fi

    local sha_file
    sha_file="${backup_to_restore}/backup.sha256"
    if [ ! -f "${sha_file}" ] ; then
        fatal_error "backup.sha256 file not found"
    fi

    local file
    local sha_new
    local part_filter

    # sda1 ext4
    # sda2 fat32
    # ->
    # sda1-ext4.ptcl|sda2-fat32.ptcl
    part_filter=$(printf '%s.ptcl|' "${partitions[@]}" | sed 's| |-|g;s|.$||')
    while read -r sha filename ; do
        file="${backup_to_restore}/$filename"
        if ! [ -f "$file" ] ; then
            fatal_error "File $(basename "$file") does not exist"
        fi
        if [[ "$filename" == *.ptcl.* ]] && ! [[ "$(basename "$filename")" =~ ${part_filter} ]] ; then
            continue
        fi
        print_info "Validating $(basename "$filename")"
        sha_new=$(pv < "$file" | sha256sum  | awk '{print $1}')
        if ! [ "$sha" == "$sha_new" ] ; then
            fatal_error "File $(basename "$file") does not match original hashsum"
        fi
    done  < <(if is_restore ; then grep -E '.ptcl.|.gpg$' "$sha_file"; \
            elif is_format ; then grep -E '.parted$|.sgdisk$' "$sha_file"; \
            else cat "$sha_file"; fi )

}


function validate_partitions() {

    if [ "${#partitions[@]}" -gt 0 ] ; then partitions=(); fi

    local part
    local fs
    local part_disk

    # partitions specified in arg
    if [ -n "$partitions_arg" ] ; then

        while read -r p; do
            if [ -z "$p" ] ; then continue; fi
            if [[ "$p" =~ ^[0-9]+$ ]] ; then
                if [ "${#partitions[@]}" -eq 0 ] ; then validate_disk; fi
                part="${DISK}$([[ "$DISK" == nvme* ]] && printf 'p')${p}"
            else
                part="$p"
            fi
            if [[ "$(printf '%s|' "${partitions[@]}")" == *"${part} "* ]] ; then continue; fi
            validate_partition "$part"
            fs=$(parted "/dev/${part}" print | grep '^ 1' | awk '{print $5}')
            if ! is_valid_fs "$fs" ; then
                fatal_error "Filesystem on /dev/$part not supported"
            fi
            # if disk not set assing it from first partition
            if [[ "$part" == nvme* ]] ; then
                part_disk="$(printf %s "$part" | sed 's/p[0-9]\+$//')"
            else
                part_disk="$(printf %s "$part" | sed 's/[0-9]\+$//')"
            fi
            if [ -z "$DISK" ] ; then
                DISK="$part_disk"
            elif ! [ "$part_disk" == "$DISK" ] ; then
                fatal_error "Multiple disks not supported"
            fi
            partitions+=("$part $fs")
        done < <(echo "$partitions_arg" | sed 's/[[:space:]]\+/,/g' | tr ',' '\n')

    else

        validate_disk

        while read -r line; do
            if [[ "$DISK" == nvme* ]] ; then
                part="${DISK}$(awk '{print "p"$1}' <<< "$line")"
            else
                part="${DISK}$(awk '{print $1}' <<< "$line")"
            fi
            validate_partition "$part"
            # match: ext4, fat32 
            fs="$(printf %s "$line" | grep -Eo '[a-z]{3}[0-9]{1,2}' | uniq | head -1)"
            if is_valid_fs "$fs" ; then
                partitions+=( "$part $fs" )
            fi
        done < <(parted "/dev/$DISK" print | grep '^ [0-9]')

    fi

    if [ "${#partitions[@]}" -eq 0 ] ; then
        fatal_error "Disk /dev/$DISK does not have partitions to backup/restore"
    fi

}

function select_backup_to_restore() {

    if [ -n "$backup_to_restore" ] ; then return; fi

    local files
    files=$(find "$BACKUP_LOCATION" -type f -name '*.ptcl.*' | if [ -n "$NAME" ] ; then grep -ic "$NAME"; else wc -l; fi )
    if [ "$files" -eq 0 ] ; then
        fatal_error "No backups found"
    fi

    local dirs
    dirs=$(find "$BACKUP_LOCATION" -maxdepth 1 -mindepth  1 -type d -name "*${NAME}*" | wc -l)
    # BACKUP_LOCATION is backup folder
    if [ "$dirs" -eq 0 ] ; then
        NAME=$(basename "$BACKUP_LOCATION")
        BACKUP_LOCATION=$(dirname "$BACKUP_LOCATION")
    fi

    local backups=()
    while read -r d; do
        # backup name pattern:
        # sda1-fat32.ptcl.gz.aaa.gpg
        # sda2-ext4.ptcl.gz.aab.gpg
        # nvme0n1p1-ext4.ptcl.gz.aab.gpg
        if ! find "$d" -maxdepth 1 -mindepth 1 -type f | grep -E -q "(nvme[0-9]n[0-9]p|sd[a-z])[0-9]+-(fat32|ext4).ptcl.gz.[a-z]{3}(.gpg)?$" ; then 
            continue
        fi
        backups+=("$d")
        printf "%-4s %s\n" "[${#backups[@]}]" "$d"
        find "$d" -type f -name '*ptcl*' | sed 's|^.*\/||;s/-/./' | awk -F. '{printf "%*-s%*-s%*-s%s\n", 5, "", 20, "/dev/"$1, 10, "["$2"]", $6}' | sort -u 
        if [ "${#backups[@]}" -eq "$PRINT_BACKUPS" ] ; then
            break
        fi
    done < <(find "$BACKUP_LOCATION" -maxdepth 1 -mindepth 1 -type d -name "*${NAME}*" | awk -F- '{print $(NF-1)$(NF)" "$0}' | sort -k1,1rn  | awk '{print $2}')

    if [ "${#backups[@]}" -eq 0 ] ; then
        fatal_error "No backups found"
    fi

    local selected
    if [ "${#backups[@]}" -gt 1 ] ; then
        while true; do
            printf '%s' "Select backup: "; read -r selected
            if ! [[ "$selected" =~ ^[0-9]+$ ]] ; then
                print_error "Invalid backup number"
                continue
            fi
            if [ "$selected" -gt "${#backups[@]}" ] || [ "$selected" -lt 1 ] ; then
                print_error "Invalid backup selected"
                continue
            fi
            break
        done
        selected=$((selected-1))
    else
        selected=0
    fi

    backup_to_restore="${backups[$selected]}"

}

trap cleanup SIGHUP SIGINT SIGTERM

for i in "$@"; do
    case $i in
    -b|--backup)
        BACKUP='Y'
        shift # past argument=value
        ;;
    -r|--restore)
        RESTORE='Y'
        shift # past argument=value
        ;;
    -f|--format)
        FORMAT='Y'
        shift # past argument=value
        ;;
    -m|--migrate)
        MIGRATE='Y'
        shift # past argument=value
        ;;
    -l=*|--backup-loc=*)
        BACKUP_LOCATION="${i#*=}"
        shift # past argument=value
        ;;
    -d=*|--disk=*)
        DISK="${i#*=}"
        shift # past argument=value
        ;;
    -p=*|--partition=*)
        partitions_arg+="$(basename "${i#*=}") "
        shift # past argument=value
        ;;
    -n=*|--name=*)
        NAME="${i#*=}"
        shift # past argument=value
        ;;
    -e|--encrypt)
        ENCRYPT='Y'
        shift # past argument with no value
        ;;
    --local)
        LOCAL='Y'
        shift # past argument with no value
        ;;
    --print-backups=*)
        if [ -n "$PRINT_BACKUPS" ] ; then fatal_error "Option --print-backups set multiple times"; fi
        PRINT_BACKUPS="${i#*=}"
        shift # past argument=value
        ;;    
    --last)
        if [ -n "$PRINT_BACKUPS" ] ; then fatal_error "Option --print-backups set multiple times"; fi
        PRINT_BACKUPS=1
        shift # past argument with no value
        ;;
    --no-integrity-check)
        INTEGRITY_CHECK='N'
        shift # past argument with no value
        ;;
    --discard)
        DISCARD='Y'
        shift # past argument with no value
        ;;
    -h|--help)
        print_help
        ;;
    *)
        print_error "Unknown option: ${i%%:*}"
        print_help
        ;;
    esac
done


# start script as root
if [[ $EUID -ne 0 ]]; then
    fatal_error "Script must be run as root"
fi

validate_apps

# validate mode
mode=''
if is_backup  ; then mode+="B"; fi
if is_format  ; then mode+="F"; fi
if is_restore ; then mode+="R"; fi
if is_migrate ; then mode+="M"; fi
if ! [[ "$mode" =~ ^[BRFM]{1}$ ]] && ! [[ "$mode" =~ ^FR$ ]] ; then
    fatal_error "Invalid action mode"
fi

if ! is_backup ; then
    if is_encrypt ; then
        print_error "Option --encrypt applicable for backup mode only"
    fi
    if is_discard ; then
        print_error "Option --discard applicable for backup mode only"
    fi
fi

if is_format && [ -n "$partitions_arg" ] ; then
    print_error "Partitions arg will be ignored in format mode"
    partitions_arg=""
fi

if ! is_restore && is_local ; then
    if is_format ; then fatal_error "Option --local cannot be used in format mode"; fi
    print_error "Option --local will be ignored"
fi

if [ -n "$PRINT_BACKUPS" ] && ! [[ "$PRINT_BACKUPS" =~ ^[0-9]+$ ]] ; then
    fatal_error "Option --print-backups must be numeric"
fi
# set default option
if [ -z "$PRINT_BACKUPS" ] ; then
    PRINT_BACKUPS=10
fi

validate_backup_location

if is_backup ; then

    validate_partitions

    # if NAME is not provided use name of prev backup
    # backup-name-20120901-121450 -> backup-name
    if [ -z "$NAME" ] ; then
        backup_count=$(find "$BACKUP_LOCATION" -maxdepth 1 -mindepth 1 -type d | wc -l)
        if [ "$backup_count" -eq 0 ] ; then
            fatal_error "Backup name must be set"
        fi
        NAME=$(find "$BACKUP_LOCATION" -mindepth 1 -maxdepth 1 -type d | awk -F- '{print $(NF-1) $(NF) " " $0}' \
            | sort -k1,1rn | awk '{print $2}' | head -n 1 | sed 's|.*\/||;s|-[0-9]\{4,\}.*$||')
    fi

    lsblk -o NAME,MAJ:MIN,RM,SIZE,RO,TYPE,LABEL,MOUNTPOINT | grep -v -E 'loop|sr'
    backup_dir="${BACKUP_LOCATION}/${NAME}-$(date "+%Y%m%d-%H%M%S")"
    if [ -d "$backup_dir" ] ; then
        fatal_error "Backup dir already exists"
    fi
    
    echo "================================================================================"
    printf '%-25s%s \n' "Backup location:" "$backup_dir"
    printf '%-25s%s \n' "Backup device:" "/dev/$DISK"
    while read -r part fs; do 
        printf '%-25s%s [%s]\n' '' "/dev/$part" "$fs"
    done < <(printf "%s\n" "${partitions[@]}")
    if is_encrypt ; then
        printf "%-25s%s\n" "Encryption:" "GPG symmetric AES256"
    fi
    echo "================================================================================"

    if ! confirm "Start backup?" ; then exit 1; fi

    if is_encrypt ; then

        while true; do
            printf %s "Enter password: "; read -s password; printf '\n'
            if [ -z "$password" ] ; then
                print_error "Password cannot be empty"
                continue
            fi
            printf %s "Repeat password: "; read -s password2; printf '\n'
            if [ -z "$password2" ] ; then
                print_error "Password cannot be empty"
                continue
            fi
            if [ "$password" != "$password2" ] ; then
                print_error "Passwords do not match"
                continue
            fi
            break
        done
        unset password2

    fi

    discard_disk

    mkdir -p "$backup_dir"

    split_size=3G
    log_file="${backup_dir}/partclone-backup-$(date "+%Y%m%d-%H%M%S").log"
    while read -r part fs; do 

        check_fs "$part" "$fs"

        # run partclone
        print_info "Creating backup for /dev/$part"
        arch_name="${backup_dir}/${part}-${fs}.ptcl"
        partclone."$fs" -c -d -s "/dev/$part" -L "$log_file" | gzip -c | split -a3 -b${split_size} - "${arch_name}.gz."

    done < <(printf "%s\n" "${partitions[@]}")

    if is_encrypt ; then

        password_file="${backup_dir}/backup.key"
        password_file_gpg="${password_file}.gpg"
        tr -dc 'A-Za-z0-9!@#$%^&*()-=_+:<>?,./;[]\{}|' < /dev/urandom | head -c 512 > "$password_file"
        while read -r f; do
            print_info "Encrypting $(basename "$f")"
            if ! pv < "$f" | gpg -c --cipher-algo AES256 --passphrase-file "$password_file" --batch -o "${f}.gpg" ; then
                fatal_error "Unable to encrypt $f"
            fi
        done < <(find "$backup_dir" -type f -name '*.ptcl.*')
        find "$backup_dir" -type f -name '*.ptcl.*' -and -not -name '*.gpg' -exec rm '{}' \;

        if ! echo "$password" | gpg -c --passphrase-fd 0 --batch --cipher-algo AES256 "$password_file" ; then
            fatal_error "Unable to encrypt backup.key"
        fi
        unset "$password"
        if [ -f "$password_file_gpg" ] ; then
            rm "$password_file"
        fi
    fi

    print_info "Saving partition table"

    parted "/dev/$DISK" print >> "${backup_dir}/${DISK}-partition-table.parted"
    sgdisk --backup="${backup_dir}/${DISK}-partition-table.sgdisk" "/dev/${DISK}"

    # create sha256
    print_info "Generating sha256 hash"
    while read -r f; do
        sha256sum "$f" | sed 's|/.*/||g' >> "${backup_dir}/backup.sha256"
    done < <(find "$backup_dir" -type f -not -name '*.log' -and -not -name '*.sha256')

    total_size=$(du -sh "${backup_dir}" | awk '{print $1}')
    print_info "Backup is complete, total size: $total_size"

    if [ -n "$backup_loc_mnt" ] ; then
        print_info "Unmounting backup disk"
        umount "$backup_loc_mnt" || fatal_error "Unable to unmount $backup_loc_mnt"
        rm -rf "$backup_loc_mnt"
    fi

    exit 0

fi


if is_format ; then

    validate_disk

    select_backup_to_restore

    # check if .sgdisk file exists in backup dir
    sgdisk_backup="${backup_to_restore}/${DISK}-partition-table.sgdisk"
    if [ ! -f "${sgdisk_backup}" ] ; then
        fatal_error "Unable to find sgdisk backup file for /dev/$DISK"
    fi

    validate_integrity

    if ! confirm "Script will recreate partitions on /dev/$DISK, continue?" ; then exit 1; fi

    sgdisk --load-backup="$sgdisk_backup" "/dev/$DISK" || exit 1

    # read $disk-partition-table.parted and set filesystem for each partition
    parted_backup="${backup_to_restore}/${DISK}-partition-table.parted"
    if [ ! -f "${parted_backup}" ] ; then
        fatal_error "Unable to find parted backup, filesystem types must be set manually"
    fi

    while read -r line; do
        if [[ "${DISK}" == nvme* ]] ; then
            part="${DISK}$(awk '{print "p"$1}' <<< "$line")"
        else
            part="${DISK}$(awk '{print $1}' <<< "$line")"
        fi
        validate_partition "$part"
        fs="$(printf %s "$line" | grep -Eo '[a-z]{3}[0-9]{1,2}|swap' | uniq | head -1)"
        if is_valid_format_fs "$fs" ; then
            partitions+=( "$part $fs" )
        fi
    done < <(grep '^ [0-9]' "$parted_backup")

    if [ "${#partitions[@]}" -eq 0 ] ; then
        fatal_error "Parted backup does not have partitions to restore"
    fi

    while read -r part fs ; do
        printf '  %s\t-> %s\n' "/dev/$part" "$fs"
    done < <(printf "%s\n" "${partitions[@]}")

    if ! confirm "Script will set the following filesystem types, continue?" ; then exit 1; fi

    # put here manual steps if required
    while read -r part fs ; do
        print_info "Setting filesystem on /dev/$part"
        if [ "$fs" == "ext4" ] ; then
            mkfs.ext4 -q "/dev/$part" || exit 1
        fi
        if [ "$fs" == "fat32" ] ; then
            mkfs.fat -F32 "/dev/$part" || exit 1
        fi
        if [ "$fs" == "swap" ] ; then
            mkswap "/dev/$part" || exit 1
            swapon "/dev/$part" || exit 1
        fi
    done < <(printf "%s\n" "${partitions[@]}")

    print_info "Partitions on /dev/${DISK} restored"

fi

if is_restore ; then

    validate_partitions

    select_backup_to_restore

    # validate that backup has required partitions
    while read -r part fs; do
        if [ "$(find "$backup_to_restore" -type f -name "*${part}-${fs}.ptcl.*" | wc -l)" -eq 0 ] ; then
            fatal_error "Selected backup does not have partition /dev/$part"
        fi
    done < <(printf "%s\n" "${partitions[@]}")

    validate_integrity

    print_info "Script will restore the following partitions:"
    while read -r part fs; do
        while read -r f; do
            if is_local ; then
                printf '  %s\t-> %s\n' "$(basename "$f")" "${backup_to_restore}-local/${part}"
            else
                printf '  %s\t-> %s\n' "$(basename "$f")" "/dev/${part}"
            fi
        done < <(find "$backup_to_restore" -type f -name "${part}-${fs}*" | sort)
    done < <(printf "%s\n" "${partitions[@]}")

    if ! confirm "Restore backup?" ; then exit 1; fi

    gpg_files_count=$(find "$backup_to_restore" -type f -name '*.gpg' | wc -l)

    if [ "${gpg_files_count}" -gt 0 ] ; then

        password_file="${backup_to_restore}/backup.key"
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

        declare -a gpg_files
        while read -r part fs; do 
            while read -r f; do
                if [[ "$f" == *"${part}-${fs}.ptcl"* ]] ; then
                    gpg_files+=("$f")
                fi
            done < <(find "$backup_to_restore" -type f -name '*.gpg')
        done < <(printf "%s\n" "${partitions[@]}")

        for f in "${gpg_files[@]}" ; do
            print_info "Decrypting $(basename "$f")"
            if ! pv < "$f" | gpg --passphrase-file "$password_file" --no-tty --batch -d -o "${f/.gpg/}" ; then
                fatal_error "Unable to decrypt $f"
            fi
        done
        rm "$password_file"

    fi

    while read -r part fs; do

        if ! is_local ; then

            print_info "Restoring partition /dev/$part"
            log_file="${backup_to_restore}/partclone-restore-$(date "+%Y%m%d-%H%M%S").log"
            # *.aaa must be first in list
            find "$backup_to_restore" -type f -name "${part}-${fs}*" -and -not -name '*.gpg' -printf "%p\n" \
            | sort | xargs cat | gunzip -c | partclone."$fs" -r -o "/dev/$part" -L "$log_file"

        else

            restore_dir="${backup_to_restore}-local"
            restore_mnt="${restore_dir}/${part}"
            restore_file="${restore_mnt}.img"
            if [ -d "$restore_dir" ] ; then
                rm -rf "$restore_dir"
            fi
            mkdir -p "$restore_mnt"

            print_info "Restoring partition /dev/$part to $restore_mnt"
            # *.aaa must be first in list
            find "$backup_to_restore" -type f -name "${part}-${fs}*" -and -not -name '*.gpg' -printf "%p\n" \
            | sort | xargs cat | gunzip -c | partclone.restore --restore_raw_file -C -s - -o "$restore_file"
            if ! [ -f "$restore_file" ] ; then
                fatal_error "Image file was not created"
            fi
            size=$(du -c "$restore_file" | tail -1 | awk '{print $1}')
            if [ "$size" -eq 0 ] ; then
                fatal_error "Image file is empty"
            fi

            # replace fat32 with vfat to avoid error:
            # mount: /mnt/restore-sdc1: unknown filesystem type 'fat32'.
            if [ "$fs" == fat32 ] ; then
                fs="vfat"
            fi

            mount -o loop "$restore_file" "$restore_mnt" -t "$fs" -o ro

            rm "$restore_file"

        fi

    done < <(printf "%s\n" "${partitions[@]}")

    # remove decrypted backup files 
    if [ "${gpg_files_count}" -gt 0 ] ; then
        find "$backup_to_restore" -type f -name '*.ptcl.*' -and -not -name '*.gpg' -exec rm '{}' \;
    fi

    print_info "Restore is complete"

    if [ -n "$backup_loc_mnt" ] && ! is_local ; then
        print_info "Unmounting backup disk"
        umount "$backup_loc_mnt" || fatal_error "Unable to unmount $backup_loc_mnt"
        rm -rf "$backup_loc_mnt"
    fi

    exit 0

fi

if is_migrate ; then

    validate_disk

    select_backup_to_restore

    backup_disk=$(find "$backup_to_restore" -name '*.ptcl.*' | head -1 | sed 's|^.*\/||' | awk '{print substr($0,0,3)}')
    if [ "$backup_disk" == "$DISK" ] ; then
        fatal_error "Invalid disk is selected"
    fi

    if [ ! -f "${backup_to_restore}/backup.sha256" ] ; then
        fatal_error "Unable to find backup.sha56 for this backup"
    fi
    sha_file="${backup_to_restore}/backup.sha256"

    while read -r f; do 
        printf '  %s\t-> %s\n' "$f" "$(printf %s "$f" | sed "s/^${backup_disk}/${DISK}/")"
    done < <(find "$backup_to_restore" -name '*.ptcl.*' | sed 's|^.*\/||' | sort)

    if ! confirm "Script will rename backup files for the new disk /dev/$DISK, continue?" ; then exit 1; fi

    while read -r f ; do
        mv "${backup_to_restore}/$f" "${backup_to_restore}/$(printf %s "$f" | sed "s/^${backup_disk}/${DISK}/")"
    done < <(find "$backup_to_restore" -name '*.ptcl.*' | sed 's|^.*\/||' | sort)

    while read -r sha f; do
        old=$(basename "$f")
        if ! [[ "$old" == "${backup_disk}"* ]] ; then
            continue
        fi
        new=$(basename "$f" | sed "s/^${backup_disk}/${DISK}/")
        sed -i "s|\/${old}$|\/${new}|" "$sha_file"
    done < <(cat "$sha_file")

    validate_integrity

    print_info "Backup files are successfully renamed"

fi

