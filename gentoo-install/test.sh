#!/bin/bash 

source "$(dirname "$0")/commons.sh"
validate_config

# info "Installing x11-apps/mesa-progs" && show_count
# sudo emerge --ask x11-apps/mesa-progs

# echo processor_model = $gen2_processor_model

# if ! confirm "Continue?" ; then
#     exit 1
# fi

# select_disk
# set_gentoo_partitions
# echo boot_partition=$gen2_boot_partition
# echo swap_partition=$gen2_swap_partition
# echo root_partition=$gen2_root_partition
# echo home_partition=$gen2_home_partition

# grep '^[A-Z0-9_]\+=\"' /etc/portage/make.conf > ./test.conf
# add_value ./test.conf KEY VALUE
# replace_value ./test.conf KEY NEW_VALUE
# merge_values ./test.conf USE "networkmanager vbox dhcp"

# cpu_flags=$(cpuid2cpuflags | cut -d: -f2)
# add_value ./test.conf CPU_FLAGS_X86 "$cpu_flags"

# configure_kernel



