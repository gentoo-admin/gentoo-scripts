#!/bin/bash
#
# Script to clean a gentoo system after system update.
# 

BACKUP_DIR=/wdhdd/Backup
BACKUP_DIR_KERNEL_CONFIG=/home/$SUDO_USER/Documents/linux/gentoo/config
LOCAL_REPO=/var/db/repos/localrepo
KEEP_EBUILDS=5
KEEP_KERNELS=3

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

function remove_older_than_days() {

    # arg1: dir where directories will be removed
    # arg2: number of days     

    local dir=$1
    if [ -z "$dir" ]  || [ ! -d "$dir" ] ; then
        error "$dir is not a valid directory"
        return
    fi
    
    local days=$2 
    if [ -z "$days" ] ; then
        error "Unknown days value provided"
        return
    fi

    local count
    count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d -mtime +"$days" | wc -l)
    if [ "$count" -le 5 ] ; then
        return
    fi

    find "$dir" -maxdepth 1 -mindepth 1 -type d -mtime +"$days" -exec rm -rf {} + 
    
}

function remove_files_older_than_count() {

    # arg1: dir where files will be Removed
    # arg2: number of files to keep
    # arg3: file name mask (optional)

    local dir=$1
    if [ -z "$dir" ]  || [ ! -d "$dir" ] ; then
        error "$dir is not a valid directory"
        return
    fi

    local count=$2 
    if [ -z "$count" ] ; then
        error "Unknown count value provided"
        return
    fi

    local file_mask
    if [ -n "$3" ] ; then
        file_mask="*${3}*"
    else
        file_mask="*.*"
    fi

    local files
    files=$(find "$dir" -not -path '*/\.*' -type f -name "$file_mask" | wc -l)
    if [ "$files" -eq 0 ] ; then
        return
    fi
    if [ "$count" -ge "$files" ] ; then
        return
    fi

    while read -r f; do
        rm -r "$f"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -not -path '*/\.*' -type f -name "$file_mask" \
    | sort -V | head -n $((files-count))) 

}

function remove_with_confirm() {

    local dir=$1
    if [ ! -d "$dir" ] ; then
        error "$dir is not a valid directory"
    fi

    if [ -d "$dir" ] ; then
        files=$(find "$dir" -type f -not -name '.*' | wc -l)
        if [[ "$files" -gt 0 ]] ; then
            ls -lh "$dir"
            if confirm "Remove content of $dir?" ; then
                find "$dir" -maxdepth 1 -mindepth 1 -not -name '.*' -exec rm -r "{}" \;
            fi
        fi
    fi
    
}

function set_mode() {

    if [[ -z "$1" ]] || [[ -z "$2" ]] ; then
        error "Invalid mode arguments provided"
        return
    fi
    if [[ ! -f "$1" ]] ; then
        error "$1 is not valid file"
        return
    fi
    if [[ ! "$2" =~ ^[0-9]{3,4}$ ]] ; then
        error "Invalid mode"
        return
    fi

    local file="$1"
    local mode="$2"
    if [[ "$mode" =~ ^[0-9]{4}$ ]] ; then
        mode="0${mode}"
    fi
    if ! [ "$(stat -c "%u%a" "$file")" == "$mode" ]; then
        chmod "$mode" "$file"
    fi
}

# arg #1 = package name
function built_today() {
    
    if [ -z "$1" ] ; then
        error "Invalid package name"
        return 1
    fi
    local files_count
    files_count="$(find /var/db/pkg/ -maxdepth 2 -mindepth 2 -type d -name "${1}*" | wc -l)"
    if [ "$files_count" -eq 0 ] ; then
        warn "Unable to find package with name $1"
        return 1
    fi
    local dir
    dir="$(find /var/db/pkg/ -maxdepth 2 -mindepth 2 -type d -name "${1}*" | sort -Vr | head -1)"
    if [ ! -f "$dir/BUILD_TIME" ] ; then
        warn "Package dir $dir does not have BUILD_TIME file"
        return 1
    fi

    local file
    local today
    local build_time
    local build_date

    file="$dir/BUILD_TIME"
    build_time=$(cat "$file")
    build_date=$(date -d @"$build_time" +"%Y-%m-%d")
    today=$(date +"%Y-%m-%d")
    [[ "$build_date" == "$today" ]] 

}

set -e

if [ ! -f "/etc/os-release" ] || [ ! "$(grep ^ID= /etc/os-release | cut -d= -f2)" == "gentoo" ]; then
    fatal_error "Unsupported operating system."
fi

if [[ $EUID -ne 0 ]]; then
   fatal_error "This script must be run as root" 
fi

if [ ! -d "/home/$SUDO_USER/" ] ; then
   fatal_error "Invalid user: $SUDO_USER" 
fi

info "Starting post install script"
dist_dir=$(emerge --info | grep '^DISTDIR=' | sed 's/\(^.*\"\)\(.*\)\"/\2/')

dm_config=/etc/conf.d/display-manager
if [ -f "$dm_config" ] ; then
    dm=$(grep DISPLAYMANAGER $dm_config | awk -F'"' '{print $2}')
    if [ "$dm" != "sddm" ] ; then
        info "Setting display manager to sddm"
        sed -i "/^DISPLAYMANAGER=/ s/$dm/sddm/" $dm_config
    fi
fi

if built_today "imagemagick" ; then
    info "Replacing ImageMagick PDF policy"
    sed -i '/domain=\"coder\".*pattern=\"PDF\"/ s/"[^"]\+"/\"read \| write\"/2' /etc/ImageMagick-7/policy.xml
fi

if built_today "intel-microcode" ; then
    curr_date=$(date +"%Y-%m-%d")
    file="/boot/early_ucode.cpio"
    update_date=$(stat -c %y "$file" | awk '{print $1}')
    if [ "$update_date" != "$curr_date" ] ; then
        info "Updating intel microcode"
        mv "$file" /tmp/
        iucode_tool -S --write-earlyfw="$file" /lib/firmware/intel-ucode/*
    fi
fi

if built_today gentoo-kernel && confirm "New kernel was merged, install it?" ; then

    # assuming last kernel was successfully built 
    last=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*gentoo-dist' | sort -Vr | head -n1)

    # check is symlink set
    curr_link=$(readlink -f /usr/src/linux)
    if [ -z "$curr_link" ] || [ "$last" != "$curr_link" ] ; then
        ln -sf "$last" /usr/src/linux
    fi

    last_ver=$(cut -d'-' -f2,5 <<< "$last")  
    if ! grep -q "sys-kernel/gentoo-kernel:$last_ver" /var/lib/portage/world ; then
        info "Recording new kernel in @world"
        emerge -v --noreplace sys-kernel/gentoo-kernel:"$last_ver"
    fi

    info "Rebuilding modules"
    emerge @module-rebuild

    info "Generating initramfs"
    genkernel --install initramfs || fatal_error "Unable to reinstall initramfs"

    rm -rf /boot/*old*

    # remove old kernels
    # eclean-kernel --ask -n$KEEP_KERNELS --destructive
    total=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*gentoo-dist' | wc -l)
    old_kernels=$((total-KEEP_KERNELS))
    if [ "$old_kernels" -gt 0 ] ; then
        count=1
        while read -r kernel; do
            if [ "$count" -gt "$KEEP_KERNELS" ] ; then
                printf ' %-4s' "[-]"
            else
                printf ' %-4s' "[+]"
            fi
            printf '%s' "$(basename "$kernel")"
            if [ "$kernel" == "$last" ] ; then
                printf ' *'
            fi
            printf '\n'
            count=$((count+1))
        done < <(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*gentoo-dist' | sort -Vr)

        if confirm "Found $old_kernels old kernels, remove it?" ; then
            while read -r kernel; do
                emerge -v --deselect "$kernel"
                kernel_name="$(basename "$kernel")"
                # update probably needed if kernel has patch ver
                ver=$(cut -d'-' -f2,5 <<< "$kernel_name")
                fails=0
                trap 'fails=$((fails+1))' ERR
                rm -r /usr/src/linux-"$ver"*
                rm -r /lib/modules/"$ver"*
                rm /boot/vmlinuz-"$ver"*
                rm /boot/System.map-"$ver"*
                rm /boot/config-"$ver"*
                rm /boot/initramfs-"$ver"*
                if [ "$fails" -eq 0 ] ; then
                    info "Kernel $kernel_name is removed"
                else
                    error "Unable to remove kernel $kernel_name"
                fi
            done < <(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*gentoo-dist' | sort -V | head -n${old_kernels})
        fi
    fi

    info "Generating grub config"
    grub-mkconfig -o /boot/grub/grub.cfg 2>&1 || fatal_error "Unable to configure grub"

fi

# copy kernel and make config
info "Backing up config files"
if [ -d "$BACKUP_DIR_KERNEL_CONFIG" ] ; then
    cp /usr/src/linux/.config "${BACKUP_DIR_KERNEL_CONFIG}/kernel-config-$(uname -r)"
    cp /etc/portage/make.conf "${BACKUP_DIR_KERNEL_CONFIG}/make.conf"
else    
    error "Directory $BACKUP_DIR_KERNEL_CONFIG does not exist, unable to copy kernel and portage config files"
fi

info "Cleaning files"
rm -rf /wdhdd/.Trash*
rm -rf /home/"${SUDO_USER}"/.local/share/Trash/*

remove_with_confirm "/home/${SUDO_USER}/Downloads/" 
# remove_with_confirm /home/${SUDO_USER}/Music/Convert
# remove_with_confirm /home/${SUDO_USER}/Music/Converted

info "Cleaning cache"
rm -rf /home/"${SUDO_USER}"/.cache/* 
rm -rf /home/"${SUDO_USER}"/.thumbnails/*

find /usr/lib/python* -type f -name '*.pyc' -exec rm '{}' \;
find /usr/lib/python* -maxdepth 0 -type d -name '*pycache*' -exec rm -rf '{}' \;
rm -rf /usr/lib/python*/test
find /usr/lib/portage -type f -name '*.pyc' -exec rm '{}' \;
find /usr/lib/portage -maxdepth 0 -type d -name '*pycache*' -exec rm -rf '{}' \;

