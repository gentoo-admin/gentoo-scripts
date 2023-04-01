#!/bin/bash
# script to install KDE desktop
#

# validate  
gen2_commons="$(dirname "$0")/commons.sh"
if ! [ -f "$gen2_commons" ] ; then
    echo "./commons.sh is required to run this script"
    exit 1
fi
# shellcheck source=./commons.sh
source "$gen2_commons"

if ! [ -f "$gen2_config" ] ; then
    fatal_error "./CONFIG is required to run this script"
fi
# shellcheck source=./CONFIG
source "$gen2_config"

if [[ $EUID -ne 0 ]]; then
    fatal_error "This script must be run as root"
fi

# installing Xorg 
info "Installing Xorg" && show_count
emerge x11-base/xorg-drivers x11-base/xorg-server || fatal_error "Unable to emerge Xorg"

info "Installing KDE" && show_count
echo 'L10N="en"' >> /etc/portage/make.conf
emerge plasma-meta kdeaccessibility-meta kdeadmin-meta kdecore-meta \
kdegraphics-meta kdemultimedia-meta kdeutils-meta kdeplasma-addons plasma-pa || fatal_error "Unable to emerge KDE"

info "Installing network manager" && show_count
emerge kde-apps/kwalletmanager net-misc/networkmanager kde-plasma/plasma-nm \
|| fatal_error "Unable to install network manager"
rc-update add NetworkManager default

info "Installing display manager" && show_count
emerge x11-misc/sddm kde-plasma/sddm-kcm kde-plasma/kwallet-pam || fatal_error "Unable to emerge display manager"

usermod -a -G video sddm
sed -i 's/\(^DISPLAYMANAGER=\)\(.*\)/\1\"sddm\"/' /etc/conf.d/display-manager
rc-update add xdm default

# probably not needed anymore after etc-update is called earlier
if ! grep -q '^-auth[[:space:]]\+optional[[:space:]]\+pam_kwallet5.so' /etc/pam.d/sddm ; then
    echo '-auth           optional        pam_kwallet5.so' >> /etc/pam.d/sddm
fi
if ! grep -q '^-session[[:space:]]\+optional[[:space:]]\+pam_kwallet5.so[[:space:]]\+auto_start' /etc/pam.d/sddm ; then
    echo '-session        optional        pam_kwallet5.so auto_start' >> /etc/pam.d/sddm
fi

users=()
while true; do
    if ! confirm "Create new user?" ; then
        break
    fi
    read -p "Enter user name: " username
    if cut -d: -f1 /etc/passwd | grep -q "$username"  ; then
        error "User $username already exists"
        continue
    fi
    users+=("$username")
    useradd -m -G users,wheel,audio -s /bin/bash "$username"
    passwd "$username"
    # nvidia config
    if [[ "$gen2_video_card" == *nvidia* ]] ; then
        gpasswd -a "$username" video
    fi
done

info "Installing sudo" && show_count
emerge app-admin/sudo app-editors/vim || fatal_error "Unable to emerge sudo"
# export VISUAL=vim; visudo
if [ "${#users[@]}" -gt 0 ] ; then
    if ! [ -d /etc/sudoers.d ] ; then
        mkdir /etc/sudoers.d
    fi
    for user in "${users[@]}" ; do
        touch "/etc/sudoers.d/$user"
        {
            echo "## Allow full access for $user"
            # echo "$user ALL=(ALL) NOPASSWD: ALL"
            echo "$user ALL=(ALL) ALL"
        } >> "/etc/sudoers.d/$user"
    done
fi

info "Installing CUPS" && show_count
emerge net-print/cups || fatal_error "Unable to emerge CUPS"
rc-update add cupsd default
for user in "${users[@]}" ; do 
    gpasswd -a "$user" lpadmin
done

info "Installing Samba" && show_count
if installed cups ; then
    echo "net-fs/samba cups" >> /etc/portage/package.use/samba
fi
emerge net-fs/samba || fatal_error "Unable to emerge Samba"

info "Configuring local repository"
LOCAL_REPO=/var/db/repos/localrepo
mkdir -p ${LOCAL_REPO}/{metadata,profiles}
chown -R portage:portage ${LOCAL_REPO}
echo 'localrepo' > ${LOCAL_REPO}/profiles/repo_name
{
    echo 'masters = gentoo'
    echo 'auto-sync = false'
} >> ${LOCAL_REPO}/metadata/layout.conf
{
    echo "[localrepo]"
    echo "location = $LOCAL_REPO"
} >> /etc/portage/repos.conf/localrepo.conf
localrepo_tar="$(dirname "$0")/localrepo.tar.bz2"
if [ -f "$localrepo_tar" ] ; then
    tar -xf "$localrepo_tar" -C /
fi

if confirm "Configure 2 hdd?" ; then
    
    select_disk
    if [ -n "$gen2_disk" ] && [ -z "$gen2_part" ] ; then
        part="$(lsblk -o NAME,TYPE -ln "$gen2_disk" | grep -c part)"
        if [ "$part" -eq 0 ] ; then
            info "Creating new partition on $gen2_disk"
            echo 'g;n;1;;;w;' | tr ';' '\n' | fdisk "$gen2_disk"
            gen2_part="$(lsblk -o NAME,TYPE -ln "$gen2_disk" | grep part | awk '{print "/dev/" $1}')"
            mkfs.ext4 "$gen2_part"
        elif [ "$part" -gt 1 ] ; then
            error "Selected disk has more than 1 partition"
            gen2_part=''
        elif [ "$part" -eq 1 ] ; then
            gen2_part="$(lsblk -o NAME,TYPE -ln "$gen2_disk" | grep part | awk '{print "/dev/" $1}')"
        fi
    fi

    if [ -n "$gen2_part" ] ; then
        hdd_mount=/wdhdd
        printf "UUID=%-40s  %s  ext4    defaults            0 0 \n" "$(lsblk -o UUID "$gen2_part" -ln)" "$hdd_mount" >> /etc/fstab
        mkdir "$hdd_mount"
        chmod -R 777 "$hdd_mount"
        cat /etc/fstab
        printf '\n\n'
    fi

fi

info "Installing network analyzers" && show_count
emerge net-analyzer/wireshark net-analyzer/nmap

info "Installing Open JDK" && show_count
if emerge dev-java/openjdk-bin ; then
    jvm="$(find /opt -maxdepth 1 -mindepth 1 -type d -name "*jdk*" | sort -Vr | head -n1)"
    if [ "${#users[@]}" -gt 0 ] ; then
        for user in "${users[@]}" ; do
            {
                echo "export JAVA_HOME=\"${jvm}\""
                echo "export JDK_HOME=\"\${JAVA_HOME}\""
                echo "PATH=\"\${PATH}:\${JAVA_HOME}/bin:\""
                echo ''
            } >> /home/"${user}"/.bash_profile
        done
    fi
fi

info "Installing browsers" && show_count
emerge www-client/google-chrome
emerge www-client/opera
emerge www-client/firefox-bin

info "Installing VLC" && show_count
echo 'media-video/vlc gnutls live lua matroska rtsp theora upnp vcdx' >> /etc/portage/package.use/vlc
{
    echo "# always use unstable version of VLC"
    echo "media-video/vlc ~x86"
} >> /etc/portage/package.accept_keywords/vlc
emerge media-video/vlc 

info "Installing MySQL" && show_count
echo "dev-db/mariadb" >> /etc/portage/package.mask/mariadb
emerge dev-db/mysql
if confirm "Configure MySQL?" ; then
    emerge --config dev-db/mysql
    rc-update add mysql default
    rc-service mysql start
fi

info "Installing LibreOffice" && show_count
emerge app-office/libreoffice-bin

info "Installing graphical tools" && show_count
emerge media-gfx/gimp media-gfx/imagemagick

info "Installing PDF tools" && show_count
emerge app-text/pdftk

info "Installing torrent" && show_count
emerge net-p2p/qbittorrent

# info "Installing VirtualBox"
# emerge virtualbox virtualbox-additions virtualbox-extpack-oracle
# for user in "${users[@]}" ; do
#     gpasswd -a "$user" vboxusers
# done
# if ! [ -d /etc/modules-load.d/ ] ; then
#     mkdir -p /etc/modules-load.d
# fi
# printf "%s\n" vbox{drv,netadp,netflt,pci} >> /etc/modules-load.d/virtualbox.conf

# applications from local repository
info "Installing vscode" && show_count
echo "app-editors/vscode-bin ~amd64" >> /etc/portage/package.accept_keywords/vscode
emerge vscode-bin
# commands below does not work so might need to install maually later
/opt/vscode/bin/code --install-extension timonwong.shellcheck
/opt/vscode/bin/code --install-extension llvm-vs-code-extensions.vscode-clangd
/opt/vscode/bin/code --install-extension ZainChen.json
/opt/vscode/bin/code --install-extension DotJoshJohnson.xml
for user in "${users[@]}"; do
    echo "external-sources=true" > /home/"${user}"/.shellcheckrc
    chown "${user}":"${user}" ~/.shellcheckrc 
done

info "Installing ExpressVPN" && show_count
emerge expressvpn-bin

info "Installing Eclipse" && show_count
emerge eclipse-jee-bin
# by default eclipse will start with the bundled JVM but since versions 4.23 it's broken (cannot start)
# will find installed JVM and replace it in eclipse.ini file
jvm="$(find /opt -maxdepth 1 -mindepth 1 -type d -name "*jdk*" | sort -Vr | head -n1)"
if [ -n "$jvm" ] && [ -d "${jvm}/bin" ]; then
    jvm+="/bin"
    sed -i "/\-vm$/ {n;s|.*|${jvm}|}" /opt/eclipse/eclipse.ini
else
    warn "Unable to find installed JDK, eclipse will start with embedded JVM which might fail"
fi

info "Installing fonts" && show_count
fonts=()
fonts+=("droid-sans-mono")
fonts+=("fira-code")
fonts+=("cascadia-code")
fonts+=("source-code-pro")
for font  in "${fonts[@]}" ; do
    font_zip="/tmp/${font}.zip"
    if ! wget https://www.fontsquirrel.com/fonts/download/$font -O "$font_zip" ; then
        error "Unable to download font $font"
        continue
    fi
    mkdir /usr/share/fonts/"$font"
    unzip "$font_zip" -d /usr/share/fonts/"$font" || error "Unable to unzip font $font"
done
fc-cache -f -v

# clean distfiles
info "Cleaning distfiles" && show_count
dist_dir=$(emerge --info | grep '^DISTDIR=' | sed 's/\(^.*\"\)\(.*\)\"/\2/')
rm -rf "${dist_dir:?}"/*

if [ -f /install-scripts/connect-wifi ] && confirm "Connect to Wifi?" ; then
    bash /install-scripts/connect-wifi
fi

screenfetch

