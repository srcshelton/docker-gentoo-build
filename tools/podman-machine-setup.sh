#! /usr/bin/env bash

set -eu
set -o pipefail

trace=${TRACE:-}
[[ -z "${trace}" ]] || set -o xtrace

cd "$( dirname "${0}" )/.." || exit 1

# shellcheck disable=SC1091
. ./common/container-engine-helpers.sh

machine='podman-machine-default'
cores=4
memory_gib=12
disk_gib=25
initialise=0

if [[ "$( uname -s )" == 'Darwin' ]]; then
	cores="$(
		sysctl -n hw.perflevel0.physicalcpu 2>/dev/null ||
			sysctl -n hw.physicalcpu 2>/dev/null ||
			printf '4\n'
	)"
elif type -pf nproc >/dev/null 2>&1; then
	cores="$( nproc )"
fi

while (( ${#} )); do
	case "${1}" in
		-h|--help)
			cat <<EOF
Usage: $( basename "${0}" ) [OPTIONS]

Prepare a Podman-managed Linux virtual machine for this repository. The
selected machine is checked, started when permitted, and made Podman's default
system connection.

Without --init, the machine must already exist and be running. With --init,
the script creates or starts it when necessary and then runs gentoo-init.docker
with the selected Podman executable.

Options:
  -i, --init          Create or start the machine when necessary, then
                      initialise this repository's Gentoo container images
  -M, --machine NAME  Select the Podman machine
                      (default: '${machine}')
  -c, --cores COUNT   CPU count for a newly-created machine
                      (default: '${cores}')
  -m, --memory GiB    Memory for a newly-created machine, in GiB
                      (default: '${memory_gib}')
  -d, --disk GiB      Disk size for a newly-created machine, in GiB
                      (default: '${disk_gib}')
  -h, --help          Show this help

Podman 4.0.3 or later is required. Resource options apply only when creating a
machine; they do not resize an existing machine.

Environment:
  VERBOSE  Show every Podman command
  TRACE    Enable shell tracing when non-empty
EOF
			exit 0
			;;
		-i|--init)
			initialise=1
			;;
		-M|--machine|-c|--cores|-m|--memory|-d|--disk)
			if (( ${#} < 2 )); then
				echo >&2 "FATAL: Option '${1}' requires a value"
				exit 1
			fi
			case "${1}" in
				-M|--machine) machine=${2} ;;
				-c|--cores) cores=${2} ;;
				-m|--memory) memory_gib=${2} ;;
				-d|--disk) disk_gib=${2} ;;
			esac
			shift
			;;
		-M=*|--machine=*) machine=${1#*=} ;;
		-c=*|--cores=*) cores=${1#*=} ;;
		-m=*|--memory=*) memory_gib=${1#*=} ;;
		-d=*|--disk=*) disk_gib=${1#*=} ;;
		-f|--force-run-on-vm|-t|--xfer|--transfer|--transfer-cache)
			echo >&2 "FATAL: '${1}' belongs to the retired legacy in-VM" \
				"workflow and is no longer supported"
			exit 1
			;;
		*)
			echo >&2 "FATAL: Unknown option '${1}'"
			exit 1
			;;
	esac
	shift
done

for value_name in cores memory_gib disk_gib; do
	value=${!value_name}
	if [[ "${value}" == *[!0-9]* ]] || (( value < 1 )); then
		echo >&2 "FATAL: ${value_name} must be a positive integer, not" \
			"'${value}'"
		exit 1
	fi
done
unset value value_name

podman_path="$( type -pf podman 2>/dev/null || : )"
if [[ ! -x "${podman_path}" ]]; then
	echo >&2 "FATAL: Cannot find a Podman executable in PATH"
	exit 1
fi

podman_version="$(
	container_engine_run "${podman_path}" --version 2>/dev/null |
		sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' |
		head -n 1
)"
if [[ -z "${podman_version}" ]]; then
	echo >&2 "FATAL: Cannot determine Podman version"
	exit 1
fi
if ! awk -v installed="${podman_version}" -v minimum='4.0.3' '
	function component(version, position, fields) {
		split(version, fields, ".")
		return fields[position] + 0
	}
	BEGIN {
		for (position = 1; position <= 3; position++) {
			if (component(installed, position) > component(minimum, position))
				exit 0
			if (component(installed, position) < component(minimum, position))
				exit 1
		}
		exit 0
	}
' </dev/null
then
	echo >&2 "FATAL: Podman ${podman_version} is unsupported by the" \
		"host-mounted machine workflow; version 4.0.3 or later is required"
	exit 1
fi

if ! container_engine_run "${podman_path}" machine inspect "${machine}" \
		>/dev/null 2>&1
then
	if (( ! initialise )); then
		echo >&2 "FATAL: Podman machine '${machine}' does not exist; rerun with" \
			"'--init' to create and start it"
		exit 1
	fi
	container_engine_run "${podman_path}" machine init \
			--cpus "${cores}" \
			--disk-size "${disk_gib}" \
			--memory "$(( memory_gib * 1024 ))" \
		"${machine}"
fi

machine_state="$(
	container_engine_run "${podman_path}" machine inspect \
		--format '{{.State}}' "${machine}"
)"
if [[ "${machine_state}" != 'running' ]]; then
	if (( ! initialise )); then
		echo >&2 "FATAL: Podman machine '${machine}' is '${machine_state:-unknown}';" \
			"rerun with '--init' to start it"
		exit 1
	fi
	container_engine_run "${podman_path}" machine start "${machine}"
fi

if ! container_engine_run "${podman_path}" system connection default \
		"${machine}"
then
	echo >&2 "FATAL: Cannot select Podman machine '${machine}' as the active" \
		"system connection"
	exit 1
fi

for (( attempt = 1; attempt <= 600; attempt++ )); do
	if container_engine_run "${podman_path}" info >/dev/null 2>&1; then
		break
	fi
	if (( attempt == 600 )); then
		echo >&2 "FATAL: Podman machine '${machine}' did not become usable" \
			"within 60 seconds"
		exit 1
	fi
	sleep 0.1
done

echo >&2 "INFO:  Podman ${podman_version} machine '${machine}' is ready"

if (( initialise )); then
	CONTAINER_ENGINE="${podman_path}" ./gentoo-init.docker
fi

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
