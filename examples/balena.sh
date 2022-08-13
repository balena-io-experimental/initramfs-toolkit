#!/bin/bash
if [ "$EUID" -ne 0 ]; then
	echo "This script requires root privileges"
	exit 1
fi

source ../mount.sh
source ../initramfs.sh

root_part_num=2
image_path=balenaos.img
mount_path=/mnt
initramfs_srcdir=initramfs_srcdir
kernel_type=Image.gz
initramfs_path=initramfs.img.gz

if mountpoint "${mount_path}" >/dev/null; then
	echo "${mount_path} is in use"
	exit 1;
fi

if [ ! -f "${image_path}" ]; then
	wget https://api.balena-cloud.com/download?deviceType=generic-aarch64 \
	       	-O "${image_path}.gz"
	gunzip "${image_path}.gz"
fi

unmount() {
	umount "${mount_path}"
}

trap unmount EXIT
mount_image_part "${image_path}" "${root_part_num}" "${mount_path}"

cp "${mount_path}/boot/${kernel_type}" .

utils=(ssh)
modules=(smsc95xx br_netfilter)
hostapp_path="$(dirname "$(dirname "$(find "${mount_path}" -path '*/usr/bin')")")"
populate_initramfs "${utils[*]}" \
		   "${modules[*]}" \
		   ${initramfs_srcdir} \
		   "${hostapp_path}/"

# After populating the initramfs, we can do any post-processing we want before
# generating the image. Let's replace /init:
cat << EOF > "${initramfs_srcdir}/init"
#!/bin/sh
set -x
if ! mount -t devtmpfs none /dev; then
	echo "Failed to mount devtmpfs at /dev w/ $?"
	exit 1;
fi

if ! mount -t proc none /proc; then
	echo "Failed to mount proc at /proc w/ $?"
	exit 1;
fi

echo Hello, world!

echo "Let's see if we can load a module"
modprobe smsc95xx

echo "Sleeping, exit with [Ctrl-a x]"
sleep infinity
EOF

chmod +x ${initramfs_srcdir}/init
mkdir -p ${initramfs_srcdir}/proc

generate_initramfs "${initramfs_srcdir}" "${initramfs_path}"

qemu-system-aarch64 \
	-M virt \
	-nographic \
	-cpu cortex-a53 \
	-m 512M \
	-smp cores=4 \
	-kernel ${kernel_type} \
	-initrd ${initramfs_path}
	
