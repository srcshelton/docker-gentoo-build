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

#export USE="-libressl"

# Allow a separate image directory for persistent images...
#tmp="$( $docker system info | grep 'imagestore:' | cut -d':' -f 2- | awk '{ print $1 }' )"
#if [ -n "${tmp}" ]; then
#	export IMAGE_ROOT="${tmp}"
#fi

arg=''
haveargs=0
rebuildutils=0
rebuild=0
update=0
system=0
pretend=0
force=0
rc=0
case " ${*:-} " in
	*' -h '*|*' --help '*)
		if [ -d "${basedir}/docker-dell" ]; then
			echo >&2 "Usage: $( basename "${0}" ) [--rebuild-utilities] [--rebuild-images [--force]] [--update-pkgs] [--update-system [--pretend]]"
		else
			echo >&2 "Usage: $( basename "${0}" ) [--rebuild-images [--force]] [--update-pkgs] [--update-system [--pretend]]"
		fi
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
		-p|--pretend)
			pretend=1
			;;
		-f|--force)
			force=1
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

		[ "$( $docker image ls 'localhost/dell-dsu' | wc -l )" = '2' ] ||
			"${basedir}"/docker-dell/dell.docker --dsu  \
				>> log/dell.docker.dsu.log 2>&1 &
		[ "$( $docker image ls 'localhost/dell-ism' | wc -l )" = '2' ] ||
			"${basedir}"/docker-dell/dell.docker --ism ${IMAGE_ROOT:+--storage-opt="" --root "${IMAGE_ROOT}"} \
				>> log/dell.docker.ism.log 2>&1 &
	fi
fi

if [ "${rebuild:-0}" = '1' ]; then
	mkdir -p log

	if "${basedir}"/docker-gentoo-build/gentoo-init.docker; then
		if [ $(( force )) -eq 0 ]; then
			"${basedir}"/docker-gentoo-build/gentoo-build-svc.docker all ||
			: $(( rc = rc + ${?} ))
			"${basedir}"/docker-gentoo-build/gentoo-web/gentoo-build-web.docker ||
			: $(( rc = rc + ${?} ))
		else
			"${basedir}"/docker-gentoo-build/gentoo-build-svc.docker --force all ||
			: $(( rc = rc + ${?} ))
			"${basedir}"/docker-gentoo-build/gentoo-web/gentoo-build-web.docker --force ||
			: $(( rc = rc + ${?} ))
		fi
		#"${basedir}"/docker-gentoo-build/gentoo-build-kernel.docker --keep-build --config /proc/config.gz ||
		"${basedir}"/docker-gentoo-build/gentoo-build-kernel.docker --keep-build --clang ||
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
	#
	# shellcheck disable=SC2046
	USE="-natspec -libressl" \
	"${basedir}"/docker-gentoo-build/gentoo-build-pkg.docker \
			--buildpkg=y \
			--emptytree \
			--usepkg=y \
			--with-bdeps=y \
		$(
			for pkg in /var/db/pkg/*/*; do
				pkg="$( echo "${pkg}" | rev | cut -d'/' -f 1-2 | rev )"
				if echo "${pkg}" | grep -q '^container/'; then
					continue
				fi
				echo ">=${pkg}"
			done
		) --name 'buildpkg.hostpkgs.update' 2>&1 |
	awk 'BEGIN { RS = null ; ORS = "\n\n" } 1' |
	tee log/buildpkg.hostpkgs.update.log
	: $(( rc = rc + ${?} ))

	trap '' INT
	$docker container ps -a |
			grep -qw -- 'buildpkg.hostpkgs.update$' &&
		$docker container rm --volumes 'buildpkg.hostpkgs.update'
	trap - INT
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
			--exclude libressl \
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
			--exclude libressl \
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
