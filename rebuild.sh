#! /bin/sh

set -eu

# Are we really POSIX sh?  If not, this might still work...
if set -o | grep -q -- 'pipefail'; then
	# shellcheck disable=SC3040
	set -o pipefail
fi

debug=${DEBUG:-}
trace=${TRACE:-}

cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

utils_basedir='.'
# FIXME: Don't hard-code directory name...
if [ -d ../docker-dell ]; then
	utils_basedir='..'
fi

for script in \
	gentoo-build-kernel \
	gentoo-build-pkg \
	gentoo-build-svc \
	gentoo-init
do
	if ! [ -x "${script}.docker" ]; then
		echo >&2 'FATAL: Cannot locate container build tools'
		exit 1
	fi
done
unset script

_command='docker'
if command -v podman >/dev/null 2>&1; then
	_command='podman'
fi

# Allow a separate image directory for persistent images...
#tmp="$( # <- Syntax
#	${_command} system info |
#		grep 'imagestore:' |
#		cut -d':' -f 2- |
#		awk '{print $1}'
#	)"
#if [ -n "${tmp}" ]; then
#	export IMAGE_ROOT="${tmp}"
#fi

if [ -s .kbuild_opt ]; then
	[ $(( debug )) -ne 0 ] && echo >&2 "DEBUG: $( basename "${0}" ): Including build options from '.kbuild_opt' ..."
	kbuild_opt="${kbuild_opt:-} $( cat .kbuild_opt )"
fi
if [ -z "${kbuild_opt:-}" ]; then
		kbuild_opt="--config-from=config.gz --keep-build --no-patch --clang --llvm-unwind"
fi
all=0
alt_use='bison flex gnu http2'  # http2 targeting curl for rust packages...
arg=''
exclude=''
force=0
failures=''
haveargs=0
pkgcache=0
pretend=0
err=0
rc=0
rebuildimgs=0
rebuildutils=0
skip=0
system=0
tools=1
update=0
case " ${*:-} " in
	*' -h '*|*' --help '*)
		printf >&2 'Usage: %s ' "$( basename "${0}" )"
		if [ -d "${utils_basedir}/docker-dell" ]; then
			printf >&2 '[--rebuild-utilities] '
		fi
		echo >&2 '[--rebuild-images [--skip-build] [--no-tools] [--force] [--all]] [--init-pkg-cache] [--update-pkgs [--exclude="<pkg ...>"]] [--update-system [--pretend] [--exclude="<pkg ...>"]]'
		echo >&2
		echo >&2 "       kernel build options: kbuild_opt='${kbuild_opt}'"
		exit 0
		;;
esac

_output=''
rc=0
if ! [ -x "$( command -v "${_command}" )" ]; then
	echo >&2 "FATAL: Cannot locate binary '${_command}'"
	exit 1
elif ! _output="$( "${_command}" info 2>&1 )"; then
	"${_command}" info 2>&1 || rc=${?}
	if [ "${_command}" = 'podman' ]; then
		echo >&2 "FATAL: Unable to successfully execute '${_command}'" \
			"(${rc}) - do you need to run '${_command} machine start' or" \
			"re-run '$( basename "${0}" )' as 'root'?"
	else
		echo >&2 "FATAL: Unable to successfully execute '${_command}'" \
			"(${rc}) - do you need to re-run '$( basename "${0}" )' as 'root'?"
	fi
	exit 1
elif [ "$( uname -s )" != 'Darwin' ] &&
		[ $(( $( id -u ) )) -ne 0 ] &&
		echo "${_output}" | grep -Fq -- 'rootless: false'
then
	echo >&2 "FATAL: Please re-run '$( basename "${0}")' as user 'root'"
	exit 1
fi
unset _output

for arg in ${@+"${@}"}; do
	case "${arg:-}" in
		--rebuild-utilities)
			rebuildutils=1
			haveargs=1
			;;
		--rebuild-images)
			rebuildimgs=1
			haveargs=1
			;;
		--skip-build)
			skip=1
			;;
		--no-tools)
			tools=0
			;;
		--update-pkgs|--update-packages)
			update=1
			haveargs=1
			;;
		--update-system)
			system=1
			haveargs=1
			;;
		--exclude=*)
			exclude="$( echo "${arg}" | sed -r "s/^--exclude=['\"]?(.*)['\"]?$/\1/" )"
			haveargs=1
			;;
		-a|--all)
			all=1
			;;
		-f|--force)
			force=1
			;;
		-i|--init-pkg-cache)
			pkgcache=1
			haveargs=1
			;;
		-p|--pretend)
			pretend=1
			;;
		*)
			echo >&2 "FATAL: Unknown argument '${arg:-}'"
			exit 1
			;;
	esac
done
if [ $(( haveargs )) -eq 0 ]; then
	rebuildutils=1
	rebuildimgs=1
	update=1
	system=1
	# For safety
	pretend=1
fi
if [ $(( rebuildimgs )) -ne 1 ]; then
	if [ $(( skip )) -eq 1 ]; then
		echo >&2 "WARN:  Option '--skip-build' is only valid with '--rebuild-images'"
		skip=0
	fi
	if [ $(( force )) -eq 1 ]; then
		echo >&2 "WARN:  Option '--force' is only valid with '--rebuild-images'"
		force=0
	fi
	if [ $(( all )) -eq 1 ]; then
		echo >&2 "WARN:  Option '--all' is only valid with '--rebuild-images'"
		all=0
	fi
else  # if [ $(( rebuildimgs )) -eq 1 ]; then
	if [ $(( skip )) -eq 1 ]; then
		if [ "$( "${_command}" image ls -n 'localhost/gentoo-build' | wc -l )" = '0' ]; then
			echo >&2 "WARN:  Option '--skip-build' is only valid with a pre-existing 'build' image"
			echo >&2 "WARN:  Ignoring '--skip-build' and generating new image(s)"
			skip=0
		fi
	fi
fi
if [ $(( pretend )) -eq 1 ] && [ $(( system )) -ne 1 ]; then
	echo >&2 "WARN:  Option '--pretend' is only valid with '--update-system'"
	pretend=0
fi
if [ $(( update )) -ne 1 ] && [ $(( system )) -ne 1 ] && [ -n "${exclude:-}" ]; then
	echo >&2 "WARN:  Options '--exclude' is only valid with '--update-packages' and '--update-system'"
	unset exclude
fi

# We should now include common/vars.sh unconditionally - it might slow startup,
# but for the most part, this script will be doing significant heavy-lifting in
# any case...
#
# shellcheck disable=SC1091
. ./common/vars.sh

[ -z "${trace:-}" ] || set -o xtrace

export TRACE="${CTRACE:-}" # Optinally enable child tracing

if [ "${rebuildutils:-"0"}" = '1' ]; then
	if ! [ -d "${utils_basedir}/docker-dell" ]; then
		if [ $(( haveargs )) -ne 0 ]; then
			echo >&2 'FATAL: docker-dell tools not found on this system'
			exit 1
		fi
	else
		if ! mkdir -p "${log_dir:="log"}"; then
			echo >&2 "FATAL: Could not create log directory '${log_dir}': ${?}"
			exit 1
		fi

		if [ "$( "${_command}" image ls -n 'localhost/dell-dsu' | wc -l )" = '0' ]; then
			"${utils_basedir}"/docker-dell/dell.docker --dsu \
					${IMAGE_ROOT:+"--root"} ${IMAGE_ROOT:+"${IMAGE_ROOT}"} \
				>> "${log_dir}"/dell.dsu.log 2>&1 &
			# shellcheck disable=SC3044
			disown 2>/dev/null || :  # doesn't exist in POSIX sh :(
		fi
		if [ "$( "${_command}" image ls -n 'localhost/dell-ism' | wc -l )" = '0' ]; then
			"${utils_basedir}"/docker-dell/dell.docker --ism \
					${IMAGE_ROOT:+"--root"} ${IMAGE_ROOT:+"${IMAGE_ROOT}"} \
				>> "${log_dir}"/dell.ism.log 2>&1 &
			# shellcheck disable=SC3044
			disown 2>/dev/null || :  # doesn't exist in POSIX sh :(
		fi
	fi
fi

if [ "${rebuildimgs:-"0"}" = '1' ]; then
	if ! mkdir -p "${log_dir:="log"}"; then
		echo >&2 "FATAL: Could not create log directory '${log_dir}': ${?}"
		exit 1
	fi

	if [ $(( skip )) -ne 0 ] || ./gentoo-init.docker; then
		forceflag=''
		if ! [ $(( force )) -eq 0 ]; then
			forceflag='--force'
		fi
		selection='--services installed'
		if ! [ $(( tools )) -eq 0 ]; then
			selection="${selection} tools"
		fi
		if ! [ $(( all )) -eq 0 ]; then
			selection='--services all'
		fi
		[ $(( debug )) -ne 0 ] && echo >&2 "DEBUG: $( basename "${0}" ): Calling service script './gentoo-build-svc.docker${forceflag:+" ${forceflag}"}${forceflag:+" --rebuild"} ${selection}'"
		# shellcheck disable=SC2086
		if ! ./gentoo-build-svc.docker \
				${forceflag:+"${forceflag}"} \
				${forceflag:+"--rebuild"} \
				${selection}
		then
			: $(( err = ${?} ))
			: $(( rc = rc + err ))
			failures="${failures:+"${failures} "}gentoo-build-svc:${err}"
		fi
		if [ -x gentoo-web/gentoo-build-web.docker ]; then
			if ! ./gentoo-web/gentoo-build-web.docker \
					${forceflag}
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-web:${err}"
			fi
		fi

		# Don't impose memory limits on hosts with <8GB RAM, linux
		# won't build (with clang) on 4GB hosts :(
		ram=$(( $( # <- Syntax
			grep -m 1 'MemTotal:' /proc/meminfo |
				awk '{ print $2 }'
		) / 1024 / 1024 ))
		if [ $(( ram )) -lt 7 ]; then
			# shellcheck disable=SC2086
			if ! NO_MEMORY_LIMITS=1 ./gentoo-build-kernel.docker \
					${kbuild_opt:-}
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-kernel:${err}"
			fi
		else
			# shellcheck disable=SC2086
			if ! ./gentoo-build-kernel.docker \
					${kbuild_opt:-}
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-kernel:${err}"
			fi
		fi
		unset ram
	else
		: $(( err = ${?} ))
		: $(( rc = rc + err ))
		if [ $(( err )) -ne 0 ]; then
			failures="${failures:+"${failures} "}gentoo-init:${err}"
		fi
	fi
fi

if [ "${pkgcache:-"0"}" = '1' ]; then
	if ! mkdir -p "${log_dir:="log"}"; then
		echo >&2 "FATAL: Could not create log directory '${log_dir}': ${?}"
		exit 1
	fi

	# Build binary packages for 'init' stage installations (which aren't built
	# with --buildpkgs=y because at this stage we've not built our own compiler
	# or libraries)...

	(
		[ -n "${python_default_target:-}" ] ||
			die "No valid python default target set"

		perl_features='ithreads'
		export PERL_FEATURES="${perl_features}"
		export PYTHON_SINGLE_TARGET="${python_default_target}"
		export PYTHON_TARGETS="${python_default_target}"

		default_use="$( # <- Syntax
				echo "${perl_features}" |
					xargs -rI'{}' echo "perl_features_{}"
			)
			python_single_target_${python_default_target}
			python_targets_${python_default_target}"

		# shellcheck disable=SC2030
		failures=''
		# shellcheck disable=SC2030
		rc=0
		use=''
		image=''
		if command -v portageq >/dev/null 2>&1; then
			# shellcheck disable=SC2030
			ARCH="${ARCH:-"$( portageq envvar ARCH )"}"
		else
			echo >&2 "WARN:  Cannot locate 'portageq' utility"
		fi
		if [ -z "${ARCH:-}" ]; then
			case "$( uname -m )" in
				aarch64)
					ARCH='arm64' ;;
				arm*)
					ARCH='arm' ;;
				x86_64)
					ARCH='amd64' ;;
				*)
					echo >&2 "FATAL: Unknown architecture '$( uname -m )'"
					exit 1
					;;
			esac
		fi
		readonly ARCH

		# Cache packages with minimal USE-flags, as used during the base-image
		# build...
		{
			# shellcheck disable=SC2030,SC2086,SC2154
			if { ! USE="$( # <- Syntax
					echo " -* -asm ${alt_use} ${use_cpu_flags:-} compat" \
							"embedded ftp getentropy gmp ipv6 ninja nls" \
							"python readline reference " ${default_use} ' ' |
						sed 's/ asm //g'
			)" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.init' \
						--usepkg=y \
						--with-bdeps=n \
					net-misc/dhcpcd \
					net-firewall/iptables \
					dev-libs/gmp \
					dev-libs/libgcrypt \
					dev-libs/openssl \
					dev-perl/libintl-perl \
					dev-libs/libxml2 \
					sys-apps/gawk \
					app-arch/zstd \
					dev-libs/isl \
					dev-libs/mpc \
					dev-libs/libbsd \
					app-crypt/libmd \
					dev-libs/mpfr \
					sys-libs/zlib \
					dev-libs/expat \
					dev-libs/libffi \
					sys-apps/gentoo-functions \
					dev-libs/libtasn1 \
					dev-libs/icu \
					sys-apps/which \
					sys-apps/iproute2 \
					sys-apps/less \
					sys-apps/portage \
					dev-libs/nettle ;
			} || { ! USE="$( echo "-* ${alt_use} ${use_cpu_flags:-} asm" \
						"compile-locales cxx ipv6 ktls lib-only minimal" \
						"openssl pcre pie reference ssl varrun" \
						${default_use} ${use_essential_gcc}
					)" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.init' \
						--usepkg=y \
						--with-bdeps=n \
					dev-lang/python \
					dev-libs/openssl \
					sys-apps/shadow \
					app-arch/xz-utils \
					dev-libs/gmp \
					app-misc/pax-utils \
					sys-devel/gettext \
					app-editors/vim \
					app-editors/vim-core \
					sys-libs/gdbm \
					dev-lang/perl \
					net-libs/gnutls \
					sys-process/procps \
					sys-libs/glibc \
					sys-apps/kbd \
					sys-apps/grep \
					sys-apps/diffutils \
					net-misc/wget \
					net-misc/iputils \
					dev-build/make \
					sys-apps/openrc \
					sys-apps/man-db \
					sys-devel/gcc ;
			} || { ! USE="$( echo "-* ${alt_use} ${use_cpu_flags:-} mdev" \
						"native-extensions pie" ${default_use}
					)" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.init' \
						--usepkg=y \
						--with-bdeps=n \
					sys-devel/gettext \
					sys-apps/portage \
					net-misc/openssh \
					sys-apps/busybox ;
			} || { ! USE="$( echo "-* ${alt_use} ${use_cpu_flags:-} acl" \
						"bzip2 e2fsprogs expat iconv lzma lzo xattr zstd"
					)" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.init' \
						--usepkg=y \
						--with-bdeps=n \
					app-arch/libarchive \
					sys-devel/binutils \
					sys-apps/kmod ;
			} || { ! USE="$( echo "-* ${alt_use} ${use_cpu_flags:-} lzma" \
						"python zstd" ${default_use}
					)" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.init' \
						--usepkg=y \
						--with-bdeps=n \
					sys-apps/kmod ;
			}
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;0:${err}"
			fi
		} | tee "${log_dir}"/buildpkg.init.log

		for image in 'localhost/gentoo-stage3' 'localhost/gentoo-init'; do
			if [ "$( "${_command}" image ls -n "${image}" | wc -l )" = '0' ]; then
				# shellcheck disable=SC2154
				eval "$( # <- Syntax
					"${_command}" container run \
							--rm \
							--entrypoint /bin/sh \
							--name 'buildpkg.stage3_flags.read' \
							--network none \
						"${image}" -c "cat ${stage3_flags_file}"
				)"
				if [ -n "${STAGE3_USE:-}" ]; then
					# Add 'symlink' USE flag to ensure that /usr/src/linux is
					# updated;
					#
					# FIXME: This flag also affects a small number of other
					#        ebuilds (possibly replacing bzip2 & gzip binaries)
					#
					# Also add ${alt_use} USE flags as otherwise
					# app-alternatives/lex aborts the build :(
					use="${STAGE3_USE} ${alt_use} symlink"
					for flag in ${use}; do
						case "${flag}" in
							"${ARCH}"|readline|nls|static|static-libs|zstd)
								continue ;;
						esac
						# shellcheck disable=SC2030
						USE="${USE:+"${USE} "}${flag}"
					done
					break
				fi
				# shellcheck disable=SC2046
				unset $( set | grep '^STAGE3_' | cut -d'=' -f 1 )
			fi
		done
		if [ -z "${USE:-}" ]; then
			# Assume that python_default_target has the most recent/primary
			# version first...
			python_single_target="${python_default_target%%" "*}"
			use="
				${use_essential_gcc}
				${alt_use}
				acl
				bzip2
				crypt
				extra-filters
				jit
				lzma
				python
				  python_single_target_${python_single_target}
				  python_targets_${python_default_target}
				ssl symlink
				xml
			"
			USE=''
			for flag in ${use}; do
				USE="${USE:+"${USE} "}${flag}"
			done
		fi
		unset image
		use="${USE}"
		USE="-* ${use}"
		export USE

		{
			# shellcheck disable=SC2030
			if ! \
					USE="$( echo "-* ${use} bison nls readline zstd" \
							"python_single_target_${python_default_target}" \
							"python_targets_${python_default_target}" \
							"${use_essential_gcc} -jit"
						)" \
					PYTHON_SINGLE_TARGET="${python_default_target}" \
					PYTHON_TARGETS="${python_default_target}" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
					virtual/libc \
					dev-libs/libxml2 \
					sys-apps/gawk \
					sys-devel/bc \
					sys-devel/gcc \
					sys-libs/libxcrypt
			then
				: $(( err = ${?} ))
				# shellcheck disable=SC2031
				: $(( rc = rc + err ))
				# shellcheck disable=SC2031
				failures="${failures:+"${failures} "}gentoo-build-pkg;1:${err}"
			fi

			if ! USE="-* ${use} perl_features_ithreads python_targets_${python_default_target:-"python3_13"}" \
					PERL_FEATURES='ithreads' \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
					virtual/libc \
					app-arch/bzip2 \
					app-arch/xz-utils \
					dev-lang/perl \
					dev-lang/python \
					dev-libs/libsodium \
					dev-perl/List-MoreUtils \
					sys-apps/baselayout \
					sys-apps/busybox \
					sys-apps/portage \
					sys-kernel/gentoo-sources
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;2:${err}"
			fi

			if ! USE="-* ${use} nls" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
						--with-pkg-use='sys-apps/net-tools hostname' \
						--with-pkg-use='sys-apps/coreutils -hostname' \
					virtual/libc \
					sys-apps/net-tools
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;3:${err}"
			fi
			if ! USE="-* ${use} nls" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
						--with-pkg-use='sys-apps/net-tools hostname' \
						--with-pkg-use='sys-apps/coreutils -hostname' \
					virtual/libc \
					sys-apps/coreutils
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;4:${err}"
			fi
			if ! USE="-* ${use} hostname nls python_single_target_${python_default_target} python_targets_${python_default_target}" \
					PYTHON_SINGLE_TARGET="${python_default_target}" \
					PYTHON_TARGETS="${python_default_target}" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
						--with-pkg-use='sys-apps/net-tools hostname' \
						--with-pkg-use='sys-apps/coreutils -hostname' \
						--with-pkg-use="app-editors/vim python_single_target_${python_default_target} python_targets_${python_default_target}" \
					virtual/libc \
					app-editors/vim-core \
					app-editors/vim
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;5:${err}"
			fi

			if ! USE="-* ${use} flex nls" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
					virtual/libc \
					app-arch/cpio \
					dev-libs/elfutils
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;6:${err}"
			fi

			# Requirement patched out for >=sys-devel/binutils-2.41
			#if [ "${ARCH}" = 'arm64' ]; then
			#	USE='gold'
			#fi
			if ! USE="-* ${alt_use} ${USE} python_targets_${python_default_target:-"python3_13"} pam tools" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
					virtual/libc \
					sys-libs/libcap
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;7:${err}"
			fi
		} | tee "${log_dir}"/buildpkg.cache.log

		# shellcheck disable=SC2031
		if [ $(( err )) -ne 0 ]; then
			echo >&2 "ERROR: ${failures}"
		fi

		unset USE ARCH failures  # rc

		# shellcheck disable=SC2031
		exit ${rc}
	)

	: $(( err = ${?} ))
	# shellcheck disable=SC2031
	: $(( rc = rc + err ))
	if [ $(( err )) -ne 0 ]; then
		# shellcheck disable=SC2031
		failures="${failures:+"${failures} "}init-pkg-cache:${err}"
	fi
fi

if [ "${update:-"0"}" = '1' ]; then
	if ! mkdir -p "${log_dir:="log"}"; then
		echo >&2 "FATAL: Could not create log directory '${log_dir}': ${?}"
		exit 1
	fi

	# Rebuild packages for host installation...

	# (unzip[natspec] depends on libnatspec, which depends on python:2.7,
	#  which depends on sqlite, which depends on unzip - disable this USE
	#  flag here to remove this circular dependency)

	# Adding awk squashes blank lines (which portage seems to like to add), but
	# adds buffering and so lengthy pauses before output is rendered.  Adding
	# 'stdbuf' intended to fix this - and did so partially - but also sometimes
	# lead to output being delayed indefinitely for long-running builds :(

	# shellcheck disable=SC2046
	#USE='-natspec pkg-config' \
	#stdbuf -o0 "./gentoo-build-pkg.docker \
	#		--buildpkg=y \
	#		--emptytree \
	#		--usepkg=y \
	#		--with-bdeps=y \
	#	$( # <- Syntax
	#		for pkg in /var/db/pkg/*/*; do
	#			pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
	#			if echo "${pkg}" | grep -Eq '^container-services/|/pkgconfig-'; then
	#				continue
	#			fi
	#			echo ">=${pkg}"
	#		done
	#	) --name 'buildpkg.hostpkgs.update' 2>&1 |
	#stdbuf -i0 -o0 awk 'BEGIN { RS = null ; ORS = "\n\n" } 1' |
	#tee "${log_dir}"/buildpkg.hostpkgs.update.log

	# Look for "build" gcc USE-flags in package.use only (or use defaults
	# above) ...
	#
	if ! [ -s /etc/portage/package.use/00_package.use ]; then
		if ! echo "${CFLAGS:-} ${CXXFLAGS:-}" |
				grep -Fqw \
					-e '-fgraphite' \
					-e '-fgraphite-identity' \
					-e '-floop-nest-optimize' \
					-e '-floop-parallelize-all'
		then
			gcc_use="$( # <- Syntax
				echo " ${use_essential_gcc} " |
					sed 's/ graphite / -graphite /g ; s/^ // ; s/ $//'
			)"
		fi
	else
		gcc_use="$( # <- Syntax
			sed 's/#.*$//' /etc/portage/package.use/00_package.use |
			tr -s '[:space:]' |
			grep -E '^\s?([<>=~]=?)?sys-devel/gcc' |
			cut -f 2- |
			xargs -n 1 echo |
			sort |
			uniq
		)"
	fi

	# shellcheck disable=SC2031
	if [ -z "${ARCH:-}" ]; then
		if command -v portageq >/dev/null 2>&1; then
			ARCH="${ARCH:-"$( portageq envvar ARCH )"}"
		else
			echo >&2 "WARN:  Cannot locate 'portageq' utility"
		fi
		if [ -z "${ARCH:-}" ]; then
			case "$( uname -m )" in
				aarch64)
					ARCH='arm64' ;;
				arm*)
					ARCH='arm' ;;
				x86_64)
					ARCH='amd64' ;;
				*)
					echo >&2 "FATAL: Unknown architecture '$( uname -m )'"
					exit 1
					;;
			esac
		fi
		readonly ARCH
	fi
	# Requirement patched out for >=sys-devel/binutils-2.41
	#if echo "${ARCH}" | grep -q -- 'arm'; then
	#	alt_use="${alt_use:+"${alt_use} "}gold"
	#fi

	# FIXME: sys-devel/gcc can be rebuilt in the midst of other packages, but
	#        if this enables 'lib-only' (which it shouldn't due to
	#        work-arounds) or if graphite/openmp *FLAGS are in effect but gcc
	#        it rebuilt without the apropriate USE flags to support these, then
	#        subsequent builds will break.  Therefore, let's exclude this
	#        package by default, as the host system version will be rebuilt if
	#        necessary by the post-pkgs step in any case...
	if [ -z "${exclude:-}" ] ||
			! echo " ${exclude} " |
				grep -Eq -- ' (sys-devel/)?gcc([-:][0-9][^ ]+)? '
	then
		exclude="${exclude:+"${exclude} "}sys-devel/gcc"
	fi

	# shellcheck disable=SC2046
	(
		# shellcheck disable=SC2030,SC2031
		export USE="-lib-only -natspec pkg-config ${gcc_use} ${alt_use}"
		{
			./gentoo-build-pkg.docker \
						--buildpkg=y \
						--emptytree \
						--usepkg=y \
						--with-bdeps=y \
						${exclude:+"--exclude=${exclude}"} \
					$( # <- Syntax
						[ -d /var/db/pkg ] && for pkg in /var/db/pkg/*/*; do
							pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
							# fam & gamin block each other, tend to have broken
							# downstream dependencies, and will be pulled-in as
							# necessary in any case;
							# We want to use more modern pkgconf in place of
							# legacy pkgconfig;
							# container-init packages will block their
							# namesakes providing actual binaries, so exclude
							# them also
							#
							if echo "${pkg}" | grep -Eq '^app-admin/(fam|gamin)-|^container-services/|/pkgconfig-|/-MERGING-'; then
								continue
							fi
							# Specify python packages at the level of, e.g.
							# '3.11*' rather than a more specific minor-version
							# or the major release only
							#
							if echo "${pkg}" | grep -q '^dev-lang/python'; then
								echo "=${pkg%"."*}*"
							else
								echo ">=${pkg}"
							fi
						done
					) --name 'buildpkg.hostpkgs.update' 2>&1 ||
				exit ${?}
		} | tee "${log_dir}"/buildpkg.hostpkgs.update.log
	)
	: $(( err = ${?} ))
	: $(( rc = rc + err ))
	failures="${failures:+"${failures} "}gentoo-build-pkg;hostpkgs:${err}"

	trap '' INT
	"${_command}" container ps -a |
			grep -qw -- 'buildpkg.hostpkgs.update$' &&
		"${_command}" container rm --volumes 'buildpkg.hostpkgs.update'
	trap - INT

	if [ $(( rc )) -eq 0 ]; then
		gcc_use='-* lib-only nptl openmp'

		# ... and look for 'deployment' gcc USE-flags in 05_host.use only (or
		# use the defaults above)
		#
		if [ -s /etc/portage/package.use/05_host.use ]; then
			gcc_use="$( # <- Syntax
				sed 's/#.*$//' /etc/portage/package.use/05_host.use |
				tr -s '[:space:]' |
				grep -E '^\s?([<>=~]=?)?sys-devel/gcc' |
				cut -f 2- |
				xargs -n 1 echo |
				sort |
				uniq
			)"
		fi
		(
			# Since dev-build/ninja gained app-alternatives/ninja, building
			# sys-devel/gcc also requires USE='reference' (or 'samurai')...
			#
			# shellcheck disable=SC2031
			export USE="${gcc_use} ${alt_use} reference python_targets_${python_default_target:-"python3_13"}"
			{
				./gentoo-build-pkg.docker \
							--buildpkg=y \
							--name 'buildpkg.hostpkgs.gcc.update' \
							--usepkg=y \
							--with-bdeps=y \
							--with-pkg-use='app-alternatives/ninja reference' \
							${exclude:+"--exclude=${exclude}"} \
						sys-devel/gcc 2>&1 ||
					exit ${?}
			} | tee "${log_dir}"/buildpkg.hostpkgs.gcc.update.log
		)
		: $(( err = ${?} ))
		: $(( rc = rc + err ))
		failures="${failures:+"${failures} "}gentoo-build-pkg;gcc:${err}"

		trap '' INT
		"${_command}" container ps -a |
				grep -qw -- 'buildpkg.hostpkgs.gcc.update$' &&
			"${_command}" container rm --volumes 'buildpkg.hostpkgs.gcc.update'
		trap - INT
	fi
fi

if [ "${system:-"0"}" = '1' ]; then
	if [ $(( pretend )) -ne 0 ]; then
		echo >&2 'Checking for updated packages ...'
		pretend='--pretend'
	else
		echo >&2 'Installing updated packages ...'
		pretend=''
	fi

	# With a trimmed-down world file which only contains leaf-packages and not
	# dependencies, running 'emerge @world' is not sufficient - we need to look
	# at what we already have installed as well...
	#
	if output="$( # <- Syntax
		# shellcheck disable=SC2046
		emerge \
					--binpkg-changed-deps=y \
					--binpkg-respect-use=y \
					--color=n \
					${exclude:+"--exclude=${exclude}"} \
					--newuse \
					--pretend \
					--tree \
					--update \
					--usepkg=y \
					--verbose-conflicts \
					--verbose=y \
					--with-bdeps=n \
				@world $(
						 [ -d /var/db/pkg ] &&
							find /var/db/pkg/ -mindepth 2 -maxdepth 2 -type d |
								grep -Fv -- '-MERGING-' |
								cut -d'/' -f 5-6 |
								sed 's/^/>=/'
					)
					# --usepkgonly and --deep are horribly broken :(
					#
					#--deep \
	)"; then
		echo "${output}" |
			grep -E '^\[binary\s+U[[:space:]~]+\]\s+' |
			cut -d']' -f 2- |
			sed 's/^\s\+// ; s/^/=/' |
			cut -d' ' -f 1 |
			xargs -r emerge \
						--binpkg-changed-deps=y \
						--binpkg-respect-use=y \
						--keep-going \
						--oneshot \
						${pretend:+"--pretend"} \
						--tree \
						--usepkg=y \
						--verbose-conflicts \
						--verbose=y \
						--with-bdeps=n
	fi
	: $(( err = ${?} ))
	: $(( rc = rc + err ))
	failures="${failures:+"${failures} "}emerge:${err}"
fi

[ -n "${trace:-}" ] && set +o xtrace

if [ $(( rc )) -ne 0 ]; then
	echo >&2 "ERROR: ${failures}"
fi

exit "${rc}"

# vi: set colorcolumn=80 noet sw=4 ts=4:
