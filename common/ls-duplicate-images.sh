#! /bin/sh

#set -o xtrace

if echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" ) [--all] [--latest]"
	exit 0
fi

if [ $(( $( id -u ) )) -ne 0 ]; then
        echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
        exit 1
fi

all='--filter reference=localhost/*'
latest='latest'
if echo " ${*:-} " | grep -Fq -- ' --all '; then
	all=''
fi
if echo " ${*:-} " | grep -Fq -- ' --latest '; then
	latest=''
fi

images="$(
	eval "podman image list --noheading ${all:+" ${all}"}"			|
		cut -d' ' -f 1							|
		grep -v '<none>'						|
		sort								|
		uniq -c								|
		awk '( $1 > 1 ) { print $2 }'					|
		while read -r name; do
			if [ -z "${latest:-}" ]; then
				podman image list "${name}"
			else
				result="$( podman image list "${name}" )"
				if ! echo "${result:-}" | grep -qw "${latest}"; then
					echo "${result}"
				fi
			fi
		done								|
		tr -s '[:space:]'						|
		sort -rV							|
		uniq								|
		sed -r '
			s/ IMAGE ID / IMAGE_ID / ;
			s/ ([0-9]+) ([^ ]+) ago / \1_\2_ago / ;
			s/ About (an?) ([^ ]+) ago / About_\1_\2_ago / ;
			s/ (.)B$/_\1B/
		'								|
		column -t							|
		sed -r '
			s/IMAGE_ID/IMAGE ID/ ;
			s/([0-9]+)_([^_]+)_ago/\1 \2 ago/ ;
			s/About_([^_]+)_([^_]+)_ago/About \1 \2 ago/ ;
			s/_(.)B$/ \1B/
		'
)"

# Relocate headers to top of output...
#echo "${images}" | tail -n 1
#echo "${images}" | head -n -1
echo "${images}" | grep -m 1 '^REPOSITORY\s'
echo "${images}" | grep -v '^REPOSITORY\s'

# vi: set sw=8 ts=8:
