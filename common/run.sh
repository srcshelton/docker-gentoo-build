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
#: "${PODMAN_MEMORY_RESERVATION:="256m"}"
#: "${PODMAN_MEMORY_LIMIT:="512m"}"
#: "${PODMAN_SWAP_LIMIT:="1g"}"
# Small
#: "${PODMAN_MEMORY_RESERVATION:="512m"}"
#: "${PODMAN_MEMORY_LIMIT:="1g"}"
#: "${PODMAN_SWAP_LIMIT:="2g"}"
# Medium
#: "${PODMAN_MEMORY_RESERVATION:="1g"}"
#: "${PODMAN_MEMORY_LIMIT:="2g"}"
#: "${PODMAN_SWAP_LIMIT:="3g"}"
# Large
#: "${PODMAN_MEMORY_RESERVATION:="2g"}"
#: "${PODMAN_MEMORY_LIMIT:="4g"}"
#: "${PODMAN_SWAP_LIMIT:="6g"}"
# Extra-Large
#: "${PODMAN_MEMORY_RESERVATION:="4g"}"
#: "${PODMAN_MEMORY_LIMIT:="8g"}"
#: "${PODMAN_SWAP_LIMIT:="11g"}"
# XXL
#: "${PODMAN_MEMORY_RESERVATION:="8g"}"
#: "${PODMAN_MEMORY_LIMIT:="16g"}"
#: "${PODMAN_SWAP_LIMIT:="20g"}"
#
: "${PODMAN_MEMORY_RESERVATION:="2g"}"
# We don't want to put the system under undue memory-pressure, but at the same
# time sys-devel/gcc and llvm-core/llvm no longer compile with 4GB RAM... so
# let's see whether we can get away with 5GB?  Parallel builds may also require
# more memory than this too, of course :o
#
# Update: 5GB isn't enough, but 6GB appears to be, just.  That's at least a 50%
#         increase in memory required between gcc-11 and gcc-12 :(
#         dev-python/pypy3_10-exe-7.3.12_p2 OOMs with 2GB reservation/8GB limit
#         but appears to succeed with 10GB limit.
# Update: 12GB isn't enough for gcc-14 with LTO on some architectures (Nvidia
#         Grave/GH200 on ARM, for example), which seem to fail up to 28GB
#         allocation but work with 30GB(!)
# Update: PODMAN_MEMORY_LIMIT needs to be a function of the number of cores
#         available - building clang/llvm with LTO requires >64GB RAM (it
#         finally worked at 94GB!) on a 64-core GH200(!!)
#         With up to 8 cores a maximum of 8GB seemed to be enough, or 12GB if
#         linking Linux with debug enabled...
if (( $( nproc ) < 8 )); then
	: "${PODMAN_MEMORY_LIMIT:="10g"}"
else
	# We can only do integer arithmetic!
	: "${PODMAN_MEMORY_LIMIT:="$(( ( $( nproc ) * 3 ) / 2 ))g"}"
fi
: "${PODMAN_SWAP_LIMIT:="${PODMAN_MEMORY_LIMIT}"}"

# shellcheck disable=SC2034
debug=${DEBUG:-}
trace=${TRACE:-}

declare -i _common_run_show_command=1

# Output functions...
#

output() {
	if [[ -z "${*:-}" ]]; then
		printf '\n'
	else
		printf '%s\n' "${*}"
	fi
}  # output

die() {
	#output >&2 "FATAL: ${BASH_SOURCE[0]:-"$( basename "${0}" )"}:" \
	#		"${*:-"Unknown error"}"
	output >&2 "FATAL: ${*:-"Unknown error"}"
	exit 1
}  # die

error() {
	if [[ -z "${*:-}" ]]; then
		output >&2
	else
		#output >&2 "ERROR: ${BASH_SOURCE[0]:-"$( basename "${0}" )"}: ${*}"
		output >&2 "ERROR: ${*}"
	fi
	return 1
}  # error

warn() {
	if [[ -z "${*:-}" ]]; then
		output >&2
	else
		#output >&2 "WARN:  ${BASH_SOURCE[0]:-"$( basename "${0}" )"}: ${*}"
		output >&2 "WARN:  ${*}"
	fi
}  # warn

note() {
	if [[ -z "${*:-}" ]]; then
		output >&2
	else
		#output >&2 "NOTE:  ${BASH_SOURCE[0]:-"$( basename "${0}" )"}: ${*}"
		output >&2 "NOTE:  ${*}"
	fi
}  # note

info() {
	if [[ -z "${*:-}" ]]; then
		output
	else
		#output "INFO:  ${BASH_SOURCE[0]:-"$( basename "${0}" )"}: ${*}"
		output "INFO:  ${*}"
	fi
}  # info

print() {
	local -i min=1

	if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
		(( min = ${1} ))
		if [[ -n "${2:-}" ]]; then
			shift
		else
			set --
		fi
	fi
	if [[ -n "${debug:-}" ]] && (( debug >= min )); then
		if [[ -z "${*:-}" ]]; then
			output >&2
		else
			if [[ -n "${BASH_SOURCE[-1]:-}" ]] &&
					[[ "${BASH_SOURCE[-1]:-}" != "${BASH_SOURCE[0]}" ]]
			then
				output >&2 "DEBUG: $( # <- Syntax
						basename "${BASH_SOURCE[-1]}"
					)->${BASH_SOURCE[0]}:${FUNCNAME[1]}(${BASH_LINENO[0]}):" \
					"${*}"
			else
				output >&2 "DEBUG: $( # <- Syntax
						basename "${0}"
					):${FUNCNAME[1]}(${BASH_LINENO[0]}): ${*}"
			fi
		fi
		return 0
	# Unhelpful with 'set -e'...
	#else
	#	return 1
	fi
}  # print

export -f output die error warn note info print

# Utility functions...
#

# Provide a wrapper to try to run mkdir/rm/etc. as the current user, and then
# via the 'sudo' binary if this fails.  Note that this is intended for atomic
# operations without side-effects, rather than as a universal 'sudo'
# replacement...
#
sudo() {
	"${@:-}" 2>/dev/null ||
		"$( type -pf "${FUNCNAME[0]}" )" "${@:-}"
}  # sudo

replace_flags() {
	# list="$( replace_flags <new> [flags] [to] [add] -- existing_list[@] )"
	local -a flags=() list=() output=()
	local -A seen=()
	local -i state=0
	local arg='' flag=''

	for arg in "${@:-}"; do
		case "${arg:-}" in
			--)
				print 2 "Switching state from 'flags' ('${flags[*]:-}') to" \
					"'list' ('${list[*]:-}') ..."
				state=1
				continue
				;;
			''|' ')
				print 2 "Dropping arg '${arg:-}' ..."
				:
				;;
			*' '*)
				arg="$( sed 's/^ \+// ; s/ \+$//' <<<"${arg}" )"
				if (( state )); then
					print 2 "Adding multi arg list '${arg:-}' to list" \
						"'${list[*]:-}' ..."
					readarray -O "${#list[@]}" -t list < <( # <- Syntax
							xargs -rn 1 <<<"${arg}"
						)
					print 2 "... updated list is '${list[*]:-}'"
				else
					print 2 "Adding multi arg flags '${arg:-}' to flags" \
						"'${flags[*]:-}' ..."
					readarray -O "${#flags[@]}" -t flags < <( # <- Syntax
							xargs -rn 1 <<<"${arg}"
						)
					print 2 "... updated flags is '${flags[*]:-}'"
				fi
				;;
			*)
				if (( state )); then
					print 2 "Adding list item '${arg:-}' to list" \
						"'${list[*]:-}' ..."
					list+=( "${arg}" )
					print 2 "... updated list is '${list[*]:-}'"
				else
					print 2 "Adding flag '${arg:-}' to flags" \
						"'${flags[*]:-}' ..."
					flags+=( "${arg}" )
					print 2 "... updated flags is '${flags[*]:-}'"
				fi
				;;
		esac
	done
	print 2 "Finished processing args - will add flags '${flags[*]:-}' to" \
		"list '${list[*]:-}'"

	if (( 0 == ${#flags[@]} )); then
		warn "No flags supplied to ${FUNCNAME[0]} - received '${*:-}'"
		return 1
	fi

	for flag in "${flags[@]}"; do
		# Remove existing instances of '(-)flag'...
		#
		for arg in "${list[@]}"; do
			case "${arg}" in
				"-${flag#"-"}"|"${flag#"-"}"|'')
					print 2 "Will add flag '${arg}' to list later ..."
					# Do nothing, as we add the flag below...
					:
					# N.B. This means that if we have '-flag flag' then the
					#      second occurence is dropped...
					#seen["${arg#"-"}"]=1  # <- This loses the flag!
					;;
				*)
					if ! (( seen["${arg}"] )); then
						print 2 "Adding flag '${arg}' to list"
						output+=( "${arg}" )
						seen["${arg}"]=1
					else
						print 2 "Dropping duplicate flag '${arg}' from list"
					fi
					continue
					;;
			esac
		done

		# ... and then add '(-)flag' to the start or end of the list
		#
		case "${flag}" in
			'')
				:
				;;
			-*)
				print 2 "Adding flag '${flag}' to start of list ..."
				if [[ -z "${output[*]:-}" ]]; then
					output=( "${flag}" )
				else
					output=( "${flag}" "${output[@]}" )
				fi
				;;
			*)
				if ! (( seen["${flag}"] )); then
					print 2 "Adding flag '${flag}' to end of list ..."
					output+=( "${flag}" )
					seen["${flag}"]=1
				else
					print 2 "Dropping duplicate flag '${flag}' from end of" \
						"list"
				fi
				;;
		esac
	done

	print 2 "replace_flags result: '${output[*]:-}'"
	echo "${output[*]:-}"
}  # replace_flags

add_arg() {
	local flag="${1:-}" arg=''

	# add_arg control-var output
	#
	# print 'output' if 'control-var' is set, expanding '%%' for the name of
	# the specified control-var, and '##' for the value.  Multiple 'output'
	# values will be individually substituted.

	if [[ -n "${2:-}" ]]; then
		# We've saved the first argument as 'flag', now ensure that our
		# parameters are the remaining arguments...
		shift
	fi

	# FIXME: I can't remember why the test needs to be "${!flag:-}", but the
	#        output is not as intended with this test dropped :(
	# N.B. Looping over arguments *after* the first is simply to include an
	#      initial space before each sucessive parameter.
	if [[ -n "${flag:-}" && -n "${!flag:-}" ]]; then
		if [[ -n "${1:-}" ]]; then
			# e.g. add_arg 1 2 3 -> 1 ...
			arg="${1}"
			arg="${arg//"##"/"${!flag}"}"
			printf '%s' "${arg//"%%"/"${flag}"}"
			if [[ -n "${2:-}" ]]; then
				shift
				# e.g. add_arg 1 2 3 -> ... 2 3
				for arg in "${@:-}"; do
					arg="${arg//"##"/"${!flag}"}"
					printf ' %s' "${arg//"%%"/"${flag}"}"
					#       ^
				done
			fi
		else
			# e.g. add_arg test -> 'test'
			printf '%s' "${flag}"
		fi
	fi
}  # add_arg

add_mount() {
	# Mount a filesystem object into a container...
	#
	local -i dir=0
	local -i append=1
	local src='' dst='' arg='' ro="${docker_readonly:+",${docker_readonly}"}"

	(( debug > 1 )) &&
		print "Received (1) '${1:-}' (2) '${2:-}' (3) '${3:-}' (4) '${4:-}'"

	for arg in "${@:-}"; do
		shift
		case "${arg:-}" in
			'')
				: ;;
			--dir)
				dir=1 ;;
			--export)
				append=1 ;;
			--print)
				append=0 ;;
			--ro)
				: ;;
			--noro|--no_ro|--no-ro)
				ro='' ;;
			*)
				[[ -z "${arg:-}" ]] || set -- ${@+"${@}"} "${arg}" ;;
		esac
		(( debug > 1 )) &&
			print "arg is '${arg:-}', params are '${*}'"
	done
	unset arg
	(( debug > 1 )) &&
		print "params are '${*}'"

	if (( ${#} > 2 )); then
		error "Too many arguments supplied to ${FUNCNAME[0]} - received '${*}'"
		return 1
	fi

	src="${1:-}"
	dst="${2:-}"
	src_path="${src#"%base%"}"

	if [[ -z "${src:-}" ]]; then
		error "No source argument supplied to ${FUNCNAME[0]} -" \
			"received '${src}' '${dst}' from '${*:-}'"
		return 1
	fi
	if [[ -n "${dst:-}" && -n "${src_path:-}" ]]; then
		if [[ "${dst}" == "${src_path}" ]]; then
			warn "Overspecified call to ${FUNCNAME[0]}, 'dst' unnecessary" \
				"in '${*}'"
		elif [[ "${dst}" == "${src_path%"/"}"/* ]]; then
			warn "Overspecified call to ${FUNCNAME[0]}, '...' possible at" \
				"start of '${*}'"
		elif [[ "${dst}" == */"${src_path#"/"}" ]]; then
			warn "Overspecified call to ${FUNCNAME[0]}, '...' possible at" \
				"end of '${*}'"
		fi
	elif [[ -z "${dst:-}" ]]; then
		dst="${src_path}"
	fi

	if [[ "${src}" == '%base%/'* ]]; then
		src="${PWD}/${base_dir:+"${base_dir}/"}${src_path#"/"}"
	fi
	if [[ "${src}" == *'/' ]]; then
		# FIXME: Warn if auto-enabling directory mode?
		dir=1
	fi
	case "${dst}" in
		*'/...') dst="${dst%"/..."}/${src_path#"/"}" ;;
		*'...') dst="${dst%"..."}/${src_path#"/"}" ;;
		'.../'*) dst="${src_path%"/"}/${dst#".../"}" ;;
		'...'*) dst="${src_path%"/"}/${dst#"..."}" ;;
	esac
	dst="${dst%"/"}"
	unset src_path

	if ! [[ -e "${src}" ]]; then
		print "${FUNCNAME[0]} skipping source object '${src}': does not exist"
		return 1
	elif (( 0 == dir )) && [[ -d "${src}" ]]; then
		print "${FUNCNAME[0]} skipping source object '${src}': is a directory"
		return 1
	elif (( 0 == dir )) && ! [[ -s "${src}" ]]; then
		print "${FUNCNAME[0]} skipping source file '${src}': is empty"
		return 1
	fi

	# [[ -e "${src}" && ( (( 1 == dir )) || ! -d "${src}" && -s "${src}" ) ]]
	print "Mounting ${ro:+"read-only "}$( # <- Syntax
			(( dir )) && echo 'directory' || echo 'file'
		) '${src}' to '${dst}' ..."

	if (( append )); then
		DOCKER_EXTRA_MOUNTS="${DOCKER_EXTRA_MOUNTS:+"${DOCKER_EXTRA_MOUNTS} "}"
		DOCKER_EXTRA_MOUNTS="${DOCKER_EXTRA_MOUNTS}--mount type=bind,source=${src},destination=${dst}${ro:-}"
		export DOCKER_EXTRA_MOUNTS
	else
		printf -- '--mount type=bind,source=%s,destination=%s%s' \
			"${src}" "${dst}" "${ro:-}"
	fi

	return 0
}  # add_mount

export -f sudo replace_flags add_arg add_mount

#[[ -n "${trace:-}" ]] && set -o xtrace

if [[ "$( uname -s )" == 'Darwin' ]]; then
	# Darwin/BSD lacks GNU readlink - either realpath or perl's Cwd module
	# will do at a pinch, although both lack the additional options of GNU
	# binaries...
	#
	readlink() {
		if ! [[ "${1:-}" == '-e' ]]; then
			warn "readlink called with unsupported mode '${1:-}'"
			return 1
		fi
		if type -pf realpath >/dev/null 2>&1; then
			realpath "${2}" 2>/dev/null
		else
			# The perl statement below returns $PWD if the supplied
			# path doesn't exist :(
			[[ -e "${2}" ]] || return 1
			perl -MCwd=abs_path -le 'print abs_path readlink(shift);' "${2}"
		fi
	}  # readlink
	export -f readlink
fi

# Mostly no longer needed, with Dockerfile.env...
#
_docker_setup() {
	export -a args=() extra=()
	export package='' package_version='' package_name='' repo=''
	export name='' container_name='' image="${IMAGE:-"gentoo-build:latest"}"

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
			#profile='17.0'
			profile='23.0/split-usr'
			chost='aarch64-unknown-linux-gnu'  # default
			#chost='aarch64-pc-linux-gnu'
			;;
		armv6l)
			docker_arch='amd/v6'
			arch='arm'
			#profile='17.0/armv6j'
			profile='23.0/split-usr/armv6j_hf'
			chost='armv6j-hardfloat-linux-gnueabihf'
			;;
		arm7l)
			docker_arch='amd/v7'
			arch='arm'
			#profile='17.0/armv7a'
			profile='23.0/split-usr/armv7a_hf'
			chost='armv7a-hardfloat-linux-gnueabihf'
			;;
		i386|i686)  # Untested!
			docker_arch='i386'
			arch='x86'
			#profile='17.0'
			profile='23.0/split-usr'
			chost='i686-pc-linux-gnu'
			;;
		x86_64|amd64)
			docker_arch='amd64'
			arch='amd64'
			#profile='17.1/no-multilib'
			profile='23.0/split-usr/no-multilib'
			chost='x86_64-pc-linux-gnu'
			;;
		*)
			die "Unknown architecture '$( uname -m )'"
			;;
	esac

	return 0
}  # _docker_setup

# Sets image, name, package, extra, and args based on arguments
#
# FIXME: This is *massively* broken for arguments with spaces - reimplement in
#        bash with array support?
#
_docker_parse() {
	local dp_arg=''

	if [[ -z "${*:-}" ]]; then
		package='app-shells/bash'
	else
		for dp_arg in "${@}"; do
			if echo "${dp_arg}" | grep -Eq -- '^-(h|-help)$'; then
				output >&2 "Usage: $( basename -- "${0#"-"}" )" \
					"[--name <container name>] [--image <source image>]" \
					"<package> [emerge_args]"
				exit 0

			elif [[ "${name}" == '<next>' ]]; then
				name="${dp_arg}"
				print "Setting container name to '${name}' in $( # <- Syntax
						basename -- "${0#"-"}"
					)"

			elif [[ "${image}" == '<next>' ]]; then
				image="${dp_arg}"
				print "Setting source image to '${image}' in $( # <- Syntax
						basename -- "${0#"-"}"
					)"

			elif echo "${dp_arg}" |
					grep -Eq -- '^-(n|-name)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'
			then
				if echo "${dp_arg}" | grep -Fq '=' ; then
					name="$( echo "${dp_arg}" | cut -d'=' -f 2- )"
					print "Setting container name to '${name}' in $( # <- Syntax
							basename -- "${0#"-"}"
						)"
				else
					name='<next>'
				fi

			elif echo "${dp_arg}" |
					grep -Eq -- '^-(i|-image)(=[a-z0-9]+([._-]{1,2}[a-z0-9]+)*)?$'
			then
				if echo "${dp_arg}" | grep -Fq -- '=' ; then
					image="$( echo "${dp_arg}" | cut -d'=' -f 2- )"
					print "Setting source image to '${image}' in $( # <- Syntax
							basename -- "${0#"-"}"
						)"
				else
					image='<next>'
				fi

			elif echo "${dp_arg}" | grep -q -- '^-'; then
				#args="${args:+"${args} "}${dp_arg}"
				args+=( "${dp_arg}" )
				print "Adding argument '${dp_arg}'"

			elif echo "${dp_arg}" | grep -q -- '^@'; then
				#extra="${extra:+"${extra} "}${dp_arg}"
				extra+=( "${dp_arg}" )
				print "Adding extra argument '${dp_arg}'"

				# Currently category general names are between 3 and
				# 7 ("gnustep") letters, package names start with [023469Z] or
				# lower-case...
				#
				# Update: There's now 'container' (9)
				#
			elif echo "${dp_arg}" |
					grep -Eq -- '((virtual|[a-z]{3,9}-[a-z]+)/)?[a-zA-Z0-9][a-zA-Z0-9_.+-]+\*?(:[0-9.]+\*?)?(::.*)?$'
			then
				if [[ -z "${package:-}" ]]; then
					package="${dp_arg%"::"*}"
					print "Setting package to '${package}'"
					if echo "${dp_arg}" | grep -Fq -- '::'; then
						repo="${dp_arg#*"::"}"
						print "... and repo to '${repo}'"
					fi
				else
					#extra="${extra:+"${extra} "}${dp_arg}"
					extra+=( "${dp_arg}" )
					print "Adding extra argument '${dp_arg}'"
				fi

			else
				warn "Unknown argument '${dp_arg}'"
			fi
		done
		if [[ "${name}" == '<next>' ]]; then
			name=''
		fi
		if [[ "${image}" == '<next>' ]]; then
			image=''
		fi

		export args repo extra name image
	fi

	export package

	unset dp_arg

	return 0
}  # _docker_parse

# Validates package and sets container
#
_docker_resolve() {
	local dr_package="${1:-"${package}"}"
	local dr_prefix="${2:-"buildpkg"}"
	local dr_name='' dr_pattern=''

	if [[ ! -x "$( type -pf versionsort )" ]]; then
		# On non-Gentoo systems we need to build 'eix' (for 'versionsort') and
		# 'equery' into a container, and then call that to acquire "proper"
		# package-version handling facilities.
		#
		# For systems such as Darwin where the host system may not have
		# /var/db/repo(s)/gentoo (et al.), we can also fetch the pertinent
		# content from docker.io/gentoo/portage - although there's no guarantee
		# that an appropriate image will exist, and even then the container has
		# to have run in order to use '--volumes-from', and that means
		# executing at least a placeholder binary ('/bin/sh -c /bin/true') from
		# a 'linux/amd64' image.
		#
		# Without a linkage between this repo and the custom overlay repo, we
		# can only find the appropriate tag for this image from the latest
		# overlay commit, rather than the most appropriate one.  There's no
		# obvious better solution here...
		#
		# shellcheck disable=SC2086
		if docker ${DOCKER_VARS:-} image ls localhost/gentoo-helper:latest |
				grep -Eq -- '^(localhost/)?([^.]+\.)?gentoo-helper'
		then
			# shellcheck disable=SC2032  # Huh?
			versionsort() {
				local result=''
				local -i rc=0

				result="$( # <- Syntax
						docker container run \
								--rm \
								--name='portage-helper' \
								--network=none \
							gentoo-helper versionsort "${@:-}"
					)" || rc="${?}"

				print "versionsort returned '${result}': ${rc}"
				echo -n "${result}"

				return "${rc}"
			}  # versionsort
		else
			# Before we have that (and to make building a container for those
			# tools easier) let's offer a best-effort, albeit limited,
			# replacement...
			#
			versionsort() {
				local -i name=0

				if [[ "${1:-}" == '-n' ]]; then
					name=1
					if [[ -n "${2:-}" ]]; then
						shift
					else
						return 1
					fi
				fi

				if type -pf qatom >/dev/null 2>&1; then
					if (( name )); then
						# shellcheck disable=SC2046
						qatom -CF '%{CATEGORY}/%{PN}' $( # <- Syntax
									xargs -rn 1 <<<"${@:-}"
								) |
							sort
					else
						# shellcheck disable=SC2046
						qatom -CF '%{PV} %[PR]' $( # <- Syntax
									xargs -rn 1 <<<"${@:-}" |
										sed 's/ $// ; s/ /-/'
								) |
							sort -V
					fi
				else
					if (( name )); then
						xargs -rn 1 <<<"${@:-}" |
							sed 's/-[0-9].*$//' |
							sort
					else
						xargs -rn 1 <<<"${@:-}" |
							sed 's/^.*[a-z]-\([0-9].*\)$/\1/' |
							sort -V
					fi
				fi
			}  # versionsort
		fi
		export -f versionsort
	fi

	if ! [[ -x "$( type -pf equery )" ]]; then
		# shellcheck disable=SC2086
		if docker ${DOCKER_VARS:-} image ls localhost/gentoo-helper:latest |
				grep -Eq -- '^(localhost/)?([^.]+\.)?gentoo-helper'
		then
			equery() {
				local image_tag='' extra_mounts='' result=''
				local -i rc=0

				local -r url='https://raw.githubusercontent.com'
				local -r path='refs/heads/master'
				local -r owner='srcshelton'
				local -r repo='gentoo-ebuilds'
				local -r file='.portage_commit'
				local -r platform='linux/amd64'
				image_tag="$( # <- Syntax
						curl -fsSL "${url}/${owner}/${repo}/${path}/${file}" |
							head -n 1 |
							awk '{print $2}' |
							sed 's/-.*$//'
					)"
				if [[ -n "${image_tag:-}" ]]; then
					warn "Synthesising portage tree for containerised" \
						"'equery' - this may be slow ..."
					docker image pull --quiet --platform "${platform}" \
						"docker.io/gentoo/portage:${image_tag}" 2>/dev/null
					docker container stop \
						portage-helper-repo >/dev/null 2>&1 || :
					docker container rm -v \
						portage-helper-repo >/dev/null 2>&1 || :
					docker container run \
							--name 'portage-helper-repo' \
							--network none \
							--platform 'linux/amd64' \
						"docker.io/gentoo/portage:${image_tag}" 2>/dev/null &&
					docker container stop \
						portage-helper-repo 2>/dev/null
				fi

				if [[ -e /etc/portage/package.accept_keywords ]]; then
					extra_mounts='--mount type=bind,src=/etc/portage/package.accept_keywords,dst=/etc/portage/package.accept_keywords,ro'
				fi

				# We'll execute this container via _docker_run rather than by
				# direct invocation, so that we get all of the necessary repo
				# directories mounted...
				#
				# ... or, actually, we won't - because we only need keyword
				# overrides!
				#
				result="$( # <- Syntax
						BUILD_CONTAINER=0 \
						DOCKER_VOLUMES='--volumes-from portage-helper-repo:ro' \
						NO_BUILD_MOUNTS=1 \
						NO_MEMORY_LIMITS=1 \
						DOCKER_EXTRA_MOUNTS="${extra_mounts:-}" \
						image='' \
						IMAGE='localhost/gentoo-helper:latest' \
						container_name='gentoo-helper' \
							_docker_run equery "${@:-}"
					)" || rc="${?}"

				print "equery returned '${result}': ${?}"
				echo "${result}"

				return "${rc}"
			}  # equery
		else
			equery() {
				local -a args=()
				local arg='' repopaths='' repopath='' cat='' pkg='' eb=''  # pv=''
				local slot='' masked='' keyworded=''

				if [[ -z "${arch:-}" ]]; then
					_docker_setup
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

				if type -pf portageq; then
					repopaths="$( portageq get_repo_path "${EROOT:-"/"}" "$( #
							portageq get_repos "${EROOT:-"/"}" |
								xargs -rn 1 2>/dev/null |
								grep -iw gentoo |
								tail -n 1
						)" )"
				elif [[ -d /etc/portage/repos.conf ]]; then
					repopaths="$( # <- Syntax
							grep '^\s*location\s*=\s*' /etc/portage/repos.conf/*.conf |
								cut -d'=' -f 2- |
								awk '{print $NF}'
						)"
				elif [[ -d /var/db/repos/gentoo || -L /var/db/repos/gentoo ]]
				then
					repopaths="$( readlink -e '/var/db/repos/gentoo' )"
				elif [[ -d /var/db/repo/gentoo || -L /var/db/repo/gentoo ]]
				then
					repopaths="$( readlink -e '/var/db/repo/gentoo' )"
				else
					die "Unable to locate 'gentoo' repo directory"
				fi

				for arg in "${@:-}"; do
					for repopath in ${repopaths}; do
						if [[ "${arg}" == */* ]]; then
							local stripped_arg=''
							stripped_arg="$( # <- Syntax
									# shellcheck disable=SC2001
									sed 's/^[^a-zA-Z]\+//' <<<"${arg}"
								)"
							cat="${stripped_arg%"/"*}"
							pkg="${arg#*"/"}"
							unset stripped_arg
						else
							local stripped_arg=''
							stripped_arg="$( # <- Syntax
									# shellcheck disable=SC2001
									sed 's/^[^a-zA-Z]\+//' <<<"${arg}"
								)"
							pkg="${stripped_arg}"
							unset stripped_arg
							cat="$( # <- Syntax
									eval ls -1d "${repopath}/*/${pkg}" \
											2>/dev/null |
										rev |
										cut -d'/' -f 2 |
										rev |
										sort |
										uniq
								)"
						fi

						if [[ "${pkg}" == *-[0-9]* ]]; then
							#pv="${pkg}"
							pkg="${pkg%"-"[0-9]*}"
						fi

						for eb in $( # <- Syntax
								eval ls -1 "${repopath}/${cat}/${pkg}/" \
										2>/dev/null |
									grep -- '\.ebuild$' |
									sort -V
							)
						do
							slot='0.0'
							masked=' '
							keyworded=' '
							# I - Installed
							# P - In portage tree
							# O - In overlay
							if [[ -s "${repopath}/${cat}/${pkg}/${eb}" ]]; then
								# Some SLOT definitions reference other
								# variables, such as LLVM_MAJOR :(
								export LLVM_MAJOR=0 PV=0
								export LLVM_SOABI="${LLVM_MAJOR}"
								eval "$( # <- Syntax
										grep 'SLOT=' \
											"${repopath}/${cat}/${pkg}/${eb}"
									)" 2>/dev/null
								unset LLVM_SOABI PV LLVM_MAJOR
								slot="${SLOT:-"${slot}"}"
								if grep -Eq -- "~${arch}([^-]|$)" \
										"${repopath}/${cat}/${pkg}/${eb}"
								then
									keyworded='~'
								fi
							fi
							echo "[-P-]" \
								"[${masked}${keyworded}]" \
								"${cat}/${eb%".ebuild"}:${slot}"
						done  # for eb in $( ... )
					done  # for repopath in ${repopaths}
				done  # for arg in "${@:-}"
			}  # equery
		fi
		export -f equery
	fi

	print "Resolving name '${dr_package}' ..."

	[[ -n "${trace:-}" ]] && set -o xtrace

	# Bah - 'sort -V' *doesn't* version-sort correctly when faced with
	# Portage versions including revisions (and presumably patch-levels) :(
	#
	# We need a numeric suffix in order to determine the package name, but
	# can't add one universally since "pkg-1.2-0" has a name of 'pkg-1.2'
	# (rather than 'pkg')...
	dr_name="$( # <- Syntax
				versionsort -n "${dr_package##*[<>=]}" 2>/dev/null
			)" ||
		dr_name="$( # <- Syntax
					versionsort -n "${dr_package##*[<>=]}-0" 2>/dev/null
				)" ||
			:
	dr_pattern='-~'
	if [[ "${FORCE_KEYWORDS:-}" == '1' ]]; then
		dr_pattern='-'
	fi

	if [[ -d /etc/portage ]]; then
		# Ensure that ebuilds keyworded for building are checked when
		# confirming the package to build...
		sudo mkdir -p /etc/portage/package.accept_keywords 2>/dev/null || :
		if ! [[ -d /etc/portage/package.accept_keywords ]]; then
			die "'/etc/portage/package.accept_keywords' must be a directory"
		else
			if [[ -e "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords" ]]
			then
				TMP_KEYWORDS="$( # <- Syntax
						sudo mktemp -p /etc/portage/package.accept_keywords/ \
							"$( basename -- "${0#"-"}" ).XXXXXXXX"
					)"
				if ! [[ -e "${TMP_KEYWORDS:-}" ]]; then
					unset TMP_KEYWORDS
				else
					# shellcheck disable=SC2064
					trap "test -e '${TMP_KEYWORDS:-}' && sudo rm -f '${TMP_KEYWORDS:-}'" \
						SIGHUP SIGINT SIGQUIT
					sudo chmod 0666 "${TMP_KEYWORDS}"
					if [[ -d "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords" ]]
					then
						cat "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords"/* \
							> "${TMP_KEYWORDS}"
					elif [[ -s "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords" ]]
					then
						cat "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords" \
							> "${TMP_KEYWORDS}"
					fi
				fi
			fi
		fi
	fi

	# FIXME: For hosts running with a podman machine, run equery within the VM
	#
	# shellcheck disable=SC2016
	dr_package="$( # <- Syntax
			equery --no-pipe --no-color list --portage-tree --overlay-tree \
					"${dr_package}" |
				grep -- '^\[' |
				grep -v \
					-e "^\[...\] \[.[${dr_pattern}]\] " \
					-e "^\[...\] \[M.\] " |
				cut -d']' -f 3- |
				cut -d' ' -f 2- |
				cut -d':' -f 1 |
				xargs -r -I '{}' \
					bash -c 'printf "%s\n" "$( versionsort "${@:-}" )"' _ {} |
				tail -n 1
		)" || :
	if [[ -n "${TMP_KEYWORDS:-}" && -e "${TMP_KEYWORDS}" ]]; then
		sudo rm "${TMP_KEYWORDS}"
		trap - SIGHUP SIGINT SIGQUIT
		unset TMP_KEYWORDS
	fi
	if [[ -z "${dr_name:-}" || -z "${dr_package:-}" ]]; then
		warn "Failed to match portage atom to package name" \
			"'${1:-"${package}"}'"
		return 1
	fi
	dr_package="${dr_name}-${dr_package}"

	package="$( # <- Syntax
			echo "${dr_package}" |
			cut -d':' -f 1 |
			sed --regexp-extended 's/^([~<>]|=[<>]?)//'
		)"
	package_version="$( versionsort "${package}" )"
	# shellcheck disable=SC2001  # POSIX sh compatibility
	package_name="$( # <- Syntax
			echo "${package%"-${package_version}"}" | sed 's/+/plus/g'
		)"
	# shellcheck disable=SC2001  # POSIX sh compatibility
	container_name="${dr_prefix}.$( echo "${package_name}" | sed 's|/|.|g' )"
	export package package_version package_name container_name

	#[[ -n "${trace:-}" ]] && set +o xtrace

	unset dr_package

	return 0
}  # _docker_resolve

_docker_image_exists() {
	image="${1:-"${container_name}"}"
	version="${2:-"${package_version}"}"

	[[ -n "${image:-}" ]] || return 1

	if [[ -n "${version:-}" ]]; then
		image="${image%"-${version}"}"
	fi
	if [[ "${image}" =~ : ]]; then
		version="${image#*":"}"
		image="${image%":"*}"
	fi
	if [[ "${image}" =~ \/ ]]; then
		image="${image/\//.}"
	fi

	# shellcheck disable=SC2086
	if ! docker ${DOCKER_VARS:-} image ls "${image}" |
			grep -Eq -- "^(localhost/)?([^.]+\.)?${image}"
	then
		error "docker image '${image}' not found"
		return 1

	elif ! docker ${DOCKER_VARS:-} image ls "${image}:${version}" |
			grep -Eq -- "^(localhost/)?([^.]+\.)?${image}"
	then
		error "docker image '${image}' found, but not version '${version}'"
		return 1
	fi

	# shellcheck disable=SC2086
	docker ${DOCKER_VARS:-} image ls "${image}:${version}" |
		grep -E -- "^(localhost/)?([^.]+\.)?${image}" |
		awk '{ print $3 }'

	return 0
}  # _docker_image_exists

# Launches container
#
_docker_run() {
	#inherit name container_name BUILD_CONTAINER
	#inherit NO_BUILD_MOUNTS NO_CPU_LIMITS NO_LOAD_LIMITS NO_MEMORY_LIMITS \
	#   NO_REPO_MASKS
	#inherit DOCKER_VARS
	#inherit PODMAN_MEMORY_RESERVATION PODMAN_MEMORY_LIMIT PODMAN_SWAP_LIMIT
	#inherit ACCEPT_KEYWORDS ACCEPT_LICENSE DEBUG DEV_MODE DOCKER_CAPS \
	#   DOCKER_CMD_VARS DOCKER_DEVICES DOCKER_ENTRYPOINT DOCKER_EXTRA_MOUNTS \
	#   DOCKER_HOSTNAME DOCKER_INTERACTIVE DOCKER_PRIVILEGED \
	#   DOCKER_VOLUMES ECLASS_OVERRIDE EMERGE_OPTS FEATURES INSTALL_MASK \
	#   PYTHON_SINGLE_TARGET PYTHON_TARGETS ROOT TERM TRACE USE
	#inherit ARCH PKGDIR_OVERRIDE PKGDIR
	#inherit DOCKER_VERBOSE DOCKER_CMD
	#inherit image IMAGE

	print "_docker_run() called from '$( # <- Syntax
			printf '%s() <- ' "${FUNCNAME[@]}" |
				sed 's/ <- $//'
		)'"

	local dr_rm='' dr_id='' portage_log_dir=''
	local -i rc=0
	local -i rcc=0

	# Don't substitute if variable is assigned but empty...
	local BUILD_CONTAINER="${BUILD_CONTAINER-1}"

	local NO_BUILD_MOUNTS="${NO_BUILD_MOUNTS:-}"
	local NO_CPU_LIMITS="${NO_CPU_LIMITS:-}"
	local NO_LOAD_LIMITS="${NO_LOAD_LIMITS:-}"
	local NO_MEMORY_LIMITS="${NO_MEMORY_LIMITS:-}"
	local NO_REPO_MASKS="${NO_REPO_MASKS:-}"

	[[ "${BUILD_CONTAINER}" == '1' ]] || unset BUILD_CONTAINER

	[[ -n "${name:-}" ]] || dr_rm='--rm'

	if [[ -z "${name:-}" && -z "${container_name:-}" ]]; then
		error "One of 'name' or 'container_name' must be set"
		return 1
	fi

	[[ -n "${trace:-}" ]] && set -o xtrace

	trap '' INT
	# shellcheck disable=SC2086
	docker ${DOCKER_VARS:-} container ps --noheading |
			grep -qw -- "${name:-"${container_name}"}$" &&
		docker ${DOCKER_VARS:-} container stop --time 2 \
				"${name:-"${container_name}"}" >/dev/null
	# shellcheck disable=SC2086
	docker ${DOCKER_VARS:-} container ps --noheading -a |
			grep -qw -- "${name:-"${container_name}"}$" &&
		docker ${DOCKER_VARS:-} container rm --volumes \
				"${name:-"${container_name}"}" >/dev/null
	trap - INT

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
		$( # <- Syntax
				# shellcheck disable=SC2015
				if [[ -z "${NO_CPU_LIMITS:-}" ]] || ! (( NO_CPU_LIMITS )); then
					if
						[[ "$( uname -s )" != 'Darwin' ]] &&
							(( $( nproc ) > 1 )) &&
							docker info 2>&1 |
								grep -q -- 'cpuset'
					then
						# Pending a cleverer heuristic (... given *strange* CPU
						# configurations such as are found on the Radxa Orion
						# O6, or even more conventional big.LITTLE designs),
						# let's avoid the first CPU (0), on the basis that this
						# may have boot/tick/irq responsibillities...
						#
						# N.B. CPUs are indexed from 0 to `nproc`-1
						#
						echo "--cpuset-cpus 1-$(( $( nproc ) - 1 ))"
					fi
				fi
			)
		--init
		--name "${name:-"${container_name}"}"
		#--network slirp4netns
		# Some elements such as podman's go code tries to fetch packages from
		# IPv6-addressable hosts...
		--network host
		--pids-limit 1024
		  ${dr_rm:+"--rm"}
		--ulimit nofile=1024:1024
	)

	if [[ -n "${BUILD_CONTAINER:-}" && -z "${NO_BUILD_MOUNTS:-}" ]]; then
		# We have build-mounts, therefore assume that we're running a
		# build container...
		runargs+=(
			--privileged
		)
	else
		# This shouldn't cause much harm, regardless...
		FEATURES="${FEATURES:+"${FEATURES} "}"
		FEATURES="${FEATURES}-ipc-sandbox -mount-sandbox -network-sandbox"
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
			# shellcheck disable=SC2034  # Set from common/vars.sh
			[[ -n "${__COMMON_VARS_INCLUDED:-}" ]] || {
				echo >&2 "FATAL: Inclusion of common defaults failed"
				exit 1
			}
		fi

		local name='' ext=''
		name="$( # <- Syntax
				docker image ls |
					grep "${image/:/\\s*}" |
					awk '{ print $1 ":" $2 }'
			)" || :
		[[ -n "${name:-}" ]] && name="${name#*"/"}"
		case "${name}" in
			"${init_name#*"/"}:latest"|"${base_name#*"/"}:latest")
				: ;;
			"${build_name#*"/"}:latest")
				ext='.build' ;;
			"${build_name#*"/"}-root:latest")
				ext='.build' ;;
			service*:*)
				ext='.service' ;;
			*)
				ext='.build'
				warn "I don't know how to apply DEV_MODE to image '${image}'" \
					"- guessing 'entrypoint.sh${ext}'"
				;;
		esac
		unset name
		local dev_mode_script_dir="${PWD%"/"}"
		if [[ "${dev_mode_script_dir}" != *"/gentoo-base" ]]; then
			dev_mode_script_dir="${dev_mode_script_dir}/gentoo-base"
		fi
		if ! [[
				-f "${dev_mode_script_dir}/entrypoint.sh${ext}" &&
				-s "${dev_mode_script_dir}/entrypoint.sh${ext}"
		]]
		then
			die "Cannot locate DEV_MODE entrypoint script" \
				"'${dev_mode_script_dir}/entrypoint.sh${ext}'"
		elif ! [[ -x "${dev_mode_script_dir}/entrypoint.sh${ext}" ]]; then
			die "entrypoint script" \
				"'${dev_mode_script_dir}/entrypoint.sh${ext}' is not" \
				"executable"
		fi
		print "Running with 'entrypoint.sh${ext}' due to DEV_MODE"
		# shellcheck disable=SC2154,SC2207
		runargs+=( # <- Syntax
			--env DEV_MODE
			--env DEFAULT_JOBS="${JOBS}"
			  $( # <- Syntax
				if [[ -z "${NO_LOAD_LIMITS:-}" ]] || ! (( NO_LOAD_LIMITS ))
				then
					echo "--env DEFAULT_MAXLOAD=${MAXLOAD}"
				else
					echo "--env DEFAULT_MAXLOAD=0.00"
					echo "--env MAXLOAD=0.00"
				fi
				if [[ "${ext:-}" == '.build' ]]; then
					echo "--env log_dir=${log_dir:-}"
				fi
			  )
			--env environment_file="${environment_file}"
			--volume "${dev_mode_script_dir}/entrypoint.sh${ext}:/usr/libexec/entrypoint.sh:ro"
		)
		unset dev_mode_script_dir ext
	fi  # [[ -n "${DEV_MODE:-}" ]]

	if [[ -n "${DOCKER_CAPS:-}" ]]; then
		local arg='' caps=''

		for arg in ${DOCKER_CAPS}; do
			case "${arg:-}" in
				--cap-add=[A-Z]*)
					caps="${caps:+"${caps} "}${arg}" ;;
				[A-Z]*)
					caps="${caps:+"${caps} "}--cap-add=${arg}" ;;
				'')
					: ;;
				*)
					warn "Skipping unrecognised capability '${arg}'" ;;
			esac
		done
		DOCKER_CAPS="${caps:-}"

		unset caps arg
	fi  # [[ -n "${DOCKER_CAPS:-}" ]]

	if [[ -n "${USE:-}" ]]; then
		USE="$( echo "${USE}" | xargs -r )"
	fi

	# shellcheck disable=SC2206,SC2207
	runargs+=(
		  ${DOCKER_DEVICES:-}
		  $( add_arg DOCKER_ENTRYPOINT --entrypoint "${DOCKER_ENTRYPOINT:-}" )
		  $( add_arg ACCEPT_KEYWORDS --env %% )
		  $( add_arg ACCEPT_LICENSE --env %% )
		  #$( add_arg KBUILD_OUTPUT --env %% )
		  #$( add_arg KERNEL_DIR --env %% )
		  #$( add_arg KV_OUT_DIR --env %% )
		  $( add_arg PYTHON_SINGLE_TARGET --env %% )
		  $( add_arg PYTHON_TARGETS --env %% )
		  #$(
		  #		add_arg DOCKER_INTERACTIVE --env COLUMNS="$(
		  #			tput cols 2>/dev/null
		  #		)" --env LINES="$(
		  #			tput lines 2>/dev/null
		  #		)"
		  #)
		--env COLUMNS="$( tput cols 2>/dev/null || echo '80' )"
		--env LINES="$( tput lines 2>/dev/null || echo '24' )"
		  $( add_arg DEBUG --env %% )
		  $( add_arg ECLASS_OVERRIDE --env %% )
		  $( add_arg EMERGE_OPTS --env %% )
		  $( add_arg FEATURES --env %% )
		  $( add_arg INSTALL_MASK --env %% )
		  $( add_arg ROOT --env %% --env SYS%% --env PORTAGE_CONFIG%% )
		  $( add_arg TERM --env %% )
		  $( add_arg TRACE --env %% )
		  $( add_arg USE --env %% )
		  $( add_arg DOCKER_INTERACTIVE --interactive --tty )
		  $( add_arg DOCKER_PRIVILEGED --privileged )
		  ${DOCKER_EXTRA_MOUNTS:-}
		  ${DOCKER_VOLUMES:-}
		  ${DOCKER_CAPS:-}
		  $( add_arg DOCKER_HOSTNAME --hostname "${DOCKER_HOSTNAME:-}" )
	)

	if [[ -n "${DOCKER_CMD_VARS:-}" ]]; then
		# shellcheck disable=SC2206
		runargs+=( ${DOCKER_CMD_VARS} )
	elif [[ -n "${docker_cmd_vars[*]:-}" ]]; then
		runargs+=( "${docker_cmd_vars[@]:-}" )
	fi

	if [[ -z "${NO_MEMORY_LIMITS:-}" ]]; then
		if [[ -r /proc/cgroups ]] &&
				grep -q -- '^memory.*\s1$' /proc/cgroups &&
				[[ -n "${PODMAN_MEMORY_RESERVATION:-}" || -n "${PODMAN_MEMORY_LIMIT}" || -n "${PODMAN_SWAP_LIMIT}" ]]
		then
			# FIXME: Assume that PODMAN_{SWAP_LIMIT,MEMORY_{LIMIT,RESERVATION}}
			#        have the same order of magnitude...
			local -i swp=0 ram=0 changed=0
			local unit='' divider=''
			case "${PODMAN_MEMORY_LIMIT^^}" in
				*M)
					unit='m'
					divider='1024'
					;;
				*G)
					unit='g'
					divider='1024 / 1024'
					;;
			esac
			if [[ -n "${unit:-}" ]]; then
				# shellcheck disable=SC2004
				eval swp=$(( ( $(
					grep -m 1 'SwapTotal:' /proc/meminfo |
						awk '{ print $2 }'
				) + 16 ) / ${divider} ))
				# shellcheck disable=SC2004
				eval ram=$(( $(
					grep -m 1 'MemTotal:' /proc/meminfo |
						awk '{ print $2 }'
				) / ${divider} ))
				# shellcheck disable=SC2295
				if (( ram < ${PODMAN_MEMORY_LIMIT%[${unit,,}${unit^^}]} )) ||
						(( ( ram + swp ) < ${PODMAN_SWAP_LIMIT%[${unit,,}${unit^^}]} ))
				then
					output >&2 "INFO:  Host resources (rounded down to" \
						"nearest 1${unit^^}iB):"
					output >&2 "         RAM:        ${ram}${unit^^}"
					output >&2 "         Swap:       ${swp}${unit^^}"
					output >&2 "INFO:  Original memory limits:"
					# shellcheck disable=SC2295
					output >&2 "         Soft limit:" \
						"${PODMAN_MEMORY_RESERVATION%[${unit,,}${unit^^}]}${unit^^}"
					# shellcheck disable=SC2295
					output >&2 "         Hard limit:" \
						"${PODMAN_MEMORY_LIMIT%[${unit,,}${unit^^}]}${unit^^}"
					# shellcheck disable=SC2295
					output >&2 "         RAM + Swap:" \
						"${PODMAN_SWAP_LIMIT%[${unit,,}${unit^^}]}${unit^^}"
				fi
				# shellcheck disable=SC2295
				if (( ram < ${PODMAN_MEMORY_LIMIT%[${unit,,}${unit^^}]} ))
				then
					PODMAN_MEMORY_RESERVATION="$(( ram - 1 ))${unit,,}"
					PODMAN_MEMORY_LIMIT="$(( ram ))${unit,,}"
					#PODMAN_SWAP_LIMIT="$(( ram + swp ))${unit,,}"
					if (( ram <= 1 )); then
						PODMAN_SWAP_LIMIT="$(( ram * 2 ))${unit,,}"
					else
						PODMAN_SWAP_LIMIT="$(( ram + $(
							awk -v ram="${ram}" \
								'BEGIN{ print int( sqrt( ram ) + 0.5 ) }'
						) ))${unit,,}"
					fi
					changed=1
				fi
				# shellcheck disable=SC2295
				if (( ( ram + swp ) < ${PODMAN_SWAP_LIMIT%[${unit,,}${unit^^}]} ))
				then
					#PODMAN_SWAP_LIMIT="$(( ram + swp ))${unit,,}"
					if (( ram <= 1 )); then
						PODMAN_SWAP_LIMIT="$(( ram * 2 ))${unit,,}"
					else
						PODMAN_SWAP_LIMIT="$(( ram + $(
							awk -v ram="${ram}" \
								'BEGIN{ print int( sqrt( ram ) + 0.5 ) }'
						) ))${unit,,}"
					fi
					changed=1
				fi
				if (( changed )); then
					output >&2 "NOTE:  Changed memory limits based on host" \
						"configuration:"
					# shellcheck disable=SC2295
					output >&2 "         Soft limit:" \
						"${PODMAN_MEMORY_RESERVATION%[${unit,,}${unit^^}]}${unit^^}"
					# shellcheck disable=SC2295
					output >&2 "         Hard limit:" \
						"${PODMAN_MEMORY_LIMIT%[${unit,,}${unit^^}]}${unit^^}"
					# shellcheck disable=SC2295
					output >&2 "         RAM + Swap:" \
						"${PODMAN_SWAP_LIMIT%[${unit,,}${unit^^}]}${unit^^}"
					output >&2
				fi
			fi
			unset changed ram swp divider unit

			# shellcheck disable=SC2207
			runargs+=(
				$( add_arg PODMAN_MEMORY_RESERVATION \
					--memory-reservation "${PODMAN_MEMORY_RESERVATION}" )
				$( add_arg PODMAN_MEMORY_LIMIT \
					--memory "${PODMAN_MEMORY_LIMIT}" )
				$( add_arg PODMAN_SWAP_LIMIT \
					--memory-swap "${PODMAN_SWAP_LIMIT}" )
			)
			print "Using memory limits:" \
				"${PODMAN_MEMORY_RESERVATION}/${PODMAN_MEMORY_LIMIT}/${PODMAN_SWAP_LIMIT}"
		fi
	fi  # [[ -z "${NO_MEMORY_LIMITS:-}" ]]

	if [[ -z "${NO_BUILD_MOUNTS:-}" ]]; then
		local -a mirrormountpoints=()
		local -a mirrormountpointsro=()
		local -A mountpoints=()
		local -A mountpointsro=()
		local -i skipped=0
		local mp='' src=''  # cwd=''
		local ro="${docker_readonly:+",${docker_readonly}"}"
		local default_repo_path=''
		local default_distdir_path='' default_pkgdir_path=''

		# This should no longer be needed: a container-services/openldap
		# package can install be used to install extracted schema to
		# /etc/openldap/schema where required.
		#
		#if [[ -n "${BUILD_CONTAINER:-}" ]]; then
		#	if [[ -d '/etc/openldap/schema' ]] &&
		#			[[ -n "${name:-}" ]] &&
		#			[[ "${name%"-"*}" == 'buildsvc' ]]
		#	then
		#		src='/etc/openldap/schema/'
		#		mp='/service/etc/openldap/schema'
		#		runargs+=( --mount "type=bind,source=${src},destination=${mp}${ro}" )
		#		mp='' src=''
		#	fi
		#fi

		if [[ -n "${BUILD_CONTAINER:-}" ]]; then
			# We have build-mounts, therefore assume that we're running a
			# build container...
			runargs+=( --privileged )
		fi

		# If 'portageq' is not available, then ensure that all of the variables
		# referenced immediately prior are set so that it then never needs to
		# be called.
		#
		if ! type -pf portageq >/dev/null 2>&1; then
			warn "Using hard-coded defaults on non-Gentoo host system ..."
			default_repo_path='/var/db/repos/gentoo /var/db/repos/srcshelton'
			default_distdir_path='/var/cache/portage/dist'
			default_pkgdir_path="/var/cache/portage/pkg/${ARCH:-"${arch}"}/${PKGHOST:-"docker"}"
			if ! [[ -d /var/db/repos/gentoo || -L /var/db/repos/gentoo ]] &&
					[[ -d /var/db/repo/gentoo || -L /var/db/repo/gentoo ]]
			then
				default_repo_path="$( # <- Syntax
						readlink -e '/var/db/repo/gentoo'
					) $( # <- Syntax
						readlink -e '/var/db/repo/srcshelton'
					)"
			fi

			if [[ -s "${EROOT:-}"/etc/portage/repos.conf/srcshelton.conf ]] ||
					[[ "$( type -pf portageq 2>/dev/null )" == *portageq &&
							"$( # <- Syntax
									portageq get_repos "${EROOT:-"/"}"
								)" == *srcshelton* && -s "$( # <- Syntax
									portageq get_repo_path "${EROOT:-"/"}" \
										srcshelton
								)"/eclass/linux-info.eclass
						]]
			then
				# /var/lib/portage/eclass/linux-info is used by the
				# ::srcshelton repo to record kernel configuration
				# dependencies, but will not exist until the first package
				# which sets CONFIG_CHECK and inherits linux-info.eclass is
				# merged onto the hosts system - so let's create this directory
				# pre-emptively so that any package built (but potentially only
				# as a build-dependency) is also able to persistently record
				# its requirements.
				#
				# (Due to the potential lack of portageq, we'll assume that
				#  this repo has the linux-info.eclass override, rather than
				#  laboriously constructing the path to the from the conf file
				#  to verify manually...)
				#
				sudo mkdir -p /var/lib/portage/eclass/linux-info
				sudo chown "${EUID:-"$( id -u )"}:root" \
					/var/lib/portage/eclass/linux-info
				sudo chmod ug+rwX /var/lib/portage/eclass/linux-info
				touch -a /var/lib/portage/eclass/linux-info/.keep
			fi
		fi
		if [[ -n "${PKGDIR_OVERRIDE:-}" ]]; then
			default_pkgdir_path="${PKGDIR_OVERRIDE}"
		fi

		# shellcheck disable=SC2046,SC2206,SC2207
		mirrormountpointsro=(
			# We need write access to be able to update eclasses...
			#/etc/portage/repos.conf

			${default_repo_path:-"$( # <- Syntax
					portageq get_repo_path "${EROOT:-"/"}" $( # <- Syntax
						portageq get_repos "${EROOT:-"/"}"
					)
				)"}

			#/etc/locale.gen  # FIXME: Uncommented in inspect.docker?

			#/usr/src  # FIXME: Breaks gentoo-kernel-build package
		)

		# N.B.: Read repo-specific masks from the host system...
		if [[ -z "${NO_REPO_MASKS:-}" && -d /etc/portage/package.mask ]]
		then
			while read -r mp; do
				mirrormountpointsro+=( "${mp}" )
			done < <(
				find /etc/portage/package.mask/ \
					-mindepth 1 \
					-maxdepth 1 \
					-type f \
					-name 'repo-*-mask' \
					-print
			)
		fi

		if [[ -n "${BUILD_CONTAINER:-}" ]]; then
			portage_log_dir="${PORTAGE_LOGDIR:-"${PORT_LOGDIR:-"$( # <- Syntax
					emerge --info 2>&1 |
						grep -E -- '^PORT(AGE)?_LOGDIR=' |
						head -n 1 |
						cut -d'"' -f 2 || :
				)"}"}"
			mirrormountpoints=(
				#/var/cache/portage/dist
				"${default_distdir_path:-"$( portageq distdir )"}"
				'/etc/portage/savedconfig'
				"${portage_log_dir:-"/var/log/portage"}"
			)
			unset portage_log_dir

			if [[ -z "${arch:-}" ]]; then
				_docker_setup
			fi

			#ENV PKGDIR="${PKGCACHE:-"/var/cache/portage/pkg"}/${ARCH:-"amd64"}/${PKGHOST:-"docker"}"
			#local PKGCACHE="${PKGCACHE:="/var/cache/portage/pkg"}"
			#local PKGHOST="${PKGHOST:="docker"}"
			local PKGDIR="${PKGDIR:="${default_pkgdir_path:-"$( portageq pkgdir )"}"}"

			# Allow use of 'ARCH' variable as an override...
			print "Using architecture '${ARCH:-"${arch}"}' ..."
			mountpoints["${PKGDIR}"]="/var/cache/portage/pkg/${ARCH:-"${arch}"}/${PKGHOST:-"docker"}"
			unset PKGDIR
		fi
		mountpointsro['/etc/portage/repos.conf']='/etc/portage/repos.conf.host'

		# FIXME: crun errors when rootless due to lack of write support into
		#        /etc/portage...
		if [[ -s "gentoo-base/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}" ]]; then
			if [[ -w /etc/portage/package.accept_keywords && ! -e "/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}" ]]; then
				mountpointsro["${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}"]="/etc/portage/package.accept_keywords/${ARCH:-"${arch}"}"
			else
				warn "Cannot mount" \
					"'${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}'" \
					"due to lack of write permission for '$( id -nu )' on" \
					"'/etc/portage/package.accept_keywords', or" \
					"'/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}'" \
					"already exists (due to another running container?)"
			fi
		fi

		#cwd="$( dirname "$( readlink -e "${BASH_SOURCE[$(( ${#BASH_SOURCE[@]} - 1 ))]}" )" )"
		#print "Volume/mount base directory is '${cwd}'"
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.accept_keywords"]='/etc/portage/package.accept_keywords'
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.license"]='/etc/portage/package.license'
		#mountpointsro["${cwd}/gentoo-base/etc/portage/package.use.build"]='/etc/portage/package.use'

		local mps=''
		for mps in ${mirrormountpointsro[@]+"${mirrormountpointsro[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				if ! src="$( readlink -e "${mp}" )"; then
					warn "readlink() on mirrored read-only mountpoint '${mp}'" \
						"failed: ${?}"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mp}${ro}" )
			done
		done
		for mps in ${mirrormountpoints[@]+"${mirrormountpoints[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				if ! src="$( readlink -e "${mp}" )"; then
					warn "readlink() on mirrored mountpoint '${mp}'" \
						"failed: ${?}"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mp}" )
			done
		done
		for mps in ${mountpointsro[@]+"${!mountpointsro[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				if ! src="$( readlink -e "${mp}" )"; then
					warn "readlink() on read-only mountpoint '${mp}'" \
						"failed: ${?}"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}' ->" \
						"'${mountpointsro[${mp}]}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mountpointsro[${mp}]}${ro}" )
			done
		done
		for mps in ${mountpoints[@]+"${!mountpoints[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				if ! src="$( readlink -e "${mp}" )"; then
					warn "readlink() on mountpoint '${mp}' failed (do you" \
						"need to set 'PKGDIR'?): ${?}"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}' ->" \
						"'${mountpoints[${mp}]}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mountpoints[${mp}]}" )
			done
		done

		if [[ -n "${name:-}" ]] &&
				[[ -n "${base_name:-}" ]] &&
				[[ -n "${init_name:-}" ]]
		then
			if [[ "${name}" == "${base_name#*"/"}" ]] &&
					[[ "${image}" == "${init_name}:latest" ]]
			then
				# Prevent portage from outputting:
				#
				# !!! It seems /run is not mounted. Process management may malfunction.
				#
				info "Providing '/run' mount-point during initial base-image" \
					"build ..."
				runargs+=( --mount "type=tmpfs,tmpfs-size=64M,destination=/run" )
			fi
		fi

		if [[ $(( skipped )) -ge 1 ]]; then
			warn "${skipped} mount-points not connected to container"
			sleep 5
		fi

		unset src mps mp
	fi  # [[ -z "${NO_BUILD_MOUNTS:-}" ]]

	if [[ "${runargs[*]}" != *--privileged* ]]; then
		# This shouldn't cause much harm, regardless...
		FEATURES="${FEATURES:+"${FEATURES} "}"
		FEATURES="${FEATURES}-ipc-sandbox -mount-sandbox -network-sandbox"
		export FEATURES
	fi

	if [[ -n "${DOCKER_VERBOSE:-}" ]]; then
		output
		[[ -n "${DOCKER_VARS:-}" ]] &&
			output "VERBOSE: DOCKER_VARS is '${DOCKER_VARS}'"
		local arg='' next=''
		for arg in "${runargs[@]}"; do
			case "${next}" in
				mount)
					arg="$( # <- Syntax
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
				next="${arg#"--"}"
			else
				next=''
			fi
		done | column -t -s $'\t'
		unset next arg
		output
	fi  # [[ -n "${DOCKER_VERBOSE:-}" ]]

	(
		[[ -n "${DOCKER_CMD:-}" ]] && set -- "${DOCKER_CMD}"

		# DEBUG:
		# shellcheck disable=SC2030
		if [[ -n "${DOCKER_VARS:-}" ]]; then
			output "Defined ${BUILD_CONTAINER:+"pre-build"} container images:"
			set -x
			# shellcheck disable=SC2086
			eval docker ${DOCKER_VARS:-} image ls --noheading
			set +x
			output "Defined ${BUILD_CONTAINER:+"pre-build"} additional-store" \
				"container tasks:"
			set -x
			# shellcheck disable=SC2086
			eval docker ${DOCKER_VARS:-} container ps --noheading -a
			set +x
			output "Defined ${BUILD_CONTAINER:+"pre-build"} container tasks:"
			# shellcheck disable=SC2086
			docker ${DOCKER_VARS:-} container ps --noheading -a
		fi

		image="${image:-"${IMAGE:-"gentoo-build:latest"}"}"

		if (( debug )); then
			local arg='' bn=''
			print "Starting ${BUILD_CONTAINER:+"build"} container with" \
				"command '${_command} container run \\"
			for arg in "${runargs[@]}"; do
				case "${arg}" in
					--*)	print "    ${arg} \\" ;;
					*)		print "        ${arg} \\" ;;
				esac
			done
			print "  ${image}${*:+" \\"}"
			for arg in "${@:-}"; do
				if ! (( _common_run_show_command )) && [[ "${arg}" == '-c' ]]
				then
					print "    ${arg} ..."
					break
				fi
				[[ -n "${arg:-}" ]] && print "    ${arg} \\"
			done
			print "'"
			unset arg

			# N.B. "${0}" is the calling script, *not* run.sh!
			bn="$( basename "${0}" )"
			if mkdir -p "${log_dir:="$( # <- Syntax
							dirname "$( # <- Syntax
								readlink -e "${0}"
							)"
						)/log"}" &&
					touch "${log_dir}/debug.common.${bn}.log"
			then
				cat > "${log_dir}/debug.common.${bn}.log" <<-EOF
					#! /bin/sh

					set -eux

				EOF
				echo >> "${log_dir}/debug.common.${bn}.log" \
					"${_command} container run \\"
				for arg in "${runargs[@]}"; do
					echo >> "${log_dir}/debug.common.${bn}.log" \
						"        '${arg}' \\"
				done
				echo >> "${log_dir}/debug.common.${bn}.log" \
					"    '${image}' \\"
				# Start at $1 as $0 is the command itself...
				local -i i=1
				for (( ; i < ${#} ; i++ )); do
					echo >> "${log_dir}/debug.common.${bn}.log" \
						"        '${!i}' \\"
				done
				# At this point i == ${#}...
				echo >> "${log_dir}/debug.common.${bn}.log" \
					"        '${!i}'"
				unset i
			fi
			unset bn
		fi
		# shellcheck disable=SC2086
		docker \
				${DOCKER_VARS:-} \
			container run \
				"${runargs[@]}" \
			"${image}" ${@+"${@}"}
	)
	rc=${?}

	# shellcheck disable=SC2031,SC2086
	if
		dr_id="$( # <- Syntax
						docker ${DOCKER_VARS:-} container ps --noheading -a |
							grep -B 1 -- "\s${name:-"${container_name}"}$" |
							grep -E '^[[:xdigit:]]{12}\s' |
							tail -n 1 |
							awk '{ print $1 }'
				)" &&
			[[ -n "${dr_id:-}" ]]
	then
		rcc=$( # <- Syntax
					docker ${DOCKER_VARS:-} container inspect \
						--format='{{.State.ExitCode}}' "${dr_id}"
				) ||
			:
	fi

	if [[ -n "${rcc:-}" && "${rc}" -ne "${rcc}" ]]; then
		if [[ "${rc}" -gt "${rcc}" ]]; then
			warn "Return code (${rc}) differs from container exit code" \
				"(${rcc}) - proceeding with former ..."
		else
			warn "Return code (${rc}) differs from container exit code" \
				"(${rcc}) - proceeding with latter ..."
			rc=${rcc}
		fi
	else
		print "'${_command} container run' returned '${rc}'"
	fi

	[[ -n "${trace:-}" ]] && set +o xtrace

	# shellcheck disable=SC2086
	return ${rc}
}  # _docker_run

# Invokes container launch with package-build arguments
#
_docker_build_pkg() {
	[[ -n "${USE:-}" ]] &&
		info "USE override: '$( echo "${USE}" | xargs echo -n )'"

	# shellcheck disable=SC2016
	info "Building package '${package}'" \
		"${extra[*]+"plus additional packages '${extra[*]}' "}into" \
		"container '${name:-"${container_name}"}' ..."

	# shellcheck disable=SC2086
	_docker_run "=${package}${repo:+"::${repo}"}" \
		${extra[@]+"${extra[@]}"} ${args[@]+"${args[@]}"}

	return ${?}
}  # _docker_build_pkg

# Garbage collect
#
_docker_prune() {
	# shellcheck disable=SC2086
	#docker ${DOCKER_VARS:-} system prune --all --filter 'until=24h' \
	#	--filter 'label!=build' --filter 'label!=build.system' --force \
	#	--volumes
	#
	# volumes can't be pruned with a filter :(
	# shellcheck disable=SC2086
	#docker ${DOCKER_VARS:-} volume prune --force

	trap '' INT
	# shellcheck disable=SC2031,SC2086
	docker ${DOCKER_VARS:-} container ps --noheading |
		rev |
		cut -d' ' -f 1 |
		rev |
		grep -- '_' |
		xargs -r /bin/sh -c docker ${DOCKER_VARS:-} \
			container stop --time 2 >/dev/null
	# shellcheck disable=SC2031,SC2086
	docker ${DOCKER_VARS:-} container ps --noheading -a |
		rev |
		cut -d' ' -f 1 |
		rev |
		grep -- '_' |
		xargs -r /bin/sh -c docker ${DOCKER_VARS:-} \
			container rm --volumes >/dev/null

	# shellcheck disable=SC2031,SC2086
	docker ${DOCKER_VARS:-} image ls |
		grep -- '^<none>\s\+<none>' |
		awk '{ print $3 }' |
		xargs -r /bin/sh -c docker ${DOCKER_VARS:-} image rm
	trap - INT

	return 0
}  # _docker_prune

# Default entrypoint
#
_docker_build() {
	if [[ -z "${*:-}" ]]; then
		warn "No options passed to '_docker_build()'"
	fi

	_docker_setup || return ${?}
	_docker_parse ${@+"${@}"} || return ${?}
	_docker_resolve || return ${?}
	_docker_build_pkg || return ${?}
	#_docker_prune

	return ${?}
}  # _docker_build

if ! echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	if [[ -n "${IMAGE:-}" ]]; then
		info "Using default image '${IMAGE}'"
	else
		warn "No default '\${IMAGE}' specified"
	fi
fi

if [[ ! -d "${PWD%"/"}/gentoo-base" ]] &&
		[[ ! -x "${PWD%"/"}/gentoo-build-web.docker" ]]
then
	die "Cannot locate required directory 'gentoo-base' in '${PWD%"/"}'"
fi

# Are we using docker or podman?
if type -pf podman >/dev/null 2>&1; then
	_command='podman'
	docker() {
		if [[ -n "${debug:-}" ]] && (( debug > 1 )); then
			# FIXME: 'trace' isn't available in old (pre-4.x?) releases of
			#        podman...
			set -- --log-level trace ${@+"${@}"}
		fi
		podman ${@+"${@}"}
	}  # docker
	export -f docker

	#extra_build_args='--format docker'
	# From release 2.0.0, podman should accept docker 'readonly' attributes
	docker_readonly='ro=true'
elif type -pf docker >/dev/null 2>&1; then
	# More subtle differences between `docker` and `podman`:
	#
	#  * docker does not support podman's `--noheading` option - the same could
	#    be achieved via a `--format` template (see [1]), but this requires the
	#    default output to be explicitly restated;
	#  * docker warns that `build` is deprecated if the separate package
	#    `docker-buildx` (by Debian/Ubuntu naming) is not installed;
	#  * `docker build` output with `buildx` installed is much more verbose
	#    (and harder to read) than `docker build` output without `buildx`, or
	#    podman/buildah's `build` output.
	#
	# [1] https://docs.docker.com/config/formatting/
	#
	_command='docker'
	docker() {
		if [[ " ${*:-} " == *" --noheading "* ]]; then
			declare arg=''
			for arg in "${@}"; do
				case "${arg:-}" in
					'--noheading')
						: ;;
					'')
						: ;;
					*)
						set -- "${@}" "${arg}"
						;;
				esac
				shift
			done
			$( which docker ) ${@+"${@}"} | tail -n +2
		else
			$( which docker ) ${@+"${@}"}
		fi
	}  # docker
	export -f docker

	#extra_build_args=''
	docker_readonly='readonly'
else
	die "Cannot find 'docker' or 'podman' executable in path in common/run.sh"
fi
export _command docker_readonly  # extra_build_args

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker sw=4 ts=4 syntax=bash noexpandtab nowrap:
