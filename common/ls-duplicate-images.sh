#! /bin/sh

if echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" ) [--all]"
	exit 0
fi

if [ $(( $( id -u ) )) -ne 0 ]; then
        echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
        exit 1
fi

all='localhost'
if echo " ${*:-} " | grep -Fq -- ' --all '; then
	all=''
fi

output="$(
	eval "podman image ls${all:+ ${all}}"						|
		cut -d' ' -f 1								|
		grep -v '<none>'							|
		sort									|
		uniq -c									|
		awk '( $1 > 1 ) { print $2 }'						|
		while read -r name; do
			podman image ls "${name}"
		done									|
		tr -s '[:space:]'							|
		sed -r 's/IMAGE ID/IMAGE_ID/ ; s/ ([0-9]+) ([^ ]+) ago / \1_\2_ago /'	|
		sort -rV								|
		uniq									|
		column -t								|
		sed -r 's/IMAGE_ID/IMAGE ID/ ; s/([0-9]+)_([^_]+)_ago/\1 \2 ago/'
)"

echo "${output}" | tail -n 1

echo "${output}" | head -n -1

# vi: set sw=8 ts=8:
