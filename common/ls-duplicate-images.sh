#! /usr/bin/env bash

[[ -z "${TRACE:-}" ]] || set -o xtrace

cd "$( dirname "${0}" )/.." || exit 1

# shellcheck disable=SC1091
. ./common/container-engine-helpers.sh

declare -a all=( --filter 'reference=localhost/*' )
declare latest='latest'
declare arg=''
for arg in "${@}"; do
	case "${arg}" in
		-h|--help)
			printf 'Usage: %s [--all] [--latest]\n' "${0##*/}"
			container_engine_help
			exit 0
			;;
		--all)
			all=()
			;;
		--latest)
			latest=''
			;;
		*)
			printf >&2 "FATAL: Unknown option '%s'\n" "${arg}"
			exit 1
			;;
	esac
done
unset arg

# shellcheck disable=SC1091
. ./common/vars.sh
IMAGE='none'
# shellcheck disable=SC1091
. ./common/run.sh >/dev/null

#                1                               2    3        4      5
php_pattern_1='^(localhost/service.dev-lang.php)'
php_pattern_1+='([[:space:]]+)([0-9])\.([0-9])(\..*)$'
php_replacement_1='\1\3\4 \3.\4\5'
#                localhost/service.dev-lang.php          8   .    2    .28-r1
#                localhost/service.dev-lang.php82 8.2.28-r1
#
#                1                               2            3
php_pattern_2='^(localhost/service.dev-lang.php)([0-9]{2})[[:space:]]+(.*)$'
php_replacement_2='\1-\3'
#                localhost/service.dev-lang.php82 8.2.28-r1
#                localhost/service.dev-lang.php-8.2.28-r1

images="$(
	docker image list --noheading "${all[@]}"			|
		{
			if (( ${#all[@]} )); then
				grep -- '^localhost/'
			else
				cat
			fi
		} 							|
		sed -E "s|${php_pattern_1}|${php_replacement_1}|"		|
		awk '{print $1}'						|
		grep -v '<none>'						|
		sort								|
		uniq -c								|
		awk '( $1 > 1 ) { print $2 }'					|
		while IFS= read -r name; do
			if [[ -z "${latest}" ]]; then
				docker image list "${name}"
			else
				result="$( docker image list "${name}" )"
				if ! grep -qw "${latest}" <<<"${result}"; then
					printf '%s\n' "${result}"
				fi
			fi
		done								|
		tr -s '[:space:]'						|
		sort -rV							|
		uniq								|
		sed -E '
			s/ IMAGE ID / IMAGE_ID / ;
			s/ ([0-9]+) ([^ ]+) ago / \1_\2_ago / ;
			s/ About (an?) ([^ ]+) ago / About_\1_\2_ago / ;
			s/ (.)B$/_\1B/
		'								|
		column -t							|
		sed -E '
			s/IMAGE_ID/IMAGE ID/ ;
			s/([0-9]+)_([^_]+)_ago/\1 \2 ago/ ;
			s/About_([^_]+)_([^_]+)_ago/About \1 \2 ago/ ;
			s/_(.)B$/ \1B/
		'								|
		sed -E "s|${php_pattern_2}|${php_replacement_2}|"
)"

# Relocate headers to top of output...
#printf '%s\n' "${images}" | tail -n 1
#printf '%s\n' "${images}" | head -n -1
grep -m 1 '^REPOSITORY[[:space:]]' <<<"${images}"
grep -v -e '^REPOSITORY[[:space:]]' -e '^[[:space:]]*$' <<<"${images}"

# vi: set sw=8 ts=8:
