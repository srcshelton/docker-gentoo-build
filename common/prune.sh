#! /usr/bin/env bash

set -eu
set -o pipefail

trace=${TRACE:-}

[[ -z "${trace}" ]] || set -o xtrace

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
declare IMAGE='none'
# shellcheck disable=SC1091
. ./common/run.sh >/dev/null

trap '' INT

remove_buildah_untagged_images() {
	local image_id=''

	[[ "${_container_engine}" == 'podman' ]] || return 0
	command -v buildah >/dev/null 2>&1 || return 0

	while IFS= read -r image_id; do
		[[ -z "${image_id}" ]] ||
			container_engine_run buildah rmi "${image_id}" || :
	done < <(
		docker image ls --noheading |
			awk '$1 == "<none>" && $2 == "<none>" { print $3 }'
	)
}

# Remove images with generated temporary names...
#
declare container_name=''
while IFS= read -r container_name; do
	[[ "${container_name}" =~ ^[a-z]+_[a-z]+$ ]] || continue
	docker container rm --volumes "${container_name}" || :
done < <( docker container ps --all --format '{{.Names}}' )
unset container_name

# Remove images classed as 'dangling'...
#
declare image_id=''
while IFS= read -r image_id; do
	[[ -z "${image_id}" ]] || docker image rm "${image_id}" || :
done < <( docker image ls --quiet --filter 'dangling=true' )

# Try to remove remaining untagged images...
#
while IFS= read -r image_id; do
	[[ -z "${image_id}" ]] || docker image rm "${image_id}" || :
done < <(
	docker image ls --noheading |
		awk '$1 == "<none>" && $2 == "<none>" { print $3 }'
)
unset image_id

remove_buildah_untagged_images

# Podman's 'image prune' operation should now be internally recursive...
#
declare prune_output=''
if docker image prune -f; then
	while prune_output="$( docker image prune -f )" &&
			[[ -n "${prune_output}" ]]
	do
		printf >&2 '%s\n' "${prune_output}"
		printf '\n'
		sleep 0.1
	done

	remove_buildah_untagged_images
fi

trap - INT

unset -f remove_buildah_untagged_images
set +x
