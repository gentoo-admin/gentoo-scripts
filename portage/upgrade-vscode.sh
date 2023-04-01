#!/bin/bash
# script to update vscode

URL="https://code.visualstudio.com/updates"

PKG_NAME=vscode-bin
LOCAL_REPO=/var/db/repos/localrepo
PORTAGE_DIR=$LOCAL_REPO/app-editors/$PKG_NAME

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
    echo "This script must be run as root"
    exit 1
fi

set -e

info "Checking for update..."
while read -r line; do
    if [[ "$line" =~ https://update.code.visualstudio.com/[0-9.]+/linux-x64/stable ]] ; then
        new_build="$(echo "${BASH_REMATCH[0]}" | cut -d'/' -f4)" 
    fi
done < <(wget "$URL" -q -O -)

if [ -z "$new_build" ] ; then
    fatal_error "Unable to retrieve release ver"
fi

latest_ebuild=$(find "$PORTAGE_DIR" -name '*.ebuild' | sort -Vr | head -1)
latest_ver="$(printf %s "$latest_ebuild" | grep -o '[0-9]\+.[0-9]\+.[0-9]\+')"
latest_ver_num="$(printf %s "$latest_ver" | sed 's/[^0-9]//g')"
release_num="$(printf %s "$new_build" | sed 's/[^0-9]//g')"

if [ "$release_num" -lt "$latest_ver_num" ] ; then        
    fatal_error "Newer version $latest_ver already installed"
elif [ "$release_num" -eq "$latest_ver_num" ] ; then
    info "Build ${new_build} is latest and already installed"
    exit 1
else
    if ! confirm "New build ${new_build} is available, install?" ; then
        exit 1
    fi
fi

new_ebuild="$(printf %s "$latest_ebuild" | sed "s/[0-9.]\+/${new_build}./")"
cp "$latest_ebuild" "$new_ebuild"
ebuild "$new_ebuild" manifest
emerge -av vscode-bin

