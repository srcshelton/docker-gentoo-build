#! /bin/sh

set -eu

# Are we really POSIX sh?  If not, this might still work...
if set -o | grep -q -- 'pipefail'; then
	# shellcheck disable=SC3040
	set -o pipefail
fi

trace=${TRACE:-}

cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

basedir='.'
if [ -d ../docker-gentoo-build ]; then
	basedir='..'
fi
for script in \
	gentoo-build-kernel \
	gentoo-build-pkg \
	gentoo-build-svc \
	gentoo-init
do
	if ! [ -x "${script}.docker" ]; then
		echo >&2 "FATAL: Cannot locate container build tools"
		exit 1
	fi
done
unset script

docker='docker'
if command -v podman >/dev/null 2>&1; then
	docker='podman'
fi

# Allow a separate image directory for persistent images...
#tmp="$( $docker system info | grep 'imagestore:' | cut -d':' -f 2- | awk '{ print $1 }' )"
#if [ -n "${tmp}" ]; then
#	export IMAGE_ROOT="${tmp}"
#fi

kbuild_opt="${kbuild_opt:-"--config-from=config.gz --keep-build --no-patch --clang --llvm-unwind"}"
all=0
arg=''
force=0
haveargs=0
pkgcache=0
pretend=0
err=0
rc=0
rebuild=0
rebuildutils=0
skip=0
system=0
tools=1
update=0
case " ${*:-} " in
	*' -h '*|*' --help '*)
		printf >&2 'Usage: %s ' "$( basename "${0}" )"
		if [ -d "${basedir}/docker-dell" ]; then
			printf >&2 '[--rebuild-utilities] '
		fi
		echo >&2 "[--rebuild-images [--skip-build] [--no-tools] [--force] [--all]] [--init-pkg-cache] [--update-pkgs] [--update-system [--pretend]]"
		echo >&2
		echo >&2 "       kernel build options: kbuild_opt='${kbuild_opt}'"
		exit 0
		;;
esac

if [ $(( $( id -u ) )) -ne 0 ]; then
	echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
fi

for arg in ${@+"${@}"}; do
	case "${arg:-}" in
		--rebuild-utilities)
			rebuildutils=1
			haveargs=1
			;;
		--rebuild-images)
			rebuild=1
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
	rebuild=1
	update=1
	system=1
	# For safety
	pretend=1
fi
if [ $(( rebuild )) -ne 1 ]; then
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
else  # if [ $(( rebuild )) -eq 1 ]; then
	if [ $(( skip )) -eq 1 ]; then
		if [ "$( $docker image ls -n 'localhost/gentoo-build' | wc -l )" = '0' ]; then
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

[ -z "${trace:-}" ] || set -o xtrace

export TRACE="${CTRACE:-}" # Optinally enable child tracing

if [ "${rebuildutils:-0}" = '1' ]; then
	if ! [ -d "${basedir}/docker-dell" ]; then
		if [ $(( haveargs )) -ne 0 ]; then
			echo >&2 "FATAL: docker-dell tools not found on this system"
			exit 1
		fi
	else
		mkdir -p log

		if [ "$( $docker image ls -n 'localhost/dell-dsu' | wc -l )" = '0' ]; then
			"${basedir}"/docker-dell/dell.docker --dsu ${IMAGE_ROOT:+--root "${IMAGE_ROOT}"} \
				>> log/dell.docker.dsu.log 2>&1 &
			# shellcheck disable=SC3044
			disown 2>/dev/null || :  # doesn't exist in POSIX sh :(
		fi
		if [ "$( $docker image ls -n 'localhost/dell-ism' | wc -l )" = '0' ]; then
			"${basedir}"/docker-dell/dell.docker --ism ${IMAGE_ROOT:+--root "${IMAGE_ROOT}"} \
				>> log/dell.docker.ism.log 2>&1 &
			# shellcheck disable=SC3044
			disown 2>/dev/null || :  # doesn't exist in POSIX sh :(
		fi
	fi
fi

