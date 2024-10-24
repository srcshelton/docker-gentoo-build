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

	while [[ -e "$(
				printf '%s/._cfg%04d_%s' "${path}" ${counter} "${name}"
			)" ]]
	do
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

if [[ " ${*:-} " =~ \ -(h|-help)\  ]]; then
	echo "Usage: $( basename "${0}" ) [--dispatch-conf]"
	exit 0
else
	(( EUID )) && {
		echo >&2 "Please re-run '$( basename "${0}" )' as user 'root'"
		exit 1
	}

	if [[ " ${*:-} " =~ \ --dispatch-conf\  ]]; then
		declare file='' dir='' name=''
		while read -r update; do
			dir="$( dirname "${update}" )"
			name="$( basename "${update}" | cut -d'_' -f 3- )"
			if ! [[ -e "${dir}/${name}" ]]; then
				echo >&2 "WARN:  Can't find original file '${dir}/${name}'" \
					"for update '${update}' - skipping"
				continue
			elif diff "${dir}/${name}" "${update}"; then
				rm "${update}"
			else
				vimdiff --not-a-term \
							-c 'set colorcolumn=80' \
							-c 'next' \
							-c 'setlocal noma readonly' \
							-c 'prev' \
						-- "${dir}/${name}" "${update}" </dev/tty &&
					rm "${update}"
			fi
		done < <(
			find "${ROOT:-}/etc/portage"/ \
					-type f \
					-name '._cfg[0-9][0-9][0-9][0-9]_*' \
					-print
		)
		exit 0
	fi
fi

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

declare -i rc=0

for file in *."${ARCH}"; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" ]]; then
		diff -q "${file}" "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" )"
		cp -v "${file}" "$( find_seq "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" )"
		cp -v "${file}" "${ROOT:-}/etc/portage/${file%".${ARCH}"}/${file}" ||
			(( rc = 2 ))
	fi
done

for file in color.map package.accept_keywords/* package.mask/* profile/use.mask profile/package.use.force profile/package.use.mask savedconfig/*/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue

	declare fsrc="${file}" fdst="${file}"
	if [[ -e "${file}.${ARCH}" && -f "${file}.${ARCH}" && -s "${file}.${ARCH}" ]]; then
		fsrc="${file}.${ARCH}"
	fi

	[[ -f "${fsrc}" ]] || continue

	if [[ -s "${ROOT:-}/etc/portage/${fdst}" ]]; then
		diff -q "${fsrc}" "${ROOT:-}/etc/portage/${fdst}" >/dev/null 2>&1 &&
			continue
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/${fdst}" )"
		cp -v "${fsrc}" "$( find_seq "${ROOT:-}/etc/portage/${fdst}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/${fdst}" )"
		cp -v "${fsrc}" "${ROOT:-}/etc/portage/${fdst}" ||
			(( rc = 2 ))
	fi

	unset fdst fsrc
done

for file in package.unmask "package.unmask.${ARCH}"; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -f "${ROOT:-}/etc/portage/${file}" ]]; then
		echo >&2 "WARN:  Migrating file '${ROOT:-}/etc/portage/${file}' to '${ROOT:-}/etc/portage/package.unmask/'"

		if [[ "${file}" == 'package.unmask' ]]; then
			file="${file}.tmp"
			mv "${ROOT:-}/etc/portage/${file%".tmp"}" "${ROOT:-}/etc/portage/${file}"
		fi
		mkdir -p "${ROOT:-}/etc/portage/package.unmask"
		mv "${ROOT:-}/etc/portage/${file}" "${ROOT:-}/etc/portage/package.unmask/${file%".tmp"}"
	fi

	if [[ -s "${ROOT:-}/etc/portage/package.unmask/${file}" ]]; then
		diff -q "${file}" "${ROOT:-}/etc/portage/package.unmask/${file}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/package.unmask/${file}" )"
		cp -v "${file}" "$( find_seq "${ROOT:-}/etc/portage/package.unmask/${file}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/package.unmask/${file}" )"
		cp -v "${file}" "${ROOT:-}/etc/portage/package.unmask/${file}" ||
			(( rc = 2 ))
	fi
done

for file in package.use.build/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" ]]; then
		diff -q "${file}" "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" )"
		cp -v "${file}" "$( find_seq "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" )"
		cp -v "${file}" "${ROOT:-}/etc/portage/package.use/${file#"package.use.build/"}" ||
			(( rc = 2 ))
	fi
done

for file in "${ROOT:-}/etc/portage/savedconfig"/*/*; do
	# Skip hidden files...
	[[ "${file}" == "${file#"."}" ]] || continue
	[[ -f "${file}" ]] || continue

	if [[ -s "${ROOT:-}/etc/portage/${file#"${ROOT:-}/etc/portage/"}" ]]; then
		diff -q "${file}" "${ROOT:-}/etc/portage/${file#"${ROOT:-}/etc/portage/"}" >/dev/null 2>&1 && continue
		mkdir -p "$( dirname "${file#"${ROOT:-}/etc/portage/"}" )"
		cp -v "${file}" "$( find_seq "${file#"${ROOT:-}/etc/portage/"}" )" ||
			(( rc = 2 ))
	else
		mkdir -p "$( dirname "${file#"${ROOT:-}/etc/portage/"}" )"
		cp -v "${file}" "${file#"${ROOT:-}/etc/portage/"}" ||
			(( rc = 2 ))
	fi
done

exit ${rc}

# vi: set noet sw=4 ts=4:
