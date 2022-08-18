#!/bin/bash
# shellcheck disable=SC1091
source ../../mount.sh
source ../../initramfs.sh

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 bridge_name"
	exit 1
fi

bridge_name=$1

boot_part_num=1
root_part_num=2
image_path=balenaos.img
mount_path=/mnt
initramfs_srcdir=initramfs_srcdir
kernel_type=Image.gz
initramfs_path=initramfs.img.gz

cleanup() {
	umount "${mount_path}"
	if [ -n "${container_id}" ]; then
		docker kill "${container_id}"
		docker rm "${container_id}"
	fi

	# shellcheck disable=SC2046
	kill $(jobs -p)
}

trap cleanup EXIT

if mountpoint "${mount_path}" > /dev/null; then
	echo "${mount_path} is in use"
fi

if [ ! -f "${image_path}" ]; then
	wget https://api.balena-cloud.com/download?deviceType=generic-aarch64 \
		-O "${image_path}.gz"
	gunzip "${image_path}.gz"

	mount_image_part "${image_path}" "${boot_part_num}" "${mount_path}"
	jq .developmentMode=true "${mount_path}/config.json" \
			> "${mount_path}/config.json.tmp" \
		&& mv "${mount_path}"/config.json{.tmp,}
	umount "${mount_path}"
fi

mount_image_part "${image_path}" "${root_part_num}" "${mount_path}"

cp "${mount_path}/boot/${kernel_type}" .
mkdir -p ${initramfs_srcdir}

utils=()
modules=(nbd)
hostapp_path="$(dirname "$(dirname "$(find "${mount_path}" -path '*/usr/bin')")")"
populate_initramfs "${utils[*]}" \
		   "${modules[*]}" \
		   ${initramfs_srcdir} \
		   "${hostapp_path}/"

# balenaOS doesn't have the nbd-client utility we need, so pull a compatible
# Debian container that we'll steal it from. Note that the container image
# needs a glibc version equal or newer than the one in our initramfs.
if [ ! -f "${initramfs_srcdir}/bin/nbd-client" ]; then
	image_tag=debian:bookworm-slim@sha256:2c7e2451a81e3de90dcc5a8505ff9720ebbdfe940fa6845f8676df98c8c0780f
	container_id=$(docker run -d "${image_tag}" sleep infinity)
	docker exec -it "${container_id}" \
		/bin/sh -c "apt update && apt install -y nbd-client"
	container_merged_dir=$(
		docker inspect "${container_id}" \
			| grep MergedDir \
			| cut -d: -f2 \
			| cut -d, -f1 \
			| xargs )

	utils=(nbd-client)
	modules=()
	populate_initramfs "${utils[*]}" \
			   "${modules[*]}" \
			   "${initramfs_srcdir}" \
			   "${container_merged_dir}/"
fi

mkdir -p ${initramfs_srcdir}/{bin,init.d}

cp -v ../ipconfig-aarch64 "${initramfs_srcdir}/bin/ipconfig"

cat << EOF > ${initramfs_srcdir}/init.d/00-net
net_enabled() {
	return 0
}

net_run() {
	/bin/ipconfig eth0
}
EOF

cat << EOF > ${initramfs_srcdir}/init.d/03-nbd
. /usr/libexec/os-helpers-logging

nbd_enabled() {
	if [[ -z "\$bootparam_nbd_host" || -z "\$bootparam_nbd_name" ]]; then
		error "The parameters nbd_host and nbd_name must be defined"
		return 1
	fi
}

nbd_run() {
	nbd_host=\${bootparam_nbd_host}
	nbd_name=\${bootparam_nbd_name}
	nbd_port=\$( test ! -z \${bootparam_nbd_port} && echo " $\{bootparam_nbd_port}")
	modprobe nbd
	echo "nbd_host = \${nbd_host}"
	echo "nbd_name = \${nbd_name}"
	echo "nbd_port = \${nbd_port}"
	echo "nbd-client -N \${nbd_name} \${nbd_host}\${nbd_port} /dev/nbd0 -systemd-mark -persist"
	nbd-client -N \${nbd_name} \${nbd_host}\${nbd_port} /dev/nbd0 -systemd-mark -persist
}
EOF

generate_initramfs "${initramfs_srcdir}" "${initramfs_path}"

bridge_addr=$(
	ip a l "${bridge_name}" \
		| awk '/inet/ {print $2}' \
		| head -n1 \
		| cut -d/ -f1)

nbd_name=balenaos
qemu-nbd --format raw \
	 --export-name "${nbd_name}" \
	 balenaos.img &

# We pass the kernel and initramfs directly through to QEMU, but these could
# easily be served over TFTP as well
qemu-system-aarch64 \
	-M virt \
	-nographic \
	-cpu cortex-a53 \
	-m 512M \
	-smp cores=4 \
	-net nic,model=virtio \
	-net bridge,br="${bridge_name}" \
	-kernel ${kernel_type} \
	-initrd ${initramfs_path} \
	-append "root=/dev/nbd0p2 nbd_host=${bridge_addr} nbd_name=${nbd_name} rootwait"
	