info "Cleaning distfiles"
if [ -d "$dist_dir" ] ; then 
    find "$dist_dir" -type f -not -path '*/\.*' -delete
fi

days=60
if [ -d "$BACKUP_DIR" ] ; then
    info "Removing old backups"
    remove_older_than_days "$BACKUP_DIR" $days
fi

# remove_files_older_than_count "$BACKUP_DIR_KERNEL_CONFIG" 10

# message below is received if sandbox is not enabled for opera:
# The SUID sandbox helper binary was found, but is not configured correctly. Rather than 
# run without sandboxing I'm aborting now. You need to make sure that /opt/opera/opera_sandbox
# is owned by root and has mode 4755.
set_mode /opt/opera/opera_sandbox 4755 

# [28480:0611/174126.159866:FATAL:setuid_sandbox_host.cc(158)] 
# The SUID sandbox helper binary was found, but is not configured correctly. 
# Rather than run without sandboxing I'm aborting now. You need to make sure 
# that /opt/vscode/chrome-sandbox is owned by root and has mode 4755.
set_mode /opt/vscode/chrome-sandbox 4755 

if [ -d "$LOCAL_REPO" ] ; then
    info "Removing old ebuilds"
    while read -r dir; do
        remove_files_older_than_count "$dir" "$KEEP_EBUILDS" ".ebuild"
    done < <(find "$LOCAL_REPO" -type f -name '*.ebuild' | sed 's:[^/]*$::' | uniq) 

    # remove old ebuilds from Manifest files 
    ebuilds_to_delete=()
    while read -r manifest; do
        dir=$(dirname "$manifest")
        while read -r ebuild; do 
            if ! [ -f "${dir}/${ebuild}" ] ; then
                ebuilds_to_delete+=("$ebuild")
            fi
        done < <(grep "^EBUILD" "$manifest" | awk '{print $2}')
        for f in "${ebuilds_to_delete[@]}" ; do
            sed -i "/${f}/d" "$manifest"
        done
        ebuilds_to_delete=()
    done < <(find "$LOCAL_REPO" -name Manifest)
fi

