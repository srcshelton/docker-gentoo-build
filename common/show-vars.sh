#! /bin/sh

#debug="${DEBUG:-}"
trace="${TRACE:-}"

# Copied from vars.sh - it's not worth running the whole script just for these!
#
bold="$( printf '\e[1m' )"
red="$( printf '\e[31m' )"
green="$( printf '\e[32m' )"
blue="$( printf '\e[34m' )"
purple="$( printf '\e[35m' )"
#
# Place 'reset' last to prevent coloured xtrace output!
#
reset="$( printf '\e[0m' )"
export bold red green blue purple reset

colour=1
image=''
labels=0
value=''

[ $(( trace )) -ne 0 ] && set -o xtrace

for arg in "${@:-}"; do
	case "${arg}" in
		-C|--no-colour)
			colour=0
			;;
		--labels)
			labels=1
			;;
		-h|--help)
			echo >&2 "Usage: $( basename "${0}" ) [--no-colour] [--labels] [--value=<string>] <image>"
			exit 0
			;;
		-v*)
			if [ -z "${value:-}" ]; then
				value="${arg#"-v"}"
			else
				echo >&2 "FATAL: Too many values ('${value} ${arg#"-v"}') - only one supported"
				exit 1
			fi
			;;
		--value=*)
			if [ -z "${value:-}" ]; then
				value="${arg#"--value="}"
			else
				echo >&2 "FATAL: Too many values ('${value} ${arg#"--value="}') - only one supported"
				exit 1
			fi
			;;
		*)
			if [ -z "${image:-}" ]; then
				image="${arg}"
			else
				echo >&2 "FATAL: Too many images ('${image} ${arg}') - only one supported"
				exit 1
			fi
			;;
	esac
done

if [ -z "${image:-}" ]; then
	echo >&2 "Usage: $( basename "${0}" ) <image>"
	exit 1
fi

_command='docker'
if command -v podman >/dev/null 2>&1; then
	_command='podman'
fi

_output=''
if ! [ -x "$( command -v "${_command}" )" ]; then
	echo >&2 "FATAL: Cannot locate binary '${_command}'"
	exit 1
elif ! _output="$( "${_command}" info 2>&1 )"; then
	if [ "${_command}" = 'podman' ]; then
		echo >&2 "FATAL: Unable to successfully execute" \
			"'${_command}' - do you need to run '${_command}" \
			"machine start' or re-run '$( basename "${0}" )' as" \
			"'root'?"
	else
		echo >&2 "FATAL: Unable to successfully execute" \
			"'${_command}' - do you need to re-run" \
			"'$( basename "${0}" )' as 'root'?"
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

tab="$( printf '\t' )"

# The 'inspect' command works with containers (and container IDs) too...
if [ "$( "${_command}" image list --noheading "${image}" | wc -l )" -gt '1' ]; then
	echo >&2 "WARN:  Cannot determine unique image '${image}'"
	#exit 1
fi

# See https://github.com/containers/podman/issues/8785
#buildah inspect --format '{{ .OCIv1.Config.Env }}' "${image}" |
#	tr "${tab}" ' ' |
#	tr -s '[:space:]' |
#	sed -r 's/^\[(.*)\]$/\1/' |
#	sed -r 's/ ([A-Za-z][A-Za-z0-9_-]*)=/\n\1=/g' ; echo

if [ $(( labels )) -ne 0 ]; then
	"${_command}" image inspect --format '{{ .Config.Labels }}' "${image}" |
		eval "sed -r  \
			-e 's/^map\[(.*)\]$/\1/' \
			-e 's/^([A-Za-z][A-Za-z0-9._-]*):/\1: /' \
			-e 's/ ([A-Za-z][A-Za-z0-9._-]*):/\n\1: /g' \
			$(
				if [ $(( colour )) -ne 0 ] ; then
					printf "| sed 's/^/%s/ ; s/: /%s: /'" "${purple}" "${reset}"
					# shellcheck disable=SC2030,SC2031
					if [ -n "${value:-}" ]; then
						echo "| sed -e '/${value}.*: /s/${value}/${value}${purple}/' -e 's/${value}/${bold}${red}${value}${reset}/g'"
					fi
				fi
			)"
else
	"${_command}" image inspect --format '{{ .Config.Env }}' "${image}" |
		tr "${tab}" ' ' |
		tr -s '[:space:]' |
		eval "sed -r \
			-e 's/^\[(.*)\]$/\1/' \
			-e 's/ ([A-Za-z][A-Za-z0-9._-]*)=/\n\1=/g' \
			$(
				if [ $(( colour )) -ne 0 ] ; then
					printf "| sed 's/^/%s/ ; s/=/%s: /'" "${purple}" "${reset}"
					# shellcheck disable=SC2030,SC2031
					if [ -n "${value:-}" ]; then
						echo "| sed -e '/${value}.*: /s/${value}/${value}${purple}/' -e 's/${value}/${bold}${red}${value}${reset}/g'"
					fi
				fi
			)"
fi
