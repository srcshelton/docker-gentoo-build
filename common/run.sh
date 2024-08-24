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
# We don't want to put the system under undue memory-pressure, but at the same
# time sys-devel/gcc and sys-devel/llvm no longer compile with 4GB RAM... so
# let's see whether we can get away with 5GB?  Parallel builds may also require
# more memory than this too, of course :o
#
# Update: 5GB isn't enough, but 6GB appears to be, just.  That's at least a 50%
#         increase in memory required between gcc-11 and gcc-12 :(
#         dev-python/pypy3_10-exe-7.3.12_p2 OOMs with 2GB reservation/8GB limit
#         but appears to succeed with 10GB limit.
#
: "${PODMAN_MEMORY_RESERVATION:="2g"}"
: "${PODMAN_MEMORY_LIMIT:="12g"}"
: "${PODMAN_SWAP_LIMIT:="${PODMAN_MEMORY_LIMIT}"}"

_command='docker'

# shellcheck disable=SC2034
debug=${DEBUG:-}
trace=${TRACE:-}

declare -i _common_run_show_command=1

# Output functions...
#

output() {
	if [[ -z "${*:-}" ]]; then
		echo
	else
		echo -e "${*:-}"
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
	if [[ -n "${debug:-}" ]]; then
		if [[ -z "${*:-}" ]]; then
			output >&2
		else
			if [[ -n "${BASH_SOURCE[-1]:-}" ]]; then
				output >&2 "DEBUG: $( # <- Syntax
					basename "${BASH_SOURCE[-1]}"
				)->${BASH_SOURCE[0]}: ${*}"
			else
				output >&2 "DEBUG: $( basename "${0}" ): ${*}"
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

replace_flags() {
	# list="$( replace_flags <new> [flags] [to] [add] -- existing_list[@] )"
	local -a flags=() list=() output=()
	local -A seen=()
	local -i state=0
	local arg='' flag=''

	for arg in "${@:-}"; do
		case "${arg:-}" in
			--)
				#print "Switching state from 'list' ('${list[*]:-}') to" \
				#	"'flags' ('${flags[*]:-}') ..."
				state=1
				continue
				;;
			''|' ')
				#print "Dropping arg '${arg:-}' ..."
				:
				;;
			*' '*)
				arg="$( sed 's/^ \+// ; s/ \+$//' <<<"${arg}" )"
				if (( state )); then
					#print "Adding multi arg '${arg:-}' to list" \
					#	"'${list[*]:-}' ..."
					readarray -O "${#list[@]}" -t list < <( # <- Syntax
						xargs -rn 1 <<<"${arg}"
					)
					#print "... list is '${list[*]:-}'"
				else
					#print "Adding multi arg '${arg:-}' to flags" \
					#	"'${flags[*]:-}' ..."
					readarray -O "${#flags[@]}" -t flags < <( # <- Syntax
						xargs -rn 1 <<<"${arg}"
					)
					#print "... flags is '${flags[*]:-}'"
				fi
				;;
			*)
				if (( state )); then
					#print "Adding arg '${arg:-}' to list '${list[*]:-}' ..."
					list+=( "${arg}" )
					#print "... list is '${list[*]:-}'"
				else
					#print "Adding arg '${arg:-}' to flags '${flags[*]:-}' ..."
					flags+=( "${arg}" )
					#print "... flags is '${flags[*]:-}'"
				fi
				;;
		esac
	done
	#print "Adding flags '${flags[*]:-}' to list '${list[*]:-}'"

	if (( 0 == ${#flags[@]} )); then
		print "WARN: No flags supplied to ${FUNCNAME[0]} - received '${*:-}'"
		return 1
	fi

	for flag in "${flags[@]}"; do
		# Remove existing instances of '(-)flag'...
		#
		for arg in "${list[@]}"; do
			case "${arg}" in
				"-${flag#"-"}"|"${flag#"-"}"|'')
					# Do nothing, as we add the flag below...
					:
					# N.B. This means that if we have '-flag flag' then the
					#      second occurence is dropped...
					seen["${arg#"-"}"]=1
					;;
				*)
					if ! (( seen["${arg}"] )); then
						output+=( "${arg}" )
						seen["${arg}"]=1
					fi
					continue
					;;
			esac
		done

		# ... and then add '(-)flag' to the start of end of the list
		#
		case "${flag}" in
			'')
				:
				;;
			-*)
				if [[ -z "${output[*]:-}" ]]; then
					output=( "${flag}" )
				else
					output=( "${flag}" "${output[@]}" )
				fi
				#print "Adding flag '${flag}' to start of list ..."
				;;
			*)
				if ! (( seen["${flag}"] )); then
					output+=( "${flag}" )
					seen["${flag}"]=1
				fi
				#print "Adding flag '${flag}' to end of list ..."
				;;
		esac
	done

	#print "replace_flags result: '${output[*]:-}'"
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

export -f replace_flags add_arg add_mount

#[[ -n "${trace:-}" ]] && set -o xtrace

if [[ "$( uname -s )" == 'Darwin' ]]; then
	readlink() {
		perl -MCwd=abs_path -le 'print abs_path readlink(shift);' "${2}"
	}  # readlink
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

			elif echo "${dp_arg}" |
					grep -Eq -- '((virtual|[a-z]{3,7}-[a-z]+)/)?[a-zA-Z0-9][a-zA-Z0-9_.+-]+\*?(:[0-9.]+\*?)?(::.*)?$'
			then
				# Currently category general names are between 3 and
				# 7 ("gnustep") letters, package names start with [023469Z] or
				# lower-case...
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

	if [[ ! -x "$( command -v versionsort )" ]] ||
			[[ ! -x "$( command -v equery )" ]]
	then
		# On non-Gentoo systems we need to build 'eix' (for 'versionsort') and
		# 'equery' into a container, and then call that to acquire "proper"
		# package-version handling facilities.
		# shellcheck disable=SC2086
		if
			docker ${DOCKER_VARS:-} image ls localhost/gentoo-helper:latest |
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
			export -f versionsort

			equery() {
				local result=''
				local -i rc=0

				# We'll execute this container via _docker_run rather than
				# by direct invocation, so that we get all of the necessary
				# repo directories mounted...
				result="$( # <- Syntax
					BUILD_CONTAINER=0 \
					NO_MEMORY_LIMITS=1 \
					image='' \
					IMAGE='localhost/gentoo-helper:latest' \
					container_name='gentoo-helper' \
						_docker_run equery "${@:-}"
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
					repopath="$( portageq get_repo_path "${EROOT:-"/"}" $(
						portageq get_repos "${EROOT:-"/"}" |
							xargs -rn 1 2>/dev/null |
							grep -iw gentoo |
							tail -n 1
					))"
				elif [[ -d /var/db/repos ]]; then
					repopath='/var/db/repos/gentoo'
				elif [[ -d /var/db/repo ]]; then
					repopath='/var/db/repo/gentoo'
				else
					die "Unable to locate 'gentoo' repo directory"
				fi

				for arg in "${@:-}"; do
					if [[ "${arg}" == */* ]]; then
						cat="${arg%"/"*}"
						pkg="${arg#*"/"}"
					else
						pkg="${arg}"
						cat="$( # <- Syntax
							eval ls -1d "${repopath}/*/${pkg}*" |
								rev |
								cut -d'/' -f 3 |
								rev
						)"
					fi
					for eb in $( # <- Syntax
						eval ls -1 "${repopath}/${cat}/${pkg}*" |
							grep -- '\.ebuild$'
					); do
						slot='0.0'
						masked=' '
						keyworded=' '
						# I - Installed
						# P - In portage tree
						# O - In overlay
						if [[ -s "${repopath}/${cat}/${pkg%"-"[0-9]*}/${eb}" ]]
						then
							eval "$( # <- Syntax
								grep 'SLOT=' \
									"${repopath}/${cat}/${pkg%"-"[0-9]*}/${eb}"
							)"
							slot="${SLOT:-"${slot}"}"
							if grep -Fq "~${arch}" \
									"${repopath}/${cat}/${pkg%"-"[0-9]*}/${eb}"
							then
								keyworded='~'
							fi
						fi
						echo "[-P-]" \
							"[${masked}${keyworded}]" \
							"${cat}/${eb%".ebuild"}:${slot}"
					done
				done
			}  # equery
			export -f equery
		fi
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
	)" || dr_name="$( # <- Syntax
		versionsort -n "${dr_package##*[<>=]}-0" 2>/dev/null
	)" || :
	dr_pattern='-~'
	if [[ "${FORCE_KEYWORDS:-}" == '1' ]]; then
		dr_pattern='-'
	fi
	# Ensure that ebuilds keyworded for building are checked when confirming
	# the package to build...
	sudo mkdir -p /etc/portage/package.accept_keywords 2>/dev/null || :
	if ! [[ -d /etc/portage/package.accept_keywords ]]; then
		die "'/etc/portage/package.accept_keywords' must be a directory"
	else
		if [[ -e "${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords" ]]
		then
			TMP_KEYWORDS="$( # <- Syntax
				sudo mktemp -p /etc/portage/package.accept_keywords/ "$( # <- Syntax
					basename -- "${0#"-"}"
				).XXXXXXXX"
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
	if [[ -n "${TMP_KEYWORDS:-}" ]] && [[ -e "${TMP_KEYWORDS}" ]]; then
		sudo rm "${TMP_KEYWORDS}"
		trap - SIGHUP SIGINT SIGQUIT
		unset TMP_KEYWORDS
	fi
	if [[ -z "${dr_name:-}" ]] || [[ -z "${dr_package:-}" ]]; then
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

	# Don't substitute if variable is assigned but empty...
	local BUILD_CONTAINER="${BUILD_CONTAINER-1}"

	local NO_BUILD_MOUNTS="${NO_BUILD_MOUNTS:-}"
	local NO_MEMORY_LIMITS="${NO_MEMORY_LIMITS:-}"
	local NO_REPO_MASKS="${NO_REPO_MASKS:-}"

	[[ "${BUILD_CONTAINER}" == '1' ]] || unset BUILD_CONTAINER

	[[ -n "${name:-}" ]] || dr_rm='--rm'

	if [[ -z "${name:-}" ]] && [[ -z "${container_name:-}" ]]; then
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

	# FIXME: Make this package-specific hack generic (or unneeded!)
	if [[ -n "${BUILD_CONTAINER:-}" ]] && [[ -z "${NO_BUILD_MOUNTS:-}" ]]; then
		if [[ -d '/etc/openldap/schema' ]] &&
				[[ -n "${name:-}" ]] &&
				[[ "${name%"-"*}" == 'buildsvc' ]]
		then
			DOCKER_EXTRA_MOUNTS="${DOCKER_EXTRA_MOUNTS:+"${DOCKER_EXTRA_MOUNTS} "}"
			DOCKER_EXTRA_MOUNTS="${DOCKER_EXTRA_MOUNTS}--mount type=bind,source=/etc/openldap/schema/,destination=/service/etc/openldap/schema"
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
		$( # <- Syntax
			# shellcheck disable=SC2015
			if
				[[ "$( uname -s )" != 'Darwin' ]] &&
					(( $( nproc ) > 1 )) &&
					docker info 2>&1 |
						grep -q -- 'cpuset'
			then
				echo "--cpuset-cpus 1-$(( $( nproc ) - 1 ))"
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
	if [[ -n "${BUILD_CONTAINER:-}" ]] && [[ -z "${NO_BUILD_MOUNTS:-}" ]]; then
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
		runargs+=( # <- Syntax
			  --env DEV_MODE
			  --env DEFAULT_JOBS="${JOBS}"
			  --env DEFAULT_MAXLOAD="${MAXLOAD}"
			  --env environment_file="${environment_file}"
			  --volume "${dev_mode_script_dir}/entrypoint.sh${ext}:/usr/libexec/entrypoint.sh:ro"
		)
		unset dev_mode_script_dir ext
	fi

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
		  $( add_arg ROOT --env %% --env SYS%% --env PORTAGE_CONFIG%% )
		  $( add_arg TERM --env %% )
		  $( add_arg TRACE --env %% )
		  $( add_arg USE --env %% )
		  $( add_arg DOCKER_INTERACTIVE --interactive --tty )
		  $( add_arg DOCKER_PRIVILEGED --privileged )
		  ${DOCKER_EXTRA_MOUNTS:-}
		  ${DOCKER_VOLUMES:-}
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
		fi
	fi
	if [[ -z "${NO_BUILD_MOUNTS:-}" ]]; then
		local -a mirrormountpoints=()
		local -a mirrormountpointsro=()
		local -A mountpoints=()
		local -A mountpointsro=()
		local -i skipped=0
		local mp='' src=''  # cwd=''
		local default_repo_path='' default_distdir_path=''
		local default_pkgdir_path=''

		if ! type -pf portageq >/dev/null 2>&1; then
			default_repo_path='/var/db/repos/gentoo /var/db/repos/srcshelton'
			default_distdir_path='/var/cache/portage/dist'
			default_pkgdir_path='/var/cache/portage/pkg'
			if [[ ! -d /var/db/repos/gentoo ]] && [[ -d /var/db/repo/gentoo ]]
			then
				default_repo_path='/var/db/repo/gentoo /var/db/repo/srcshelton'
			fi
		fi
		if [[ -n "${PKGDIR_OVERRIDE:-}" ]]; then
			default_pkgdir_path="${PKGDIR_OVERRIDE}"
		fi

		# shellcheck disable=SC2046,SC2206,SC2207
		mirrormountpointsro=(
			## We need write access to be able to update eclasses...
			#/etc/portage/repos.conf

			${default_repo_path:-"$( # <- Syntax
				portageq get_repo_path "${EROOT:-"/"}" $(
					portageq get_repos "${EROOT:-"/"}"
				)
			)"}

			#/etc/locale.gen

			#/usr/src  # Breaks gentoo-kernel-build package
		)

		# N.B.: Read repo-specific masks from the host system...
		if [[ -z "${NO_REPO_MASKS:-}" ]] && [[ -d /etc/portage/package.mask ]]
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
			mirrormountpoints=(
				#/var/cache/portage/dist
				"${default_distdir_path:-"$( portageq distdir )"}"
				'/etc/portage/savedconfig'
				'/var/log/portage'
			)

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
		fi
		mountpoints['/etc/portage/repos.conf']='/etc/portage/repos.conf.host'

		if [[ -s "gentoo-base/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}" ]]; then
			mountpointsro["${PWD%"/"}/gentoo-base/etc/portage/package.accept_keywords.${ARCH:-"${arch}"}"]="/etc/portage/package.accept_keywords/${ARCH:-"${arch}"}"
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
				src="$( readlink -e "${mp}" )" ||
					die "readlink() on mirrored read-only mountpoint '${mp}'" \
						"failed: ${?}"
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mp}${docker_readonly:+",${docker_readonly}"}" )
			done
		done
		for mps in ${mirrormountpoints[@]+"${mirrormountpoints[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				src="$( readlink -e "${mp}" )" ||
					die "readlink() on mirrored mountpoint '${mp}'" \
						"failed: ${?}"
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
				src="$( readlink -e "${mp}" )" ||
					die "readlink() on read-only mountpoint '${mp}'" \
						"failed: ${?}"
				if [[ -z "${src:-}" ]]; then
					warn "Skipping mountpoint '${mp}' ->" \
						"'${mountpointsro[${mp}]}'"
					: $(( skipped = skipped + 1 ))
					continue
				fi
				runargs+=( --mount "type=bind,source=${src},destination=${mountpointsro[${mp}]}${docker_readonly:+",${docker_readonly}"}" )
			done
		done
		for mps in ${mountpoints[@]+"${!mountpoints[@]}"}; do
			[[ -n "${mps:-}" ]] || continue
			for mp in ${mps}; do
				src="$( readlink -e "${mp}" )" ||
					die "readlink() on mountpoint '${mp}' failed (do you" \
						"need to set 'PKGDIR'?): ${?}"
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
	fi

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
			local arg=''
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
			if touch common.run.sh.debug.log; then
				cat > common.run.sh.debug.log <<-EOF
					#! /bin/sh

					set -eux

				EOF
				echo >> common.run.sh.debug.log "${_command} container run \\"
				for arg in "${runargs[@]}"; do
					echo >>common.run.sh.debug.log "        '${arg}' \\"
				done
				echo >> common.run.sh.debug.log "    '${image}' \\"
				# Start at $1 as $0 is the command itself...
				local -i i=1
				for (( ; i < ${#} ; i++ )); do
					echo >> common.run.sh.debug.log "        '${!i}' \\"
				done
				# At this point i == ${#}...
				echo >> common.run.sh.debug.log "        '${!i}'"
				unset i
			fi
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
		) || :
	fi

	if [[ -n "${rcc:-}" ]] && [[ "${rc}" -ne "${rcc}" ]]; then
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
if ! type -pf podman >/dev/null 2>&1; then
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
	_command='podman'
	docker() {
		podman ${@+"${@}"}
	}  # docker
	export -f docker

	#extra_build_args='--format docker'
	# From release 2.0.0, podman should accept docker 'readonly' attributes
	docker_readonly='ro=true'
fi
export _command docker_readonly  # extra_build_args

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker sw=4 ts=4 syntax=bash noexpandtab nowrap:
