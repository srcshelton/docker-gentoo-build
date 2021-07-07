#! /usr/bin/env bash

set -u

find_seq() {
	local file="${1:-}"

	[[ -n "${file:-}" ]] || return 1

	path="$( dirname "${file}" )"
	name="$( basename "${file}" )"

	local -i counter=1

	while [[ -e "$( printf '%s/._cfg%04d_%s' "${path}" ${counter} "${name}" )" ]]; do
		(( counter++ ))
	done

	printf '%s/._cfg%04d_%s' "${path}" ${counter} "${name}"
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

type -pf portageq >/dev/null 2>&1 || {
	echo >&2 "FATAL: Cannot locate 'portageq' utility"
	exit 1
}

(( EUID )) && {
	echo >&2 "Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
}

declare -r ARCH="$( portageq envvar ARCH )"
declare -i rc=0

for file in *.${ARCH}; do
	[[ "${file}" == "${file#.}" ]] || continue
	diff -q "${file}" "/etc/portage/${file%.${ARCH}}/${file}" >/dev/null 2>&1 && continue
	cp -v "${file}" "$( find_seq "/etc/portage/${file%.${ARCH}}/${file}" )" ||
		(( rc = 2 ))
done

for file in color.map package.accept_keywords/* package.mask/* profile/use.mask savedconfig/*/*; do
	[[ "${file}" == "${file#.}" ]] || continue
	diff -q "${file}" "/etc/portage/${file}" >/dev/null 2>&1 && continue
	cp -v "${file}" "$( find_seq "/etc/portage/${file}" )" ||
		(( rc = 2 ))
done

for file in package.use.build/*; do
	[[ "${file}" == "${file#.}" ]] || continue
	diff -q "${file}" "/etc/portage/package.use/${file#package.use.build/}" >/dev/null 2>&1 && continue
	cp -v "${file}" "$( find_seq "/etc/portage/package.use/${file#package.use.build/}" )" ||
		(( rc = 2 ))
done

for file in /etc/portage/savedconfig/*/*; do
	[[ "${file}" == "${file#.}" ]] || continue
	diff -q "${file}" "/etc/portage/${file#/etc/portage/}" >/dev/null 2>&1 && continue
	cp -v "${file}" "$( find_seq "${file#/etc/portage/}" )" ||
		(( rc = 2 ))
done

exit ${rc}
