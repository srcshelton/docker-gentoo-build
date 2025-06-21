#! /bin/sh

set -u

debug="${DEBUG:-"0"}"

def_repo="$( portageq repositories_configuration / | grep -m 1 '^\[DEFAULT\]$' -A 64 | grep -m 1 '^$' -B 64 | grep -- '^main-repo = ' | cut -d'=' -f 2- | xargs )"
if [ -z "${def_repo:-}" ]; then
	echo >&2 "FATAL: Cannot read DEFAULT portage repo"
	exit 1
fi
def_repo_path="$( portageq get_repo_path / "${def_repo}" )"
if [ -z "${def_repo_path:-}" ] || [ ! -d "${def_repo_path}" ]; then
	echo >&2 "FATAL: Cannot access DEFAULT portage repo path '${def_repo_path:-}'"
	exit 1
fi
# shellcheck disable=SC2010
arch="$( ls -1 "${def_repo_path}"/profiles/desc/cpu_flags_*.desc | grep -o '...\.desc$' | cut -d'.' -f 1 )"
if [ -z "${arch:-}" ]; then
	echo >&2 "FATAL: Could not read 'cpu_flags_*.desc' file(s) from '${def_repo_path}/profiles/desc/'"
	exit 1
fi

if echo " ${*} " | grep -Eq ' -(h|-help) '; then
	echo "Usage: $( basename "${0}" ) [$( printf '%s' "${arch}" | tr '\n' '|' )]"
	exit 0
fi

if [ ! -s "${def_repo_path}/profiles/desc/cpu_flags_${1:-"x86"}.desc" ]; then
	echo >&2 "FATAL: No CPU flags description found for architecture '${1:-"x86"}'"
	exit 1
fi

while read -r line; do
	echo "${line}" | grep -q -- ' - ' || continue

	flag="$( echo "${line}" | awk -F' - ' '{print $1}' )"
	[ $(( debug )) -eq 1 ] && echo >&2 "DEBUG: Found description for flag '${flag}' ($line)"
	if echo "${line}" | grep -- "^${flag} - " | grep -Fq -- '[' ; then
		count=2
		while true; do
			extra="$( echo "${line}" | awk -F'[' "{print \$${count}}" | cut -d']' -f 1 )"
			if [ -n "${extra:-}" ]; then
				[ $(( debug )) -eq 1 ] && echo >&2 "DEBUG: Found extra flag '${extra}'"
				flag="${flag}|${extra}"
			else
				break
			fi
			: $(( count = count + 1 ))
		done
		unset extra count
	fi
	#echo "${flag:-}"
	grep -- '^flags' /proc/cpuinfo | tail -n 1 | awk -F': ' '{print $2}' | grep -Eq -- "${flag}" && echo "${flag}" | cut -d'|' -f 1
done < "${def_repo_path}/profiles/desc/cpu_flags_${1:-"x86"}.desc"

exit 0
