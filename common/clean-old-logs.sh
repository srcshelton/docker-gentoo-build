#! /bin/sh

set -eu
set -o pipefail >/dev/null 2>&1 || :

debug="${DEBUG:-}"
trace="${TRACE:-}"

# Mis-interacts with 'qatom' :(
unset DEBUG

if ! command -v qatom >/dev/null 2>&1; then
	echo >&2 "FATAL: 'qatom' not found, please install" \
		"app-portage/portage-utils"
	exit 1
fi

cd "$( realpath -e "$( dirname "${0}" )" )" || {
	echo >&2 "FATAL: chdir() to '$( # <- Syntax
			realpath -e "$( dirname "${0}" )"
		)' failed: ${?}"
	exit 1
}

# shellcheck disable=SC1091
[[ ! -s ./vars.sh ]] || . ./vars.sh
# shellcheck disable=SC2034  # Set from vars.sh
[[ -n "${__COMMON_VARS_INCLUDED:-}" ]] || {
		echo >&2 "FATAL: Inclusion of common defaults from" \
			"'${PWD}/vars.sh' failed"
		exit 1
	}

[ -d "${log_dir:="$( # <- Syntax
			realpath -e "$( # <- Syntax
				dirname "$( # <- Syntax
					realpath -e "${0}"
				)"
			)/.."
		)/log"}" ] || {
	echo >&2 "FATAL: Cannot locate log directory"
	exit 1
	}

file='' prefix='' name='' guard=''

if [ $(( debug )) -ge 1 ]; then
	echo >&2 "DEBUG: Checking for old logs beneath '${log_dir}' ..."
	guard='echo'
fi

[ $(( trace )) -ge 1 ] && set -o xtrace

find "${log_dir}/" \
			-mindepth 1 \
			-maxdepth 1 \
			-type f \
			-name '*.log' \
			-print |
		sort -V |
		while read -r file
do
	case "$( basename "${file}" )" in
		'buildsvc.'*|'buildweb.'*|'service.'*)
			prefix="$( basename "${file}" | cut -d'.' -f 1 )"
			name="$( basename "${file}" | cut -d'.' -f 2- | sed 's|\.|/| ; s/\.log$//' )"
			;;
		'sys-kernel.'*'clang-'*)
			prefix=''
			# sys-kernel-* can have two version components: the kernel version
			# itself, and the LLVM/clang compiler used...
			name="$( basename "${file}" | sed 's|\.clang-.*$|| ; s|\.|/|' )"
			;;
		'sys-kernel.'*)
			prefix=''
			name="$( basename "${file}" | sed 's|\.|/| ; s/\.log$//' )"
			;;
		'web.'*)
			prefix=''
			name="$( basename "${file}" | sed 's|\.|/| ; s/\.log$//' )"
			;;
		*)
			if [ $(( debug )) -ge 1 ]; then
				echo >&2 "DEBUG: Skipping persistent log '$( # <- Syntax
						basename "${file}"
					)' ..."
			fi
			continue
			;;
	esac

	if [ $(( debug )) -ge 1 ]; then
		echo >&2 "DEBUG: ... checking for versions of '${file}' (${prefix:-}" \
			"${name}) ..."
	fi

	printf '%s %s\n' "$( qatom -CF '%{CATEGORY}/%{PN}' "${name}" )" "${prefix}"
done |
	sort -V |
	uniq |
	while read -r name prefix; do
		file="${prefix:+"${prefix}."}$( echo "${name}" | sed 's|/|.|' )"

		if [ $(( debug )) -ge 1 ]; then
			echo >&2 "DEBUG: ... checking for matches for name '${file}'" \
				"(${prefix:-} ${name})"
		fi

		find "${log_dir}/" \
				-mindepth 1 \
				-maxdepth 1 \
				-type f \
				-name "${file}-[0-9]*" \
				-print |
			sort  -V |
			head -n -1
	done |
	xargs -r ${guard:-} rm -v

# vi: set colorcolumn=80:
