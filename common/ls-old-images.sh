#! /usr/bin/env bash

[[ -z "${TRACE:-}" ]] || set -o xtrace

cd "$( dirname "${0}" )/.." || exit 1

# shellcheck disable=SC1091
. ./common/container-engine-helpers.sh

declare arg=''
for arg in "${@}"; do
	case "${arg}" in
		-h|--help)
			printf 'Usage: %s\n' "${0##*/}"
			container_engine_help
			exit 0
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

declare images=''
images="$( docker image list --filter 'reference=localhost/*' )"

# FIXME: Use 'base_name', etc. from vars.sh

head -n 1 <<<"${images}"

grep --colour=always -- '^localhost/gentoo-build.*$' <<<"${images}"

grep -A "$( wc -l <<<"${images}" )" \
		-- '^localhost/gentoo-build' <<<"${images}" |
	grep -Ev \
		-e '^localhost/gentoo-(build|base|init|stage3|env)' \
		-e '^docker.io/gentoo/stage3' |
	grep -E --colour=never -- '^localhost/(service|sys-kernel\.)'

# vi: set sw=8 ts=8:
