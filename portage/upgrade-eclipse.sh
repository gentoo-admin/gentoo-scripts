#!/bin/bash
# script to upgrade eclipse 

URL="https://www.eclipse.org/downloads/packages/"
LOCAL_REPO=/var/db/repos/localrepo
ECLIPSE_REPO=$LOCAL_REPO/dev-java/eclipse-jee-bin

function throw_error() {
    print_info "$1"
    exit 1
}

function print_info() {
    printf "[%s] - %s\n" "$(basename "$0")" "$1"
}

function print_text() {
    printf "[%s] - %s" "$(basename "$0")" "$1"
}

print_info "Checking for update..."
while read -r line; do
    if [[ "$line" == *"Eclipse"* ]] ; then
        if [ -z "$eclipse_release" ] && [[ "$line" =~ [0-9]{4}-[0-9]{2} ]] ; then
            eclipse_release="${BASH_REMATCH[0]}"   
        fi
        if [ -z "$release" ] && [[ "$line" =~ [0-9]\.[0-9]+ ]] ; then
            release="${BASH_REMATCH[0]}.0"
        fi
        if [ -n "$eclipse_release" ] && [ -n "$release" ] ; then
            break
        fi
    fi
done < <(wget "$URL" -q -O -)

if [ -z "$eclipse_release" ] || [ -z "$release" ] ; then
    throw_error "Unable to parse build from wget"
fi

latest_ebuild="$(find "$ECLIPSE_REPO" -name '*.ebuild' | sort -Vr | head -1)"
if [ -z "$latest_ebuild" ] ; then 
   throw_error "Eclipse ebuild not found in local repository"
fi
latest_ver="$(printf %s "$latest_ebuild" | grep -o '[0-9]\+.[0-9]\+.[0-9]\+')"
latest_ver_num="$(printf %s "$latest_ver" | sed 's/[^0-9]//g')"
release_num="$(printf %s "$release" | sed 's/[^0-9]//g')"
if [ "$latest_ver_num" -eq "$release_num" ] ; then
    throw_error "Build $eclipse_release ($release) is currently installed"
elif [ "$latest_ver_num" -gt "$release_num" ] ; then
    throw_error "Newer build $eclipse_release ($release) is currently installed"
fi

while true; do
    print_text "New build $eclipse_release (${release}) is found, install? [yn] "
    read -r yn
    case $yn in
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please select [yn]";;
    esac
done

new_ebuild="$(printf %s "$latest_ebuild" | sed "s/[0-9]\+.[0-9]\+.[0-9]/$release/")"
cp "$latest_ebuild" "$new_ebuild"
sed -i "/PV_YM=/ s/[0-9]\{4\}-[0-9]\{2\}/${eclipse_release}/" "$new_ebuild"
chown -R portage:portage "$ECLIPSE_REPO"
ebuild "$new_ebuild" manifest

emerge -av dev-java/eclipse-jee-bin

# replace default jvm path in eclipse.ini file
# curr_jvm="$(readlink "$(which java)" | sed 's/[^/]\+$//')"
# in case of eselect-java is installed, command above will return a bash script 
# 
curr_jvm="$(find /opt -maxdepth 1 -mindepth 1 -type d -name "*openjdk*" | sort -Vr | head -n1)/bin"
if ! [ -d "$curr_jvm" ] ; then
    throw_error "Java bin directory not valid: $curr_jvm"
fi
sed -i "/\-vm$/ {n;s|.*|${curr_jvm}|}" /opt/eclipse/eclipse.ini

