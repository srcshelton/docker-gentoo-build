#! /usr/bin/env bash

# Examine *installed* packages to see whether any are of higher version than
# those which are keyworded, suggesting that the keywording is no longer
# required...
#

set -u
set -o pipefail

declare debug="${DEBUG:-}"
declare trace="${TRACE:-}"

declare ARCH="${1:-arm64}"
declare SKIP='raspberrypi'

declare dest='' pkg=''

print() {
	local -i level=1

	if [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && (( ${1} > 1 )); then
		(( level = ${1} ))
		if [[ -n "${2:-}" ]]; then
			shift
		else
			set --
		fi
	fi

	if (( debug >= level )); then
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

declare -i removed=0

(( trace )) && set -o xtrace

cat "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" |
	sed 's/#.*$//' |
	grep -v '^\s*$' |
	sort |
	while read -r pkg _flag
do
	print 2 "Read entry '${pkg:-}' (with keywords '${_flag:-}')"

	declare orig='' cat='' d=''
	declare -i remove=0

	if [[ "${pkg:0:2}" =~ [\<\>]= ]]; then
		orig="${pkg:2}"
	elif [[ "${pkg:0:1}" =~ [~=!\<\>] ]]; then
		orig="${pkg:1}"
	else
		orig="${pkg}"
	fi
	if type -pf versionsort >/dev/null 2>&1; then
		pkg="$( versionsort -n "${orig}" )"
	else
		# shellcheck disable=SC2001
		pkg="$( sed 's/-[0-9].*$//' <<<"${orig}" )"
	fi
	cat="${pkg%/*}"
	print 2 "Searching for package matching '${pkg#"${cat}/"}' in" \
		"category '${cat:-}' ..."

	if [[ -d "/var/db/pkg/${cat}" ]]; then
		pkg="$( # <- Syntax
			find "/var/db/pkg/${cat}/" \
					-mindepth 1 \
					-maxdepth 1 \
					-name "${pkg#"${cat}/"}*" \
					-type d \
					-print |
				sort -V |
				tail -n 1 |
				sed 's|^/var/db/pkg/|| ; s|/$||'
		)"
	else
		pkg="$( # <- Syntax
			find /var/db/pkg/ \
					-mindepth 2 \
					-maxdepth 2 \
					-name "${pkg#"${cat}/"}*" \
					-type d \
					-print |
				sort -V |
				tail -n 1 |
				sed 's|^/var/db/pkg/|| ; s|/$||'
		)"
	fi
	unset cat

	if [[ -z "${pkg}" ]]; then
		print "No installed candidate package for '${orig}'"
		continue
	fi

	unset orig

	remove=1

	print 2 "Checking '${pkg}' ..." ;
	if grep -Eq -- "${SKIP}" <<<"${pkg}"; then
		print "Skipping package '${pkg}'"
		remove=0
	else
		if ! [[ -d "/var/db/pkg/${pkg}" ]]; then
			d=''
			for d in "/var/db/pkg/${pkg}"*; do
				if [[ -d "${d}" ]]; then
					pushd >/dev/null "${d}" ||
						die "pushd() to '${d}' failed: ${?}"
					pkg="$( pwd | sed 's|^/var/db/pkg||' )"
					popd >/dev/null ||
						die "popd() failed: ${?}"
					print "Package '${pkg}' has been superseded" \
						"by '${pkg}' (/var/db/pkg/${pkg})"
				else
					print "Package '${pkg}' (/var/db/pkg/${pkg}) doesn't" \
						"exist"
					if emerge -vp --nodeps "=${pkg}" 2>&1 >/dev/null |
							grep -v '^\s*$'
					then
						print "Package '${pkg}' can be installed"
						remove=0
					else
						print "Package '${pkg}' is obselete or cannot be" \
							"installed"
					fi
				fi
			done
			unset d
		else
			if ! [[ -s "/var/db/pkg/${pkg}/KEYWORDS" ]]; then

				print "File '/var/db/pkg/${pkg}/KEYWORDS' doesn't exist"
			else
				if grep -qE "^${ARCH}| ${ARCH}" "/var/db/pkg/${pkg}/KEYWORDS"; then
					print "Package '${pkg}' is now keyworded for '${ARCH}'"
				else
					print "Package '${pkg}' still needs keywording"
					remove=0
				fi
			fi
		fi
	fi

	if (( remove )); then
		print "Removing '${pkg}'"
		sed \
				-e "/^[[:space:]]*${pkg//\//.}[[:space:]]/ d" \
				-i "${dest}" &&
			removed=1
	fi
done
unset remove _flag pkg

if ! (( removed )); then
	echo "No necessary changes detected"
fi
unset removed

if ! diff -q "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" "${dest}"; then
	diff -u "gentoo-base/etc/portage/package.accept_keywords.${ARCH}" "${dest}"
	echo
	echo "Keeping output file '${dest}' - please merge and remove manually"
else
	rm "${dest}" || die "Removing file '${dest}' failed: ${?}"
fi

unset dest

exit 0
