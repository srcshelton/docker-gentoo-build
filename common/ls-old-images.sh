#! /bin/sh

#set -o xtrace

if echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" )"
	exit 0
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

filter='--filter reference=localhost/*'
images="$( eval "${_command} image list ${filter:-}" )"
lines="$( echo "${images}" | wc -l )"

# FIXME: Use 'base_name', etc. from vars.sh

echo "${images}" | head -n 1

echo "${images}" |
	grep --colour=always -- '^localhost/gentoo-build.*$'

echo "${images}" |
	grep -A "${lines:-"100"}" -- '^localhost/gentoo-build' |
	grep -v -e '^localhost/gentoo-\(build\|base\|init\|stage3\|env\)' -e '^docker.io/gentoo/stage3' |
	grep --colour=never -- '^localhost/\(service\|sys-kernel\.\)'

# vi: set sw=8 ts=8:
