#! /usr/bin/env bash

set -u
set -o pipefail

debug="${DEBUG:-}"

ARCH="${1:-arm64}"
SKIP='raspberrypi'

print() {
	if (( debug )); then
		if [[ -n "${*:-}" ]]; then
			echo >&2 "DEBUG: ${*:-}"
		else
			echo >&2 "DEBUG"
		fi
	fi
}

die() {
	echo >&2 "FATAL: ${*:-Unknown error}"
	exit 1
}

cd "$( dirname "$( readlink -e "${0}" )" )/.." ||
	die "chdir() to script parent directory failed: ${?}"

[[ -s "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" ]] ||
	die "Cannot read file package.accept_keywords.${ARCH}"

dest="$( mktemp --tmpdir "$( basename "${0}" ).XXXXXXXX" )" ||
	die "mktemp() failed: ${?}"

cp "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" "${dest}" ||
	die "File copy failed: ${?}"

cat "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" |
	sed 's/#.*$//' |
	grep -v '^\s*$' |
	sort |
	while read -r pkg flag
do
	orig="${pkg}"

	if [[ "${pkg:0:1}" == '~' ]]; then
		pkg="$( sed 's/-r[0-9]\+//' <<<"${pkg:1}" )"
		pkg="$( # <- Syntax
			ls -1d "/var/db/pkg/${pkg}"*/ |
				sort -V |
				tail -n 1 |
				sed 's|^/var/db/pkg/|| ; s|/$||'
		)"
	fi

	if [[ -z "${pkg}" ]]; then
		print "No candidate packages for acceptance '${orig}'"
		continue
	fi

	remove=1

	#print "Checking '${pkg#=}' ..." ;
	if grep -Eq -- "${SKIP}" <<<"${pkg#=}"; then
		print "Skipping package '${pkg#=}'"
		remove=0
	else
		if ! [[ -d "/var/db/pkg/${pkg#=}" ]]; then
			rawpkg="$( sed 's/-[0-9].*//' <<<"${pkg#=}" )"
			if [[ -d "/var/db/pkg/${rawpkg}"* ]]; then
				pushd >/dev/null "/var/db/pkg/${rawpkg}"*
				rawpkg="$( pwd | sed 's|^/var/db/pkg||' )"
				popd >/dev/null
				print "Package '${pkg#=}' has been superseded by '${rawpkg}' (/var/db/pkg/${rawpkg})"
			else
				print "Package '${pkg#=}' (/var/db/pkg/${pkg#=}) doesn't exist"
				if emerge -vp --nodeps "=${pkg#=}" 2>&1 >/dev/null | grep -v '^\s*$' ; then
					print "Package '${pkg#=}' can be installed"
					remove=0
				else
					print "Package '${pkg#=}' is obselete or cannot be installed"
				fi
			fi
		else
			if ! [[ -s "/var/db/pkg/${pkg#=}/KEYWORDS" ]]; then

				print "File '/var/db/pkg/${pkg#=}/KEYWORDS' doesn't exist"
			else
				if grep -qE "^${ARCH}| ${ARCH}" "/var/db/pkg/${pkg#=}/KEYWORDS"; then
					print "Package '${pkg#=}' is now keyworded for '${ARCH}'"
				else
					print "Package '${pkg#=}' still needs keywording"
					remove=0
				fi
			fi
		fi
	fi

	if (( remove )); then
		print "Removing '${pkg#=}'"
		sed -e "/^[[:space:]]*${pkg//\//.}[[:space:]]/ d" -i "${dest}"
	fi
done

if ! diff -q "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" "${dest}"; then
	diff -u "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" "${dest}"
	echo
	echo "Keeping output file '${dest}' - please merge and remove manually"
else
	rm "${dest}" || die "Removing file '${dest}' failed: ${?}"
fi

exit 0
