#!/bin/bash
# script to load all required data onto usb drive to install gentoo from
# !!! DEPRECATED !!!
# should use ./minimal-cd.sh instead

gen2_commons="$(dirname "$0")/commons.sh"
if ! [ -f "$gen2_commons" ] ; then
    echo "./commons.sh is required to run this script"
    exit 1
fi
# shellcheck source=./commons.sh
source "$gen2_commons"

gen2_config="$(dirname "$0")/CONFIG"
if [ ! -f "$gen2_config" ] ; then
    fatal_error "./CONFIG is required to run this script"
fi
# shellcheck source=./CONFIG
source "$gen2_config"

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

find . -name '*.bz2' -exec rm -rf '{}' \;

info "Creating local repo backup"
tar -czf ./localrepo.tar.bz2 /var/db/repos/localrepo/

select_partition
if [ -z "$gen2_part" ] ; then
    exit 1
fi

mount_part=$(findmnt "$gen2_part" -o TARGET -ln)
if [ -z "$mount_part" ] ; then
    mount_part=${gen2_part/dev/mnt}
    if ! [ -d "$mount_part" ] ; then
        mkdir "$mount_part"
    fi
    info "Mounting $gen2_part on $mount_part"
    mount "$gen2_part" "$mount_part"
fi
info "$gen2_part is mounted at $mount_part, copying files"
install_dir="${mount_part}/gentoo-install"
# copy all files from current dir to usb drive
if [ -d "$install_dir" ] ; then
    rm -rf "$install_dir"
fi
mkdir -p "$install_dir"
cp "$(dirname "$0")"/* "$install_dir"

inof "Unmounting $gen2_part"
umount "$mount_part" && rm -rf "$mount_part"
find . -name '*.bz2' -exec rm -rf '{}' \;

info "All files are copied to $gen2_disk"

