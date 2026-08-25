#! /usr/bin/env bash

# This script should no longer be needed since podman issue 7872 [1] was
# resolved: keeping more for historical interest.
#
# [1] https://github.com/containers/podman/issues/7872
#

set -eu

declare trace="${TRACE:-}"

[[ -z "${trace}" ]] || set -o xtrace

cd "$( dirname "${0}" )/.." || exit 1

# shellcheck disable=SC1091
. ./common/container-engine-helpers.sh

declare -a cmd=( image prune -f )
declare desc='images'
declare arg=''
for arg in "${@}"; do
	case "${arg}" in
		-h|--help)
			printf 'Usage: %s [--system]\n' "${0##*/}"
			container_engine_help
			exit 0
			;;
		--system)
			cmd=( system prune -f )
			desc='system'
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

trap '' INT

printf 'Starting to prune %s %s ...\n' "${_container_engine}" "${desc}"

declare prune_output=''
declare -i total=0 run=0 rc=0
while true; do
	if prune_output="$( docker "${cmd[@]}" 2>/dev/null )"; then
		run="$( printf '%s' "${prune_output}" | grep -cv '^Deleted ' || : )"
		rc=0
	else
		rc=${?}
	fi

	if (( rc )); then
		printf >&2 '%s ended: %d\n\n' "${_container_engine}" "${rc}"
		printf >&2 'Removed %d images so far, with %d indeterminate\n' \
			"${total}" "${run}"
		exit "${rc}"
	fi

	(( total += run ))

	if (( 0 == run )); then
		printf 'image prune operation complete - removed %d images\n' "${total}"
		exit 0
	else
		printf 'Removed %d images on this pass...\n' "${run}"
	fi
done

trap - INT

set +x
