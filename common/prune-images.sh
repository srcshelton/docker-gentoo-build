#! /bin/bash

# This script should no longer be needed since podman issue 7872 [1] was
# resolved: keeping more for historical interest.
#
# [1] https://github.com/containers/podman/issues/7872
#

set -eu

declare -i trace=$(( ${TRACE:-} ))

(( trace )) && set -x

_command='docker'
if type -pf podman >/dev/null; then
	_command='podman'
fi

trap '' INT

declare cmd='image prune -f' desc='images'
case " ${*} " in
	' -h '|' --help ')
		echo "Usage: $( basename "${0}" ) [--system]"
		exit 0
		;;
	' --system ')
		cmd='system prune -f'
		desc='system'
		;;
	'  ')
		:
		;;
	*)
		echo >&2 "FATAL: Unknown arguments '${*}'"
		exit 1
		;;
esac

echo "Starting to prune ${_command} ${desc} ..."

declare -i total=0 run=0 rc=0
while true; do
	(( run = $( eval "$_command ${cmd}" 2>/dev/null | grep -cv '^Deleted ' ) )) || rc=${?}

	if (( rc )); then
		echo >&2 "${_command} ended: ${rc}"
		echo >&2
		echo >&2 "Removed ${total} images so far, with ${run} indeterminate"
		exit ${rc}
	fi

	(( total += run ))

	if (( 0 == run )); then
		echo "image prune operation complete - removed ${total} images"
		exit 0
	else
		echo "Removed ${run} images on this pass..."
	fi
done

trap - INT

set +x
