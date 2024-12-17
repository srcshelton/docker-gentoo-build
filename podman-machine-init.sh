#! /usr/bin/env bash

set -eu  # x

#declare -i debug=${DEBUG:-}
declare -i trace=${TRACE:-}

declare -r REPO='https://github.com/srcshelton/docker-gentoo-build.git'
declare -r INIT='gentoo-init.docker'

(( trace )) && set -o xtrace

export LANG=C
export LC_ALL=C

declare MACHINE='podman-machine-default'
declare REMOTE_HOME='/var/home'
declare REMOTE_USER='core'
declare ARCH=''

declare -i init=0 xfer=0 cores=4 local_install=0

if [[ "$( uname -s )" == 'Darwin' ]]; then
	# Darwin/BSD lacks GNU readlink - either realpath or perl's Cwd module
	# will do at a pinch, although both lack the additional options of GNU
	# binaries...
	#
	readlink() {
		if command -v realpath >/dev/null 2>&1; then
			realpath "${2}"
		else
			perl -MCwd -le 'print Cwd::abs_path shift' "${2}"
		fi
	}
	export -f readlink
else
	case "$( id -un )" in
		"${REMOTE_USER}")
			: ;;
		'mixtile')
			REMOTE_USER='mixtile' ;;
		*)
			REMOTE_USER="$( id -un )"
			if ! REMOTE_HOME="$( dirname "$( # <- Syntax
					eval "readlink -e ~${REMOTE_USER}"
				)" )" || ! [ -d "${REMOTE_HOME}/${REMOTE_USER}" ]
			then
				echo >&2 "FATAL: Unable to determine home directory" \
					"for user '${REMOTE_USER:-}': ${?}"
				exit 1
			else
				echo >&2 "INFO:  Using home '${REMOTE_HOME}' for" \
					"user '${REMOTE_USER}' ..."
			fi
			;;
	esac
fi

if type -pf portageq >/dev/null 2>&1; then
	ARCH="$( portageq envvar ARCH )"
else
	echo >&2 "WARN:  Cannot locate 'portageq' utility"
fi
if [[ -z "${ARCH:-}" ]]; then
	case "$( uname -m )" in
		aarch64)
			ARCH='arm64' ;;
		arm*)
			ARCH='arm' ;;
		x86_64)
			ARCH='amd64' ;;
		*)
			echo >&2 "FATAL: Unknown architecture '$( uname -m )'"
			exit 1
			;;
	esac
fi
readonly ARCH

if [[ "$( uname -s )" == 'Darwin' ]]; then
	declare -i total=${cores}
	total=$(( $( sysctl -n machdep.cpu.core_count || sysctl -n machdep.cpu.core_total ) ))

	case "$( sysctl -n machdep.cpu.brand_string )" in
		'Apple M1'|'Apple M2'|'Apple M3')
			# M1: 'Tonga' - 4 Firestorm and 4 Icestorm cores, first
			#     seen in the A14 Bionic ('Sicily')
			# M2: 'Staten' - 4 Avalance and 4 Blizzard cores, first
			#     seen in the A15 Bionic ('Ellis')
			# M3: 'Ibiza' - 4 Everest and 4 Sawtooth cores, first
			#     seen in the A17 Pro ('Coll')
			cores=$(( total - 4 ))
			;;
		'Apple M4')
			# 'Donan' - either 3 or 4 Everest and 6 Sawtooth cores,
			# first seen in the A18 Pro ('Tahiti')
			cores=$(( total - 6 ))
			;;

		'Apple M1 Pro'|'Apple M1 Max')
			# 'Jade' - either 8 Firestorm and 2 Icestorm or 6
			# Firestorm and 8 Icestorm cores
			case "${total}" in
				14)
					cores=$(( total - 2 )) ;;
				*)
					cores=$(( total - 8 )) ;;
			esac
			;;
		'Apple M2 Pro'|'Apple M2 Max')
			# 'Rhodes' - either 8 Avalanche and 4 Blizzard or 6
			# Avalanche and 4 Blizzard cores
			cores=$(( total - 4 ))
			;;
		'Apple M3 Pro')
			# 'Lobos' - either 5 or 6 Everest and 6 Sawtooth cores
			cores=$(( total - 6 ))
			;;
		'Apple M4 Pro')
			# Either 8 or 10 Everest and 4 Sawtooth cores
			cores=$(( total - 4 ))
			;;

		'Apple M3 Max')
			# 'Palma' - either 10 or 12 Everest and 4 Sawtooth
			# cores
			cores=$(( total - 4 ))
			;;
		'Apple M4 Max')
			# Either 10 or 12 Everest and 4 Sawtooth cores
			cores=$(( total - 4 ))
			;;

		'Apple M1 Ultra')
			# Two M1 Max joined via UltraFusion Interconnect
			# resulting in 16 Firestorm and 4 Icestorm cores
			cores=$(( total - 4 ))
			;;
		'Apple M2 Ultra')
			# Two M2 Max joined via UltraFusion Interconnect
			# resulting in 16 Avalanche and 8 Blizzard cores
			cores=$(( total - 8 ))
			;;

		'Intel'*)
			# Adjust for SMT/HT
			cores=$(( total / 2 ))
	esac
	unset total
else
	cores="$( nproc || grep 'cpu cores' /proc/cpuinfo | tail -n 1 | awk -F': ' '{ print $2 }' )"
fi
cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

declare arg=''
for arg in "${@:-}"; do
	case "${arg:-}" in
		-h|--help)
			echo "Usage: $( basename "${0}" ) <--host>|[--machine=<name>] [--cores=<${cores}>] [--init] [--transfer-cache]"
			exit 0
			;;
		-c|--cores)
			cores="${arg#*"-"}"
			;;
		--host)
			if ! [[ "${*:-}" == '--host' ]]; then
				echo >&2 "FATAL: '--host' cannot be used with any other options"
				exit 1
			fi
			local_install=1
			;;
		-i|--init)
			init=1
			;;
		-m=*|--machine=*)
			MACHINE="${arg#*"="}"
			;;
		-t|--xfer|--transfer|--transfer-cache)
			xfer=1
			;;
	esac
done
unset arg

if (( local_install )); then
	sudo mkdir -p /var/cache &&
		test -s "${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar" &&
		sudo tar -xpf "${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar" -C /var/cache/

	sudo mkdir -p /var/cache/portage &&
		sudo chown "${REMOTE_USER}:root" /var/cache/portage &&
		sudo chmod ug+rwX /var/cache/portage

	sudo mkdir -p "/var/cache/portage/pkg/${ARCH}/docker" &&
		sudo chown "${REMOTE_USER}:root" "/var/cache/portage/pkg/${ARCH}/docker" &&
		sudo chmod ug+rwX "/var/cache/portage/pkg/${ARCH}/docker"

	if ! [[ -x sync-portage.sh ]]; then
		echo >&2 "WARN:  Cannot locate 'sync-portage.sh' script - please run" \
			"this manually in order to populate '/etc/portage'"
	else
		sudo ./sync-portage.sh &&
			sudo cp gentoo-base/etc/portage/make.conf /etc/portage/

		echo >&2 "INFO:  Please review the settings in '/etc/portage/make.conf'"
	fi
else
	if ! [[ -f ~/.ssh/id_ed25519 && -s ~/.ssh/id_ed25519 ]]; then
		echo >&2 "FATAL: ssh private key '${HOME}/.ssh/id_ed25519' not accessible"
		exit 1
	fi

	if ! podman machine list | grep -q -- "^${MACHINE}"; then
		podman machine init --cpus "${cores}" --disk-size 25 -m $(( 12 * 1024 )) "${MACHINE}"
	fi
	if ! podman machine list | grep -q -- "^${MACHINE}.*Currently running"; then
		podman machine start "${MACHINE}"
		until [[ "$( podman machine list --noheading --format '{{.Name}} {{.LastUp}}' | grep "^${MACHINE}[* ]" )" =~ ^${MACHINE}\*?\ Currently\ running$ ]]; do
			printf '.'
			sleep 0.1
		done
		until podman machine ssh "${MACHINE}" 'true'; do
			printf '.'
			sleep 0.1
		done
		echo
	fi

	if ! [[ -s ~/.ssh/"${MACHINE}.pub" ]]; then
		ssh-keygen -t ed25519 -P '' -f ~/.ssh/"${MACHINE}"
	fi

	if [[ -s ~/.ssh/authorized_keys ]] && grep -Fq -- "$( < ~/.ssh/"${MACHINE}.pub" )" ~/.ssh/authorized_keys; then
		:
	else
		mkdir -p ~/.ssh
		chmod 0700 ~/.ssh
		cat ~/.ssh/"${MACHINE}.pub" >> ~/.ssh/authorized_keys
		chmod 0600 ~/.ssh/authorized_keys
	fi

	podman-remote system connection add "$( id -un )" --identity ~/.ssh/id_ed25519 "$( podman machine inspect | grep .sock | cut -d'"' -f 4 )"

	podman machine ssh "${MACHINE}" 'cat - > ~/.ssh/id_ed25519 && chmod 0600 ~/.ssh/id_ed25519' < ~/.ssh/"${MACHINE}"
	podman machine ssh "${MACHINE}" 'cat - > ~/.ssh/id_ed25519.pub && chmod 0600 ~/.ssh/id_ed25519.pub' < ~/.ssh/"${MACHINE}.pub"

	podman machine ssh "${MACHINE}" <<-EOF
		test -d src/podman-gentoo-build || {
			mkdir -p src &&
			cd src &&
			git clone "${REPO}" podman-gentoo-build ;
		} ;
		git config --system --replace-all safe.directory '*' ;
		cd ~/src/podman-gentoo-build && git pull --all
	EOF

	for f in 'local.sh' 'portage-cache.tar'; do
		if [[ -f "${f}" && -s "${f}" ]]; then
			case "${f}" in
				*.sh)
					dest="${REMOTE_HOME}/${REMOTE_USER}/src/podman-gentoo-build/common/" ;;
				*.tar)
					dest="${REMOTE_HOME}/${REMOTE_USER}/" ;;
			esac
			podman machine ssh "${MACHINE}" "mkdir -p '${dest}' && scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -v '$( id -nu )@host.containers.internal:$( pwd )/${f}' '${dest}'"
		fi
	done

	podman machine ssh "${MACHINE}" "sudo mkdir -p /var/cache ; test -s ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar && sudo tar -xpf ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar -C /var/cache/ || sudo mkdir -p /var/cache/portage ; sudo chown ${REMOTE_USER}:root /var/cache/portage && sudo chmod ug+rwX /var/cache/portage"

	if ! (( init || xfer )); then
		podman machine ssh "${MACHINE}"
	else
		if (( init )); then
			time podman machine ssh "${MACHINE}" "${REMOTE_HOME}/${REMOTE_USER}/src/podman-gentoo-build/${INIT}"
		fi
		if (( xfer )); then
			podman machine ssh "${MACHINE}" 'cd /var/cache && tar -cvpf - portage' > portage-cache.tar
		fi
	fi
fi

# vi: set syntax=bash:
