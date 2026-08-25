#! /usr/bin/env bash

#debug="${DEBUG:-}"
declare trace="${TRACE:-}"

# Copied from vars.sh - it's not worth running the whole script just for these!
#
declare bold=$'\e[1m'
declare red=$'\e[31m'
declare green=$'\e[32m'
declare blue=$'\e[34m'
declare purple=$'\e[35m'
#
# Place 'reset' last to prevent coloured xtrace output!
#
declare reset=$'\e[0m'
export bold red green blue purple reset

# shellcheck disable=SC1091
. "$( dirname "${0}" )/container-engine-helpers.sh"

declare -i colour=1 labels=0
declare target_image='' value=''

[[ -z "${trace}" ]] || set -o xtrace

declare arg=''
for arg in "${@}"; do
	case "${arg}" in
		-C|--no-colour)
			colour=0
			;;
		--labels)
			labels=1
			;;
		-h|--help)
			printf >&2 'Usage: %s [--no-colour] [--labels]' \
				"${0##*/}"
			printf >&2 ' [--value=<string>] <image>\n'
			container_engine_help >&2
			exit 0
			;;
		-v*)
			if [[ -z "${value}" ]]; then
				value="${arg#-v}"
			else
				printf >&2 "FATAL: Too many values ('%s %s') - only one" \
					"${value}" "${arg#-v}"
				printf >&2 ' supported\n'
				exit 1
			fi
			;;
		--value=*)
			if [[ -z "${value}" ]]; then
				value="${arg#--value=}"
			else
				printf >&2 "FATAL: Too many values ('%s %s') - only one" \
					"${value}" "${arg#--value=}"
				printf >&2 ' supported\n'
				exit 1
			fi
			;;
		*)
			if [[ -z "${target_image}" ]]; then
				target_image="${arg}"
			else
				printf >&2 "FATAL: Too many images ('%s %s') - only one" \
					"${target_image}" "${arg}"
				printf >&2 ' supported\n'
				exit 1
			fi
			;;
	esac
done
unset arg

if [[ -z "${target_image}" ]]; then
	printf >&2 'Usage: %s <image>\n' "${0##*/}"
	exit 1
fi

cd "$( dirname "${0}" )/.." || exit 1

# shellcheck disable=SC1091
. ./common/vars.sh
declare IMAGE='none'
# shellcheck disable=SC1091
. ./common/run.sh >/dev/null

# The 'inspect' command works with containers (and container IDs) too...
if (( $( docker image list --noheading "${target_image}" | wc -l ) > 1 )); then
	printf >&2 "WARN:  Cannot determine unique image '%s'\n" "${target_image}"
	#exit 1
fi

# See https://github.com/containers/podman/issues/8785
#buildah inspect --format '{{ .OCIv1.Config.Env }}' "${target_image}" |
#	tr $'\t' ' ' |
#	tr -s '[:space:]' |
#	sed -E 's/^\[(.*)\]$/\1/' |
#	sed -E 's/ ([A-Za-z][A-Za-z0-9_-]*)=/\n\1=/g'

declare -a sed_args=()
if (( labels )); then
	sed_args=(
		-E
		-e 's/^map\[(.*)\]$/\1/'
		-e 's/^([A-Za-z][A-Za-z0-9._-]*):/\1: /'
		-e 's/ ([A-Za-z][A-Za-z0-9._-]*):/\n\1: /g'
	)
	if (( colour )); then
		sed_args+=( -e "s/^/${purple}/ ; s/: /${reset}: /" )
	fi
else
	sed_args=(
		-E
		-e 's/^\[(.*)\]$/\1/'
		-e 's/ ([A-Za-z][A-Za-z0-9._-]*)=/\n\1=/g'
	)
	if (( colour )); then
		sed_args+=( -e "s/^/${purple}/ ; s/=/${reset}: /" )
	fi
fi
if (( colour )) && [[ -n "${value}" ]]; then
	sed_args+=(
		-e "/${value}.*: /s/${value}/${value}${purple}/"
		-e "s/${value}/${bold}${red}${value}${reset}/g"
	)
fi

if (( labels )); then
	if [[ "${_container_engine}" == 'container' ]]; then
		container_engine_run "${_command}" image inspect "${target_image}" |
			jq -r '
				[
					if type == "array" then .[] else . end |
					.variants[]?.config.config.Labels //
					.config.config.Labels //
					.config.Labels //
					empty
				][0] // {} |
				"map[" + (to_entries | map("\(.key):\(.value)") | join(" ")) + "]"
			'
	else
		docker image inspect --format '{{ .Config.Labels }}' "${target_image}"
	fi | sed "${sed_args[@]}"
else
	if [[ "${_container_engine}" == 'container' ]]; then
		container_engine_run "${_command}" image inspect "${target_image}" |
			jq -r '
				[
					if type == "array" then .[] else . end |
					.variants[]?.config.config.Env //
					.config.config.Env //
					.config.Env //
					empty
				][0] // [] | "[" + join(" ") + "]"
			'
	else
		docker image inspect --format '{{ .Config.Env }}' "${target_image}"
	fi |
		tr $'\t' ' ' |
		tr -s '[:space:]' |
		sed "${sed_args[@]}"
fi
