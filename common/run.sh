
debug=${DEBUG:-}
trace=${TRACE:-}

die() {
	printf >&2 'FATAL: %s\n' "${*:-Unknown error}"
	exit 1
} # die

warn() {
	[ -z "${*:-}" ] && echo || printf >&2 'WARN:  %s\n' "${*}"
} # warn

print() {
	if [ -n "${DEBUG:-}" ]; then
		[ -z "${*:-}" ] && echo || printf >&2 'DEBUG: %s\n' "${*}"
	fi
} # print

docker_setup() {
	export ARCH='amd64'
	export PKGHOST='docker'
	export PKGCACHE='/var/cache/portage/pkg'
	export PKGDIR="${PKGCACHE}/${ARCH}/${PKGHOST}" # /var/cache/portage/pkg/amd64/docker

	export DISTDIR="/var/cache/portage/dist"
	export PORT_LOGDIR="/var/log/portage"

	export REPOS="/var/db/repo"

	export args='' package='' repo='' extra='' name='' image="${IMAGE:-gentoo-build:latest}" rm=''

	return 0
} # docker_setup

# Sets image, name, package, extra, and args based on arguments
#
docker_parse() {
	arg=''

	if [ -z "${*:-}" ]; then
		package='app-shells/bash'
	else
		for arg in "${@}"; do
			if echo "${arg}" | grep -Eq -- '^-(h|-help)$'; then
				echo >&2 "Usage: $( basename "${0}" ) [--name <container name>] [--image <source image>] <package> [emerge_args]"
				exit 0

			elif [ "${name}" = '<next>' ]; then
				export name="${arg}"
				print "Setting container name to '${name}' in $( basename "${0}" )"

			elif [ "${image}" = '<next>' ]; then
				export image="${arg}"
				print "Setting source image to '${image}' in $( basename "${0}" )"

			elif echo "${arg}" | grep -Eq -- '^-(n|-name)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${arg}" | grep -Fq '=' ; then
					export name="$( echo "${arg}" | cut -d'=' -f 2- )"
					print "Setting container name to '${name}' in $( basename "${0}" )"
				else
					name='<next>'
				fi

			elif echo "${arg}" | grep -Eq -- '^-(i|-image)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${arg}" | grep -Fq -- '=' ; then
					export image="$( echo "${arg}" | cut -d'=' -f 2- )"
					print "Setting source image to '${image}' in $( basename "${0}" )"
				else
					image='<next>'
				fi

			elif echo "${arg}" | grep -q -- '^-'; then
				args="${args:+${args} }${arg}"
				print "Adding argument '${arg}'"

			elif echo "${arg}" | grep -q -- '^@'; then
				extra="${extra:+${extra} }${arg}"
				print "Adding extra argument '${arg}'"

			elif echo "${arg}" | grep -Eq -- '((virtual|[a-z]{3,7}-[a-z]+)/)?[a-z0-9Z][a-zA-Z0-9_.+-]+(:[0-9.]+)?(::.*)?$'; then
				# Currently category general names are between 3 and 7 ("gnustep") letters,
				# Package names start with [023469Z] or lower-case ...
				if [ -z "${package:-}" ]; then
					export package="${arg%::*}"
					print "Setting package to '${package}'"
					if echo "${arg}" | grep -Fq -- '::'; then
						export repo="${arg#*::}"
						print "... and repo to '${repo}'"
					fi
				else
					export extra="${extra:+${extra} }${arg}"
					print "Adding extra argument '${arg}'"
				fi

			else
				warn "Unknown argument '${arg}'"
			fi
		done
		if [ "${name}" = '<next>' ]; then
			export name=''
		else
			:
		fi
		if [ "${image}" = '<next>' ]; then
			export image=''
		else
			:
		fi
	fi

	return 0
} # docker_parse

# Validates package and sets container
#
docker_resolve() {
	package="${1:-${package}}"

	if ! [ -x "$( type -pf versionsort )" ]; then
		echo "FATAL: 'versionsort' not found - please install package 'app-portage/eix'"
		exit 1
	fi

	echo "Resolving name '${package}' ..."

	package="$(
		equery --no-pipe --no-color list --portage-tree --overlay-tree "${package}" |
		grep -- '^\[' |
		grep -v -- '^\[...\] \[.[-~]\] ' |
		cut -d']' -f 3- |
		cut -d' ' -f 2- |
		sort -V |
		tail -n 1
	)" || return 1
	[ -n "${package:-}" ] || return 1

	export package="$( echo "${package}" | cut -d':' -f 1 )"
	export package_version="$( versionsort "${package}" )"
	package_name="${package%-${package_version}}"
	export package_name="${package_name//+/plus}"
	export container="buildpkg.${package_name/\//.}"

	return 0
} # docker_resolve

# Launches container
#
docker_run() {
	[ -n "${name:-}" ] || rm='--rm'

	if [ -z "${name:-}" -a -z "${container:-}" ]; then
		echo >&2 "ERROR: One of 'name' or 'container' must be set"
		return 1
	fi

	#set -o xtrace

	$docker ps | grep -qw -- "${name:-${container}}$" && $docker stop -t 2 "${name:-${container}}"
	$docker ps -a | grep -qw -- "${name:-${container}}$" && $docker rm -v "${name:-${container}}"

	rc=0

	# --privileged is required for portage sandboxing... or alternatively
	# execute 'emerge' with:
	# FEATURES="-ipc-sandbox -mount-sandbox -network-sandbox -pid-sandbox"
	#
	# PTRACE capability is required to build glibc (but as-of podman-2.0.0
	# it is not permissible to specify capabilities with '--privileged')
	#
	# shellcheck disable=SC2086
	$docker run \
		${ROOT:+--env ROOT --env SYSROOT --env PORTAGE_CONFIGROOT} \
		${TERM:+--env TERM} \
		${USE:+--env USE} \
		${ACCEPT_KEYWORDS:+--env ACCEPT_KEYWORDS} \
		${ACCEPT_LICENSE:+--env ACCEPT_LICENSE} \
		${FEATURES:+--env FEATURES} \
		${DOCKER_VARS:-} \
		--mount type=bind,source=/var/cache/portage/pkg/amd64/xeon_e56.docker/,destination=/var/cache/portage/pkg/amd64/docker \
		--mount type=bind,source=/var/cache/portage/dist/,destination=/var/cache/portage/dist \
		--mount type=bind,source=/var/log/portage/,destination=/var/log/portage \
		--mount type=bind,source=/var/db/repo/gentoo/,destination=/var/db/repo/gentoo${docker_readonly:+,${docker_readonly}} \
		--mount type=bind,source=/var/db/repo/srcshelton/,destination=/var/db/repo/srcshelton${docker_readonly:+,${docker_readonly}} \
		--mount type=bind,source=/var/db/repo/container/,destination=/var/db/repo/container${docker_readonly:+,${docker_readonly}} \
		--mount type=bind,source=/etc/portage/repos.conf/,destination=/etc/portage/repos.conf${docker_readonly:+,${docker_readonly}} \
		${DEV_MODE:+--volume ./gentoo-base/entrypoint.sh.build:/usr/libexec/entrypoint.sh:ro} \
		${DOCKER_EXTRA_MOUNTS:-} \
		${DOCKER_VOLUMES:-} \
		--privileged \
		${DOCKER_DEVICES:-} \
		${rm} \
		--name "${name:-${container}}" \
		${DOCKER_INTERACTIVE:+--interactive --tty} \
		${DOCKER_ENTRYPOINT:+--entrypoint ${DOCKER_ENTRYPOINT}} \
		"${image:-${IMAGE:-gentoo-build:latest}}" \
			${DOCKER_CMD:-${@}}
	rc=${?}
	#rc=$( $docker inspect --format='{{.State.ExitCode}}' "${name:-${container}}" )

	set +o xtrace

	return ${rc}
} # docker_run

# Invokes container launch with package-build arguments
#
docker_build_pkg() {
	[ -n "${USE:-}" ] && echo "USE override: ${USE}"

	echo "Building package '${package}' ${extra:+plus additional packages '${extra}' }into container '${name:-${container}}' ..."

	docker_run "=${package}${repo:+::${repo}}" ${extra:-} ${args:-}

	return ${?}
} # docker_build_pkg

# Garbage collect
#
docker_prune() {
	#$docker system prune --all --filter 'until=24h' --filter 'label!=build' --filter 'label!=build.system' --force # --volumes
	# volumes can't be pruned with a filter :(
	#$docker volume prune --force

	$docker ps | rev | cut -d' ' -f 1 | rev | grep -- '_' | xargs -r $docker stop -t 2
	$docker ps -a | rev | cut -d' ' -f 1 | rev | grep -- '_' | xargs -r $docker rm -v

	$docker image ls | grep -- '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r $docker image rm

	return 0
} # docker_prune

# Default entrypoint
#
docker_build() {
	if [ -z "${*:-}" ]; then
		echo "WARN:  No options passed to 'docker_build()'"
	else
		:
	fi

	docker_setup
	docker_parse "${@:-}"
	docker_resolve
	docker_build_pkg
	#docker_prune

	return ${?}
} # docker_build

if ! echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	if [ -n "${IMAGE:-}" ]; then
		echo "Using default image '${IMAGE}'"
	else
		echo >&2 "WARN:  No default '\${IMAGE}' specified"
	fi
fi

if type -pf podman >/dev/null 2>&1; then
	docker='podman'
	docker_readonly='ro=true'
	#extra_build_args='--format docker'
fi

# vi: set syntax=sh:
