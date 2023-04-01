

Fully functional and automated script to install KDE Gentoo Linux on AMD-based systems, was successfully tested on various gaming PCs (Gigabyte, MinisForum etc.).  Install time depends on the processor speed and package setup, varied from 5 to 8 hours on testing machines (Ryzen 7/9 8 cores/16 threads) with the default KDE profile with full setup including user applicatons.

Logs.
It's highly recommended to keep the installation logs to troubleshoot the issues/bugs during installation. The log size in testing was approximately ~350MiB in total. Installation scripts will be saved on the target machine in the /install-scripts dir and can be run again to reinstall.

Gentoo-kernel vs gentoo-sources.
The script supports both gentoo-kernel and gentoo-sources kernel packages, however, gentoo-kernel is the default and preferred. If the gentoo-kernel is selected, gentoo will pull the latest kernel .config from Fedora repository, which will work fine on most systems. This is not a 'genkernel -all' config however, so will enable most of common hardware, but not all. Install scipt, on the other side, has its own kernel config, created for the testing machines, and will match it against the one pulled from Fedora repostory. Ideally, a new kernel config should be created for each new gentoo setup so will be merged when script ask for it. However this step can be skipped, if Fedora kernel is ok, ignoring script prompt will not break anything during installation.

NVidia.
For NVidia, the script will install only the drivers, so manual post-config will still be needed after the full system install.

Install.
Refer to INSTALL for step-by-step instructions.

Issues.
A couple of things were found during previous installations:
-- UUID on target partitions can be randomly changed during base system install (so Gentoo script recreates partitions or just replaces UUIDs on them?) - in this case newly installed os will not be able to mount all partitions upon first boot and display an error message. This will happen because /etc/fstab is configured with the UUIDs instead of device name, as suggested in the Gentoo handbook. If the error is displayed, run the script ./fstab-fix.sh before proceeeding to the next step.
-- sometimes package integrity is broken at the Gentoo repository, so packages can progressively compile, but eventually fail. This specifically applies for the case when the gentoo repository going through KDE upgrade. If this is the case, wait and run the KDE desktop script sometime (like a day) later.
