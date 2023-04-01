#!/bin/bash
# Script to install masked Oracle JDK

if [ -z "$1" ] || ! [[ "$1" =~ [0-9]+.[0-9]+.[0-9]+ ]] ; then
    echo "./$(basename $0) [ERROR] : Provide JDK version to install: ./$(basename $0) 11.0.2"
    exit 1
fi

ver="$1"
ver1=$(echo $ver | cut -d. -f1)
prefix=dev-java
package=oracle-jdk-bin
package_ver=${package}-${ver}
ebuild=${package_ver}.ebuild
target_dir=/var/db/repos/localrepo/$prefix/$package
download_dir=/home/$USER/Downloads
install_dir=/opt/${package_ver}

# jdk-11.0.7_linux-x64_bin.tar.gz
tar="$download_dir/jdk-${ver}_linux-x64_bin.tar.gz"
if ! [ -f "$tar" ] ; then
    echo "./$(basename $0) [ERROR] : Unable to find jdk-${ver}_linux-x64_bin.tar.gz in:"
    echo "  $download_dir"
    exit 1
fi
if ! [ -f "$download_dir/$ebuild" ] ; then
    echo "./$(basename $0) [ERROR] : Unable to find ebuild for Oracle JDK ${ver} in"
    echo "  $download_dir"
    exit 1
fi

while true; do
    read -p "./$(basename $0) [INFO] : Install Oracle JDK ${ver}? [yn] " yn
    case $yn in 
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please select y or n";;
    esac
done

set -e

# record each JDK separately in world set
sed -i '/SLOT=/ s/="[^"][^"]*"/="${PV}"/' $download_dir/$ebuild 
# unmask oracle-jdk-bin in /usr/portage/profiles/package.mask
sudo sed -i '/^dev-java\/oracle-jdk-bin/ s/^#*/#/' /usr/portage/profiles/package.mask
# add Oracle-BCLA-JavaSE to /etc/portage/make.conf
sudo sed -i 's/^ACCEPT_LICENSE="[^"]*/& Oracle-BCLA-JavaSE/' /etc/portage/make.conf

# flags required by emerge: 
# /etc/portage/package.use: dev-java/oracle-jdk-bin javafx gtk3
# /etc/portage/package.accept_keywords: dev-java/oracle-jdk-bin ~amd64

# process ebuild
sudo cp $tar /usr/portage/distfiles/
if ! [ -d $target_dir ] ; then
    sudo mkdir -p $target_dir
fi
sudo cp $download_dir/$ebuild $target_dir
sudo chown -R portage:portage $target_dir
sudo ebuild $target_dir/$ebuild manifest
sudo emerge -av =${prefix}/${package_ver}

# add to world set 
grep "${prefix}/${package}:${ver}" /var/lib/portage/world > /dev/null 2>&1
if [ $? -ne 0 ] ; then
    sudo emerge -v --noreplace ${prefix}/${package}:${ver}    
fi

# mask oracle-jdk-bin in /usr/portage/profiles/package.mask
sudo sed -i '/^#dev-java\/oracle-jdk-bin/ s/^#//' /usr/portage/profiles/package.mask 
# remove Oracle-BCLA-JavaSE license from /etc/portage/make.conf
sudo sed -i '/^ACCEPT_LICENSE=/ s/ Oracle-BCLA-JavaSE//' /etc/portage/make.conf

while true; do
    read -p "./$(basename $0) [INFO] : Make Oracle JDK ${ver} default JVM ? [yn] " yn
    case $yn in 
        [Yy]* ) break;;
        [Nn]* ) exit;;
        * ) echo "Please select y or n";;
    esac
done


if ! [ -d "$install_dir" ] ; then
    echo "./$(basename $0) [ERROR] : Unable to find Oracle JDK ${ver} installation in /opt/"
    exit 1
fi

for f in $(ls /usr/bin/ja{r,v}* | grep -v config | sed 's/.*\///g')
do
    if [ -f $install_dir/bin/$f ] ; then
        sudo ln -sfn $install_dir/bin/$f /usr/bin/$f
    fi
done

# export JAVA_HOME="/opt/oracle-jdk-bin-11.0.7"
# export JDK_HOME="/opt/oracle-jdk-bin-11.0.7"
# export JAVAC="/opt/oracle-jdk-bin-11.0.7/bin/javac"
# PATH="${PATH}:${JAVA_HOME}/bin:"
sed -i "/\/opt\/oracle-jdk-bin-.*\//  s/[0-9.]\+/${ver}/" ~/.bash_profile
sudo sed -i "/requiredJavaVersion=/ s/=[0-9.]\+/=${ver1}/" /opt/eclipse/eclipse.ini

sudo revdep-rebuild
sudo env-update
source /etc/profile 
source ~/.bash_profile
