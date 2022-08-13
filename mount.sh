#!/bin/bash
#set -e
mount_image_part() {
	# Usage: mount_image_part os.img 2 /mnt
	#
	# Mounts an image partition by calculating the offset of the partition
	# inside the loopback image. Obviates the need for losetup, udev, etc.
	# (Works great in containers!)
        local image_path=$1
        local part_number=$2
        local mountpoint=$3
        local sector_size
        local part_offset
        sector_size=$( \
                fdisk -l "${image_path}" \
                | grep "Sector size" \
                | cut -d: -f2 \
                | cut -d' ' -f2 )
        part_offset=$(
                fdisk -l "${image_path}" \
                | grep "${image_path}${part_number}" \
                | awk '{print $2}' )
        # accounts for partitions marked bootable
        if [ "${part_offset}" = "*" ]; then
                part_offset=$(
                        fdisk -l "${image_path}" \
                        | grep "${image_path}${part_number}" \
                        | awk '{print $3}' )
        fi

        mount "${image_path}" \
                -o "offset=$((part_offset * sector_size))" \
                "${mountpoint}"
}
