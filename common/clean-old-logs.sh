#! /bin/sh

set -eu

PREFIX='docker'

debug="${DEBUG:-}"

# Mis-interacts with 'qatom' :(
unset DEBUG

if ! command -v qatom >/dev/null 2>&1; then
	echo >&2 "FATAL: 'qatom' not found, please install" \
		"app-portage/portage-utils"
	exit 1
fi

guard=''
if [ $(( debug )) -ge 1 ]; then
	guard='echo'
	set -o xtrace
fi

dir="$( realpath -e "$( dirname "$( realpath -e "${0}" )" )/../log/" )"

[ -d "${dir}" ] || exit 1

f='' p='' n=''
find "${dir}/" \
			-mindepth 1 \
			-maxdepth 1 \
			-type f \
			-name '*.log' \
			-print |
		while read -r f
do
	echo "${f}" | grep -Fq -- "/${PREFIX}." || continue

	p="$( basename "${f}" | cut -d'.' -f 1-2 )"
	n="$( basename "${f}" | cut -d'.' -f 3- | sed 's|\.|/| ; s/\.log$//' )"

	printf '%s ' "${p}"
	qatom -CF '%{CATEGORY}/%{PN}' "${n}"
done |
	sort |
	uniq |
	while read -r p n; do
		f="${p}.$( echo "${n}" | sed 's|/|.|' )"
		find "${dir}/" \
				-mindepth 1 \
				-maxdepth 1 \
				-type f \
				-name "${f}-[0-9]*" \
				-print |
			sort  -V |
			head -n -1
	done |
	xargs -r ${guard:-} rm -v

# vi: set colorcolumn=80:
