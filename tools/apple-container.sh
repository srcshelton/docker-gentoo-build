#! /bin/sh

set -eu

[ -z "${TRACE:-}" ] || set -x

LC_ALL='C'
export LC_ALL

APPLE_CONTAINER_MIN_VERSION='1.3.0'
APPLE_CONTAINER_STOP_MINIMUM=25
APPLE_CONTAINER_START_MINIMUM=60

DEFAULT_BUILDER_CPUS=4
DEFAULT_BUILDER_MEMORY='8G'
DEFAULT_STOP_TIMEOUT=30
DEFAULT_START_TIMEOUT=300

CONTAINER_PROCESS_PATTERN='container-apiserver|container-builder-shim|'\
'container-core-images|container-network-vmnet|container-runtime-linux|'\
'machine-apiserver'
# A valid system can exist before its builder has first been created.
RESET_REQUIRED_DIRECTORIES='apiserver containers content kernels networks '\
'plugin-state snapshots volumes'
RESET_REQUIRED_FILES='apiserver/apiserver.plist state.json'

script_name="${0##*"/"}"
script_dir="$( CDPATH='' cd -P "$( dirname "${0}" )" && pwd )" || exit 1
# shellcheck disable=SC1091
. "${script_dir}/../common/container-engine-helpers.sh"
unset script_dir
mode='restart'
mode_set=0
force=0
container_debug_option=0

builder_cpus=${CONTAINER_BUILDER_CPUS:-${DEFAULT_BUILDER_CPUS}}
builder_memory="${CONTAINER_BUILDER_MEMORY:-"${DEFAULT_BUILDER_MEMORY}"}"
stop_timeout=${CONTAINER_STOP_TIMEOUT:-${DEFAULT_STOP_TIMEOUT}}
start_timeout=${CONTAINER_START_TIMEOUT:-${DEFAULT_START_TIMEOUT}}

app_root=''
app_root_set=0
install_root=''
install_root_set=0
install_root_explicit=0
log_root=''
log_root_set=0

if [ -n "${CONTAINER_APP_ROOT:-}" ]; then
	app_root="${CONTAINER_APP_ROOT}"
	app_root_set=1
fi
if [ -n "${CONTAINER_INSTALL_ROOT:-}" ]; then
	install_root="${CONTAINER_INSTALL_ROOT}"
	install_root_set=1
	install_root_explicit=1
fi
if [ -n "${CONTAINER_LOG_ROOT:-}" ]; then
	log_root="${CONTAINER_LOG_ROOT}"
	log_root_set=1
fi

active_pid=''
lock_acquired=0
lock_dir=''

output() {
	printf '%s\n' "${*:-}"
}

warn() {
	printf >&2 'WARN:  %s\n' "${*:-}"
}

die() {
	printf >&2 'FATAL: %s\n' "${*:-}"
	exit 1
}

usage() {
	cat <<EOF
Usage: ${script_name} [--start | --restart | --reset [--force]] [OPTIONS]

Start or restart Apple container services and their image builder. A reset
stops the system, removes validated application data, and leaves it stopped.

Options:
  --start                 Start services if needed; do not stop a running
                          system
  --restart               Restart running services (default)
  --reset                 Remove persistent container data; requires --force
  --force                 Allow forced shutdown, builder recreation, and short
                          timeouts
  --debug                 Pass Apple's global --debug option to container
  --no-debug              Ignore an inherited CONTAINER_DEBUG value
  --cpus N                Builder CPU count
  --memory SIZE           Builder memory allocation, such as '8G'
  --stop-timeout SECONDS  Stop timeout (default: '${DEFAULT_STOP_TIMEOUT}')
  --start-timeout SECONDS Start timeout (default: '${DEFAULT_START_TIMEOUT}')
  --app-root PATH         Override Apple container application-data root
  --install-root PATH     Override Apple container installation root
  --log-root PATH         Override Apple container log root
  -h, --help              Show this help

Environment:
  CONTAINER_DEBUG
  CONTAINER_BUILDER_CPUS
  CONTAINER_BUILDER_MEMORY
  CONTAINER_STOP_TIMEOUT
  CONTAINER_START_TIMEOUT
  CONTAINER_APP_ROOT
  CONTAINER_INSTALL_ROOT
  CONTAINER_LOG_ROOT
  VERBOSE                  Show every Apple container command
  TRACE                    Enable shell tracing when non-empty

Command-line values override environment values. The native Apple root
environment variables are translated into system-start options as needed.
EOF
}

select_mode() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	selected_mode="${1}"
	if [ $(( mode_set )) -ne 0 ] && [ "${mode}" != "${selected_mode}" ]; then
		die "Options '--${mode}' and '--${selected_mode}' cannot be combined"
	fi
	mode="${selected_mode}"
	mode_set=1
	unset selected_mode
}

require_value() {
	if [ $(( ${#} )) -ne 2 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	if [ -z "${2:-}" ]; then
		return 2
	fi
	option_name="${1}"
	option_count=${2}
	if [ $(( option_count )) -lt 2 ]; then
		die "Option '${option_name}' requires a value"
	fi
	unset option_count option_name
}

while [ $(( ${#} )) -gt 0 ]; do
	case "${1:-}" in
		'--start')
			select_mode 'start'
			;;
		'--restart')
			select_mode 'restart'
			;;
		'--reset')
			select_mode 'reset'
			;;
		'--force')
			force=1
			;;
		'--debug')
			container_debug_option=1
			;;
		'--no-debug')
			container_debug_option=0
			unset CONTAINER_DEBUG
			;;
		'--cpus')
			require_value "${1:-}" ${#}
			builder_cpus=${2:-0}
			shift
			;;
		'--cpus='*)
			builder_cpus=${1#*"="}
			;;
		'--memory')
			require_value "${1:-}" ${#}
			builder_memory="${2:-}"
			shift
			;;
		'--memory='*)
			builder_memory="${1#*"="}"
			;;
		'--stop-timeout')
			require_value "${1:-}" ${#}
			stop_timeout=${2:-0}
			shift
			;;
		'--stop-timeout='*)
			stop_timeout=${1#*"="}
			;;
		'--start-timeout')
			require_value "${1:-}" ${#}
			start_timeout=${2:-0}
			shift
			;;
		'--start-timeout='*)
			start_timeout=${1#*"="}
			;;
		'--app-root')
			require_value "${1:-}" ${#}
			app_root="${2:-}"
			app_root_set=1
			shift
			;;
		'--app-root='*)
			app_root="${1#*"="}"
			app_root_set=1
			;;
		'--install-root')
			require_value "${1:-}" ${#}
			install_root="${2:-}"
			install_root_set=1
			install_root_explicit=1
			shift
			;;
		'--install-root='*)
			install_root="${1#*"="}"
			install_root_set=1
			install_root_explicit=1
			;;
		'--log-root')
			require_value "${1:-}" ${#}
			log_root="${2:-}"
			log_root_set=1
			shift
			;;
		'--log-root='*)
			log_root="${1#*"="}"
			log_root_set=1
			;;
		'-h'|'--help')
			usage
			exit 0
			;;
		'--')
			shift
			if [ $(( ${#} )) -ne 0 ]; then
				die "Unexpected operand '${1:-}'"
			fi
			break
			;;
		'-'*)
			die "Unknown option '${1:-}'"
			;;
		*)
			die "Unexpected operand '${1:-}'"
			;;
	esac
	shift
done

if [ "${mode}" = 'reset' ] && [ $(( force )) -eq 0 ]; then
	die 'Option --reset requires --force'
fi

if [ "$( /usr/bin/uname -s )" != 'Darwin' ]; then
	die 'This script requires macOS'
fi

if ! command -v container >/dev/null 2>&1; then
	die 'Apple container binary not found in path'
fi
container_binary="$( command -v container )"

is_positive_integer() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 1
	fi
	case "${1}" in
		*[!0-9]*) return 1 ;;
	esac
	[ $(( ${1} )) -gt 0 ] 2>/dev/null
}

if ! is_positive_integer "${builder_cpus:-}"; then
	die "Builder CPU count '${builder_cpus:-}' is not a positive integer"
fi
if [ -z "${builder_memory:-}" ]; then
	die 'Builder memory allocation cannot be empty'
fi
if ! is_positive_integer "${stop_timeout:-}"; then
	die "Stop timeout '${stop_timeout:-}' is not a positive integer"
fi
if ! is_positive_integer "${start_timeout:-}"; then
	die "Start timeout '${start_timeout:-}' is not a positive integer"
fi

if [ $(( stop_timeout )) -lt $(( APPLE_CONTAINER_STOP_MINIMUM )) ]; then
	warn "Stop timeout ${stop_timeout}s is shorter than Apple's 5s container"
	warn 'stop plus 20s shutdown windows'
	if [ $(( force )) -eq 0 ]; then
		die 'Use --force to allow a stop timeout below' \
			"${APPLE_CONTAINER_STOP_MINIMUM}s"
	fi
fi
if [ $(( start_timeout )) -lt $(( APPLE_CONTAINER_START_MINIMUM )) ]; then
	warn "Start timeout ${start_timeout}s is shorter than Apple's native"
	warn "${APPLE_CONTAINER_START_MINIMUM}s XPC registration timeout"
	if [ $(( force )) -eq 0 ]; then
		die 'Use --force to allow a start timeout below' \
			"${APPLE_CONTAINER_START_MINIMUM}s"
	fi
fi

container_cli() {
	if [ $(( ${#} )) -eq 0 ]; then
		return 2
	fi
	if [ $(( container_debug_option )) -ne 0 ]; then
		container_engine_run "${container_binary}" --debug "${@}"
	else
		container_engine_run "${container_binary}" "${@}"
	fi
}

container_version_output=''
if ! container_version_output="$( container_cli --version 2>/dev/null )"; then
	container_version_output=''
fi
container_version="$(
	printf '%s\n' "${container_version_output:-}" |
		awk '
			$1 == "container" && $2 == "CLI" && $3 == "version" &&
				$4 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {
				print $4
				exit
			}
		'
)"
if [ -z "${container_version:-}" ]; then
	die "Executable '${container_binary}' did not return a recognisable" \
		"Apple container version: '${container_version_output:-"<unknown>"}'"
elif awk \
		-v installed="${container_version}" \
		-v minimum="${APPLE_CONTAINER_MIN_VERSION}" '
		function number(version, fields) {
			split(version, fields, ".")
			return (fields[1] * 1000000) + (fields[2] * 1000) + fields[3]
		}
		BEGIN { exit !(number(installed) < number(minimum)) }
	' </dev/null
then
	die "Apple 'container' ${container_version} is unsupported; upgrade to" \
			"${APPLE_CONTAINER_MIN_VERSION} or later"
fi
unset container_version container_version_output

json_extract() {
	if [ $(( ${#} )) -ne 2 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	if [ -z "${2:-}" ]; then
		return 2
	fi
	json_value="${1}"
	json_key="${2}"
	if printf '%s\n' "${json_value}" |
			/usr/bin/plutil -extract "${json_key}" raw -o - - 2>/dev/null
	then
		unset json_key json_value
		return 0
	fi
	unset json_key json_value
	return 1
}

canonicalize_target_path() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	canonical_value="${1}"

	while [ "${canonical_value}" != '/' ] &&
			[ "${canonical_value%"/"}" != "${canonical_value}" ]
	do
		canonical_value="${canonical_value%"/"}"
	done

	case "${canonical_value}" in
		'/')
			printf '/\n'
			unset canonical_value
			return 0
			;;
		'/'*)
			:
			;;
		*)
			canonical_value="${PWD%"/"}/${canonical_value}"
			;;
	esac

	if ! canonical_parent="$( dirname "${canonical_value}" )"; then
		unset canonical_value
		return 1
	fi
	if ! canonical_name="$( basename "${canonical_value}" )"; then
		unset canonical_parent canonical_value
		return 1
	fi
	if ! canonical_parent="$(
				CDPATH='' cd -P "${canonical_parent}" 2>/dev/null && pwd -P
			)"
	then
		unset canonical_name canonical_parent canonical_value
		return 1
	fi

	if [ "${canonical_parent}" = '/' ]; then
		printf '/%s\n' "${canonical_name}"
	else
		printf '%s/%s\n' "${canonical_parent}" "${canonical_name}"
	fi
	unset canonical_name canonical_parent canonical_value
}

homebrew_install_root() {
	if ! command -v brew >/dev/null 2>&1; then
		return 1
	fi
	homebrew_binary="$( command -v brew )"
	homebrew_root=''
	if ! homebrew_root="$(
			command "${homebrew_binary}" --prefix container 2>/dev/null
		)"
	then
		unset homebrew_binary homebrew_root
		return 1
	fi
	if [ -z "${homebrew_root:-}" ]; then
		unset homebrew_binary homebrew_root
		return 1
	fi
	if ! homebrew_root="$(
			canonicalize_target_path "${homebrew_root}"
		)"
	then
		unset homebrew_binary homebrew_root
		return 1
	fi
	if [ ! -x "${homebrew_root}/bin/container" ] ||
			[ ! -x "${homebrew_root}/bin/container-apiserver" ] ||
			[ ! -d "${homebrew_root}/libexec/container-plugins" ]
	then
		unset homebrew_binary homebrew_root
		return 1
	fi

	homebrew_container_identity=''
	if ! homebrew_container_identity="$(
			/usr/bin/stat -Lf '%d:%i' \
				"${homebrew_root}/bin/container" 2>/dev/null
		)"
	then
		unset homebrew_binary homebrew_container_identity homebrew_root
		return 1
	fi
	selected_container_identity=''
	if ! selected_container_identity="$(
			/usr/bin/stat -Lf '%d:%i' "${container_binary}" 2>/dev/null
		)"
	then
		unset homebrew_binary homebrew_container_identity homebrew_root \
			selected_container_identity
		return 1
	fi
	if [ "${homebrew_container_identity}" != \
			"${selected_container_identity}" ]
	then
		unset homebrew_binary homebrew_container_identity homebrew_root \
			selected_container_identity
		return 1
	fi

	printf '%s\n' "${homebrew_root}"
	unset homebrew_binary homebrew_container_identity homebrew_root \
		selected_container_identity
}

active_status_json=''
active_app_root=''
active_install_root=''
active_log_root=''
system_was_running=0
if active_status_json="$(
		container_cli system status --format json 2>/dev/null
	)"
then
	active_status=''
	if ! active_status="$( json_extract "${active_status_json}" 'status' )"; then
		active_status=''
	fi
	if [ "${active_status}" = 'running' ]; then
		system_was_running=1
		if ! active_app_root="$(
				json_extract "${active_status_json}" 'appRoot'
			)"
		then
			active_app_root=''
		fi
		if ! active_install_root="$(
				json_extract "${active_status_json}" 'installRoot'
			)"
		then
			active_install_root=''
		fi
		if ! active_log_root="$(
				json_extract "${active_status_json}" 'logRoot'
			)"
		then
			active_log_root=''
		fi
	fi
fi
unset active_status

if [ $(( app_root_set )) -eq 0 ]; then
	if [ -n "${active_app_root}" ]; then
		app_root="${active_app_root}"
	else
		app_root="${HOME}/Library/Application Support/com.apple.container"
	fi
fi
if ! app_root="$( canonicalize_target_path "${app_root}" )"; then
	die "Unable to resolve application root '${app_root}'; its parent must" \
		'exist'
fi

apiserver_plist="${app_root}/apiserver/apiserver.plist"
recorded_install_root=''
if [ -n "${active_install_root}" ]; then
	recorded_install_root="${active_install_root}"
elif [ -f "${apiserver_plist}" ]; then
	if ! recorded_install_root="$(
				/usr/bin/plutil -extract \
					EnvironmentVariables.CONTAINER_INSTALL_ROOT raw \
					-o - "${apiserver_plist}" 2>/dev/null
			)"
	then
		recorded_install_root=''
	fi
fi
if [ $(( install_root_explicit )) -eq 0 ]; then
	homebrew_root=''
	if homebrew_root="$( homebrew_install_root )"; then
		if [ -n "${recorded_install_root}" ] &&
				[ "${recorded_install_root}" != "${homebrew_root}" ]
		then
			warn "Replacing recorded installation root" \
				"'${recorded_install_root}' with current Homebrew root" \
				"'${homebrew_root}'"
		fi
		install_root="${homebrew_root}"
		install_root_set=1
	elif [ -n "${recorded_install_root}" ]; then
		install_root="${recorded_install_root}"
		install_root_set=1
	fi
	unset homebrew_root
fi
unset recorded_install_root
if [ $(( log_root_set )) -eq 0 ]; then
	if [ -n "${active_log_root}" ]; then
		log_root="${active_log_root}"
		log_root_set=1
	elif [ -f "${apiserver_plist}" ]; then
		if ! log_root="$(
				/usr/bin/plutil -extract \
					EnvironmentVariables.CONTAINER_LOG_ROOT raw \
					-o - "${apiserver_plist}" 2>/dev/null
			)"
		then
			log_root=''
		fi
		if [ -n "${log_root}" ]; then
			log_root_set=1
		fi
	fi
fi

if [ $(( install_root_set )) -ne 0 ]; then
	if ! install_root="$( canonicalize_target_path "${install_root}" )"; then
		if [ $(( install_root_explicit )) -ne 0 ]; then
			die "Unable to resolve installation root '${install_root}'; its" \
				'parent must exist'
		fi
		warn "Discovered installation root '${install_root}' cannot be resolved"
		warn 'Allowing Apple container to discover its installation root'
		install_root=''
		install_root_set=0
	fi
fi
if [ $(( install_root_set )) -ne 0 ] && [ ! -d "${install_root}" ]; then
	if [ $(( install_root_explicit )) -ne 0 ]; then
		die "Installation root '${install_root}' does not exist"
	fi
	warn "Discovered installation root '${install_root}' does not exist"
	warn 'Allowing Apple container to discover its installation root'
	install_root=''
	install_root_set=0
fi
if [ $(( log_root_set )) -ne 0 ]; then
	if ! log_root="$( canonicalize_target_path "${log_root}" )"; then
		die "Unable to resolve log root '${log_root}'; its parent must exist"
	fi
fi

CONTAINER_APP_ROOT="${app_root}"
export CONTAINER_APP_ROOT
if [ $(( install_root_set )) -ne 0 ]; then
	CONTAINER_INSTALL_ROOT="${install_root}"
	export CONTAINER_INSTALL_ROOT
else
	unset CONTAINER_INSTALL_ROOT
fi
if [ $(( log_root_set )) -ne 0 ]; then
	CONTAINER_LOG_ROOT="${log_root}"
	export CONTAINER_LOG_ROOT
else
	unset CONTAINER_LOG_ROOT
fi

cleanup() {
	cleanup_status=${?}
	trap - 0 HUP INT TERM
	if [ -n "${active_pid:-}" ]; then
		if ! kill -s TERM "${active_pid}" 2>/dev/null; then
			:
		fi
		if ! wait "${active_pid}" 2>/dev/null; then
			:
		fi
		active_pid=''
	fi
	if [ $(( lock_acquired )) -ne 0 ]; then
		rm -f "${lock_dir}/pid"
		if ! rmdir "${lock_dir}" 2>/dev/null; then
			:
		fi
		lock_acquired=0
	fi
	exit ${cleanup_status}
}

interrupted() {
	if [ $(( ${#} )) -ne 2 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	if [ -z "${2:-}" ]; then
		return 2
	fi
	interrupted_signal="${1}"
	interrupted_status=${2}
	warn "Interrupted by signal ${interrupted_signal}"
	unset interrupted_signal
	exit $(( interrupted_status ))
}

trap cleanup 0
trap 'interrupted HUP 129' HUP
trap 'interrupted INT 130' INT
trap 'interrupted TERM 143' TERM

current_uid="$( id -u )"
lock_dir="${TMPDIR:-"/tmp"}/${script_name:-}.${current_uid:-}.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
	lock_pid=''
	if ! lock_pid="$( sed -n '1p' "${lock_dir}/pid" 2>/dev/null )"; then
		lock_pid=''
	fi
	if is_positive_integer "${lock_pid:-}" &&
			kill -0 "${lock_pid}" 2>/dev/null
	then
		die "Another ${script_name} process is running as PID ${lock_pid}"
	fi
	lock_owner=''
	if ! lock_owner="$( /usr/bin/stat -f '%u' "${lock_dir}" 2>/dev/null )"; then
		lock_owner=''
	fi
	if [ "${lock_owner}" != "${current_uid}" ]; then
		die "Refusing to remove unowned stale lock '${lock_dir}'"
	fi
	warn "Removing stale lock '${lock_dir}'"
	rm -f "${lock_dir}/pid"
	if ! rmdir "${lock_dir}" 2>/dev/null; then
		die "Unable to remove stale lock '${lock_dir}'"
	fi
	if ! mkdir "${lock_dir}"; then
		die "Unable to create lock '${lock_dir}'"
	fi
fi
lock_acquired=1
if ! printf '%s\n' "${$}" >"${lock_dir}/pid"; then
	die 'Unable to record lock owner'
fi

run_with_timeout() {
	if [ $(( ${#} )) -lt 3 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	if [ -z "${2:-}" ]; then
		return 2
	fi
	timed_limit=${1}
	timed_description="${2}"
	if ! is_positive_integer "${timed_limit}"; then
		unset timed_description timed_limit
		return 2
	fi
	shift 2

	"${@}" &
	active_pid=${!}
	timed_pid=${active_pid:-0}
	timed_elapsed=0

	while kill -0 "${timed_pid}" 2>/dev/null; do
		if [ $(( timed_elapsed )) -ge $(( timed_limit )) ]; then
			warn "${timed_description} exceeded ${timed_limit}s; terminating" \
				"PID ${timed_pid}"
			if ! kill -s TERM "${timed_pid}" 2>/dev/null; then
				:
			fi
			timed_grace=0
			while kill -0 "${timed_pid}" 2>/dev/null &&
					[ $(( timed_grace )) -lt 3 ]
			do
				sleep 1
				timed_grace=$(( timed_grace + 1 ))
			done
			if kill -0 "${timed_pid}" 2>/dev/null; then
				if ! kill -s KILL "${timed_pid}" 2>/dev/null; then
					:
				fi
			fi
			if ! wait "${timed_pid}" 2>/dev/null; then
				:
			fi
			active_pid=''
			unset timed_description timed_elapsed timed_grace timed_limit \
				timed_pid timed_status
			return 124
		fi
		sleep 1
		timed_elapsed=$(( timed_elapsed + 1 ))
	done

	if wait "${timed_pid}"; then
		timed_status=0
	else
		timed_status=${?}
	fi
	active_pid=''
	unset timed_description timed_elapsed timed_grace timed_limit timed_pid
	return ${timed_status}
}

system_is_running() {
	container_cli system status >/dev/null 2>&1
}

builder_is_running() {
	builder_id=''
	if ! builder_id="$( container_cli builder status --quiet 2>/dev/null )"; then
		unset builder_id
		return 1
	fi
	if [ "${builder_id}" = 'buildkit' ]; then
		unset builder_id
		return 0
	fi
	unset builder_id
	return 1
}

verify_system_running() {
	verified_status_json=''
	if ! verified_status_json="$(
			container_cli system status --format json 2>/dev/null
		)"
	then
		unset verified_status_json
		return 1
	fi
	verified_status=''
	if ! verified_status="$(
			json_extract "${verified_status_json}" 'status'
		)"
	then
		unset verified_status verified_status_json
		return 1
	fi
	if [ "${verified_status}" != 'running' ]; then
		unset verified_status verified_status_json
		return 1
	fi

	verified_app_root=''
	if ! verified_app_root="$(
			json_extract "${verified_status_json}" 'appRoot'
		)"
	then
		unset verified_status verified_status_json
		return 1
	fi
	if ! verified_app_root="$(
			canonicalize_target_path "${verified_app_root}"
		)"
	then
		unset verified_status verified_status_json
		return 1
	fi
	if [ "${verified_app_root}" != "${app_root}" ]; then
		warn "Running application root '${verified_app_root}' does not match" \
			"'${app_root}'"
		unset verified_status verified_status_json
		return 1
	fi

	verified_install_root=''
	if ! verified_install_root="$(
			json_extract "${verified_status_json}" 'installRoot'
		)"
	then
		verified_install_root=''
	fi
	if [ -n "${verified_install_root}" ]; then
		if ! verified_install_root="$(
				canonicalize_target_path "${verified_install_root}"
			)"
		then
			unset verified_status verified_status_json
			return 1
		fi
	elif [ $(( install_root_set )) -ne 0 ]; then
		unset verified_status verified_status_json
		return 1
	fi
	if [ $(( install_root_set )) -ne 0 ]; then
		if [ "${verified_install_root}" != "${install_root}" ]; then
			warn "Running installation root '${verified_install_root}' does" \
				"not match '${install_root}'"
			unset verified_status verified_status_json
			return 1
		fi
	fi

	verified_log_root=''
	if ! verified_log_root="$(
			json_extract "${verified_status_json}" 'logRoot'
		)"
	then
		verified_log_root=''
	fi
	if [ -n "${verified_log_root}" ]; then
		if ! verified_log_root="$(
				canonicalize_target_path "${verified_log_root}"
			)"
		then
			unset verified_status verified_status_json
			return 1
		fi
	elif [ $(( log_root_set )) -ne 0 ]; then
		unset verified_status verified_status_json
		return 1
	fi
	if [ $(( log_root_set )) -ne 0 ]; then
		if [ "${verified_log_root}" != "${log_root}" ]; then
			warn "Running log root '${verified_log_root}' does not match '${log_root}'"
			unset verified_status verified_status_json
			return 1
		fi
	fi
	unset verified_status verified_status_json
	return 0
}

container_processes_running() {
	/usr/bin/pgrep -U "${current_uid}" -f \
		"${CONTAINER_PROCESS_PATTERN}" \
		>/dev/null 2>&1
}

container_services_running() {
	if system_is_running; then
		return 0
	fi
	container_processes_running
}

force_stop_services() {
	warn 'Forcing removal of Apple container launchd services'
	for launchd_domain in "gui/${current_uid}" "user/${current_uid}"; do
		/bin/launchctl print "${launchd_domain}" 2>/dev/null |
			/usr/bin/grep -Eo -- 'com\.apple\.container\.[A-Za-z0-9._-]+' |
			/usr/bin/sort -u |
			while IFS= read -r launchd_service; do
				if [ -z "${launchd_service:-}" ]; then
					continue
				fi
				if ! /bin/launchctl bootout \
						"${launchd_domain}/${launchd_service}" 2>/dev/null
				then
					:
				fi
			done
	done

	container_pids=''
	if ! container_pids="$(
			/usr/bin/pgrep -U "${current_uid}" -f \
				"${CONTAINER_PROCESS_PATTERN}" \
				2>/dev/null
		)"
	then
		container_pids=''
	fi
	for container_pid in ${container_pids}; do
		if ! kill -s TERM "${container_pid}" 2>/dev/null; then
			:
		fi
	done

	force_elapsed=0
	while container_processes_running && [ $(( force_elapsed )) -lt 5 ]; do
		sleep 1
		force_elapsed=$(( force_elapsed + 1 ))
	done
	if container_processes_running; then
		container_pids=''
		if ! container_pids="$(
				/usr/bin/pgrep -U "${current_uid}" -f \
					"${CONTAINER_PROCESS_PATTERN}" \
					2>/dev/null
			)"
		then
			container_pids=''
		fi
		for container_pid in ${container_pids}; do
			if ! kill -s KILL "${container_pid}" 2>/dev/null; then
				:
			fi
		done
	fi
	unset container_pid container_pids force_elapsed launchd_domain \
		launchd_service
}

stop_system() {
	if builder_is_running; then
		output 'Stopping Apple container builder ...'
		if run_with_timeout "${stop_timeout}" \
				'container builder stop' container_cli builder stop
		then
			: # Builder stopped cleanly.
		else
			builder_stop_status=${?}
			warn "Builder stop failed with status ${builder_stop_status};" \
				'system stop will retry it'
			unset builder_stop_status
		fi
	fi

	output 'Stopping Apple container system ...'
	if run_with_timeout "${stop_timeout}" \
			'container system stop' container_cli system stop
	then
		: # System stopped cleanly.
	else
		system_stop_status=${?}
		warn "System stop failed with status ${system_stop_status}"
		unset system_stop_status
	fi

	if container_services_running; then
		if [ $(( force )) -eq 0 ]; then
			die 'Container services remain active; rerun with --force for' \
				'targeted recovery'
		fi
		force_stop_services
	fi

	if container_services_running; then
		die 'Apple container services remain active after forced shutdown'
	fi
}

start_system_once() {
	set -- system start \
		--enable-kernel-install \
		--timeout "${start_timeout}" \
		--app-root "${app_root}"
	if [ $(( install_root_set )) -ne 0 ]; then
		set -- "${@}" --install-root "${install_root}"
	fi
	if [ $(( log_root_set )) -ne 0 ]; then
		set -- "${@}" --log-root "${log_root}"
	fi

	start_command_status=0
	if run_with_timeout "${start_timeout}" \
			'container system start' container_cli "${@}"
	then
		start_command_status=0
	else
		start_command_status=${?}
	fi
	if verify_system_running; then
		if [ $(( start_command_status )) -ne 0 ]; then
			warn 'System became healthy despite start command status' \
				"${start_command_status}"
		fi
		unset start_command_status
		return 0
	fi
	if [ $(( start_command_status )) -eq 0 ]; then
		start_command_status=1
	fi
	return ${start_command_status}
}

start_system() {
	output 'Starting Apple container system ...'
	if start_system_once; then
		return 0
	else
		start_failure=${?}
	fi
	if [ $(( force )) -eq 0 ]; then
		die "Container system failed to start with status ${start_failure}"
	fi
	warn 'System start failed; applying forced service cleanup and retrying' \
		'once'
	force_stop_services
	if ! start_system_once; then
		die 'Container system failed to start after forced retry'
	fi
	unset start_failure
}

start_builder_once() {
	start_command_status=0
	if run_with_timeout "${start_timeout}" 'container builder start' \
			container_cli builder start \
				--cpus "${builder_cpus}" \
				--memory "${builder_memory}"
	then
		start_command_status=0
	else
		start_command_status=${?}
	fi
	if builder_is_running; then
		if [ $(( start_command_status )) -ne 0 ]; then
			warn 'Builder became healthy despite start command status' \
				"${start_command_status}"
		fi
		unset start_command_status
		return 0
	fi
	if [ $(( start_command_status )) -eq 0 ]; then
		start_command_status=1
	fi
	return ${start_command_status}
}

start_builder() {
	output "Starting Apple container builder with ${builder_cpus} CPUs and" \
		"${builder_memory} memory ..."
	if start_builder_once; then
		return 0
	else
		builder_failure=${?}
	fi
	if [ $(( force )) -eq 0 ]; then
		die "Builder failed to start with status ${builder_failure}; rerun" \
			'with --force to recreate it'
	fi

	warn 'Builder start failed; applying legacy remove-and-recreate recovery'
	if ! run_with_timeout "${stop_timeout}" \
			'container builder rm' container_cli builder rm --force
	then
		warn 'Unable to remove the failed builder cleanly'
	fi
	if ! start_builder_once; then
		die 'Builder failed to start after legacy recovery'
	fi
	unset builder_failure
}

running_app_root() {
	running_status_json=''
	if ! running_status_json="$(
			container_cli system status --format json 2>/dev/null
		)"
	then
		unset running_status_json
		return 1
	fi
	running_status=''
	if ! running_status="$( json_extract "${running_status_json}" 'status' )"; then
		unset running_status running_status_json
		return 1
	fi
	if [ "${running_status}" != 'running' ]; then
		unset running_status running_status_json
		return 1
	fi
	running_root=''
	if ! running_root="$( json_extract "${running_status_json}" 'appRoot' )"; then
		unset running_root running_status running_status_json
		return 1
	fi
	if ! running_root="$( canonicalize_target_path "${running_root}" )"; then
		unset running_root running_status running_status_json
		return 1
	fi
	printf '%s\n' "${running_root}"
	unset running_root running_status running_status_json
}

filesystem_available_kib() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	filesystem_path="${1}"
	filesystem_available=''
	if ! filesystem_available="$(
			/bin/df -kP "${filesystem_path}" 2>/dev/null |
				/usr/bin/awk '
					NR == 2 { print $4; found = 1 }
					END { if (!found) exit 1 }
				'
		)"
	then
		unset filesystem_available filesystem_path
		return 1
	fi
	case "${filesystem_available}" in
		''|*[!0-9]*)
			unset filesystem_available filesystem_path
			return 1
			;;
	esac
	printf '%s\n' "${filesystem_available}"
	unset filesystem_available filesystem_path
}

validate_reset_app_root() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	reset_root="${1}"
	case "${reset_root}" in
		''|'/'|'/Applications'|'/Library'|'/System'|'/Users'|'/Volumes'|\
		'/bin'|'/etc'|'/opt'|'/private'|'/sbin'|'/usr'|'/var'|"${HOME}"|\
		"${HOME}/Library"|"${HOME}/Library/Application Support")
			die "Refusing unsafe application-data reset path '${reset_root}'"
			;;
	esac
	if [ -L "${reset_root}" ]; then
		die "Refusing to reset symlink '${reset_root}'"
	fi
	if [ ! -d "${reset_root}" ]; then
		unset reset_root
		return 0
	fi

	reset_owner=''
	if ! reset_owner="$(
			/usr/bin/stat -f '%u' "${reset_root}" 2>/dev/null
		)"
	then
		reset_owner=''
	fi
	if [ "${reset_owner}" != "${current_uid}" ]; then
		die "Refusing to reset application root '${reset_root}' owned by" \
			"UID ${reset_owner:-"unknown"}"
	fi

	for reset_required_directory in ${RESET_REQUIRED_DIRECTORIES}; do
		if [ ! -d "${reset_root}/${reset_required_directory}" ]; then
			die "Refusing application root '${reset_root}': required directory" \
				"'${reset_required_directory}' is missing, has the wrong type," \
				'or is a symlink'
		fi
		if [ -L "${reset_root}/${reset_required_directory}" ]; then
			die "Refusing application root '${reset_root}': required directory" \
				"'${reset_required_directory}' is missing, has the wrong type," \
				'or is a symlink'
		fi
	done
	for reset_required_file in ${RESET_REQUIRED_FILES}; do
		if [ ! -f "${reset_root}/${reset_required_file}" ]; then
			die "Refusing application root '${reset_root}': required file" \
				"'${reset_required_file}' is missing, has the wrong type, or" \
				'is a symlink'
		fi
		if [ -L "${reset_root}/${reset_required_file}" ]; then
			die "Refusing application root '${reset_root}': required file" \
				"'${reset_required_file}' is missing, has the wrong type, or" \
				'is a symlink'
		fi
	done
	if ! /usr/bin/plutil -p "${reset_root}/state.json" >/dev/null 2>&1; then
		die "Refusing application root '${reset_root}': state.json is invalid"
	fi

	reset_plist="${reset_root}/apiserver/apiserver.plist"
	reset_label=''
	if ! reset_label="$(
			/usr/bin/plutil -extract Label raw -o - "${reset_plist}" 2>/dev/null
		)"
	then
		reset_label=''
	fi
	if [ "${reset_label}" != 'com.apple.container.apiserver' ]; then
		die "Application root '${reset_root}' has an unexpected launchd label"
	fi

	reset_recorded_app_root=''
	if ! reset_recorded_app_root="$(
			/usr/bin/plutil -extract \
				EnvironmentVariables.CONTAINER_APP_ROOT raw \
				-o - "${reset_plist}" 2>/dev/null
		)"
	then
		die "Application root '${reset_root}' has no valid recorded app root"
	fi
	if ! reset_recorded_app_root="$(
			canonicalize_target_path "${reset_recorded_app_root}"
		)"
	then
		die "Application root '${reset_root}' has no valid recorded app root"
	fi
	if [ "${reset_recorded_app_root}" != "${reset_root}" ]; then
		die "Application root '${reset_root}' records a different app root" \
			"'${reset_recorded_app_root}'"
	fi

	reset_recorded_install_root=''
	if ! reset_recorded_install_root="$(
			/usr/bin/plutil -extract \
				EnvironmentVariables.CONTAINER_INSTALL_ROOT raw \
				-o - "${reset_plist}" 2>/dev/null
		)"
	then
		reset_recorded_install_root=''
	fi
	case "${reset_recorded_install_root}/" in
		"${reset_root}/"*)
			die "Refusing to reset '${reset_root}': installation root" \
				"'${reset_recorded_install_root}' is inside it"
			;;
	esac

	unset reset_label reset_owner reset_plist reset_recorded_app_root \
		reset_recorded_install_root reset_required_directory \
		reset_required_file reset_root
}

validate_reset_log_root() {
	if [ $(( ${#} )) -ne 1 ]; then
		return 2
	fi
	if [ -z "${1:-}" ]; then
		return 2
	fi
	reset_root="${1}"
	case "${reset_root}" in
		''|'/'|'/Applications'|'/Library'|'/System'|'/Users'|'/Volumes'|\
		'/bin'|'/etc'|'/opt'|'/private'|'/sbin'|'/usr'|'/var'|"${HOME}"|\
		"${HOME}/Library")
			die "Refusing unsafe log reset path '${reset_root}'"
			;;
	esac
	if [ -L "${reset_root}" ]; then
		die "Refusing to reset log symlink '${reset_root}'"
	fi
	if [ ! -d "${reset_root}" ]; then
		unset reset_root
		return 0
	fi
	reset_owner=''
	if ! reset_owner="$(
			/usr/bin/stat -f '%u' "${reset_root}" 2>/dev/null
		)"
	then
		reset_owner=''
	fi
	if [ "${reset_owner}" != "${current_uid}" ]; then
		die "Refusing to reset log root '${reset_root}' owned by" \
			"UID ${reset_owner:-"unknown"}"
	fi

	reset_name="$( basename "${reset_root}" )"
	if ! printf '%s\n' "${reset_name}" |
			/usr/bin/grep -Eiq -- 'container'
	then
		die "Refusing non-dedicated log root '${reset_root}'; its name must" \
			'contain container'
	fi
	unset reset_name reset_owner reset_root
}

validate_reset_roots() {
	validate_reset_app_root "${app_root}"

	reset_running_app_root=''
	if [ $(( system_was_running )) -ne 0 ]; then
		if ! reset_running_app_root="$(
				canonicalize_target_path "${active_app_root:-}"
			)"
		then
			die 'Unable to validate the running system application root'
		fi
	elif system_is_running; then
		if ! reset_running_app_root="$( running_app_root )"; then
			die 'Unable to validate the running system application root'
		fi
	elif container_processes_running; then
		die 'Container processes are running but their application root' \
			'cannot be identified'
	fi
	if [ -n "${reset_running_app_root}" ] &&
			[ "${reset_running_app_root}" != "${app_root}" ]
	then
		die "Running container system uses '${reset_running_app_root}', not" \
			"the requested reset root '${app_root}'"
	fi

	if [ $(( log_root_set )) -ne 0 ]; then
		case "${log_root}/" in
			"${app_root}/"*)
				: # The validated application root contains this path.
				;;
			*)
				validate_reset_log_root "${log_root}"
				;;
		esac
	fi
	unset reset_running_app_root
}

reset_container_data() {
	validate_reset_roots

	reset_df_target="$( dirname "${app_root}" )"
	reset_available_before_kib=''
	if ! reset_available_before_kib="$(
			filesystem_available_kib "${reset_df_target}"
		)"
	then
		reset_available_before_kib=''
	fi

	reset_kib=0
	if [ -d "${app_root}" ]; then
		reset_kib="$(
			/usr/bin/du -sk "${app_root}" 2>/dev/null |
				/usr/bin/awk '{ print $1 }'
		)"
		case "${reset_kib}" in
			''|*[!0-9]*) reset_kib=0 ;;
		esac
		output "Removing Apple container application data '${app_root}' ..."
		if ! rm -rf "${app_root}"; then
			die "Unable to remove application root '${app_root}'"
		fi
	fi
	if [ -e "${app_root}" ]; then
		die "Application root '${app_root}' still exists after reset"
	fi
	if [ -L "${app_root}" ]; then
		die "Application root '${app_root}' still exists after reset"
	fi

	if [ $(( log_root_set )) -ne 0 ]; then
		case "${log_root}/" in
			"${app_root}/"*)
				: # Removed with the application root.
				;;
			*)
				validate_reset_log_root "${log_root}"
				if [ -d "${log_root}" ]; then
					reset_log_kib="$(
						/usr/bin/du -sk "${log_root}" 2>/dev/null |
							/usr/bin/awk '{ print $1 }'
					)"
					case "${reset_log_kib}" in
						''|*[!0-9]*) reset_log_kib=0 ;;
					esac
					reset_kib=$(( reset_kib + reset_log_kib ))
					output "Removing Apple container logs '${log_root}' ..."
					if ! rm -rf "${log_root}"; then
						die "Unable to remove log root '${log_root}'"
					fi
				fi
				if [ -e "${log_root}" ]; then
					die "Log root '${log_root}' still exists after reset"
				fi
				if [ -L "${log_root}" ]; then
					die "Log root '${log_root}' still exists after reset"
				fi
				;;
		esac
	fi

	if ! /usr/bin/defaults delete \
			com.apple.container.defaults >/dev/null 2>&1
	then
		:
	fi
	if system_is_running; then
		die 'Container system unexpectedly running after reset'
	fi
	if container_processes_running; then
		die 'Container processes unexpectedly remain after reset'
	fi

	reset_available_after_kib=''
	if ! reset_available_after_kib="$(
			filesystem_available_kib "${reset_df_target}"
		)"
	then
		reset_available_after_kib=''
	fi
	output "Apple container reset complete; removed ${reset_kib} KiB of" \
		'directory data'
	if [ -n "${reset_available_before_kib}" ] &&
			[ -n "${reset_available_after_kib}" ]
	then
		reset_available_change_kib=$((
			reset_available_after_kib - reset_available_before_kib
		))
		if [ $(( reset_available_change_kib )) -ge 0 ]; then
			output 'Application-root filesystem available space increased by' \
				"${reset_available_change_kib} KiB"
		else
			warn 'Application-root filesystem available space changed by' \
				"${reset_available_change_kib} KiB during reset"
		fi
	fi
	output "Installation root '${install_root:-"<automatic>"}' was preserved"
	unset reset_available_after_kib reset_available_before_kib \
		reset_available_change_kib reset_df_target reset_kib reset_log_kib
}

case "${mode}" in
	'start')
		if system_is_running; then
			if ! verify_system_running; then
				die 'A container system is running with different root' \
					'settings; use --restart'
			fi
			output 'Apple container system is already operational'
		else
			start_system
		fi
		start_builder
		;;
	'restart')
		if [ $(( system_was_running )) -eq 0 ] && ! system_is_running; then
			die 'Container system is not running; use --start'
		fi
		output 'Restarting Apple container services ...'
		stop_system
		start_system
		start_builder
		;;
	'reset')
		validate_reset_roots
		output "Validated Apple container application root '${app_root}'"
		output 'Required directories, metadata, ownership, and launchd' \
			'identity are consistent'
		if container_services_running; then
			output 'Stopping Apple container services before reset ...'
			stop_system
		fi
		reset_container_data
		exit 0
		;;
esac

if ! verify_system_running; then
	die 'Final container system health verification failed'
fi
if ! builder_is_running; then
	die 'Final container builder health verification failed'
fi

case "${mode}" in
	'start')
		output 'Apple container system and builder are operational'
		;;
	'restart')
		output 'Apple container system and builder successfully restarted'
		;;
esac
output "Application root: ${verified_app_root}"
output "Installation root: ${verified_install_root:-"<unknown>"}"
output "Log root: ${verified_log_root:-"<macOS unified logging>"}"
output "Builder resources: ${builder_cpus} CPUs, ${builder_memory} memory"

# vi: set cc=80 sw=4 ts=4:
