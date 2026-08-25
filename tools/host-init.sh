#! /usr/bin/env bash

set -eu
set -o pipefail

trace=${TRACE:-}
[[ -z "${trace}" ]] || set -o xtrace

cd "$( dirname "${0}" )/.." || exit 1

case "${*:-}" in
	-h|--help)
		cat <<EOF
Usage: $( basename "${0}" )

Prepare a non-Gentoo Linux host for this repository's container builds. This
script restores an optional Portage cache archive, creates the cache and
package directories, synchronises the supplied Portage configuration, and
installs the supplied make.conf.

Commands which require root privileges are run through sudo when necessary.
The script accepts no options or operands other than help.

Options:
  -h, --help      Show this help

Environment:
  GENTOO_PKGHOST  Package-cache namespace (default: 'container')
  SUDO_USER       User which should own the host cache directories
  TRACE           Enable shell tracing when non-empty
EOF
		exit 0
		;;
	'')
		;;
	*)
		echo >&2 "FATAL: Unknown option or operand '${*}'"
		echo >&2 "Try '$( basename "${0}" ) --help' for more information."
		exit 1
		;;
esac

if type -pf portageq >/dev/null 2>&1; then
	arch="$( portageq envvar ARCH )"
else
	case "$( uname -m )" in
		aarch64|arm64) arch='arm64' ;;
		arm*) arch='arm' ;;
		x86_64) arch='amd64' ;;
		*)
			echo >&2 "FATAL: Unknown architecture '$( uname -m )'"
			exit 1
			;;
	esac
fi

host_user=${SUDO_USER:-$( id -un )}
host_home=${HOME}
if command -v getent >/dev/null 2>&1; then
	host_home="$( getent passwd "${host_user}" | cut -d':' -f 6 )"
fi

# These operations must be performed as root.
as_root() {
	if (( EUID )); then
		sudo "${@}"
	else
		"${@}"
	fi
}

as_root mkdir -p /var/cache
if [[ -s "${host_home}/portage-cache.tar" ]]; then
	as_root tar -xpf "${host_home}/portage-cache.tar" -C /var/cache/
fi

as_root mkdir -p /var/cache/portage
as_root chown "${host_user}:root" /var/cache/portage
as_root chmod ug+rwX /var/cache/portage

pkg_cache="/var/cache/portage/pkg/${arch}/${GENTOO_PKGHOST:-container}"
as_root mkdir -p "${pkg_cache}"
as_root chown "${host_user}:root" "${pkg_cache}"
as_root chmod ug+rwX "${pkg_cache}"

if [[ ! -x ./tools/sync-portage.sh ]]; then
	echo >&2 "FATAL: Cannot locate '${PWD}/tools/sync-portage.sh'"
	exit 1
fi
as_root ./tools/sync-portage.sh
as_root mkdir -p /etc/portage
as_root cp gentoo-base/etc/portage/make.conf /etc/portage/

echo >&2 "INFO:  Host setup is complete; please review" \
	"'/etc/portage/make.conf'"

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
