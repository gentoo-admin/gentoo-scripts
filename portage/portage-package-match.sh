#!/bin/sh
# This script looks and matches portage package name by files listed in .deb contol files
# check https://packages.debian.org/ for current stable version 

DEBIAN_FILELIST="https://packages.debian.org/buster/amd64/PACKAGE_NAME/filelist"
DEB_FILE="/home/sasha/Downloads/CodeLite-15.0.3-gtk3-ubuntu-focal-x86_64.deb"
TMP_DIR=/tmp/package-match

if [ ! -f "$DEB_FILE" ] ; then
    echo "File does not exist: $DEB_FILE"
    exit 1
fi
if [ -d "$TMP_DIR" ] ; then
    rm -rf "$TMP_DIR"
fi
mkdir "$TMP_DIR"
cp "$DEB_FILE" "$TMP_DIR"
cd "$TMP_DIR"
DEB_TMP="$(basename $DEB_FILE)"

ar x "$DEB_TMP"
# some deb archives have control.tar.xz instead of control.tar.gz
control_tar="$(find "$TMP_DIR" -type f -name 'control.*')"
if [ -z "$control_tar" ] ; then
    echo "File does not exist: $TMP_DIR/control.tar.*"
    exit 1    
fi
tar xf "$control_tar"

if [ ! -f "$TMP_DIR/control" ] ; then
    echo "File does not exist: $TMP_DIR/control"
    exit 1
fi

IFS=$',' arr=($(grep Depends "$TMP_DIR/control" | cut -d: -f2-))
for a in "${arr[@]}"
do
    echo "Debian package: $a"
    package_name="$(echo "$a" | cut -d'(' -f1 | sed 's/[[:space:]]//g')"
    package_ver="$(echo "$a" | cut -d'(' -f2 | cut -d')' -f1)"
    # get list of files 
    IFS=$'\n' 
    url=$(echo "$DEBIAN_FILELIST" | sed "s/PACKAGE_NAME/$package_name/")
    list=($(curl -s "$url" | sed -ne '/id="pfilelist"><pre>/,/<\/pre>/p'))
    for l in "${list[@]}"
    do
        if [[ "$l" == */lib/*.so* ]] ; then
            qfile -v "$(echo "$l" | sed 's/^.*\///')"
            if [ $? -eq 0 ] ; then
                break
            fi
        fi
    done
done
