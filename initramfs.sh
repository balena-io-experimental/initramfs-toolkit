#set -x

find_bin_deps() {
	# Usage: find_deps /usr/bin/
	objdump -p "$1" 2>/dev/null \
		| grep NEEDED \
		| awk '{ print $2 }'
}

find_mod_deps() {
	module=$1
	rootdir=$2
	moddep_path="$(find "${rootdir}" -name modules.dep)"
	>&2 echo "moddep_path: ${moddep_path}"
	grep "/${module}.ko.*:" "${moddep_path}" | cut -d: -f2-
}

is_absolute() {
	[[ "$1" == /* ]]
}

install_binary() {
	# Usage: install_binary scp "${sysroot}" "${initramfs_srcdir}"
	#/
	# Copies a binary with dependencies, recursively, from ${sysroot} to
	# ${initramfs_srcdir}
	#
	# Optionally, specify space delimited arrays of search paths, relative
	# to ${sysroot}, for binaries and libraries respectively. The defaults
	# should work in most places.
	local binary="${1}"
	local rootdir="${2}"
	local outdir="${3}"
	local bin_dirs=${4:-"bin usr/bin sbin usr/sbin"}
	local lib_dirs=${5:-"lib lib64 usr/lib usr/lib64"}
	local path
	local deps
	local src
	local dest

	search_paths=$(for d in $bin_dirs $lib_dirs; do echo -n "${rootdir}${d} "; done)
	path="$(find ${search_paths} \
			-maxdepth 1 \
			-name "${binary}" \
			-print \
			-quit \
			2>/dev/null \
		)"
	if [ -z "${path}" ]; then
		echo "Unable to find binary: '${binary}'"
		exit 1;
	fi

	src="$(
		if [ -L "${path}" ]; then
			link="$(readlink "${path}")"
			if is_absolute "${link}"; then
				echo "${rootdir}${link}"
			else
				readlink -f "${path}"
			fi
		else
			echo "${path}";
		fi)"
	dest="$(
		if [[ "${path}" == *.so* ]]; then
			echo "${outdir}/lib";
		else
			echo "${outdir}/bin";
		fi
	)"

	# avoid recursive loops
	if [ -f "${dest}/${binary}" ]; then
		return
	fi

	deps="$(find_bin_deps "${src}")"
	for d in ${deps}; do
		install_binary "${d}" "${rootdir}" "${outdir}" "${search_paths}"
	done

	mkdir -p "${dest}"
	cp -v "${src}" "${dest}/${binary}"
}

install_module() {
	# Usage: install_module smsc95xx ${sysroot} ${initramfs_srcdir}
	#
	# Copies a kernel module with dependencies, recursively, from
	# ${sysroot} to ${initramfs_srcdir}
	local module="${1}"
	local rootdir="${2}"
	local outdir="${3}"
	local path
	local outdir_abs

	path="$(cd "${rootdir}" && find lib/modules -name "${module}.ko*")"
	if [ -z "${path}" ]; then
		echo "Unable to find module: '${module}'"
		exit 1;
	fi

	if find "${outdir}/lib/modules" -name "${module}.ko*" 2>/dev/null | grep . ; then
		return
	fi

	deps="$(find_mod_deps "${module}" "${rootdir}")"
	echo "${module} deps: ${deps}"
	for d in ${deps}; do
		dep="$(basename "${d}" | cut -d. -f1)"
		install_module "${dep}" "${rootdir}" "${outdir}"
	done

	outdir_abs="$(readlink -f "${outdir}")"
	(cd "${rootdir}" && cp -v --parents "${path}" "${outdir_abs}"/)
	(cd "${rootdir}" && cp -v --parents \
		"$(find . -name modules.dep)" \
		"${outdir_abs}")
}

populate_initramfs() {
	# Usage: populate_initramfs "${utils[*]}" \
	#			    "${modules[*]}" \
	#			    "${initramfs_srcdir}" \
	#			    "${sysroot}"
	#
	# Copies utils and kernel modules with dependencies from ${sysroot} to
	# ${initramfs_srcdir}
	local wanted_binaries=${1}
	local wanted_modules=${2}
	local outdir="${3}"
	local root="${4}"

	for b in ${wanted_binaries}; do
		install_binary "$b" "${root}" "${outdir}"
	done

	for m in ${wanted_modules}; do
		install_module "$m" "${root}" "${outdir}"
	done
}

generate_initramfs() {
	# Usage: generate_initramfs "${initramfs_srcdir}" "initramfs.img.gz"
	#
	# Creates a gzipped cpio archive of the contents of ${initramfs_srcdir}
	#
	# Optionally specify a compressor that accepts data from stdin
	local srcdir="${1}"
	local output="${2}"
	local compressor=${3:-gzip}
	(cd "${srcdir}" || exit; find . | cpio -o -H newc | ${compressor}) > "${output}"
}
