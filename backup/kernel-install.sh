#!/bin/bash
# script to install/compile a new kernel

function log() {
    printf "%s [%s]  - %s\n" "$(date '+%m-%d-%Y %H:%M:%S.%3N')" "$(basename "$0")" "$1"
}

function fatal_error() {
    log "$1"
    exit 1
}

# compare build versions, return:
# 0: arg1 > arg2
# 1: arg1 = arg2
# 2: arg1 < arg2
function compare_ver() {

    if [ -z "$1" ] || ! [[ "$1" =~ ^[0-9]+.[0-9]+.[0-9]+(-r[0-9]+)?$ ]] ; then
        fatal_error "Invalid kernel ver"
    fi
    if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+.[0-9]+.[0-9]+(-r[0-9]+)?$ ]] ; then
        fatal_error "Invalid kernel ver"
    fi

    local new
    local old
    local f1
    local f2

    new=$(printf %s "$1" | sed 's/-r/./')
    old=$(printf %s "$2" | sed 's/-r/./')
    for (( i=1; i<=4; i++ )); do
        f1=$(printf %s "$new" | cut -d. -f"$i")
        if [ -z "$f1" ] ; then f1=0; fi
        f2=$(printf %s "$old" | cut -d. -f"$i")
        if [ -z "$f2" ] ; then f2=0; fi
        if [ "$f1" -eq "$f2" ] ; then continue; 
        elif [ "$f1" -gt "$f2" ] ; then return 0; 
        elif [ "$f1" -lt "$f2" ] ; then return 2; fi
    done

    return 1

}

function is_greater() {
    compare_ver "$1" "$2"
    [[ $? -eq 0 ]]
}

function is_equal() {
    compare_ver "$1" "$2"
    [[ $? -eq 1 ]]
}

function is_less() {
    compare_ver "$1" "$2"
    [[ $? -eq 2 ]]
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

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

new_ver="$1"
if [ -n "$new_ver" ] ; then
    if ! [[ "$new_ver" =~ ^[0-9]+.[0-9]+.[0-9]+(-r[0-9]+)?$ ]] ; then
        fatal_error "Invalid kernel format"
    fi
    if ! equery -N -C list -p "gentoo-sources-${new_ver}" >/dev/null 2>&1 ; then
        fatal_error "Kernel ${new_ver} does not exist in portage tree"
    fi    
fi

last_path=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*' | sort -Vr | head -1)
prev_path=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*' | sort -Vr | head -2 | tail -1)
current_path=$(readlink -f /usr/src/linux)

last_ver=$(printf %s "$last_path" | sed 's|^.*/||' | cut -d- -f2,4)
curr_ver=$(printf %s "$current_path" | sed 's|^.*/||' | cut -d- -f2,4)

if [ -z "$new_ver" ] ; then
    if is_equal "$last_ver" "$curr_ver" ; then
        mode='CURRENT'
    elif is_greater "$last_ver" "$curr_ver" ; then
        mode='MERGED'
    fi
else
    if is_greater "$new_ver" "$curr_ver" && is_greater "$new_ver" "$last_ver" ; then
        mode='MASKED'
    fi
    if is_less "$new_ver" "$curr_ver" ; then
        fatal_error "Downgrading kernel not supported"
    fi
fi
if [ -z "$mode" ] ; then
    fatal_error "Invalid kernel setup"
fi

if [ "$mode" == 'CURRENT' ] ; then
    log "Found current kernel: $last_ver" 
elif [ "$mode" == 'MERGED' ] ; then
    log "Found merged kernel: $last_ver"
elif [ "$mode" == 'MASKED' ] ; then
    log "Found masked kernel: $new_ver"
fi

if [ "$mode" == 'MASKED' ] ; then
    # =sys-kernel/gentoo-sources-4.12.12 ~amd64
    if ! grep -q '=sys-kernel/gentoo-sources' /etc/portage/package.accept_keywords ; then
        bash -c "echo '' >> /etc/portage/package.accept_keywords"
        bash -c "echo '# upgrade to masked kernel ' >> /etc/portage/package.accept_keywords"
        bash -c "echo \"=sys-kernel/gentoo-sources-${new_ver} ~amd64\" >> /etc/portage/package.accept_keywords"
    else
        sed -i "/=sys-kernel\/gentoo-sources/ s/[0-9.]\+\(-r[0-9\+]\)\?[^[:space:]]/${new_ver}/" /etc/portage/package.accept_keywords
    fi
    # <=sys-kernel/gentoo-sources-4.12.12
    if grep -q '<=sys-kernel/gentoo-sources' /etc/portage/package.mask ; then
        sed -i "/<=sys-kernel\/gentoo-sources/ s/^/# /" /etc/portage/package.mask
    fi
    emerge -av sys-kernel/gentoo-sources

    last_path=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*' | sort -Vr | head -1)
    prev_path=$(find /usr/src/ -maxdepth 1 -mindepth 1 -type d -name 'linux*' | sort -Vr | head -2 | tail -1)
    current_path=$(readlink -f /usr/src/linux)

    last_ver=$(printf %s "$last_path" | sed 's|^.*/||' | cut -d- -f2,4)
    curr_ver=$(printf %s "$current_path" | sed 's|^.*/||' | cut -d- -f2,4)

    mode='MERGED'
fi

if [ "$mode" == 'MERGED' ] ; then
    if [ -z "$prev_path" ] ; then
        fatal_error "Unable to find previous kernel"
    fi
    ln -sfvn "$last_path" /usr/src/linux
    emerge -v --noreplace "gentoo-sources:$last_ver"
    cp "${prev_path}/.config" "$last_path"
fi

cd "$(readlink -f /usr/src/linux)" || exit 1

if confirm "Configure kernel?" ; then make menuconfig; fi

if ! confirm "Compile kernel?" ; then exit 1; fi

set -e
set -x

make clean
set +x
if [ "$mode" == 'MERGED' ] ; then
    set -x
    make olddefconfig
    set +x 
fi
set -x
make modules_prepare
make prepare
make
make modules_install
make install
emerge -v @module-rebuild
genkernel --install initramfs
set +x

log "Upgrading grub"
grub-mkconfig -o /boot/grub/grub.cfg

if grep -q '# <=sys-kernel/gentoo-sources' /etc/portage/package.mask ; then
    log "Masking kernels"
    sed -i "/<=sys-kernel\/gentoo-sources/ s/[0-9.]\+\(-r[0-9\+]\)\?[^[:space:]]/${new_ver}/" /etc/portage/package.mask
    sed -i "/<=sys-kernel\/gentoo-sources/ s/^# //" /etc/portage/package.mask
fi

log "Removing old kernels"
find /boot -maxdepth 1 -mindepth 1 -type f -name '*old*' -exec rm "{}" \;

eclean-kernel -n3 --destructive --ask

eselect kernel list
