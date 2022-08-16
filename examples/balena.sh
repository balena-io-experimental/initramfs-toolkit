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

utils=(
	balena-engine
	balena-engine-init
	balena-proxy-config
	curl
	iptables
	ip6tables
)
modules=(
	br_netfilter
	xt_MASQUERADE
)
hostapp_path="$(dirname "$(dirname "$(find "${mount_path}" -path '*/usr/bin')")")"
populate_initramfs "${utils[*]}" \
		   "${modules[*]}" \
		   ${initramfs_srcdir} \
		   "${hostapp_path}/"

# After populating the initramfs, we can do any post-processing we want before
# generating the image.
mkdir -p ${initramfs_srcdir}/{etc,proc,usr/bin,sys,tmp,var/lib}
ln -sf ../run ${initramfs_srcdir}/var/run

cat << EOF > "${initramfs_srcdir}/etc/resolv.conf"
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Copy certs to enable TLS
cp -rv "${hostapp_path}/etc/ssl" "${initramfs_srcdir}/etc"

# Let's replace init
cat << EOF > "${initramfs_srcdir}/init"
#!/bin/sh
if ! mount -t devtmpfs none /dev; then
	echo "Failed to mount devtmpfs at /dev w/ $?"
	exit 1;
fi

if ! mount -t proc none /proc; then
	echo "Failed to mount proc at /proc w/ $?"
	exit 1;
fi

if ! mount -t sysfs none /sys; then
	echo "Failed to mount sysfs at /sys w/ $?"
	exit 1;
fi

if ! mount -t tmpfs tmpfs /tmp; then
	echo "Failed to mount tmpfs at /tmp w/ $?"
	exit 1;
fi

#if ! mount -t cgroup -o all cgroup /sys/fs/cgroup; then
#	echo "Unable to mount cgroup v1 controllers"
#	exit 1;
#else
#	echo 1 > /sys/fs/cgroup/memory.use_hierarchy
#fi

mount -t tmpfs -o nosuid,nodev,noexec,mode=755 tmpfs /sys/fs/cgroup
for cg in cpu memory pids devices blkio unified cpuset net_cls; do
	mkdir -p /sys/fs/cgroup/\$cg
done

# These cgroups are typically setup by systemd, this is copied from balenaOS
_cgroup_mnt_opts=rw,nosuid,nodev,noexec,relatime
mount -t cgroup -o "\${_cgroup_mnt_opts},blkio" none /sys/fs/cgroup/blkio
mount -t cgroup -o "\${_cgroup_mnt_opts},cpu,cpuacct" none /sys/fs/cgroup/cpu
mount -t cgroup -o "\${_cgroup_mnt_opts},cpuset" none /sys/fs/cgroup/cpuset
mount -t cgroup -o "\${_cgroup_mnt_opts},devices" none /sys/fs/cgroup/devices
mount -t cgroup -o "\${_cgroup_mnt_opts},memory" none /sys/fs/cgroup/memory
mount -t cgroup -o "\${_cgroup_mnt_opts},net_cls,net_prio" none /sys/fs/cgroup/net_cls
mount -t cgroup -o "\${_cgroup_mnt_opts},pids" none /sys/fs/cgroup/pids
mount -t cgroup2 -o "\${_cgroup_mnt_opts},nsdelegate" none /sys/fs/cgroup/unified
echo 1 > /sys/fs/cgroup/memory/memory.use_hierarchy

modprobe br_netfilter

BALENAD_SOCKET=/var/run/balena-engine.sock

PATH=/sbin:/usr/sbin:/bin:/usr/bin \
balenad \
	--host "unix://\${BALENAD_SOCKET}" \
	--experimental \
	--pidfile /var/run/balena.pid \
	--group root &

echo "Waiting for balena-engine to respond"

while ! curl --fail --unix-socket "\${BALENAD_SOCKET}" http:/v1.40/_ping > /dev/null 2>&1; do
	sleep 0.2;
done

echo "balena-engine is running"

ipconfig eth0

echo "Exit with [Ctrl-a x]"
/bin/sh
EOF

chmod +x ${initramfs_srcdir}/init

cp -rv "${hostapp_path}/var/lib/docker" "${initramfs_srcdir}/var/lib/"
ln -sf docker "${initramfs_srcdir}/var/lib/balena-engine"

engine_links=(
	balena
	balenad
	balena-containerd
	balena-containerd-ctr
	balena-containerd-shim
	balena-engine-containerd
	balena-engine-containerd-ctr
	balena-engine-containerd-shim
	balena-engine-daemon
	balena-engine-proxy
	balena-engine-runc
	balena-proxy
	balena-runc
)

ln -sf ../../bin/balena-engine ${initramfs_srcdir}/usr/bin/balena-engine
for l in "${engine_links[@]}"; do
	ln -sf balena-engine "${initramfs_srcdir}/usr/bin/${l}"
done

# iptables modules
mkdir -p "${initramfs_srcdir}/usr/lib/xtables"
cp -rv "${hostapp_path}/usr/lib/xtables/"* "${initramfs_srcdir}/usr/lib/xtables"
cp -v "${hostapp_path}/usr/lib/libxtables"* "${initramfs_srcdir}/usr/lib/"

# built from klibc, part of early userspace utils
# https://www.kernel.org/doc/Documentation/early-userspace/README
cp -v ipconfig "${initramfs_srcdir}/bin"

cp -v "${hostapp_path}/usr/lib/os-release" "${initramfs_srcdir}/usr/lib/"

generate_initramfs "${initramfs_srcdir}" "${initramfs_path}"

qemu-system-aarch64 \
	-M virt \
	-nographic \
	-cpu cortex-a53 \
	-m 512M \
	-smp cores=4 \
	-kernel ${kernel_type} \
	-initrd ${initramfs_path}
	
