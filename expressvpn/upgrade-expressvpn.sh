#!/bin/bash
# when expressvpn displays a message that new ver is available, run
# sudo ./update-expressvpn.sh
# requires xclip to copy auth key to clipboard

URL="https://www.vlycgtx.com/latest?utm_source=linux_app"

TMP_DIR=/tmp/expressvpn

PKG_NAME=expressvpn-bin
LOCAL_REPO=/var/db/repos/localrepo
PORTAGE_DIR=$LOCAL_REPO/net-vpn/$PKG_NAME

function info_open() {
    printf "%s [%s] %s  - %s" "$(date '+%F %T.%3N')" "$(basename "$0")" INFO "$1"
}

function info() {
    info_open "$1"
    printf '\n'
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

function is_expressvpn_started() {
    [[ $(/etc/init.d/expressvpn status | awk -F: '{print $NF}' | sed "s/^[[:space:]]\+//") == "started"* ]]
}

function is_nmcli_connected() {
    [[ $(nmcli --terse -f STATE general status) == "connected" ]]
}

function unpack_deb() {
    # arg 1: full path to .deb archive
    # arg 2: tmp dir name
    if [ -z "$1"  ] || [ -z "$2" ]; then
        fatal_error "Invalid arguments to unpack .deb archives"
    fi
    if [ ! -f "$1" ] ; then
        fatal_error "File $1 does not exist"
    fi
    
    local file="$1"
    local dir="$2"

    mkdir -p "$dir"/{data,control}
    ar x "$file" --output "$dir"
    if [ ! -f "$dir/control.tar.gz" ] ; then
        fatal_error "Missing control.tar.gz archive"
    fi
    if [ ! -f "$dir/data.tar.gz" ] ; then
        fatal_error "Missing data.tar.gz archive" 
    fi
    tar xf "$dir/control.tar.gz" -C "$dir/control" 
    tar xf "$dir/data.tar.gz" -C "$dir/data"

}

function compare_dir() {

    if [ -z "$1" ] || [ ! -d "$1" ] ; then
        info "Dir $1 not found"
        return 1
    fi
    if [ -z "$2" ] || [ ! -d "$2" ] ; then
        info "Dir $2 not found"
        return 1
    fi

    local dir1="$1"
    local dir2="$2"

    info "Comparing dir /$(echo "$dir1" | cut -d'/' -f5-)"
    diff -qr "$dir1" "$dir2" | grep 'Only in'

}

function compare_file() {

    if [ -z "$1" ] || [ ! -f "$1" ] ; then 
        info "File $1 not found"
        return 1
    fi
    if [ -z "$2" ] || [ ! -f "$2" ] ; then 
        info "File $2 not found"
        return 1
    fi
    local file1="$1"
    local file2="$2"

    info "Comparing file /$(echo "$file1" | cut -d'/' -f5-)"
    diff "$file1" "$file2"

}

function download_deb() {

    if [ -z "$1" ] ; then 
        fatal_error "Invalid url provided"
    fi

    local url="$1"
    local file
    file=$(echo "$url" | sed 's/^.*\///')

    wget -O "${dist_dir}/$file" "$url"
    if [ ! -f "${dist_dir}/$file" ] ; then
        fatal_error "Failed to download $url"
    fi

}

if [[ $EUID -ne 0 ]]; then
   fatal_error "This script must be run as root"
fi
if ! [ -d $PORTAGE_DIR ] ; then
    fatal_error "$PORTAGE_DIR does not exist"
fi
if [ "$(find $PORTAGE_DIR -type f -name '*.ebuild' | wc -l)" -eq 0 ] ; then
    fatal_error "At least one ebuild is required to generate new ebuild"
fi

info "Checking for update..."
while read -r line; do
    if [[ "$line" == *"https:"*"expressvpn"*"_amd64.deb"* ]] ; then
        for f in $line
        do
            if [[ $f =~ https://.*.deb ]] ; then
                new_build_url="${BASH_REMATCH[0]}"
                break
            fi
        done
    fi
done < <(wget "$URL" -q -O -)

if [ -z "$new_build_url" ] ; then
    fatal_error "Unable to retrieve new build url"
fi

# https://www.expressvpn.works/clients/linux/expressvpn_1.4.1.2699-1_amd64.deb
new_build=$(echo "$new_build_url" | grep -oE '[0-9]+.[0-9]+.[0-9]+.[0-9]+')
if [ -z "$new_build" ] ; then
    fatal_error "Unable to retrieve new build ver"
fi

# expressvpn-bin-1.4.1.2699.ebuild
old_ebuild=$(find "$PORTAGE_DIR" -type f -name '*.ebuild' | sort -rV | head -1 | sed 's/^.*\///')
old_build=$(echo "$old_ebuild" | grep -oE '[0-9]+.[0-9]+.[0-9]+.[0-9]+')
if [ "$new_build" == "$old_build" ] ; then
    fatal_error "Latest build is installed (${new_build})"
fi

new_ebuild="${PKG_NAME}-${new_build}.ebuild"
if [ -f "${PORTAGE_DIR}/${new_ebuild}" ] ; then
    fatal_error "New ebuild already exists in portage repo"
fi

if ! confirm "New build ${new_build} is available, install?" ; then
    exit 1
fi

# get old build url to download existing .deb
# SRC_URI="https://www.expressvpn.works/clients/linux/expressvpn_${PV}-1_amd64.deb"
# ->       https://www.expressvpn.works/clients/linux/expressvpn_1.4.1.2699-1_amd64.deb
old_build_url=$(grep 'SRC_URI=' "${PORTAGE_DIR}/${old_ebuild}" | cut -d'"' -f2 | sed "s/\$.*\}/${old_build}/")

dist_dir=$(emerge --info | grep DISTDIR | cut -d'"' -f2)
find "$dist_dir" -maxdepth 1 -type f -name 'expressvpn*' -exec rm -f '{}' \;
download_deb "$new_build_url"
download_deb "$old_build_url"

info "Creating new ebuild"
cp -a "${PORTAGE_DIR}/${old_ebuild}" "${PORTAGE_DIR}/${new_ebuild}"
ebuild "${PORTAGE_DIR}/${new_ebuild}" manifest
chown -R portage:portage "$PORTAGE_DIR"

new_deb=$(find "$dist_dir" -maxdepth 1 -type f -name 'expressvpn*.deb' | sort -Vr | head -n1)
old_deb=$(find "$dist_dir" -maxdepth 1 -type f -name 'expressvpn*.deb' | sort -Vr | tail -n1)
if [ -d "$TMP_DIR" ] ; then
    rm -rf "$TMP_DIR"
fi
mkdir "$TMP_DIR"

# /usr/portage/distfiles/expressvpn_1.4.0.1677-1_amd64.deb -> /tmp/expressvpn/1.4.0.1677/
# /usr/portage/distfiles/expressvpn_1.4.1.2966-1_amd64.deb -> /tmp/expressvpn/1.4.1.2699/
new_deb_tmp_dir="${TMP_DIR}/"$(echo "$new_deb" | sed 's/.*\///g' | cut -d'_' -f2 | cut -d- -f1)
unpack_deb "$new_deb" "$new_deb_tmp_dir"
old_deb_tmp_dir="${TMP_DIR}/"$(echo "$old_deb" | sed 's/.*\///g' | cut -d'_' -f2 | cut -d- -f1)
unpack_deb "$old_deb" "$old_deb_tmp_dir"

info "Comparing new and current .deb archives"

compare_dir "${new_deb_tmp_dir}/control" "${old_deb_tmp_dir}/control"
compare_dir "${new_deb_tmp_dir}/data/usr/bin" "${old_deb_tmp_dir}/data/usr/bin"
compare_dir "${new_deb_tmp_dir}/data/usr/sbin" "${old_deb_tmp_dir}/data/usr/sbin"
compare_dir "${new_deb_tmp_dir}/data/usr/lib/expressvpn" "${old_deb_tmp_dir}/data/usr/lib/expressvpn"

while IFS= read -r -d '' file
do
    f="$(basename "$file")"
    compare_file "${new_deb_tmp_dir}/control/$f" "${old_deb_tmp_dir}/control/$f"
done <  <(find "$new_deb_tmp_dir/control" -maxdepth 1 -executable -type f -print0)

# expressvpn.service
# expressvpn.init
while IFS= read -r -d '' file
do
    f="$(basename "$file")"
    compare_file "${new_deb_tmp_dir}/data/usr/lib/expressvpn/$f" "${old_deb_tmp_dir}/data/usr/lib/expressvpn/$f"
done <  <(find "${new_deb_tmp_dir}/data/usr/lib/expressvpn" -maxdepth 1 -type f -name 'expressvpn.*' -print0)

if confirm "Make changes in new ebuild?" ; then
    vim "${PORTAGE_DIR}/$new_ebuild"
    ebuild "${PORTAGE_DIR}/$new_ebuild" manifest
fi

emerge -av "$PKG_NAME"

chmod 755 -R /usr/lib/expressvpn/

if ! is_expressvpn_started ; then
    info "Network Manager has not started, restarting"
    /etc/init.d/NetworkManager restart
    if ! is_nmcli_connected ; then
        info "Connect to WLAN"
        while true; do
            if is_nmcli_connected ; then
                break
            fi
        done
    fi
    if ! is_expressvpn_started ; then
        /etc/init.d/expressvpn start
    fi
fi

rm -rf "$TMP_DIR"

info "To activate ExpressVPN account run 'activate-expressvpn' from reg user"

