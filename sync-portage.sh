#! /usr/bin/env bash

set -u

find_seq() {
	local file="${1:-}"

	#if ! [[ -e "${file}" ]]; then
	#	printf '%s' "${file}"
	#	return 0
	#fi

	[[ -n "${file:-}" ]] || return 1

	path="$( dirname "${file}" )"
	name="$( basename "${file}" )"

	local -i counter=0

	while [[ -e "$( printf '%s/._cfg%04d_%s' "${path}" ${counter} "${name}" )" ]]; do
		(( counter++ ))
	done

	printf '%s/._cfg%04d_%s' "${path}" "${counter}" "${name}"
} # find_seq()

declare -r base_dir='gentoo-base'

cd "$( dirname "$( readlink -e "${0}" )" )" || {
	echo >&2 "FATAL: chdir() to script directory failed: ${?}"
	exit 1
}

cd "${base_dir}"/etc/portage/ || {
	echo >&2 "FATAL: chdir() to '${base_dir}/etc/portage' failed: ${?}"
	exit 1
}

declare ARCH=''
if type -pf portageq >/dev/null 2>&1; then
	ARCH="$( portageq envvar ARCH )"
else
	echo >&2 "WARN:  Cannot locate 'portageq' utility"
	case "$( uname -m )" in
		aarch64)
			ARCH='arm64' ;;
		arm*)
			ARCH='arm' ;;
		x86_64)
			ARCH='amd64' ;;
		*)
			echo >&2 "FATAL: Unknown architecture '$( uname -m )'"
			exit 1
			;;
	esac
fi
readonly ARCH

(( EUID )) && {
	echo >&2 "Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
}

if [[ " ${*:-} " =~ \ -(h|-help)\  ]]; then
	echo "Usage: $( basename "${0}" ) [--dispatch-conf]"
	exit 0
elif [[ " ${*:-} " =~ \ --dispatch-conf\  ]]; then
	declare file='' name=''
	find /etc/portage/ -type f -name '._cfg[0-9]{4}_*' -print |
		while read -r update
	do
		name="$( echo "${update}" | cut -d'_' -f 3- )"
		if ! [[ -e "${name}" ]]; then
			echo >&2 "Can't find original file '${name}' for update" \
				"'${update}' - skipping"
			continue
		elif diff "${name}" "${update}"; then
			rm "${update}"
		else
			vimdiff \
						-c 'set colorcolumn=80' \
						-c 'next' \
						-c 'setlocal noma readonly' \
						-c 'prev' \
					"${name}" "${update}" &&
				rm "${update}"
		fi
	done
	exit 0
fi

declare -i rc=0

for file in *."${ARCH}"; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "/etc/portage/${file%".${ARCH}"}/${file}" ]]; then
		diff -q "${file}" "/etc/portage/${file%".${ARCH}"}/${file}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "/etc/portage/${file%".${ARCH}"}/${file}" )"
		cp -v "${file}" "$( find_seq "/etc/portage/${file%".${ARCH}"}/${file}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "/etc/portage/${file%".${ARCH}"}/${file}" )"
		cp -v "${file}" "/etc/portage/${file%".${ARCH}"}/${file}" ||
			(( rc = 2 ))
	fi
done

for file in color.map package.accept_keywords/* package.mask/* profile/use.mask profile/package.use.mask savedconfig/*/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue

	declare fsrc="${file}" fdst="${file}"
	if [[ -e "${file}.${ARCH}" && -f "${file}.${ARCH}" && -s "${file}.${ARCH}" ]]; then
		fsrc="${file}.${ARCH}"
	fi

	[[ -f "${fsrc}" ]] || continue

	if [[ -s "/etc/portage/${fdst}" ]]; then
		diff -q "${fsrc}" "/etc/portage/${fdst}" >/dev/null 2>&1 &&
			continue
		mkdir -p "$( dirname "/etc/portage/${fdst}" )"
		cp -v "${fsrc}" "$( find_seq "/etc/portage/${fdst}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "/etc/portage/${fdst}" )"
		cp -v "${fsrc}" "/etc/portage/${fdst}" ||
			(( rc = 2 ))
	fi

	unset fdst fsrc
done

for file in package.unmask "package.unmask.${ARCH}"; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -f "/etc/portage/${file}" ]]; then
		echo >&2 "WARN:  Migrating file '/etc/portage/${file}' to '/etc/portage/package.unmask/'"

		if [[ "${file}" == 'package.unmask' ]]; then
			file="${file}.tmp"
			mv "/etc/portage/${file%".tmp"}" "/etc/portage/${file}"
		fi
		mkdir -p /etc/portage/package.unmask
		mv "/etc/portage/${file}" "/etc/portage/package.unmask/${file%".tmp"}"
	fi

	if [[ -s "/etc/portage/package.unmask/${file}" ]]; then
		diff -q "${file}" "/etc/portage/package.unmask/${file}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "/etc/portage/package.unmask/${file}" )"
		cp -v "${file}" "$( find_seq "/etc/portage/package.unmask/${file}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "/etc/portage/package.unmask/${file}" )"
		cp -v "${file}" "/etc/portage/package.unmask/${file}" ||
			(( rc = 2 ))
	fi
done

for file in package.use.build/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "/etc/portage/package.use/${file#"package.use.build/"}" ]]; then
		diff -q "${file}" "/etc/portage/package.use/${file#"package.use.build/"}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "/etc/portage/package.use/${file#"package.use.build/"}" )"
		cp -v "${file}" "$( find_seq "/etc/portage/package.use/${file#"package.use.build/"}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "/etc/portage/package.use/${file#"package.use.build/"}" )"
		cp -v "${file}" "/etc/portage/package.use/${file#"package.use.build/"}" ||
			(( rc = 2 ))
	fi
done

for file in /etc/portage/savedconfig/*/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "/etc/portage/${file#"/etc/portage/"}" ]]; then
		diff -q "${file}" "/etc/portage/${file#"/etc/portage/"}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "${file#"/etc/portage/"}" )"
		cp -v "${file}" "$( find_seq "${file#"/etc/portage/"}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${file#"/etc/portage/"}" )"
		cp -v "${file}" "${file#"/etc/portage/"}" ||
			(( rc = 2 ))
	fi
done

exit ${rc}
