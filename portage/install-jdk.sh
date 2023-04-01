#!/bin/bash
# script to install JDK into /opt without registering with portage

INSTALL_DIR=/opt
DOWNLOAD_DIR=/home/${SUDO_USER}/Downloads
ECLIPSE_CONFIG=/opt/eclipse/eclipse.ini

declare -a installed_jdks
declare -a new_jdks

# check if jdk is installed 
function is_installed() {
    local ver
    ver="$(basename "$1" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"
    [[ "$(find "$INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d -name "*jdk*${ver}" | wc -l)" -gt 0 ]]
}

function get_installed_jdks() {
    installed_jdks=()
    while read -r jdk; do
        if ! [[ "$jdk" =~ [0-9]+.[0-9]+.[0-9]+ ]] ; then
            continue
        fi
        installed_jdks+=("$jdk")
    done < <(find "$INSTALL_DIR" -maxdepth 1 -mindepth 1 -type d -name '*jdk*')
    
    curr_jdk=""
    if [ -L /usr/bin/java ] ; then
        curr_jdk="$(readlink -f /usr/bin/java | sed 's|/bin.*||')"
    fi

}

function print_installed_jdks() {
    if [ "${#installed_jdks[*]}" -eq 0 ] ; then
        echo 'No installed JDKs found'
        return 
    fi

    local def
    printf 'Found %d installed JDKs:\n' "${#installed_jdks[*]}"
    for i in "${!installed_jdks[@]}"; do 
        def=""
        if [ -n "$curr_jdk" ] && [ "${installed_jdks[$i]}" == "$curr_jdk" ] ; then
            def="*"
        fi 
        printf '%5s %s %s\n' "[$((i+1))]" "${installed_jdks[$i]}" "$def" 
    done
}

function print_jdks_ready_to_install() {
    if [ "${#new_jdks[*]}" -eq 0 ] ; then
        echo 'No JDKs to install available'
        return 
    fi

    printf 'Found %d JDKs ready to install:\n' "${#new_jdks[*]}"
    for i in "${!new_jdks[@]}"; do 
        printf '%5s %s\n' "[$((i+1))]" "${new_jdks[$i]}"
    done
}

function confirm() {
    local resp
    while true; do
        read -p "$1 [yn] " yn
        case $yn in 
            [Yy]* ) resp=0; break;;
            [Nn]* ) resp=1; break;;
            * ) echo "Please select y or n";;
        esac
    done
    return "$resp"
}

function get_jdks_ready_to_install() {
    new_jdks=()
    while read -r jdk; do
        if ! [[ "$jdk" =~ [0-9]+.[0-9]+.[0-9]+ ]] ; then
            continue
        fi
        if is_installed "$jdk" ; then
            continue
        fi
        new_jdks+=("$jdk")
    done < <(find "$DOWNLOAD_DIR" -maxdepth 1 -mindepth 1 -type f -name '*jdk*_linux-x64_bin.tar.gz')
}

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit
fi

get_installed_jdks

if [[ "${#installed_jdks[*]}" -gt 0 ]] ; then
    print_installed_jdks    
    if confirm "Remove existing JDKs?" ; then
        read -rp "Type JDK numbers to remove (separated by space): " remove
        for num in $remove; do
            if ! [[ "$num" =~ [0-9]+ ]] ; then
                echo "Invalid number provided"
                continue    
            fi
            jdk_to_remove="${installed_jdks[ $((num-1)) ]}"
            echo "Removing JDK ${jdk_to_remove}..."
            rm -rf "$jdk_to_remove"
            if [ -n "$curr_jdk" ] && [[ "$curr_jdk" == "$jdk_to_remove" ]] ; then
                find /usr/bin/ -type l -name 'jar*'  -exec rm '{}' \;
                find /usr/bin/ -type l -name 'java*' -exec rm '{}' \;
            fi
        done
        get_installed_jdks
    fi
fi

get_jdks_ready_to_install
print_jdks_ready_to_install

if [ "${#new_jdks[*]}" -gt 0 ] ; then
    if confirm "Install JDKs from above?" ; then
        for file in "${new_jdks[@]}"; do
            echo "Installing JDK $(basename "$file")..."
            # /download dir/jdk-15.0.2_linux-x64_bin.tar.gz -> /opt/jdk-15.0.2
            # /download dir/openjdk-16.0.2_linux-x64_bin.tar.gz -> /opt/openjdk-16.0.2
            jdk_dir_name="$(basename "$file" | cut -d_ -f1)"
            tar xf "$file" -C "$INSTALL_DIR" --strip-components=1 --one-top-level="$jdk_dir_name"
        done
        get_installed_jdks
        print_installed_jdks
    fi
fi

if [[ "${#installed_jdks[*]}" -gt 0 ]] ; then
    if confirm "Change default JDK?" ; then
        while true; do
            read -p "Type JDK number to make default: " resp
            if ! [[ "$resp" =~ [0-9]+ ]] ; then
                echo "Invalid number"
                continue
            fi
            if [[ "$resp" -lt 0 ]] || [[ "$resp" -gt "${#installed_jdks[*]}" ]] ; then
                echo "Invalid number selected"
                continue
            fi
            resp=$((resp-1))
            if [ -n "$curr_jdk" ] && [[ "${installed_jdks[$resp]}" == "$curr_jdk" ]] ; then
                echo "Selected current JDK"
                continue
            fi
            break
        done
        jdk_dir="${installed_jdks[$resp]}"
        jdk_ver="$(printf %s "$jdk_dir" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+')"

        # set new JDK to JAVA_HOME in .bash_profile
        sudo -u "$SUDO_USER" bash -c 'sed -i "/JAVA_HOME=/ s|\".*\"|\"'"$jdk_dir"'\"|" /home/'"$SUDO_USER"'/.bash_profile'
        # update eclipse config
        if [ -f "$ECLIPSE_CONFIG" ] ; then
            sed -i "/requiredJavaVersion=/ s/=[0-9.]\+/=${jdk_ver}/" "$ECLIPSE_CONFIG"
            sed -i "/\-vm$/ {n;s|.*|${jdk_dir}/bin|}" "$ECLIPSE_CONFIG"
        fi
        # update symlinks in /usr/bin
        while read -r f; do
            ln -sfn "$f" "/usr/bin/$(basename "$f")"
        done < <(find "${jdk_dir}/bin" -name 'java*' -or -name 'jar*')
    fi
fi
