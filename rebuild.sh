#! /bin/sh

set -eu

trace=${TRACE:-}

cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

basedir=''
if [ -d docker-gentoo-build ]; then
	basedir='.'
elif [ -d ../docker-gentoo-build ]; then
	basedir='..'
else
	echo >&2 "FATAL: Cannot locate container build tools"
	exit 1
fi

docker='docker'
if command -v podman >/dev/null 2>&1; then
	docker='podman'
fi

# Allow a separate image directory for persistent images...
#tmp="$( $docker system info | grep 'imagestore:' | cut -d':' -f 2- | awk '{ print $1 }' )"
#if [ -n "${tmp}" ]; then
#	export IMAGE_ROOT="${tmp}"
#fi

kbuild_opt="${kbuild_opt:---config-from=/proc/config.gz --keep-build --no-patch --clang --llvm-unwind}"
arg=''
all=0
force=0
haveargs=0
pretend=0
rc=0
rebuild=0
rebuildutils=0
system=0
update=0
case " ${*:-} " in
	*' -h '*|*' --help '*)
		if [ -d "${basedir}/docker-dell" ]; then
			echo >&2 "Usage: $( basename "${0}" ) [--rebuild-utilities] [--rebuild-images [--force] [--all]] [--update-pkgs] [--update-system [--pretend]]"
		else
			echo >&2 "Usage: $( basename "${0}" ) [--rebuild-images [--force] [--all]] [--update-pkgs] [--update-system [--pretend]]"
		fi
		echo >&2
		echo >&2 "       kernel build options: kbuild_opt='${kbuild_opt}'"
		exit 0
		;;
esac
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
		--update-pkgs)
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

if [ $(( $( id -u ) )) -ne 0 ]; then
	echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
fi

[ -z "${trace:-}" ] || set -o xtrace

export TRACE="${CTRACE:-}" # Optinally enable child tracing

if [ "${rebuildutils:-0}" = '1' ]; then
	if ! [ -d "${basedir}/docker-dell" ]; then
		echo >&2 "FATAL: docker-dell tools not found on this system"
		exit 1
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
	mkdir -p log

	if "${basedir}"/docker-gentoo-build/gentoo-init.docker; then
		forceflag=''
		if ! [ $(( force )) -eq 0 ]; then
			forceflag='--force'
		fi
		selection='--installed'
		if ! [ $(( all )) -eq 0 ]; then
			selection='--all'
		fi
		"${basedir}"/docker-gentoo-build/gentoo-build-svc.docker \
				${forceflag:+${forceflag} --rebuild} \
				"${selection}" ||
			: $(( rc = rc + ${?} ))
		if [ -x "${basedir}"/docker-gentoo-build/gentoo-web/gentoo-build-web.docker ]; then
			"${basedir}"/docker-gentoo-build/gentoo-web/gentoo-build-web.docker \
					${forceflag} ||
				: $(( rc = rc + ${?} ))
		fi
		# shellcheck disable=SC2086
		"${basedir}"/docker-gentoo-build/gentoo-build-kernel.docker \
				${kbuild_opt:-} ||
			: $(( rc = rc + ${?} ))
	else
		: $(( rc = rc + ${?} ))
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
	#stdbuf -o0 "${basedir}"/docker-gentoo-build/gentoo-build-pkg.docker \
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

	gcc_use="-fortran -graphite nptl openmp pch sanitize ssp vtv zstd"
	# Look for "build" gcc USE-flags in package.use only (or use defaults above) ...
	if [ -s /etc/portage/package.use/package.use ]; then
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
	USE="-lib-only -natspec pkg-config ${gcc_use}" \
	"${basedir}"/docker-gentoo-build/gentoo-build-pkg.docker \
			--buildpkg=y \
			--emptytree \
			--usepkg=y \
			--with-bdeps=y \
		$(
			for pkg in /var/db/pkg/*/*; do
				pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
				if echo "${pkg}" | grep -Eq '^container/|/pkgconfig-'; then
					continue
				fi
				echo ">=${pkg}"
			done
		) --name 'buildpkg.hostpkgs.update' 2>&1 |
	tee log/buildpkg.hostpkgs.update.log
	: $(( rc = rc + ${?} ))

	trap '' INT
	$docker container ps -a |
			grep -qw -- 'buildpkg.hostpkgs.update$' &&
		$docker container rm --volumes 'buildpkg.hostpkgs.update'
	trap - INT

	if [ $(( rc )) -eq 0 ]; then
		gcc_use="-* lib-only nptl"
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
		USE="${gcc_use}" \
		"${basedir}"/docker-gentoo-build/gentoo-build-pkg.docker \
				--buildpkg=y \
				--usepkg=y \
				--with-bdeps=y \
				--name 'buildpkg.hostpkgs.gcc.update' \
			sys-devel/gcc 2>&1 |
		tee log/buildpkg.hostpkgs.gcc.update.log
		: $(( rc = rc + ${?} ))

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

	# shellcheck disable=SC2086
	emerge \
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
		@world |
	grep -E '^\[binary\s+U[[:space:]~]+\]\s+' |
	cut -d']' -f 2- |
	sed 's/^\s\+// ; s/^/=/' |
	cut -d' ' -f 1 |
	xargs -r emerge \
			--binpkg-respect-use=y \
			--tree \
			--usepkg=y \
			--verbose-conflicts \
			--verbose=y \
			--with-bdeps=n \
			${pretend:-}
	: $(( rc = rc + ${?} ))
fi

[ -n "${trace:-}" ] && set +o xtrace

# shellcheck disable=SC2086
exit ${rc}
