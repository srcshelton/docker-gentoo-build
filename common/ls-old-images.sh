#! /bin/sh

#set -o xtrace

if echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" )"
	exit 0
fi

if [ $(( $( id -u ) )) -ne 0 ]; then
        echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
        exit 1
fi

filter='--filter reference=localhost/*'
images="$( eval "podman image list ${filter:-}" )"
lines="$( echo "${images}" | wc -l )"

echo "${images}" | head -n 1

echo "${images}" |
	grep --colour=always '^localhost/gentoo-build.*$'

echo "${images}" |
	grep '^localhost/gentoo-build' -A "${lines:-"100"}" |
	grep -v -e '^localhost/gentoo-\(build\|base\|init\|stage3\|env\)' -e '^docker.io/gentoo/stage3' |
	grep --colour=never '^localhost/\(service\|sys-kernel\.\)'

# vi: set sw=8 ts=8:
