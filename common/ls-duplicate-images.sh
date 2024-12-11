#! /bin/sh

#set -o xtrace

if echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" ) [--all] [--latest]"
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
elif [ $(( $( id -u ) )) -ne 0 ] &&
		echo "${_output}" | grep -Fq -- 'rootless: false'
then
	echo >&2 "FATAL: Please re-run '$( basename "${0}")' as user 'root'"
	exit 1
fi
unset _output

all='--filter reference=localhost/*'
latest='latest'
if echo " ${*:-} " | grep -Fq -- ' --all '; then
	all=''
fi
if echo " ${*:-} " | grep -Fq -- ' --latest '; then
	latest=''
fi

php_pattern_1='^(localhost/service.dev-lang.php)(\s+)([0-9])\.([0-9])(\..*)$'
php_replacement_1='\1\3\4\2\3.\4\5'
php_pattern_2='^(localhost/service.dev-lang.php)([0-9]{2})(.*)$'
php_replacement_2='\1\3'

images="$(
	eval "${_command} image list --noheading ${all:+" ${all}"}"		|
		sed -r "s|${php_pattern_1}|${php_replacement_1}|"		|
		awk '{ print $1 }'						|
		grep -v '<none>'						|
		sort								|
		uniq -c								|
		awk '( $1 > 1 ) { print $2 }'					|
		while read -r name; do
			if [ -z "${latest:-}" ]; then
				"${_command}" image list "${name}"
			else
				result="$( "${_command}" image list "${name}" )"
				if ! echo "${result:-}" | grep -qw "${latest}"
				then
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
		'								|
		sed -r "s|${php_pattern_2}|${php_replacement_2}|"
)"

# Relocate headers to top of output...
#echo "${images}" | tail -n 1
#echo "${images}" | head -n -1
echo "${images}" | grep -m 1 '^REPOSITORY\s'
echo "${images}" | grep -v -e '^REPOSITORY\s' -e '^\s*$'

# vi: set sw=8 ts=8:
