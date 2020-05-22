docker_setup() {
	export ARCH='amd64'
	export PKGHOST='docker'
	export PKGCACHE='/var/cache/portage/pkg'
	export PKGDIR="${PKGCACHE}/${ARCH}/${PKGHOST}" # /var/cache/portage/pkg/amd64/docker

	export DISTDIR="/var/cache/portage/dist"
	export PORT_LOGDIR="/var/log/portage"

	export REPOS="/var/db/repo"

	export args='' package='' extra='' name='' image="${IMAGE:-gentoo-build:latest}" rm=''

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

			elif [ "${image}" = '<next>' ]; then
				export image="${arg}"

			elif echo "${arg}" | grep -Eq -- '^-(n|-name)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${arg}" | grep -Fq '=' ; then
					export name="$( echo "${arg}" | cut -d'=' -f 2- )"
				else
					name='<next>'
				fi

			elif echo "${arg}" | grep -Eq -- '^-(i|-image)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${arg}" | grep -Fq -- '=' ; then
					export image="$( echo "${arg}" | cut -d'=' -f 2- )"
				else
					image='<next>'
				fi

			elif echo "${arg}" | grep -q -- '^-'; then
				args="${args:+${args} }${arg}"

			elif echo "${arg}" | grep -q -- '^@'; then
				extra="${extra:+${extra} }${arg}"

			elif echo "${arg}" | grep -Eq -- '((virtual|[a-z]{3,7}-[a-z]+)/)?[a-z0-9Z][a-zA-Z0-9_.+-]+$'; then
				# Currently category general names are between 3 and 7 ("gnustep") letters,
				# Package names start with [023469Z] or lower-case ...
				if [ -z "${package:-}" ]; then
					export package="${arg}"
				else
					export extra="${extra:+${extra} }${arg}"
				fi

			else
				echo "WARN:  Unknown argument '${arg}'"
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

	export package_version="$( echo "${package}" | cut -d':' -f 2- )"
	export package="$( echo "${package}" | cut -d':' -f 1 )"

	package_name="${package//+/plus}"
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

	docker ps | grep -qw -- "${name:-${container}}$" && docker stop -t 2 "${name:-${container}}"
	docker ps -a | grep -qw -- "${name:-${container}}$" && docker rm -v "${name:-${container}}"

	rc=0

	# --privileged is required for portage sandboxing,
	# PTRACE capability is required to build glibc.
	#
	# shellcheck disable=SC2086
	docker run \
		${ROOT:+--env ROOT --env SYSROOT --env PORTAGE_CONFIGROOT} \
		${TERM:+--env TERM} \
		${USE:+--env USE} \
		${ACCEPT_KEYWORDS:+--env ACCEPT_KEYWORDS} \
		${ACCEPT_LICENSE:+--env ACCEPT_LICENSE} \
		${FEATURES:+--env FEATURES} \
		${DOCKER_VARS:-} \
		--mount type=bind,source=/var/cache/portage/pkg/amd64/xeon_e56.docker,destination=/var/cache/portage/pkg/amd64/docker \
		--mount type=bind,source=/var/cache/portage/dist,destination=/var/cache/portage/dist \
		--mount type=bind,source=/var/log/portage,destination=/var/log/portage \
		--mount type=bind,source=/var/db/repo/gentoo,destination=/var/db/repo/gentoo,readonly \
		--mount type=bind,source=/var/db/repo/srcshelton,destination=/var/db/repo/srcshelton,readonly \
		${DOCKER_EXTRA_MOUNTS:-} \
		${DOCKER_VOLUMES:-} \
		--privileged \
		--cap-add SYS_PTRACE \
		${DOCKER_DEVICES:-} \
		${rm} \
		--name "${name:-${container}}" \
		${DOCKER_INTERACTIVE:+--interactive --tty} \
		${DOCKER_ENTRYPOINT:+--entrypoint ${DOCKER_ENTRYPOINT}} \
		"${image:-${IMAGE:-gentoo-build:latest}}" \
			"${@:-}"
	rc=${?}
	#rc=$( docker inspect --format='{{.State.ExitCode}}' "${name:-${container}}" )

	set +o xtrace

	return ${rc}
} # docker_run

# Invokes container launch with package-build arguments
#
docker_build_pkg() {
	[ -n "${USE:-}" ] && echo "USE override: ${USE}"

	echo "Building package '${package}' ${extra:+plus additional packages '${extra}' }into container '${name:-${container}}' ..."

	docker_run "=${package}" ${extra:-} ${args:-}

	return ${?}
} # docker_build_pkg

# Garbage collect
#
docker_prune() {
	#docker system prune --all --filter 'until=24h' --filter 'label!=build' --filter 'label!=build.system' --force # --volumes
	# volumes can't be pruned with a filter :(
	#docker volume prune --force

	docker ps | rev | cut -d' ' -f 1 | rev | grep -- '_' | xargs -r docker stop -t 2
	docker ps -a | rev | cut -d' ' -f 1 | rev | grep -- '_' | xargs -r docker rm -v

	docker image ls | grep -- '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r docker image rm

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

# vi: set syntax=sh:
