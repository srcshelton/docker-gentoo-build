#! /usr/bin/env bash

# TODO: Consider how to switch from hard-coded 'gentoo-base' to using
# ${base_dir}, given that all references to ${base_dir} are relative, so it's
# of little value without incorporating ${PWD} into its value - which means
# that the current working directory must be correct when 'common/vars.sh' is
# invoked.
# Alternatively, it could incorporate a fixed installation-directory
# (conventionally '/opt/containers/docker-gentoo-build'), if one were defined
# or configured...

# This script now requires 'bash' rather than simply 'sh' in order to gain
# array-handling capability...

# Tiny
#: "${PODMAN_MEMORY_RESERVATION:=256m}"
#: "${PODMAN_MEMORY_LIMIT:=512m}"
#: "${PODMAN_SWAP_LIMIT:=1g}"
# Small
#: "${PODMAN_MEMORY_RESERVATION:=512m}"
#: "${PODMAN_MEMORY_LIMIT:=1g}"
#: "${PODMAN_SWAP_LIMIT:=2g}"
# Medium
#: "${PODMAN_MEMORY_RESERVATION:=1g}"
#: "${PODMAN_MEMORY_LIMIT:=2g}"
#: "${PODMAN_SWAP_LIMIT:=3g}"
# Large
#: "${PODMAN_MEMORY_RESERVATION:=2g}"
#: "${PODMAN_MEMORY_LIMIT:=4g}"
#: "${PODMAN_SWAP_LIMIT:=6g}"
# Extra-Large
#: "${PODMAN_MEMORY_RESERVATION:=4g}"
#: "${PODMAN_MEMORY_LIMIT:=8g}"
#: "${PODMAN_SWAP_LIMIT:=11g}"
# XXL
: "${PODMAN_MEMORY_RESERVATION:=8g}"
: "${PODMAN_MEMORY_LIMIT:=16g}"
: "${PODMAN_SWAP_LIMIT:=20g}"

# shellcheck disable=SC2034
debug=${DEBUG:-}
trace=${TRACE:-}

output() {
	if [ -z "${*:-}" ]; then
		echo
	else
		echo -e "${*:-}"
	fi
}  # output

die() {
	output >&2 "FATAL: ${*:-Unknown error}"
	exit 1
}  # die

error() {
	if [ -z "${*:-}" ]; then
		output >&2
	else
		output >&2 "ERROR: ${*}"
	fi
	return 1
}  # error

warn() {
	if [ -z "${*:-}" ]; then
		output >&2
	else
		output >&2 "WARN:  ${*}"
	fi
}  # warn

note() {
	if [ -z "${*:-}" ]; then
		output >&2
	else
		output >&2 "NOTE:  ${*}"
	fi
}  # note

info() {
	if [ -z "${*:-}" ]; then
		output
	else
		output "INFO:  ${*}"
	fi
}  # info

print() {
	if [ -n "${DEBUG:-}" ]; then
		if [ -z "${*:-}" ]; then
			output >&2
		else
			output >&2 "DEBUG: ${*}"
		fi
		return 0
	# Unhelpful with 'set -e' ...
	#else
	#	return 1
	fi
}  # print

export -f output die error warn note info print

#[ -n "${trace:-}" ] && set -o xtrace

if [[ "$( uname -s )" == 'Darwin' ]]; then
	readlink() {
		perl -MCwd=abs_path -le 'print abs_path readlink(shift);' "${2}"
	}  # readlink
fi

# Mostly no longer needed, with Dockerfile.env ...
#
docker_setup() {
	export -a args=() extra=()
	export package='' package_version='' package_name='' repo=''
	export name='' container_name='' image="${IMAGE:-gentoo-build:latest}"

	# 'docker_arch' is the 'ARCH' component of Docker's 'platform' string, and
	# is used to ensure that the correct image is pulled when multi-arch images
	# are employed.
	#
	# 'arch' is the default system architecutre, as featured in the Gentoo
	# ACCEPT_KEYWORDS declarations - for all permissible values, see
	# the values of the portage 'USE_EXPAND_VALUES_ARCH' variable currently:
	#
	# alpha amd64 amd64-fbsd amd64-linux arm arm64 arm64-macos hppa ia64 m68k
	# mips ppc ppc64 ppc64-linux ppc-macos riscv s390 sparc sparc64-solaris
	# sparc-solaris x64-cygwin x64-macos x64-solaris x64-winnt x86 x86-fbsd
	# x86-linux x86-solaris x86-winnt
	#
	# If ARCH is set, this will be used as an override in preference to the
	# values defained below:
	#

	# shellcheck disable=SC2034
	case "$( uname -m )" in
		aarch64|arm64)
			docker_arch='arm64'
			arch='arm64'
			profile='17.0'
			chost='aarch64-unknown-linux-gnu'  # default
			#chost='aarch64-pc-linux-gnu'
			;;
		armv6l)
			docker_arch='amd/v6'
			arch='arm'
			profile='17.0/armv6j'
			chost='armv6j-hardfloat-linux-gnueabihf'
			;;
		arm7l)
			docker_arch='amd/v7'
			arch='arm'
			profile='17.0/armv7a'
			chost='armv7a-hardfloat-linux-gnueabihf'
			;;
		i386|i686)  # Untested!
			docker_arch='i386'
			arch='x86'
			profile='17.0'
			chost='i686-pc-linux-gnu'
			;;
		x86_64|amd64)
			docker_arch='amd64'
			arch='amd64'
			profile='17.1/no-multilib'
			chost='x86_64-pc-linux-gnu'
			;;
		*)
			die "Unknown architecture '$( uname -m )'"
			;;
	esac

	return 0
}  # docker_setup

# Sets image, name, package, extra, and args based on arguments
#
# FIXME: This is *massively* broken for arguments with spaces - reimplement in
#        bash with array support?
#
docker_parse() {
	local dp_arg=''

	if [ -z "${*:-}" ]; then
		package='app-shells/bash'
	else
		for dp_arg in "${@}"; do
			if echo "${dp_arg}" | grep -Eq -- '^-(h|-help)$'; then
				output >&2 "Usage: $( basename -- "${0#-}" ) [--name <container name>] [--image <source image>] <package> [emerge_args]"
				exit 0

			elif [ "${name}" = '<next>' ]; then
				name="${dp_arg}"
				print "Setting container name to '${name}' in $( basename -- "${0#-}" )"

			elif [ "${image}" = '<next>' ]; then
				image="${dp_arg}"
				print "Setting source image to '${image}' in $( basename -- "${0#-}" )"

			elif echo "${dp_arg}" | grep -Eq -- '^-(n|-name)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${dp_arg}" | grep -Fq '=' ; then
					name="$( echo "${dp_arg}" | cut -d'=' -f 2- )"
					print "Setting container name to '${name}' in $( basename -- "${0#-}" )"
				else
					name='<next>'
				fi

			elif echo "${dp_arg}" | grep -Eq -- '^-(i|-image)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'; then
				if echo "${dp_arg}" | grep -Fq -- '=' ; then
					image="$( echo "${dp_arg}" | cut -d'=' -f 2- )"
					print "Setting source image to '${image}' in $( basename -- "${0#-}" )"
				else
					image='<next>'
				fi

			elif echo "${dp_arg}" | grep -q -- '^-'; then
				#args="${args:+${args} }${dp_arg}"
				args+=( "${dp_arg}" )
				print "Adding argument '${dp_arg}'"

			elif echo "${dp_arg}" | grep -q -- '^@'; then
				#extra="${extra:+${extra} }${dp_arg}"
				extra+=( "${dp_arg}" )
				print "Adding extra argument '${dp_arg}'"

			elif echo "${dp_arg}" | grep -Eq -- '((virtual|[a-z]{3,7}-[a-z]+)/)?[a-z0-9Z][a-zA-Z0-9_.+-]+\*?(:[0-9.]+\*?)?(::.*)?$'; then
				# Currently category general names are between 3 and 7 ("gnustep") letters,
				# Package names start with [023469Z] or lower-case ...
				if [ -z "${package:-}" ]; then
					package="${dp_arg%::*}"
					print "Setting package to '${package}'"
					if echo "${dp_arg}" | grep -Fq -- '::'; then
						repo="${dp_arg#*::}"
						print "... and repo to '${repo}'"
					fi
				else
					#extra="${extra:+${extra} }${dp_arg}"
					extra+=( "${dp_arg}" )
					print "Adding extra argument '${dp_arg}'"
				fi

			else
				warn "Unknown argument '${dp_arg}'"
			fi
		done
		if [ "${name}" = '<next>' ]; then
			name=''
		fi
		if [ "${image}" = '<next>' ]; then
			image=''
		fi

		export args repo extra name image
	fi

	export package

	unset dp_arg

	return 0
}  # docker_parse

# Validates package and sets container
#
docker_resolve() {
	local dr_package="${1:-${package}}"
	local prefix="${2:-buildpkg}"
	local dr_name=''

	if ! {
		[ -x "$( command -v versionsort )" ] &&
		[ -x "$( command -v equery )" ]
	}; then
		# On non-Gentoo systems we need to build 'eix' (for 'versionsort') and
		# 'equery' into a container, and then call that to acquire "proper"
		# package-version handling facilities.
		# shellcheck disable=SC2086
		if
			$docker ${DOCKER_VARS:-} image ls localhost/gentoo-helper:latest |
			grep -Eq -- '^(localhost/)?([^.]+\.)?gentoo-helper'
		then
			# shellcheck disable=SC2032  # Huh?
			versionsort() {
				local result=''
				local -i rc=0

				result="$(
					$docker container run \
							--rm \
							--name='portage-helper' \
							--network=none \
						gentoo-helper versionsort "${@:-}"
				)" || rc="${?}"

				print "versionsort returned '${result}': ${rc}"
				echo -n "${result}"

				return "${rc}"
			}  # versionsort
			export -f versionsort

			equery() {
				local result=''
				local -i rc=0

				# We'll execute this container via docker_run rather than
				# by direct invocation, so that we get all of the necessary
				# repo directories mounted...
				result="$(
					BUILD_CONTAINER=0 \
					NO_MEMORY_LIMITS=1 \
					image='' \
					IMAGE='localhost/gentoo-helper:latest' \
					container_name='gentoo-helper' \
						docker_run equery "${@:-}"
				)" || rc="${?}"

				print "equery returned '${result}': ${?}"
				echo "${result}"

				return "${rc}"
			}  # equery
			export -f equery
		else
			# Before we have that (and to make building a container for those
			# tools easier) let's offer a best-effort, albeit limited,
			# replacement...
			#
			versionsort() {
				if [[ "${1:-}" == '-n' ]]; then
					shift
				fi
				echo "${@:-}" |
					xargs -n 1 |
					sed 's/^.*[a-z]-\([0-9].*\)$/\1/' |
					sort -V
			}  # versionsort
			export -f versionsort
			equery() {
				local -a args=()
				local arg='' repopath='' cat='' pkg='' eb=''
				local slot='' masked='' keyworded=''

				if [ -z "${arch:-}" ]; then
					docker_setup
				fi

				args=( "${@:-}" )
				set --
				for arg in "${args[@]:-}"; do
					case "${arg}" in
						--*) : ;;
						list) : ;;
						*) set -- "${@}" "${arg}" ;;
					esac
				done

				# Assume we also lack 'portageq' ...
				if [ -d /var/db/repos ]; then
					repopath='/var/db/repos/gentoo'
				elif [ -d /var/db/repo ]; then
					repopath='/var/db/repo/gentoo'
				else
					die "Unable to locate 'gentoo' repo directory"
				fi

				for arg in "${@:-}"; do
					if [[ "${arg}" == */* ]]; then
						cat="${arg%/*}"
						pkg="${arg#*/}"
					else
						pkg="${arg}"
						cat="$(
							eval ls -1d "${repopath}/*/${pkg}*" |
								rev |
								cut -d'/' -f 3 |
								rev
						)"
					fi
					for eb in $(
						eval ls -1 "${repopath}/${cat}/${pkg}*" |
							grep -- '\.ebuild$'
					); do
						slot='0.0'
						masked=' '
						keyworded=' '
						# I - Installed
						# P - In portage tree
						# O - In overlay
						if
							[[ -s "${repopath}/${cat}/${pkg%-[0-9]*}/${eb}" ]]
						then
							eval "$(
								grep 'SLOT=' \
									"${repopath}/${cat}/${pkg%-[0-9]*}/${eb}"
							)"
							slot="${SLOT:-${slot}}"
							grep -Fq "~${arch}" \
								"${repopath}/${cat}/${pkg%-[0-9]*}/${eb}" &&
									keyworded='~'
						fi
						echo "[-P-]" \
							"[${masked}${keyworded}]" \
							"${cat}/${eb%.ebuild}:${slot}"
					done
				done
			}  # equery
			export -f equery
		fi
	fi

	print "Resolving name '${dr_package}' ..."

	[ -n "${trace:-}" ] && set -o xtrace
	# Bah - 'sort -V' *doesn't* version-sort correctly when faced with
	# Portage versions including revisions (and presumably patch-levels) :(
	#
	# We need a numeric suffix in order to determine the package name, but
	# can't add one universally since "pkg-1.2-0" has a name of 'pkg-1.2'
	# (rather than 'pkg')...
	dr_name="$(
		versionsort -n "${dr_package##*[<>=]}" 2>/dev/null
	)" || dr_name="$(
		versionsort -n "${dr_package##*[<>=]}-0" 2>/dev/null
	)" || :
	dr_pattern='-~'
	if [ "${FORCE_KEYWORDS:-}" = '1' ]; then
		dr_pattern='-'
	fi
	# Ensure that ebuilds keyworded for building are checked when confirming
	# the package to build...
	sudo mkdir -p /etc/portage/package.accept_keywords 2>/dev/null || :
	if ! [[ -d /etc/portage/package.accept_keywords ]]; then
		die "'/etc/portage/package.accept_keywords' must be a directory"
	else
		if [[ -e "${PWD%/}/gentoo-base/etc/portage/package.accept_keywords" ]]; then
			TMP_KEYWORDS="$( sudo mktemp -p /etc/portage/package.accept_keywords/ "$( basename -- "${0#-}" ).XXXXXXXX" )"
			if ! [[ -e "${TMP_KEYWORDS:-}" ]]; then
				unset TMP_KEYWORDS
			else
				# shellcheck disable=SC2064
				trap "test -e '${TMP_KEYWORDS:-}' && sudo rm -f '${TMP_KEYWORDS:-}'" SIGHUP SIGINT SIGQUIT
				sudo chmod 0666 "${TMP_KEYWORDS}"
				if [[ -d "${PWD%/}/gentoo-base/etc/portage/package.accept_keywords" ]]; then
					cat "${PWD%/}/gentoo-base/etc/portage/package.accept_keywords"/* > "${TMP_KEYWORDS}"
				elif [[ -s "${PWD%/}/gentoo-base/etc/portage/package.accept_keywords" ]]; then
					cat "${PWD%/}/gentoo-base/etc/portage/package.accept_keywords" > "${TMP_KEYWORDS}"
				fi
			fi
		fi
	fi
	# shellcheck disable=SC2016
	dr_package="$(
		equery --no-pipe --no-color list --portage-tree --overlay-tree "${dr_package}" |
			grep -- '^\[' |
			grep -v \
				-e "^\[...\] \[.[${dr_pattern}]\] " \
				-e "^\[...\] \[M.\] " |
			cut -d']' -f 3- |
			cut -d' ' -f 2- |
			cut -d':' -f 1 |
			xargs -r -I '{}' bash -c 'printf "%s\n" "$( versionsort "${@:-}" )"' _ {} |
			tail -n 1
	)" || :
	if [[ -n "${TMP_KEYWORDS:-}" ]] && [[ -e "${TMP_KEYWORDS}" ]]; then
		sudo rm "${TMP_KEYWORDS}"
		trap - SIGHUP SIGINT SIGQUIT
		unset TMP_KEYWORDS
	fi
	if [ -z "${dr_name:-}" ] || [ -z "${dr_package:-}" ]; then
		warn "Failed to match portage atom to package name '${1:-${package}}'"
		return 1
	fi
	dr_package="${dr_name}-${dr_package}"

	package="$(
		echo "${dr_package}" |
		cut -d':' -f 1 |
		sed --regexp-extended 's/^([~<>]|=[<>]?)//'
	)"
	package_version="$( versionsort "${package}" )"
	# shellcheck disable=SC2001 # POSIX sh compatibility
	package_name="$( echo "${package%-"${package_version}"}" | sed 's/+/plus/g' )"
	# shellcheck disable=SC2001 # POSIX sh compatibility
	container_name="${prefix}.$( echo "${package_name}" | sed 's|/|.|g' )"
	export package package_version package_name container_name

	[ -n "${trace:-}" ] && set +o xtrace

	unset dr_package

	return 0
}  # docker_resolve

docker_image_exists() {
	image="${1:-${package}}"
	version="${2:-${package_version}}"

	[[ -n "${image:-}" ]] || return 1

	if [[ -n "${version:-}" ]]; then
		image="${image%-"${version}"}"
	fi
	if [[ "${image}" =~ : ]]; then
		version="${image#*:}"
		image="${image%:*}"
	fi
	if [[ "${image}" =~ \/ ]]; then
		image="${image/\//.}"
	fi

	# shellcheck disable=SC2086
	if ! $docker ${DOCKER_VARS:-} image ls "${image}" | grep -Eq -- "^(localhost/)?([^.]+\.)?${image}"; then
		error "docker image '${image}' not found"
		return 1

	elif ! $docker ${DOCKER_VARS:-} image ls "${image}:${version}" | grep -Eq -- "^(localhost/)?([^.]+\.)?${image}"; then
		erro "docker image '${image}' found, but not version '${version}'"
		return 1
	fi

	# shellcheck disable=SC2086
	$docker ${DOCKER_VARS:-} image ls "${image}:${version}" |
		grep -E -- "^(localhost/)?([^.]+\.)?${image}" |
		awk '{ print $3 }'

	return 0
}  # docker_image_exists

# Launches container
#
docker_run() {
	#inherit name container_name
	#inherit BUILD_CONTAINER NO_BUILD_MOUNTS NO_MEMORY_LIMITS NO_REPO_MASKS
	#inherit DOCKER_VARS
	#inherit PODMAN_MEMORY_RESERVATION PODMAN_MEMORY_LIMIT PODMAN_SWAP_LIMIT
	#inherit ACCEPT_KEYWORDS ACCEPT_LICENSE DEBUG DEV_MODE DOCKER_CMD_VARS \
	#	 DOCKER_DEVICES DOCKER_ENTRYPOINT DOCKER_EXTRA_MOUNTS \
	#	 DOCKER_HOSTNAME DOCKER_INTERACTIVE DOCKER_PRIVILEGED \
	#	 DOCKER_VOLUMES ECLASS_OVERRIDE EMERGE_OPTS FEATURES \
	#	 PYTHON_SINGLE_TARGET PYTHON_TARGETS ROOT TERM TRACE USE
	#inherit ARCH PKGDIR_OVERRIDE PKGDIR
	#inherit DOCKER_VERBOSE DOCKER_CMD
	#inherit image IMAGE

	local dr_rm='' dr_id=''
	local -i rc=0
	local -i rcc=0

	local BUILD_CONTAINER="${BUILD_CONTAINER-1}"  # Don't substitute if variable is assigned but empty...
	local NO_BUILD_MOUNTS="${NO_BUILD_MOUNTS:-}"
	local NO_MEMORY_LIMITS="${NO_MEMORY_LIMITS:-}"
	local NO_REPO_MASKS="${NO_REPO_MASKS:-}"

	[ "${BUILD_CONTAINER}" = '1' ] || unset BUILD_CONTAINER

	[ -n "${name:-}" ] || dr_rm='--rm'

	if [ -z "${name:-}" ] && [ -z "${container_name:-}" ]; then
		error "One of 'name' or 'container_name' must be set"
		return 1
	fi

	[ -n "${trace:-}" ] && set -o xtrace

	trap '' INT
	# shellcheck disable=SC2086
	$docker ${DOCKER_VARS:-} container ps --noheading |
			grep -qw -- "${name:-${container_name}}$" &&
		$docker ${DOCKER_VARS:-} container stop --time 2 "${name:-${container_name}}" >/dev/null
	# shellcheck disable=SC2086
	$docker ${DOCKER_VARS:-} container ps --noheading -a |
			grep -qw -- "${name:-${container_name}}$" &&
		$docker ${DOCKER_VARS:-} container rm --volumes "${name:-${container_name}}" >/dev/null
	trap - INT

	# FIXME: Make this package-specific hack generic (or unneeded!)
	if [ -n "${BUILD_CONTAINER:-}" ] && [ -z "${NO_BUILD_MOUNTS:-}" ]; then
		if [ -d '/etc/openldap/schema' ] && [ -n "${name:-}" ] && [ "${name%-*}" = 'buildsvc' ]; then
			DOCKER_EXTRA_MOUNTS="${DOCKER_EXTRA_MOUNTS:+${DOCKER_EXTRA_MOUNTS} }--mount type=bind,source=/etc/openldap/schema/,destination=/service/etc/openldap/schema"
		fi
	fi

	# --privileged is required for portage sandboxing... or alternatively
	# execute 'emerge' with:
	# FEATURES="-ipc-sandbox -mount-sandbox -network-sandbox -pid-sandbox"
	#
	# PTRACE capability is required to build glibc (but as-of podman-2.0.0
	# it is not permissible to specify capabilities with '--privileged')
	#
	# Update: As-of podman-4.1.0, it is now possible to use '--privileged' and
	# add a capability in the same invocation!
	#
	# FIXME: Add -tty regardless of DOCKER_INTERACTIVE, so that the
	# container can access details of the host terminal size
	# *HOWEVER* this removes the ability to use ctrl+c to interrupt, so
	# hard-code COLUMNS and LINES instead :(
	#
	# Adding '--init' allows tini to ensure that SIGTERM reaches child
	# commands, not just the top-level shell process...
	#
	# We're now running under bash, so can use arrays to make this so much
	# nicer!
	#
	local -a runargs=()
	# shellcheck disable=SC2207
	runargs=(
		$(
			# shellcheck disable=SC2015
			if
				[[ "$( uname -s )" != 'Darwin' ]] &&
				(( $( nproc ) > 1 )) &&
				$docker info 2>&1 | grep -q -- 'cpuset'
			then
				echo "--cpuset-cpus 1-$(( $( nproc ) - 1 ))"
			fi
		)
		--init
		--name "${name:-${container_name}}"
		#--network slirp4netns
		# Some elements such as podman's go code tries to fetch packages from
		# IPv6-addressable hosts...
		--network host
		--pids-limit 1024
		  ${dr_rm:+--rm}
		--ulimit nofile=1024:1024
	)
	if [ -n "${BUILD_CONTAINER:-}" ] && [ -z "${NO_BUILD_MOUNTS:-}" ]; then
		# We have build-mounts, therefore assume that we're running a
		# build container...
		runargs+=(
			--privileged
		)
	else
		# This shouldn't cause much harm, regardless...
		FEATURES="${FEATURES:+${FEATURES} }-ipc-sandbox -mount-sandbox -network-sandbox"
		export FEATURES
	fi
	if [[ -n "${DEV_MODE:-}" ]]; then
		if
			[[
				-z "${JOBS:-}" ||
				-z "${MAXLOAD:-}" ||
				-z "${init_name:-}" ||
				-z "${base_name:-}" ||
				-z "${build_name:-}"
			]]
		then
			# shellcheck disable=SC1091
			[[ ! -s common/vars.sh ]] || . common/vars.sh
		fi

		local name='' ext=''
		name="${image#*/}"
		case "${image#*/}" in
			"${init_name#*/}:latest"|"${base_name#*/}:latest")
				: ;;
			"${build_name#*/}:latest")
				ext='.build' ;;
			*)
				die "I don't know how to apply DEV_MODE to image '${image}'"
				;;
		esac
		unset name
		runargs+=(
			  # FIXME: DEV_MODE currently hard-codes entrypoint.sh.build ...
			  --env DEV_MODE
			  --env DEFAULT_JOBS="${JOBS}"
			  --env DEFAULT_MAXLOAD="${MAXLOAD}"
			  --env environment_file="${environment_file}"
			  --volume "${PWD%/}/gentoo-base/entrypoint.sh${ext}:/usr/libexec/entrypoint.sh:ro"
		)
		unset ext
	fi
	# shellcheck disable=SC2206
	runargs+=(
		  ${DOCKER_DEVICES:-}
		  ${DOCKER_ENTRYPOINT:+--entrypoint ${DOCKER_ENTRYPOINT}}
		  ${ACCEPT_KEYWORDS:+--env ACCEPT_KEYWORDS}
		  ${ACCEPT_LICENSE:+--env ACCEPT_LICENSE}
		  #${KBUILD_OUTPUT:+--env KBUILD_OUTPUT}
		  #${KERNEL_DIR:+--env KERNEL_DIR}
		  #${KV_OUT_DIR:+--env KV_OUT_DIR}
		  ${PYTHON_SINGLE_TARGET:+--env PYTHON_SINGLE_TARGET}
		  ${PYTHON_TARGETS:+--env PYTHON_TARGETS}
		  #${DOCKER_INTERACTIVE:+--env COLUMNS="$( tput cols 2>/dev/null )" --env LINES="$( tput lines 2>/dev/null )"}
		--env COLUMNS="$( tput cols 2>/dev/null || echo '80' )" --env LINES="$( tput lines 2>/dev/null || echo '24' )"
		  ${DEBUG:+--env DEBUG}
		  ${ECLASS_OVERRIDE:+--env "ECLASS_OVERRIDE=${ECLASS_OVERRIDE}"}
		  ${EMERGE_OPTS:+--env "EMERGE_OPTS=${EMERGE_OPTS}"}
		  ${FEATURES:+--env FEATURES}
		  ${ROOT:+--env ROOT --env SYSROOT --env PORTAGE_CONFIGROOT}
		  ${TERM:+--env TERM}
		  ${TRACE:+--env TRACE}
		  ${USE:+--env "USE=${USE}"}
		  ${DOCKER_CMD_VARS:-}
		  ${DOCKER_INTERACTIVE:+--interactive --tty}
		  ${DOCKER_PRIVILEGED:+--privileged}
		  ${DOCKER_EXTRA_MOUNTS:-}
		  ${DOCKER_VOLUMES:-}
		  ${DOCKER_HOSTNAME:+--hostname ${DOCKER_HOSTNAME}}
	)
	if [[ -z "${NO_MEMORY_LIMITS:-}" ]]; then
		if [[ -r /proc/cgroups ]] && grep -q -- '^memory.*1$' /proc/cgroups &&
			[[ -n "${PODMAN_MEMORY_RESERVATION:-}" || -n "${PODMAN_MEMORY_LIMIT}" || -n "${PODMAN_SWAP_LIMIT}" ]]
		then
			local -i swp=$(( ( $( grep -m 1 'SwapTotal:' /proc/meminfo | awk '{ print $2 }' ) + 16 ) / 1024 / 1024 ))
			local -i ram=$(( $( grep -m 1 'MemTotal:' /proc/meminfo | awk '{ print $2 }' ) / 1024 / 1024 ))
			local -i changed=0
			if (( ram < ${PODMAN_MEMORY_LIMIT%g} )) || (( ( ram + swp ) < ${PODMAN_SWAP_LIMIT%g} )); then
				output >&2 "INFO:  Host resources (rounded down to nearest 1GiB):"
				output >&2 "         RAM:        ${ram}G"
				output >&2 "         Swap:       ${swp}G"
				output >&2 "INFO:  Original memory limits:"
				output >&2 "         Soft limit: ${PODMAN_MEMORY_RESERVATION%g}G"
				output >&2 "         Hard limit: ${PODMAN_MEMORY_LIMIT%g}G"
				output >&2 "         RAM + Swap: ${PODMAN_SWAP_LIMIT%g}G"
			fi
			if (( ram < ${PODMAN_MEMORY_LIMIT%g} )); then
				PODMAN_MEMORY_RESERVATION="$(( ram - 1 ))g"
				PODMAN_MEMORY_LIMIT="$(( ram ))g"
				#PODMAN_SWAP_LIMIT="$(( ram + swp ))g"
				if (( ram <= 1 )); then
					PODMAN_SWAP_LIMIT="$(( ram * 2 ))g"
				else
					PODMAN_SWAP_LIMIT="$(( ram + $(
						awk -v ram="${ram}" 'BEGIN{ print int( sqrt( ram ) + 0.5 ) }'
					) ))g"
				fi
				changed=1
			fi
			if (( ( ram + swp ) < ${PODMAN_SWAP_LIMIT%g} )); then
				#PODMAN_SWAP_LIMIT="$(( ram + swp ))g"
				if (( ram <= 1 )); then
					PODMAN_SWAP_LIMIT="$(( ram * 2 ))g"
				else
					PODMAN_SWAP_LIMIT="$(( ram + $(
						awk -v ram="${ram}" 'BEGIN{ print int( sqrt( ram ) + 0.5 ) }'
					) ))g"
				fi
				changed=1
			fi
			if (( changed )); then
				output >&2 "NOTE:  Changed memory limits based on host configuration:"
				output >&2 "         Soft limit: ${PODMAN_MEMORY_RESERVATION%g}G"
				output >&2 "         Hard limit: ${PODMAN_MEMORY_LIMIT%g}G"
				output >&2 "         RAM + Swap: ${PODMAN_SWAP_LIMIT%g}G"
				output >&2
			fi
			unset changed ram swp

			runargs+=(
				${PODMAN_MEMORY_RESERVATION:+--memory-reservation ${PODMAN_MEMORY_RESERVATION}}
				${PODMAN_MEMORY_LIMIT:+--memory ${PODMAN_MEMORY_LIMIT}}
				${PODMAN_SWAP_LIMIT:+--memory-swap ${PODMAN_SWAP_LIMIT}}
			)
		fi
	fi
	if [ -z "${NO_BUILD_MOUNTS:-}" ]; then
		local -a mirrormountpoints=()
		local -a mirrormountpointsro=()
		local -A mountpoints=()
		local -A mountpointsro=()
		local -i skipped=0
		local mp='' src=''  # cwd=''
		local default_repo_path='' default_distdir_path='' default_pkgdir_path=''

		if ! type -pf portageq >/dev/null 2>&1; then
			default_repo_path='/var/db/repos/gentoo /var/db/repos/srcshelton'
			default_distdir_path='/var/cache/portage/dist'
			default_pkgdir_path='/var/cache/portage/pkg'
			if [ ! -d /var/db/repos/gentoo ] && [ -d /var/db/repo/gentoo ]; then
				default_repo_path='/var/db/repo/gentoo /var/db/repo/srcshelton'
			fi
		fi
		if [ -n "${PKGDIR_OVERRIDE:-}" ]; then
			default_pkgdir_path="${PKGDIR_OVERRIDE}"
		fi

		# shellcheck disable=SC2046,SC2206,SC2207
		mirrormountpointsro=(
			#/etc/portage/repos.conf  # We need write access to be able to update eclasses...
			${default_repo_path:-$( portageq get_repo_path "${EROOT:-/}" $( portageq get_repos "${EROOT:-/}" ) )}
			#/usr/src  # Breaks gentoo-kernel-build package
			#/var/db/repo/container
			#/var/db/repo/gentoo
			#/var/db/repo/srcshelton
			#/var/db/repo/compat
		)

		# N.B.: Read repo-specific masks from the host system...
		if [ -z "${NO_REPO_MASKS:-}" ]; then
			while read -r mp; do
				mirrormountpointsro+=( "${mp}" )
			done < <( find /etc/portage/package.mask/ -mindepth 1 -maxdepth 1 -type f -name 'repo-*-mask' -print )
		fi

		if [ -n "${BUILD_CONTAINER:-}" ]; then
			mirrormountpoints=(
				#/var/cache/portage/dist
				"${default_distdir_path:-$( portageq distdir )}"
				'/etc/portage/savedconfig'
				'/var/log/portage'
			)

			if [ -z "${arch:-}" ]; then
				docker_setup
			fi

			#ENV PKGDIR="${PKGCACHE:-/var/cache/portage/pkg}/${ARCH:-amd64}/${PKGHOST:-docker}"
			#local PKGCACHE="${PKGCACHE:=/var/cache/portage/pkg}"
			#local PKGHOST="${PKGHOST:=docker}"
			local PKGDIR="${PKGDIR:=${default_pkgdir_path:-$( portageq pkgdir )}}"

			# Allow use of 'ARCH' variable as an override...
			print "Using architecture '${ARCH:-${arch}}' ..."
			mountpoints["${PKGDIR}"]="/var/cache/portage/pkg/${ARCH:-${arch}}/docker"
		fi
		mountpoints['/etc/portage/repos.conf']='/etc/portage/repos.conf.host'

		if [ -s "gentoo-base/etc/portage/package.accept_keywords.${ARCH:-${arch}}" ]; then
			mountpointsro["${PWD%/}/gentoo-base/etc/portage/package.accept_keywords.${ARCH:-${arch}}"]="/etc/portage/package.accept_keywords/${ARCH:-${arch}}"
		fi

		#cwd="$( dirname "$( readlink -e "${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]}" )" )"
		#print "Volume/mount base directory is '${cwd}'"
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.accept_keywords"]='/etc/portage/package.accept_keywords'
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.license"]='/etc/portage/package.license'
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.use.build"]='/etc/portage/package.use'

		for mp in ${mirrormountpointsro[@]+"${mirrormountpointsro[@]}"}; do
			[ -n "${mp:-}" ] || continue
			src="$( readlink -e "${mp}" )" || die "readlink() on mirrored read-only mountpoint '${mp}' failed: ${?}"
			if [ -z "${src:-}" ]; then
				warn "Skipping mountpoint '${mp}'"
				: $(( skipped = skipped + 1 ))
				continue
			fi
			runargs+=( --mount "type=bind,source=${src},destination=${mp}${docker_readonly:+,${docker_readonly}}" )
		done
		for mp in ${mirrormountpoints[@]+"${mirrormountpoints[@]}"}; do
			[ -n "${mp:-}" ] || continue
			src="$( readlink -e "${mp}" )" || die "readlink() on mirrored mountpoint '${mp}' failed: ${?}"
			if [ -z "${src:-}" ]; then
				warn "Skipping mountpoint '${mp}'"
				: $(( skipped = skipped + 1 ))
				continue
			fi
			runargs+=( --mount "type=bind,source=${src},destination=${mp}" )
		done
		for mp in ${mountpointsro[@]+"${!mountpointsro[@]}"}; do
			[ -n "${mp:-}" ] || continue
			src="$( readlink -e "${mp}" )" || die "readlink() on read-only mountpoint '${mp}' failed: ${?}"
			if [ -z "${src:-}" ]; then
				warn "Skipping mountpoint '${mp}' -> '${mountpointsro[${mp}]}'"
				: $(( skipped = skipped + 1 ))
				continue
			fi
			runargs+=( --mount "type=bind,source=${src},destination=${mountpointsro[${mp}]}${docker_readonly:+,${docker_readonly}}" )
		done
		for mp in ${mountpoints[@]+"${!mountpoints[@]}"}; do
			[ -n "${mp:-}" ] || continue
			src="$( readlink -e "${mp}" )" || die "readlink() on mountpoint '${mp}' failed (do you need to set 'PKGDIR'?): ${?}"
			if [ -z "${src:-}" ]; then
				warn "Skipping mountpoint '${mp}' -> '${mountpoints[${mp}]}'"
				: $(( skipped = skipped + 1 ))
				continue
			fi
			runargs+=( --mount "type=bind,source=${src},destination=${mountpoints[${mp}]}" )
		done

		if [ -n "${name:-}" ] && [ -n "${base_name:-}" ] && [ -n "${init_name:-}" ]; then
			if [ "${name}" = "${base_name#*/}" ] && [ "${image}" = "${init_name}:latest" ]; then
				# Prevent portage from outputting:
				#
				# !!! It seems /run is not mounted. Process management may malfunction.
				#
				info "Providing '/run' mount-point during initial base-image build ..."
				runargs+=( --mount "type=tmpfs,tmpfs-size=64M,destination=/run" )
			fi
		fi

		if [ $(( skipped )) -ge 1 ]; then
			warn "${skipped} mount-points not connected to container"
			sleep 5
		fi

		unset src mp
	fi

	if [ -n "${DOCKER_VERBOSE:-}" ]; then
		output
		[ -n "${DOCKER_VARS:-}" ] && output "VERBOSE: DOCKER_VARS is '${DOCKER_VARS}'"
		local arg='' next=''
		for arg in "${runargs[@]}"; do
			case "${next}" in
				mount)
					arg="$(
						sed -r \
								-e 's/^type=/type: /' \
								-e 's/,(src|source)=/\tsource: /' \
								-e 's/,(dst|destination)=/\tdestination: /' \
								-e 's/, ro=true$/\tRO/' \
							<<<"${arg}"
					)"
					output "VERBOSE: Mount point '${arg}'"
					;;
				volume)
					output "VERBOSE: Volume '${arg}'"
					;;
			esac
			if [[ "${arg}" =~ ^--(mount|volume)$ ]]; then
				next="${arg#--}"
			else
				next=''
			fi
		done | column -t -s $'\t'
		output
	fi

	(
		[ -n "${DOCKER_CMD:-}" ] && set -- "${DOCKER_CMD}"

		# DEBUG:
		# shellcheck disable=SC2030
		if [ -n "${DOCKER_VARS:-}" ]; then
			output "Defined ${BUILD_CONTAINER:+pre-build} container images:"
			set -x
			# shellcheck disable=SC2086
			eval $docker ${DOCKER_VARS:-} image ls --noheading
			set +x
			output "Defined ${BUILD_CONTAINER:+pre-build} additional-store container tasks:"
			set -x
			# shellcheck disable=SC2086
			eval $docker ${DOCKER_VARS:-} container ps --noheading -a
			set +x
			output "Defined ${BUILD_CONTAINER:+pre-build} container tasks:"
			$docker container ps --noheading -a
		fi

		image="${image:-${IMAGE:-gentoo-build:latest}}"

		print "Starting ${BUILD_CONTAINER:+build} container with command '$docker container run ${runargs[*]} ${image} ${*}'"
		# shellcheck disable=SC2086
		$docker \
				${DOCKER_VARS:-} \
			container run \
				"${runargs[@]}" \
			"${image}" ${@+"${@}"}
	)
	rc=${?}
	# shellcheck disable=SC2031,SC2086
	if
		dr_id="$( $docker ${DOCKER_VARS:-} container ps --noheading -a |
				grep -- "\s${name:-${container_name}}$" |
				awk '{ prnt $1 }' )" &&
			[ -n "${dr_id:-}" ]
	then
		rcc=$( $docker ${DOCKER_VARS:-} container inspect --format='{{.State.ExitCode}}' "${dr_id}" ) || :
	fi

	if [ -n "${rcc:-}" ] && [ "${rc}" -ne "${rcc}" ]; then
		if [ "${rc}" -gt "${rcc}" ]; then
			warn "Return code (${rc}) differs from container exit code (${rcc}) - proceeding with former ..."
		else
			warn "Return code (${rc}) differs from container exit code (${rcc}) - proceeding with latter ..."
			rc=${rcc}
		fi
	else
		print "'${docker} container run' returned '${rc}'"
	fi

	[ -n "${trace:-}" ] && set +o xtrace

	# shellcheck disable=SC2086
	return ${rc}
}  # docker_run

# Invokes container launch with package-build arguments
#
docker_build_pkg() {
	[ -n "${USE:-}" ] && info "USE override: '$( echo "${USE}" | xargs echo -n )'"

	# shellcheck disable=SC2016
	info "Building package '${package}' ${extra[*]+plus additional packages '${extra[*]}' }into container '${name:-${container_name}}' ..."

	# shellcheck disable=SC2086
	docker_run "=${package}${repo:+::${repo}}" ${extra[@]+"${extra[@]}"} ${args[@]+"${args[@]}"}

	return ${?}
}  # docker_build_pkg

# Garbage collect
#
docker_prune() {
	# shellcheck disable=SC2086
	#$docker ${DOCKER_VARS:-} system prune --all --filter 'until=24h' --filter 'label!=build' --filter 'label!=build.system' --force # --volumes
	# volumes can't be pruned with a filter :(
	# shellcheck disable=SC2086
	#$docker ${DOCKER_VARS:-} volume prune --force

	trap '' INT
	# shellcheck disable=SC2031,SC2086
	$docker ${DOCKER_VARS:-} container ps --noheading |
		rev |
		cut -d' ' -f 1 |
		rev |
		grep -- '_' |
		xargs -r $docker ${DOCKER_VARS:-} container stop --time 2 >/dev/null
	# shellcheck disable=SC2031,SC2086
	$docker ${DOCKER_VARS:-} container ps --noheading -a |
		rev |
		cut -d' ' -f 1 |
		rev |
		grep -- '_' |
		xargs -r $docker ${DOCKER_VARS:-} container rm --volumes >/dev/null

	# shellcheck disable=SC2031,SC2086
	$docker ${DOCKER_VARS:-} image ls |
		grep -- '^<none>\s\+<none>' |
		awk '{ print $3 }' |
		xargs -r $docker ${DOCKER_VARS:-} image rm
	trap - INT

	return 0
}  # docker_prune

# Default entrypoint
#
docker_build() {
	if [ -z "${*:-}" ]; then
		warn "No options passed to 'docker_build()'"
	fi

	docker_setup || return ${?}
	docker_parse ${@+"${@}"} || return ${?}
	docker_resolve || return ${?}
	docker_build_pkg || return ${?}
	#docker_prune

	return ${?}
}  # docker_build

if ! echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	if [ -n "${IMAGE:-}" ]; then
		info "Using default image '${IMAGE}'"
	else
		warn "No default '\${IMAGE}' specified"
	fi
fi

if [ ! -d "${PWD%/}/gentoo-base" ] && [ ! -x "${PWD%/}/gentoo-build-web.docker" ]; then
	die "Cannot locate required directory 'gentoo-base' in '${PWD%/}'"
fi

# Are we using docker or podman?
if ! command -v podman >/dev/null 2>&1; then
	docker='docker'

	#extra_build_args=''
	docker_readonly='readonly'
else
	docker='podman'

	#extra_build_args='--format docker'
	# From release 2.0.0, podman should accept docker 'readonly' attributes
	docker_readonly='ro=true'
fi
export docker docker_readonly  # extra_build_args

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker syntax=bash nowrap:
