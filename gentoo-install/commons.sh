#!/bin/bash

# config file
gen2_config="$(dirname "$0")/CONFIG"

# full path of downloaded stage tarball
gen2_stage_iso=''
# selected disk device
gen2_disk=''
# selected partition on disk
gen2_part=''

# url path to download gentoo iso
stage_url="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-stage3-amd64-openrc/"
min_cd_url="https://bouncer.gentoo.org/fetch/root/all/releases/amd64/autobuilds/current-install-amd64-minimal/"

function info() {

    if [ "$#" -eq 0 ] ; then
        return 1
    fi

    local args
    args=("$@")

    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" INFO "$(printf '%b\n' "${args[@]}")"

}

function warn() {

    if [ "$#" -eq 0 ] ; then
        return 1
    fi

    local args
    args=("$@")
    
    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" WARN "$(printf '%b\n' "${args[@]}")"

}

function error() {

    if [ "$#" -eq 0 ] ; then
        return 1
    fi

    local args
    args=("$@")
    
    printf "%s [%s] %s  - %s\n" "$(date '+%F %T.%3N')" "$(basename "$0")" ERROR "$(printf '%b\n' "${args[@]}")"

}

function fatal_error() {

    error "$@" 
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

function confirm_and_exit() {

    if ! confirm "$1" ; then
        exit 1
    fi  
}

# check portage exit codes:
# -- 130 returned when user clicked No
function check_portage_exit_code() {
    case $? in
        0)
        return 0
        ;;
        130)
        return 0
        ;;
        *)
        return 1
        ;;
    esac
}

function show_count() {
    printf "Press Ctrl+C to abort..."
    max=5
    for (( i=max; i>0; i-- )) ; do 
        printf " %d" $i
        sleep 1
    done
    printf '\n\n'
}

# function to download stage iso from https://www.gentoo.org/downloads/
# param 1: file mask such as  
# stage3-amd64-openrc
# stage3-amd64-systemd
# install-amd64-minimal
# admincd-amd64 
# livegui-amd64 
# param 2: download dir (if empty current dir will be used)
function download_stage() {

    if [ -z "$1" ] ; then
        fatal_error "Provide file mask"
    fi

    local download_dir
    if [ -z "$2" ] ; then
        download_dir="$(pwd)"
    else
        if ! [ -d "$2" ] ; then
            fatal_error "Download dir does not exist: $2"
        fi
        download_dir="$2"
    fi

    local mask
    mask="$1"

    local url
    url=''
    while read -r line; do
        if [[ "$line" == *"$mask"* ]] ; then
            for l in $line ; do
                if [[ "$l" =~ https:[^[:space:]]+${mask}[^[:space:]]+\.(iso|xz) ]] ; then
                    url="${BASH_REMATCH[0]}"
                    break
                fi
            done
        fi
    done < <(wget https://www.gentoo.org/downloads/ -q -O -)

    if [ -z "$url" ] ; then
        fatal_error "Unable to retrieve url for $mask"
    fi

    info "Downloading $url"

    local stage_filename
    stage_filename="$(basename "$url")"
    gen2_stage_iso="${download_dir}/${stage_filename}"
    wget "$url" -O "$gen2_stage_iso"

    if ! [ -f "$gen2_stage_iso" ] ; then
        fatal_error "Unable to download $url"
    fi

    if ! confirm "Validate checksum?" ; then
        return 0
    fi

    local digest_url
    if [[ "$mask" == *stage3* ]] ; then
        digest_url="${stage_url}${stage_filename}.DIGESTS"
    else 
        digest_url="${min_cd_url}${stage_filename}.DIGESTS"
    fi

    local stage_digest
    stage_digest="${gen2_stage_iso}.DIGESTS"

    wget "$digest_url" -O "$stage_digest"
    if ! [ -f "$stage_digest" ] ; then
        error "Unable to download $stage_digest"
        return 1
    fi

    grep "${stage_filename}$" "$stage_digest" | sed "s|${stage_filename}|${gen2_stage_iso}|" | sha512sum --check 

}

# portage creates conf files only when --ask option is used
function update_conf_files() {

    info "Updating conf files"

    if [ "$(find /etc -type f -name '._cfg000*' | wc -l)" -eq 0 ] ; then
        info "No conf updates required"
        return 1
    fi

    while [ "$(find /etc -type f -name '._cfg000*' | wc -l)" -gt 0 ] ; do
        dispatch-conf
        # etc-update
    done

    info "Conf files are updated"
    return 0

}

# add value for specified key in format KEY="VALUE"
function add_value() {

    local file=$1
    local key=$2
    local value=$3

    if [ -z "$file" ] || [ -z "$key" ] || [ -z "$value" ] ; then 
        fatal_error "Invalid arguments to add value"
    fi
    if [ ! -f "$file" ] ; then
        fatal_error "File does not exist: $file"
    fi

    value=$(printf %s "$value" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')

    # key=value not found
    if ! grep -q "^${key}=" "$file" ; then
        echo "${key}=\"$value\"" >> "$file"
        return 0 
    fi

    return 1
}

# replace value for specified key in format KEY="VALUE"
function replace_value() {

    local file=$1
    local key=$2
    local value=$3

    if add_value "$file" "$key" "$value" ; then
        return 1
    fi

    value=$(printf %s "$value" | sed 's/^[[:space:]]\+//;s/[[:space:]]\+$//')

    sed -i "s|\(^${key}=\)\(.*\)|\1\"${value}\"|" "$file"
}

# merge value for specified key in format KEY="... VALUE"
function merge_value() {

    local file=$1
    local key=$2
    local value=$3

    if add_value "$file" "$key" "$value" ; then
        return 1
    fi

    if [[ "$value" =~ [[:space:]] ]] ; then
        fatal_error "Single param is expected"
    fi

    local cur_value
    cur_value=$(grep "^${key}=" "$file" | cut -d'"' -f2)
    if [ -z "$cur_value" ] ; then
        return 1
    fi
    for c in $cur_value; do
        if [ "$c" == "$value" ] ; then
            return 1
        fi
        if [[ "$c" == *"$value"* ]] || [[ "$value" == *"$c"* ]] ; then
            echo "# #########################################################################"
            echo "Found possible duplicate for key '${key}' in ${file}:"
            echo "Current value:   $cur_value"
            echo "Match:           $c"
            echo "New value:       $value"
            echo "# #########################################################################"
            if ! confirm "Add param '$value' to key '$key'?" ; then
                return 1
            fi
        fi
    done

    cur_value+=" $value"
    sed -i "s|\(^${key}=\)\(.*\)|\1\"${cur_value}\"|" "$file"

}

# merge values for specified key in format KEY="... VALUE1 VALUE2 VALUE3"
function merge_values() {

    local file=$1
    local key=$2
    local values=$3

    for v in $values; do
        merge_value "$file" "$key" "$v"
    done

}

# select a disk where gentoo will be installed
function select_disk() {

    gen2_disk=''

    IFS=$'\n'
    local c
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

    sleep 0.5
    local index
    local disk_index
    for ((i=0; i<3; i++)) ; do

        index=''
        disk_index=''

        read -p "Select disk: " index
        if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
            index=''
            error "Numeric value expected"
            continue
        fi
        disk_index=${index:0:1}
        if [ "$disk_index" -lt 1 ] || [ "$disk_index" -gt "${c}" ] ; then
            error "Invalid disk index: $disk_index"
            disk_index=''
            continue
        fi
        gen2_disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$disk_index" | tail -n1 | awk '{print "/dev/" $1}')
        return 0
    done

    if [ -z "$gen2_disk" ] ; then 
        error "Invalid disk selected"
    fi
    return 1

}

# select a single partition 
function select_partition() {

    gen2_disk=''
    gen2_part=''

    IFS=$'\n'
    local c
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

    sleep 0.5
    local index
    local disk_index
    local part_index
    for ((i=0; i<3; i++)) ; do
        
        index=''
        disk_index=''
        part_index=''

        # > 12: disk #1 partition #2 
        echo "Select disk/partition (no space):"
        read -p "> " index
        if ! [[ "$index" =~ ^[0-9]+$ ]] ; then
            index=''
            error "Numeric value expected"
            continue
        fi
        # assuming pc has only 9 disks 
        if [ "${#index}" -eq 1 ] ; then
            index=''
            error "Partition index not selected"
            continue
        fi
        disk_index=${index:0:1}
        if [ "$disk_index" -lt 1 ] || [ "$disk_index" -gt "${c}" ] ; then
            error "Invalid disk index: $disk_index"
            disk_index=''
            continue
        fi
        gen2_disk=$(lsblk -o NAME,TYPE -ln | grep disk | head -n"$disk_index" | tail -n1 | awk '{print "/dev/" $1}')
        part_index=${index:1}
        if [ "$part_index" -lt 1 ] || [ "$part_index" -gt "$(lsblk "$gen2_disk" | grep -c part)" ] ; then
            error "Invalid partition index: $part_index"
            part_index=''
            continue
        fi
        gen2_part=/dev/$(lsblk -o NAME,TYPE -ln "$gen2_disk" | grep part | head -n"$part_index" | tail -n1 | awk '{print "/dev/" $1}')
        return 0

    done

    if [ -z "$gen2_disk" ] ; then 
        error "Invalid disk selected"
    fi
    if [ -z "$gen2_part" ] ; then
        error "Invalid partition selected"
    fi
    return 1

}

function configure_kernel() {

    local kernel_params
    local last_kernel
    local kernel_config

    # .kernelparams file should match name from first 2 params of the script
    # openrc-kde-chroot.sh -> openrc-kde.kernelparams
    kernel_params="$(dirname "${0}")/$(basename "${0}" | cut -d- -f1,2).kernelparams"
    if ! [ -f "$kernel_params" ] ; then
        error "File *.kernelparams not found"
        return 1
    fi
    last_kernel="$(find /usr/src -maxdepth 1 -mindepth 1 -type d -name '*gentoo*' | sort -rV | head -n1)"
    if [ -z "$last_kernel" ] ; then
        error "No kernels merged"
        return 1
    fi
    kernel_config="${last_kernel}/.config"
    if ! [ -f "$kernel_config" ] ; then
        error "Kernel ${last_kernel} does not have .config file"
        return 1
    fi

    info "Validating kernel params against $kernel_config"
    local kernel_updated
    local not_set
    local not_found

    kernel_updated=1
    not_set=()
    not_found=()
    while read -r line; do
        if ! [[ "$line" == CONFIG_* ]] ; then
            continue
        fi
        param=$(grep -w "${line}" "$kernel_config")
        if [ -z "$param" ] ; then
            not_found+=("$line")
            continue
        fi
        if [[ "$param" == *"${line}"*"is not set"* ]] ; then
            not_set+=("$line")
            continue
        fi
    done < <(cat "$kernel_params")

    echo "Params not set:"
    if [ "${#not_set[@]}" -gt 0 ] ; then
        for n in "${not_set[@]}" ; do
            echo " $n"
        done
        echo ''
    else
        echo 'No difference found'
    fi
    echo "Params not found:"
    if [ "${#not_found[@]}" -gt 0 ] ; then
        for n in "${not_found[@]}" ; do
            echo " $n"
        done
        echo ''
    else
        echo 'No difference found'
    fi
    echo ''
    echo "# #########################################################################"
    echo ''

    if [ "${#not_set[*]}" -gt 0 ] || [ "${#not_found[*]}" -gt 0 ] ; then
        if confirm "Configure kernel?" ; then
            cd "$last_kernel" ||
            while true; do 
                make menuconfig
                if confirm "Kernel configuration is complete?" ; then
                    kernel_updated=0
                    break
                fi
            done
        fi
    fi

    return $kernel_updated

}

function installed() {

    if [ -z "$1" ] ; then
        error "Unknown application name"
        return 1
    fi

    # equery list "$1"
    [[ "$( find /usr /opt -type f -name "*${1}*" 2>/dev/null | wc -l)" -gt 0 ]]

}

function validate_config() {

    if ! [ -f "$gen2_config" ] ; then
        fatal_error "./CONFIG is required to run this script"
    fi

    # shellcheck source=./CONFIG
    source "$gen2_config"

    if [ -z "$gen2_boot_partition_size" ] || ! [[ "$gen2_boot_partition_size" =~ ^[0-9]+(M|G|T)(iB)?$ ]] ; then
        fatal_error "Invalid format for boot partition size"
    fi
    if [ -z "$gen2_root_partition_size" ] || ! [[ "$gen2_root_partition_size" =~ ^[0-9]+(M|G|T)(iB)?$ ]] ; then
        fatal_error "Invalid format for root partition size"
    fi
    if [ -z "$gen2_swap_partition_size" ] || ! [[ "$gen2_swap_partition_size" =~ ^[0-9]+(M|G|T)(iB)?$ ]] ; then
        fatal_error "Invalid format for swap partition size"
    fi

    if [ -z "$gen2_processor_model" ] ; then
        fatal_error "Processor model must be set"
    fi

    if [ -z "$gen2_video_card" ] ; then
        fatal_error "Video card must be set"
    fi

    if [ -z "$gen2_wifi_card" ] ; then
        fatal_error "Wifi card must be set"
    fi

}