if [ "${rebuild:-0}" = '1' ]; then
	failures=''

	if ! mkdir -p log; then
		echo >&2 "FATAL: Could not create directory $( pwd )/log: ${?}"
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
		# shellcheck disable=SC2086
		if ! ./gentoo-build-svc.docker \
				${forceflag:+${forceflag} --rebuild} \
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
		ram=$(( $(
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

if [ "${pkgcache:-0}" = '1' ]; then
	# Build binary packages for 'init' stage installations (which aren't built
	# with --buildpkgs=y because at this stage we've not built our own compiler
	# or libraries)...

	(
		# shellcheck disable=SC2030
		failures=''
		# shellcheck disable=SC2030
		rc=0
		use=''
		image=''
		ARCH="${ARCH:-$( portageq envvar ARCH )}"

		for image in 'localhost/gentoo-stage3' 'localhost/gentoo-init'; do
			if [ "$( $docker image ls -n "${image}" | wc -l )" = '0' ]; then
				stage3_flags_file=''
				# shellcheck disable=SC1091
				. ./common/vars.sh
				eval "$(
					$docker container run \
							--rm \
							--entrypoint /bin/sh \
							--name 'buildpkg.stage3_flags.read' \
							--network none \
						"${image}" -c "cat ${stage3_flags_file}"
				)"
				if [ -n "${STAGE3_USE:-}" ]; then
					# Add 'symlink' USE flag to ensure that /usr/src/linux is
					# updated
					# FIXME: This flag also affects a small number of other
					#        ebuilds (possibly replacing bzip2 & gzip binaries)
					use="${STAGE3_USE} symlink"
					for flag in ${use}; do
						case "${flag}" in
							"${ARCH}"|readline|nls|static-libs|zstd)
								continue ;;
						esac
						# shellcheck disable=SC2030
						USE="${USE:+${USE} }${flag}"
					done
					break
				fi
				# shellcheck disable=SC2046
				unset $( set | grep '^STAGE3_' | cut -d'=' -f 1 )
			fi
		done
		if [ -z "${USE:-}" ]; then
			python_default_target=''
			# shellcheck disable=SC1091
			. ./common/vars.sh

			# Assume that python_default_target has the most recent/primary
			# version first...
			python_single_target="${python_default_target%% *}"
			use="
				${use_essential_gcc}
				acl
				bzip2
				crypt
				extra-filters
				jit
				lzma
				python
				  python_single_target_${python_single_target:-python3_10}
				  python_targets_${python_default_target:-python3_10}
				ssl symlink
				xml
			"
			USE=''
			for flag in ${use}; do
				USE="${USE:+${USE} }${flag}"
			done
		fi
		unset image
		use="${USE}"
		USE="-* ${use}"
		export USE

		{
			# shellcheck disable=SC2030
			if ! USE="-* ${use} nls readline static-libs zstd" \
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
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;1:${err}"
			fi

			if ! USE="-* ${use} static-libs" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
					virtual/libc \
					app-arch/bzip2 \
					app-arch/xz-utils \
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
			if ! USE="-* ${use} nls" \
				./gentoo-build-pkg.docker 2>&1 \
						--buildpkg=y \
						--name 'buildpkg.cache' \
						--usepkg=y \
						--with-bdeps=n \
						--with-pkg-use='sys-apps/net-tools hostname' \
						--with-pkg-use='sys-apps/coreutils -hostname' \
					virtual/libc \
					app-editors/vim-core \
					app-editors/vim
			then
				: $(( err = ${?} ))
				: $(( rc = rc + err ))
				failures="${failures:+"${failures} "}gentoo-build-pkg;5:${err}"
			fi

			if ! USE="-* ${use} nls" \
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

			if ! USE="-* pam tools" \
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
		} | tee log/buildpkg.cache.log

		# shellcheck disable=SC2031
		if [ $(( err )) -ne 0 ]; then
			echo >&2 "ERROR: ${failures}"
		fi
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

if [ "${update:-0}" = '1' ]; then
	# Rebuild packages for host installation...

	# (unzip[natspec] depends on libnatspec, which depends on python:2.7,
	#  which depends on sqlite, which depends on unzip - disable this USE
	#  flag here to remove this circular dependency)

	# Adding awk squashes blank lines (which portage seems to like to add), but
	# adds buffering and so lengthy pauses before output is rendered.  Adding
	# 'stdbuf' intended to fix this - and did so partially - but also sometimes
	# lead to output being delayed indefinitely for long-running builds :(

	# shellcheck disable=SC2046
	#USE="-natspec pkg-config" \
	#stdbuf -o0 "./gentoo-build-pkg.docker \
	#		--buildpkg=y \
	#		--emptytree \
	#		--usepkg=y \
	#		--with-bdeps=y \
	#	$(
	#		for pkg in /var/db/pkg/*/*; do
	#			pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
	#			if echo "${pkg}" | grep -Eq '^container/|/pkgconfig-'; then
	#				continue
	#			fi
	#			echo ">=${pkg}"
	#		done
	#	) --name 'buildpkg.hostpkgs.update' 2>&1 |
	#stdbuf -i0 -o0 awk 'BEGIN { RS = null ; ORS = "\n\n" } 1' |
	#tee log/buildpkg.hostpkgs.update.log

	# Look for "build" gcc USE-flags in package.use only (or use defaults above) ...
	if ! [ -s /etc/portage/package.use/package.use ]; then
		if [ -z "${use_essential_gcc:-}" ]; then
			# shellcheck disable=SC1091
			. ./common/vars.sh
		fi
		gcc_use="$(
			echo " ${use_essential_gcc} " |
				sed 's/ graphite / -graphite /g ; s/^ // ; s/ $//'
		)"
	else
		gcc_use="$(
			sed 's/#.*$//' /etc/portage/package.use/package.use |
			tr -s '[:space:]' |
			grep -E '^\s?([<>=~]=?)?sys-devel/gcc' |
			cut -f 2- |
			xargs -n 1 echo |
			sort |
			uniq
		)"
	fi
	# shellcheck disable=SC2046
	(
		# shellcheck disable=SC2030,SC2031
		export USE="-lib-only -natspec pkg-config ${gcc_use}"
		{
			./gentoo-build-pkg.docker \
						--buildpkg=y \
						--emptytree \
						--usepkg=y \
						--with-bdeps=y \
					$(
						for pkg in /var/db/pkg/*/*; do
							pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
							if echo "${pkg}" | grep -Eq '^app-admin/(fam|gamin)-|^container/|/pkgconfig-|/-MERGING-'; then
								continue
							fi
							if echo "${pkg}" | grep -q '^dev-lang/python'; then
								echo "=${pkg%.*}*"
							else
								echo ">=${pkg}"
							fi
						done
					) --name 'buildpkg.hostpkgs.update' 2>&1 ||
				exit ${?}
		} | tee log/buildpkg.hostpkgs.update.log
	)
	: $(( err = ${?} ))
	: $(( rc = rc + err ))
	failures="${failures:+"${failures} "}gentoo-build-pkg;hostpkgs:${err}"

	trap '' INT
	$docker container ps -a |
			grep -qw -- 'buildpkg.hostpkgs.update$' &&
		$docker container rm --volumes 'buildpkg.hostpkgs.update'
	trap - INT

	if [ $(( rc )) -eq 0 ]; then
		gcc_use="-* lib-only nptl openmp"
		# ... and look for "host" gcc USE-flags in host.use only (or use defaults)
		# FIXME: What about package.use.local?
		if [ -s /etc/portage/package.use/host.use ]; then
			gcc_use="$(
				sed 's/#.*$//' /etc/portage/package.use/host.use |
				tr -s '[:space:]' |
				grep -E '^\s?([<>=~]=?)?sys-devel/gcc' |
				cut -f 2- |
				xargs -n 1 echo |
				sort |
				uniq
			)"
		fi
		(
			# shellcheck disable=SC2031
			export USE="${gcc_use}"
			{
				./gentoo-build-pkg.docker \
							--buildpkg=y \
							--usepkg=y \
							--with-bdeps=y \
							--name 'buildpkg.hostpkgs.gcc.update' \
						sys-devel/gcc 2>&1 ||
					exit ${?}
			} | tee log/buildpkg.hostpkgs.gcc.update.log
		)
		: $(( err = ${?} ))
		: $(( rc = rc + err ))
		failures="${failures:+"${failures} "}gentoo-build-pkg;gcc:${err}"

		trap '' INT
		$docker container ps -a |
				grep -qw -- 'buildpkg.hostpkgs.gcc.update$' &&
			$docker container rm --volumes 'buildpkg.hostpkgs.gcc.update'
		trap - INT
	fi
fi

if [ "${system:-0}" = '1' ]; then
	if [ $(( pretend )) -ne 0 ]; then
		echo >&2 "Checking for updated packages ..."
		pretend='--pretend'
	else
		echo >&2 "Installing updated packages ..."
		pretend=''
	fi

	if output="$(
		emerge \
					--binpkg-changed-deps=y \
					--binpkg-respect-use=y \
					--color=n \
					--deep \
					--newuse \
					--pretend \
					--tree \
					--update \
					--usepkg=y \
					--verbose-conflicts \
					--verbose=y \
					--with-bdeps=n \
				@world
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
						${pretend:+'--pretend'} \
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

# vi: set colorcolumn=80:
