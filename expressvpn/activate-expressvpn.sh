#!/bin/bash

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

# decrypt activation key from .gpg file and copy to clipboard
gpg_file=$HOME/expressvpn/expressvpn.data.gpg
if ! [ -f "$gpg_file" ] ; then
    fatal_error "gpg file does not exist: $gpg_file"
fi

IFS=$'\n'
activation_key=
while true; do
    info "Enter password to decrypt file with activation key: "
    read -s password
    while read -r line; do
        # activaton key: 39487T6KV586TMX8743MT8C4698YUV59887YUG
        if [[ "$line" =~ [A-Z0-9]{23,} ]] ; then
            activation_key="${BASH_REMATCH[0]}"
            break
        fi
    done < <(echo "$password" | gpg --batch --yes --decrypt --passphrase-fd 0 "$gpg_file" 2>/dev/null)
    if [ -n "$activation_key" ] ; then
        # expressvpn does not accept key from stdin so copy to clipboard
        echo "$activation_key" | xclip -i -selection clipboard
        # from remote:
        # DISPLAY=:0 xclip -i -selection clipboard <<< "JHGJG8787FDGd5454GJGJ90898HKJHJH88989"
        info "Activation key copied to clipboard"
        break
    else
        warn "Unable to decrypt activation key"
    fi
done

expressvpn activate
unset password
unset activation_key
head -c25 /dev/urandom | base64 | xclip -i -selection clipboard

info "Connecting to random VPN location"
random=$(expressvpn list | grep '^[a-z]\+\([0-9]\+\)\?[[:space:]]\+' | sort -R | tail -1 | awk '{print $1}')
expressvpn connect "$random"

