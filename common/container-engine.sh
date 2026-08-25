#! /bin/sh

# shellcheck disable=SC2154 # Image names are set by common/vars.sh.

# Resolve one supported container engine for the current process and its
# children.  This file is sourced after common/vars.sh has loaded local image
# names and tags, so automatic selection can take the existing image pipeline
# into account.

# A local override may have enabled VERBOSE after the shared helpers were
# sourced, so preserve the final diagnostic stream before any probes redirect
# stderr.
if [ -n "${VERBOSE:-}" ]; then
	exec 3>&2
fi

_container_engine_version_at_least() {
	awk -v installed="${1}" -v minimum="${2}" '
		function component(version, position, fields) {
			split(version, fields, ".")
			return fields[position] + 0
		}
		BEGIN {
			for (position = 1; position <= 3; position++) {
				installed_component = component(installed, position)
				minimum_component = component(minimum, position)
				if (installed_component > minimum_component)
					exit 0
				if (installed_component < minimum_component)
					exit 1
			}
			exit 0
		}
	' </dev/null
}

_container_engine_image_created() (
	_engine_type=${1}
	_engine_path=${2}
	_engine_image=${3}
	_engine_created=''

	if [ "${_engine_type}" = 'container' ]; then
		_engine_created="$(
			container_engine_run "${_engine_path}" image inspect \
					"${_engine_image}" 2>/dev/null |
				jq -r '
					[
						if type == "array" then .[] else . end |
						.variants[]?.config.created? //
						.variants[]?.configuration.created? //
						.config.created? //
						.configuration.created? //
						.created? //
						empty
					] | max // empty
				' 2>/dev/null
		)" || exit 1
	else
		_engine_created="$(
			container_engine_run "${_engine_path}" image inspect \
				--format '{{.Created}}' \
				"${_engine_image}" 2>/dev/null
		)" || exit 1
	fi

	# Image existence determines completeness.  A missing or unfamiliar
	# creation timestamp merely loses the freshness tiebreaker.
	printf '%s\n' "${_engine_created:-0}" |
		tr -cd '0-9\n' |
		cut -c 1-14
)

_container_engine_score() (
	_engine_type=${1}
	_engine_path=${2}
	_engine_tag=${override_tag:-latest}

	for _engine_stage_image in \
		"5:${build_name}" \
		"4:${base_name}" \
		"3:${init_name}" \
		"2:${stage3_name}" \
		"1:${env_name}"
	do
		_engine_stage=${_engine_stage_image%%:*}
		_engine_image=${_engine_stage_image#*:}:${_engine_tag}
		if _engine_created="$(
				_container_engine_image_created \
					"${_engine_type}" "${_engine_path}" "${_engine_image}"
			)"
		then
			printf '%s\n%s\n' "${_engine_stage}" "${_engine_created:-0}"
			exit 0
		fi
	done

	printf '0\n0\n'
)

_container_engine_probe() (
	_engine_type=${1}
	_engine_path=${2}
	_engine_system=$( uname -s )
	_engine_machine=$( uname -m )
	_engine_version_output=''
	_engine_version=''
	_engine_info=''

	if ! [ -x "${_engine_path}" ]; then
		printf 'Cannot execute %s\n' "${_engine_path}"
		exit 0
	fi

	_engine_version_output="$(
		container_engine_run "${_engine_path}" --version 2>/dev/null
	)" || :
	case "$( printf '%s\n' "${_engine_version_output}" | tr '[:upper:]' '[:lower:]' )" in
		*'container cli version'*) _engine_identified='container' ;;
		*'podman version'*) _engine_identified='podman' ;;
		*'docker version'*) _engine_identified='docker' ;;
		*) _engine_identified='' ;;
	esac
	if [ "${_engine_identified}" != "${_engine_type}" ]; then
		printf "Executable identifies as '%s', not '%s'\n" \
			"${_engine_identified:-unknown}" "${_engine_type}"
		exit 0
	fi

	_engine_version="$(
		printf '%s\n' "${_engine_version_output}" |
			sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
			head -n 1
	)"
	if [ -z "${_engine_version}" ]; then
		printf 'Cannot determine version from: %s\n' \
			"${_engine_version_output:-no output}"
		exit 0
	fi

	case "${_engine_type}" in
		container)
			if [ "${_engine_system}" != 'Darwin' ] ||
					[ "${_engine_machine}" != 'arm64' ]
			then
				printf "Apple 'container' requires macOS on Apple silicon\n"
				exit 0
			fi
			if ! _container_engine_version_at_least "${_engine_version}" \
					"${APPLE_CONTAINER_MIN_VERSION}"
			then
				printf "Version %s is below required %s\n" \
					"${_engine_version}" "${APPLE_CONTAINER_MIN_VERSION}"
				exit 0
			fi
			if ! command -v jq >/dev/null 2>&1; then
				printf "Apple 'container' support requires 'jq'\n"
				exit 0
			fi
			if ! container_engine_run "${_engine_path}" system status \
					>/dev/null 2>&1
			then
				printf "The 'container' system is not running\n"
				exit 0
			fi
			if ! container_engine_run "${_engine_path}" builder status --quiet \
					>/dev/null 2>&1
			then
				printf "The 'container' builder is not running\n"
				exit 0
			fi
			;;
		podman)
			_engine_minimum=${PODMAN_MIN_VERSION}
			if [ "${_engine_system}" = 'Darwin' ]; then
				_engine_minimum=${PODMAN_MACOS_MIN_VERSION}
			fi
			if ! _container_engine_version_at_least "${_engine_version}" \
					"${_engine_minimum}"
			then
				printf 'Version %s is below required %s\n' \
					"${_engine_version}" "${_engine_minimum}"
				exit 0
			fi
			if ! _engine_info="$(
				container_engine_run "${_engine_path}" system info 2>&1
			)"
			then
				printf "Podman is not operational; its machine may not be running\n"
				exit 0
			fi
			if ! container_engine_run "${_engine_path}" image build --help \
					2>/dev/null |
					grep -Fq -- '--platform'
			then
				printf "'podman image build' lacks '--platform' support\n"
				exit 0
			fi
			if ! container_engine_run "${_engine_path}" container commit --help \
					2>/dev/null |
					grep -Fq -- '--squash' &&
					! command -v buildah >/dev/null 2>&1
			then
				printf "Podman requires 'buildah' when commit lacks '--squash'\n"
				exit 0
			fi
			_engine_runtime="$(
				container_engine_run "${_engine_path}" system info --format \
					'{{.Host.OCIRuntime.Name}}|{{.Host.OCIRuntime.Version}}' \
					2>/dev/null
			)" || _engine_runtime=''
			case "${_engine_runtime%%|*}" in
				''|'<no value>')
					printf "Cannot determine Podman's active OCI runtime\n"
					exit 0
					;;
			esac
			case "${_engine_runtime}" in
				crun'|'*)
					_engine_runtime_version="$(
						printf '%s\n' "${_engine_runtime#*|}" |
							awk '
								match($0, /[0-9]+\.[0-9]+(\.[0-9]+)?/) {
									print substr($0, RSTART, RLENGTH)
									exit
								}
							'
					)"
					if [ -z "${_engine_runtime_version}" ]; then
						printf "Cannot determine active crun version\n"
						exit 0
					fi
					if ! _container_engine_version_at_least \
							"${_engine_runtime_version}" "${CRUN_MIN_VERSION}"
					then
						printf 'Active crun %s is below required %s\n' \
							"${_engine_runtime_version}" "${CRUN_MIN_VERSION}"
						exit 0
					fi
					;;
			esac
			;;
		docker)
			if ! _container_engine_version_at_least "${_engine_version}" \
					"${DOCKER_MIN_VERSION}"
			then
				printf 'Version %s is below required %s\n' \
					"${_engine_version}" "${DOCKER_MIN_VERSION}"
				exit 0
			fi

			if [ -n "${DOCKER_CONTEXT:-}" ]; then
				_engine_context=${DOCKER_CONTEXT}
				_engine_endpoint="$(
					container_engine_run "${_engine_path}" context inspect --format \
						'{{(index .Endpoints "docker").Host}}' \
						"${_engine_context}" 2>/dev/null
				)" || _engine_endpoint=''
				if [ -z "${_engine_endpoint}" ]; then
					printf "Cannot inspect Docker context '%s'\n" \
						"${_engine_context}"
					exit 0
				fi
			elif [ -n "${DOCKER_HOST:-}" ]; then
				_engine_endpoint=${DOCKER_HOST}
			else
				_engine_context="$(
					container_engine_run "${_engine_path}" context show 2>/dev/null
				)" || _engine_context=''
				if [ -n "${_engine_context}" ]; then
					_engine_endpoint="$(
						container_engine_run "${_engine_path}" context inspect --format \
							'{{(index .Endpoints "docker").Host}}' \
							"${_engine_context}" 2>/dev/null
					)" || _engine_endpoint=''
				else
					# Docker 18.06 predates contexts and uses the local default
					# socket when DOCKER_HOST is unset.
					_engine_endpoint='unix:///var/run/docker.sock'
				fi
			fi
			case "${_engine_endpoint}" in
				unix://*) : ;;
				*)
					printf "Remote Docker endpoint '%s' is unsupported\n" \
						"${_engine_endpoint:-unknown}"
					exit 0
					;;
			esac

			if ! _engine_info="$(
				container_engine_run "${_engine_path}" system info 2>&1
			)"
			then
				printf 'The Docker daemon is not operational\n'
				exit 0
			fi
			_engine_docker_versions="$(
				container_engine_run "${_engine_path}" version --format \
					'{{.Client.Version}}|{{.Client.APIVersion}}|{{.Server.Version}}|{{.Server.APIVersion}}' \
					2>/dev/null
			)" || _engine_docker_versions=''
			_engine_client_api="$(
				printf '%s\n' "${_engine_docker_versions}" | cut -d'|' -f 2
			)"
			_engine_server_version="$(
				printf '%s\n' "${_engine_docker_versions}" | cut -d'|' -f 3
			)"
			_engine_server_api="$(
				printf '%s\n' "${_engine_docker_versions}" | cut -d'|' -f 4
			)"
			if [ -z "${_engine_server_version}" ] ||
					! _container_engine_version_at_least \
						"${_engine_server_version}" "${DOCKER_MIN_VERSION}"
			then
				printf 'Docker server version %s is below required %s\n' \
					"${_engine_server_version:-unknown}" "${DOCKER_MIN_VERSION}"
				exit 0
			fi
			if [ -z "${_engine_client_api}" ] || [ -z "${_engine_server_api}" ] ||
					! _container_engine_version_at_least \
						"${_engine_client_api}.0" "${DOCKER_MIN_API_VERSION}.0" ||
					! _container_engine_version_at_least \
						"${_engine_server_api}.0" "${DOCKER_MIN_API_VERSION}.0"
			then
				printf 'Docker client/server API %s/%s is below required %s\n' \
					"${_engine_client_api:-unknown}" \
					"${_engine_server_api:-unknown}" \
					"${DOCKER_MIN_API_VERSION}"
				exit 0
			fi
			if ! container_engine_run "${_engine_path}" image build --help \
					2>/dev/null |
					grep -Fq -- '--platform'
			then
				printf "'docker image build' lacks '--platform' support\n"
				exit 0
			fi
			;;
	esac

	if [ "${_engine_system}" != 'Darwin' ] &&
			[ $(( $( id -u ) )) -ne 0 ] &&
			printf '%s\n' "${_engine_info}" | grep -Fq -- 'rootless: false'
	then
		printf "The engine is configured rootful; run as 'root'\n"
		exit 0
	fi

	_engine_score="$(
		_container_engine_score "${_engine_type}" "${_engine_path}"
	)"
	printf 'OK\n%s\n%s\n%s\n' \
		"${_engine_version}" \
		"$( printf '%s\n' "${_engine_score}" | sed -n '1p' )" \
		"$( printf '%s\n' "${_engine_score}" | sed -n '2p' )"
)

_container_engine_probe_fields() {
	_container_engine_probe_status="$(
		printf '%s\n' "${_container_engine_probe_output}" | sed -n '1p'
	)"
	_container_engine_probe_version="$(
		printf '%s\n' "${_container_engine_probe_output}" | sed -n '2p'
	)"
	_container_engine_probe_stage="$(
		printf '%s\n' "${_container_engine_probe_output}" | sed -n '3p'
	)"
	_container_engine_probe_created="$(
		printf '%s\n' "${_container_engine_probe_output}" | sed -n '4p'
	)"
}

_container_engine_report_probe() {
	[ -n "${VERBOSE:-}" ] || return 0

	if [ "${_container_engine_probe_status}" = 'OK' ]; then
		printf >&3 "VERBOSE: Engine '%s' at '%s' is usable:" \
			"${1}" "${2}"
		printf >&3 ' version %s, image stage %s, newest image %s\n' \
			"${_container_engine_probe_version}" \
			"${_container_engine_probe_stage}" \
			"${_container_engine_probe_created}"
	else
		printf >&3 "VERBOSE: Engine '%s' at '%s' is unusable: %s\n" \
			"${1}" "${2}" "${_container_engine_probe_status}"
	fi
}

_container_engine_requested=${CONTAINER_ENGINE:-auto}
_container_engine_requested_is_path=0
_container_engine_selected=''
_container_engine_selected_path=''
_container_engine_selected_stage=-1
_container_engine_selected_created=0

if [ -n "${_CONTAINER_ENGINE_RESOLVED_TYPE:-}" ] &&
		[ -n "${_CONTAINER_ENGINE_RESOLVED_PATH:-}" ]
then
	_container_engine_probe_output="$(
		_container_engine_probe "${_CONTAINER_ENGINE_RESOLVED_TYPE}" \
			"${_CONTAINER_ENGINE_RESOLVED_PATH}"
	)"
	_container_engine_probe_fields
	_container_engine_report_probe "${_CONTAINER_ENGINE_RESOLVED_TYPE}" \
		"${_CONTAINER_ENGINE_RESOLVED_PATH}"
	if [ "${_container_engine_probe_status}" != 'OK' ]; then
		echo >&2 "FATAL: Previously-selected container engine" \
			"'${_CONTAINER_ENGINE_RESOLVED_PATH}' is no longer usable:"
		echo >&2 "       ${_container_engine_probe_status}"
		exit 1
	fi
	_container_engine_selected=${_CONTAINER_ENGINE_RESOLVED_TYPE}
	_container_engine_selected_path=${_CONTAINER_ENGINE_RESOLVED_PATH}
elif [ "${_container_engine_requested}" != 'auto' ]; then
	case "${_container_engine_requested}" in
		container|podman|docker)
			_container_engine_requested_type=${_container_engine_requested}
			_container_engine_requested_path="$(
				command -v "${_container_engine_requested_type}" 2>/dev/null || :
			)"
			;;
		*/*)
			_container_engine_requested_is_path=1
			_container_engine_requested_path=${_container_engine_requested}
			_container_engine_version_output="$(
				container_engine_run "${_container_engine_requested_path}" \
					--version 2>/dev/null
			)" || _container_engine_version_output=''
			case "$(
				printf '%s\n' "${_container_engine_version_output}" |
					tr '[:upper:]' '[:lower:]'
			)" in
				*'container cli version'*) _container_engine_requested_type='container' ;;
				*'podman version'*) _container_engine_requested_type='podman' ;;
				*'docker version'*) _container_engine_requested_type='docker' ;;
				*) _container_engine_requested_type='' ;;
			esac
			;;
		*)
			echo >&2 "FATAL: CONTAINER_ENGINE must be 'auto', 'container'," \
				"'podman', 'docker', or an executable path"
			exit 1
			;;
	esac

	if [ -z "${_container_engine_requested_path}" ]; then
		_container_engine_probe_status="Cannot find '${_container_engine_requested_type}' in PATH"
	elif [ -z "${_container_engine_requested_type}" ]; then
		_container_engine_probe_status="Cannot identify '${_container_engine_requested_path}' as a supported engine"
	else
		_container_engine_probe_output="$(
			_container_engine_probe "${_container_engine_requested_type}" \
				"${_container_engine_requested_path}"
		)"
		_container_engine_probe_fields
		_container_engine_report_probe "${_container_engine_requested_type}" \
			"${_container_engine_requested_path}"
	fi

	if [ "${_container_engine_probe_status}" = 'OK' ]; then
		_container_engine_selected=${_container_engine_requested_type}
		_container_engine_selected_path=${_container_engine_requested_path}
	elif [ $(( _container_engine_requested_is_path )) -eq 0 ]; then
		# An explicit keyword never falls back, but reporting one usable
		# alternative makes the failure actionable.  An explicit path performs
		# no further discovery, as promised by the public interface.
		_container_engine_alternative=''
		_container_engine_requested_reason=${_container_engine_probe_status}
		for _container_engine_type in container podman docker; do
			[ "${_container_engine_type}" != \
				"${_container_engine_requested_type}" ] || continue
			_container_engine_path="$(
				command -v "${_container_engine_type}" 2>/dev/null || :
			)"
			[ -n "${_container_engine_path}" ] || continue
			_container_engine_probe_output="$(
				_container_engine_probe "${_container_engine_type}" \
					"${_container_engine_path}"
			)"
			_container_engine_probe_fields
			_container_engine_report_probe "${_container_engine_type}" \
				"${_container_engine_path}"
			if [ "${_container_engine_probe_status}" = 'OK' ]; then
				_container_engine_alternative="${_container_engine_type}|${_container_engine_path}|${_container_engine_probe_version}"
				break
			fi
		done
		echo >&2 "FATAL: Selected container engine '${_container_engine_requested}'" \
			"is unusable:"
		echo >&2 "       ${_container_engine_requested_reason}"
		if [ -n "${_container_engine_alternative}" ]; then
			_container_engine_alternative_type="$(
				printf '%s\n' "${_container_engine_alternative}" |
					cut -d'|' -f 1
			)"
			_container_engine_alternative_path="$(
				printf '%s\n' "${_container_engine_alternative}" |
					cut -d'|' -f 2
			)"
			_container_engine_alternative_version="$(
				printf '%s\n' "${_container_engine_alternative}" |
					cut -d'|' -f 3
			)"
			echo >&2 "       Compatible '${_container_engine_alternative_type}'" \
				"${_container_engine_alternative_version} is available at" \
				"'${_container_engine_alternative_path}'; set"
			echo >&2 "       CONTAINER_ENGINE='${_container_engine_alternative_type}'" \
				"or CONTAINER_ENGINE='auto' to use it"
		fi
		exit 1
	else
		echo >&2 "FATAL: Selected container engine path" \
			"'${_container_engine_requested_path}' is unusable:"
		echo >&2 "       ${_container_engine_probe_status}"
		exit 1
	fi
else
	_container_engine_priority=''
	_container_engine_priority_reason=''
	_container_engine_failures=''
	for _container_engine_type in container podman docker; do
		[ "${_container_engine_type}" != 'container' ] ||
			[ "$( uname -s )" = 'Darwin' ] || continue
		_container_engine_path="$(
			command -v "${_container_engine_type}" 2>/dev/null || :
		)"
		[ -n "${_container_engine_path}" ] || continue
		if [ -z "${_container_engine_priority}" ]; then
			_container_engine_priority=${_container_engine_type}
		fi
		_container_engine_probe_output="$(
			_container_engine_probe "${_container_engine_type}" \
				"${_container_engine_path}"
		)"
		_container_engine_probe_fields
		_container_engine_report_probe "${_container_engine_type}" \
			"${_container_engine_path}"
		if [ "${_container_engine_probe_status}" != 'OK' ]; then
			_container_engine_failures="${_container_engine_failures}${_container_engine_type}: ${_container_engine_probe_status}
"
			if [ "${_container_engine_type}" = "${_container_engine_priority}" ]; then
				_container_engine_priority_reason=${_container_engine_probe_status}
			fi
			continue
		fi

		_container_engine_choose=0
		if [ -z "${_container_engine_selected}" ] ||
				[ "${_container_engine_probe_stage}" -gt \
				"${_container_engine_selected_stage}" ]
		then
			_container_engine_choose=1
		elif [ "${_container_engine_probe_stage}" -eq \
				"${_container_engine_selected_stage}" ] &&
				[ "${_container_engine_probe_created}" != \
				"${_container_engine_selected_created}" ] &&
				[ "$(
					printf '%s\n%s\n' "${_container_engine_probe_created}" \
						"${_container_engine_selected_created}" |
						sort | tail -n 1
				)" = "${_container_engine_probe_created}" ]
		then
			_container_engine_choose=1
		fi
		if [ $(( _container_engine_choose )) -eq 1 ]; then
			_container_engine_selected=${_container_engine_type}
			_container_engine_selected_path=${_container_engine_path}
			_container_engine_selected_stage=${_container_engine_probe_stage}
			_container_engine_selected_created=${_container_engine_probe_created}
		fi
	done

	if [ -z "${_container_engine_selected}" ]; then
		echo >&2 'FATAL: No installed container engine is usable:'
		printf '%s' "${_container_engine_failures:-No supported executable found
}" | sed >&2 's/^/       /'
		exit 1
	fi
	if [ "${_container_engine_selected}" != "${_container_engine_priority}" ]; then
		echo >&2 "WARN:  CONTAINER_ENGINE=auto selected" \
			"'${_container_engine_selected}' at '${_container_engine_selected_path}'" \
			"instead of higher-priority '${_container_engine_priority}'"
		if [ -n "${_container_engine_priority_reason}" ]; then
			echo >&2 "       ${_container_engine_priority} is unusable:" \
				"${_container_engine_priority_reason}"
		else
			echo >&2 "       ${_container_engine_selected} has the more complete or" \
				"newer configured image pipeline"
		fi
		echo >&2 "       Set CONTAINER_ENGINE='${_container_engine_priority}'" \
			"to require the priority choice"
	fi
fi

_container_engine=${_container_engine_selected}
_command=${_container_engine_selected_path}
_CONTAINER_ENGINE_RESOLVED_TYPE=${_container_engine}
_CONTAINER_ENGINE_RESOLVED_PATH=${_command}
if [ -n "${VERBOSE:-}" ]; then
	printf >&3 "VERBOSE: Selected container engine '%s' at '%s'\n" \
		"${_container_engine}" "${_command}"
fi
case "${_container_engine}" in
	podman) docker_readonly='ro=true' ;;
	*) docker_readonly='readonly' ;;
esac
export _container_engine _command docker_readonly
export _CONTAINER_ENGINE_RESOLVED_TYPE _CONTAINER_ENGINE_RESOLVED_PATH

unset _container_engine_alternative _container_engine_alternative_path
unset _container_engine_alternative_type _container_engine_alternative_version
unset _container_engine_choose
unset _container_engine_failures
unset _container_engine_path
unset _container_engine_priority _container_engine_priority_reason
unset _container_engine_probe_created _container_engine_probe_output
unset _container_engine_probe_stage _container_engine_probe_status
unset _container_engine_probe_version _container_engine_requested
unset _container_engine_requested_is_path
unset _container_engine_requested_path _container_engine_requested_type
unset _container_engine_requested_reason
unset _container_engine_selected _container_engine_selected_created
unset _container_engine_selected_path _container_engine_selected_stage
unset _container_engine_type
unset _container_engine_version_output

unset -f _container_engine_image_created _container_engine_probe
unset -f _container_engine_probe_fields _container_engine_report_probe
unset -f _container_engine_score
unset -f _container_engine_version_at_least

# vi: set colorcolumn=80 nowrap sw=4 ts=4:
