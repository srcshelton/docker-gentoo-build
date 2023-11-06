#! /bin/sh

set -eu

# Fix packages captured by '@preserved-rebuild', and remove the obsolete binary
# packages we can no longer use...

pkgdir="$( portageq pkgdir )"

test -d "${pkgdir}" || exit 1
test -x gentoo-build-pkg.docker || exit 1

list="$( emerge -p @preserved-rebuild --with-bdeps=n |
	grep -w 'R' |
	awk '{ print $4 }' |
	cut -d':' -f 1
)"

test -n "${list:-}" || exit 0

echo "${list}" | while read -r p; do
	pn="$( basename "${p}" )"

	sudo rm -fv "${pkgdir}/${p}.tbz2"
	sudo find "${pkgdir}/" -mindepth 3 -maxdepth 3 -type f -name "${pn}-[0-9].xpak" -exec rm -v {} +
done

# shellcheck disable=SC2046
sudo ./gentoo-build-pkg.docker virtual/libc $( echo "${list}" | sed 's/^/>=/' )
# shellcheck disable=SC2046
sudo emerge -Kva $( echo "${list}" | sed 's/^/>=/' )
