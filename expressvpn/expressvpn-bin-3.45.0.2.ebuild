# Copyright 1999-2023 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

EAPI=6

inherit eapi7-ver unpacker  

DESCRIPTION="High speed, ultra secure, and easy to use VPN."
HOMEPAGE="https://www.expressvpn.com/"

RESTRICT="primaryuri"

SRC_URI="https://www.expressvpn.works/clients/linux/expressvpn_${PV}-1_amd64.deb"

LICENSE="© 2023 ExpressVPN. All rights reserved."
SLOT="0"
RDEPEND="sys-devel/binutils
        sys-apps/net-tools
        net-vpn/openvpn
        app-admin/sudo"

KEYWORDS="amd64"

WORKDIR="${PORTAGE_BUILDDIR}/work"
S=${WORKDIR}
QA_PREBUILT=".*"

pkg_setup() {

    einfo "This application requires subscription, go to"
    einfo " $HOMEPAGE"
    einfo "to purchase a license"

    if [ ! -e /dev/net/tun ]; then
        if ! modprobe tun ; then
            ewarn "The TUN/TAP not supported in this kernel, enable it via:"
            ewarn "Device Drivers  --->"
            ewarn "  Network device support --->"
            ewarn "    [*] Universal TUN/TAP device driver support"
        fi
    fi
}

src_unpack() {

    unpack_deb "${A}" || die "Unable to unpack .deb archive"

}

src_install() {

	dobin "${WORKDIR}/usr/bin/expressvpn"
	dobin "${WORKDIR}/usr/bin/expressvpn-agent"
	dobin "${WORKDIR}/usr/bin/expressvpn-browser-helper"

	dosbin "${WORKDIR}/usr/sbin/expressvpnd"

	dodoc -r "${WORKDIR}/usr/share/doc/expressvpn"
	doman "${WORKDIR}/usr/share/man/man1/expressvpn.1"

	# cannot use dolib/dolibnew functions here since 
	# all binaries must be installed into /usr/lib/expressvpn/
	insinto /usr/lib/expressvpn/
    doins "${WORKDIR}/usr/lib/expressvpn/lightway"
	doins "${WORKDIR}/usr/lib/expressvpn/openvpn" 
    doins "${WORKDIR}/usr/lib/expressvpn/libxvclient.so" 
    doins "${WORKDIR}/usr/lib/expressvpn/expressvpn-agent.desktop"
	doins "${FILESDIR}/expressvpn.init"
	doins "${WORKDIR}/usr/lib/expressvpn/icon.png"
	doins "${WORKDIR}/usr/lib/expressvpn/version"
	insinto /usr/lib/expressvpn/chrome 
	doins "${WORKDIR}/usr/lib/expressvpn/chrome/com.expressvpn.helper.json"
	insinto /usr/lib/expressvpn/firefox
	doins "${WORKDIR}/usr/lib/expressvpn/firefox/com.expressvpn.helper.json"

}

pkg_preinst() {
    # Restore resolv.conf file
    if grep -q "Generated by expressvpn" /etc/resolv.conf 2>/dev/null; then
        # reset chattr
        if [ -x /usr/bin/chattr ] ; then
            /usr/bin/chattr -i /etc/resolv.conf || true
        fi

        # restore previous resolv.conf
        bakfile=/var/lib/expressvpn/resolv.conf.orig
        if [ -L "$bakfile" ]; then
            mv "$bakfile" /etc/resolv.conf
        elif [ -f "$bakfile" ]; then
            cat "$bakfile" > /etc/resolv.conf
            rm /var/lib/expressvpn/resolv.conf.orig
        fi
    fi

    sed -i "/DAEMON_ARGS=/ s/[0-9]\+.[0-9]\+.[0-9]\+/$(ver_cut 1-3)/" "${D}/usr/lib/expressvpn/expressvpn.init"
	sed -i "/DAEMON_ARGS=/ s/\"[0-9]\+\"/\"$(ver_cut 4)\"/" "${D}/usr/lib/expressvpn/expressvpn.init"

}

pkg_postinst() {
	
	SCRIPT_DIR=/usr/lib/expressvpn
	WORK_DIR=/var/lib/expressvpn
    USER=${SUDO_USER:-"$USER"}
	LOGFILE=${XVPN_INSTALLER_LOGFILE:-"/dev/null"}
	
	einfo "Generating certificates..."
	mkdir -p "$WORK_DIR/certs"
    chown root "$WORK_DIR/certs"
    chmod 755 "$WORK_DIR/certs"
    /usr/sbin/expressvpnd --workdir "$WORK_DIR" generate-client-ca
    /usr/sbin/expressvpnd --workdir "$WORK_DIR" generate-client-certs
    rm -f "$WORK_DIR/certs/client.req"
    rm -f "$WORK_DIR/certs/clientca.srl"
    chmod 644 "$WORK_DIR/certs/client.key"

    # Upgrade userdata to v2
    if [ -e "$WORK_DIR/userdata.dat" ] && [ ! -e "$WORK_DIR/userdata2.dat" ]; then
        mv "$WORK_DIR/userdata.dat" "$WORK_DIR/userdata2.dat"
    fi

    # Upgrade userdata to shared library
    if [ -e "$WORK_DIR/userdata2.dat" ] && [ ! -e "$WORK_DIR/data/e21fb121.bin" ]; then
        einfo "Upgrade in progress..."

        mkdir -p "$WORK_DIR/data"
        chmod 700 "$WORK_DIR/data"
        /usr/sbin/expressvpnd \
            --workdir "$WORK_DIR" \
            --client-version "$(ver_cut 1-3)" \
			--client-build "$(ver_cut 4)" \
            migrate >> "${LOGFILE}" 2>&1
    fi

    einfo "Installing Chrome extension helper..."
    if [ -f "${SCRIPT_DIR}/chrome/com.expressvpn.helper.json" ]; then
        sudo -u "${USER}" bash -c 'mkdir -p "${HOME}/.config/google-chrome/NativeMessagingHosts"'
        sudo -u "${USER}" bash -c 'cp "/usr/lib/expressvpn/chrome/com.expressvpn.helper.json" "${HOME}/.config/google-chrome/NativeMessagingHosts/com.expressvpn.helper.json"'
        sudo -u "${USER}" bash -c 'mkdir -p "${HOME}/.config/chromium/NativeMessagingHosts"'
        sudo -u "${USER}" bash -c 'cp "/usr/lib/expressvpn/chrome/com.expressvpn.helper.json" "${HOME}/.config/chromium/NativeMessagingHosts/com.expressvpn.helper.json"'
        sudo -u "${USER}" bash -c 'mkdir -p "${HOME}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"'
        sudo -u "${USER}" bash -c 'cp "/usr/lib/expressvpn/chrome/com.expressvpn.helper.json" "${HOME}/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.expressvpn.helper.json"'
    fi

    einfo "Installing Firefox extension helper..."
    if [ -f "${SCRIPT_DIR}/firefox/com.expressvpn.helper.json" ]; then
        sudo -u "${USER}" bash -c 'mkdir -p "${HOME}/.mozilla/native-messaging-hosts"'
        sudo -u "${USER}" bash -c 'cp "/usr/lib/expressvpn/firefox/com.expressvpn.helper.json" "${HOME}/.mozilla/native-messaging-hosts/com.expressvpn.helper.json"'
    fi

    einfo "Installing bash completions..."
    if [ -f "$SCRIPT_DIR/bash-completion" ]; then
        if [ -d "/etc/bash_completion.d" ]; then
            ln -nfs "$SCRIPT_DIR/bash-completion" /etc/bash_completion.d/expressvpn
        fi

        if [ -d "/usr/share/bash-completion/completions" ]; then
            ln -nfs "$SCRIPT_DIR/bash-completion" /usr/share/bash-completion/completions/expressvpn
        fi
    fi

	einfo "Installing expressvpn service..."
    if command -v systemctl &>/dev/null; then
        cp -f $SCRIPT_DIR/expressvpn.service /etc/systemd/system/expressvpn.service
        touch /etc/default/expressvpn
        /bin/systemctl enable expressvpn
        /bin/systemctl restart expressvpn
    else 
        cp -f $SCRIPT_DIR/expressvpn.init /etc/init.d/expressvpn
        chmod +x /etc/init.d/expressvpn
        touch /etc/default/expressvpn
        /etc/init.d/expressvpn restart
        rc-update add expressvpn default
    fi

    # expressvpn expects ifconfig, route and ip at /sbin/
    ln -sfn /bin/ifconfig /sbin/ifconfig
    ln -sfn /bin/route /sbin/route
    ln -sfn /bin/ip /sbin/ip

    # set permissions for openvpn 
    # 'fperms 0755 /usr/lib/expressvpn/openvpn' 
    # failed so set on a file outside of sandbox
    chmod 0755 /usr/lib/expressvpn/openvpn


    einfo "Help improve ExpressVPN"
	einfo "Enable the collection of diagnostic information to report bugs and give"
	einfo "feedback on this beta version of ExpressVPN. To enable run:"
	einfo ""
	einfo "  sudo /usr/lib/expressvpn/expressvpn-enable-beta-diagnostics"
	einfo ""

}

pkg_prerm() {
    # Disconnect before remove. OK to fail.
    if /usr/bin/expressvpn status | grep -q Connected 2>/dev/null ; then
        /usr/bin/expressvpn disconnect

        sleep 2
    fi

    # Stop engine daemon
    if command -v /bin/systemctl > /dev/null 2>&1; then
        /bin/systemctl stop expressvpn
    else
        if [ -x /etc/init.d/expressvpn ]; then
            /etc/init.d/expressvpn stop
        fi
    fi
}


pkg_postrm() {
    rm -f /usr/share/bash-completion/completions/expressvpn || true
    rm -f /etc/bash_completion.d/expressvpn || true
    rm -f /etc/defaults/expressvpn || true
    rm -f /etc/init.d/expressvpn || true
    # rm -f /etc/systemd/system/expressvpn.service || true

    rm -rf /var/lib/expressvpn || true
    rm -rf /var/log/expressvpn || true
    rm -rf /var/run/expressvpn || true

    if [ -f "/sbin/ifconfig" ] ; then
        rm /sbin/ifconfig 
    fi
    if [ -f "/sbin/route" ] ; then
        rm /sbin/route 
    fi
    if [ -f "/sbin/ip" ] ; then
        rm /sbin/ip
    fi
    
    rc-update delete expressvpn default
}

pkg_info() {
    "${ROOT}"/usr/sbin/expressvpnd --version
}
