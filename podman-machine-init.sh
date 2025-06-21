#! /usr/bin/env bash

set -eu  # x

#declare -i debug=${DEBUG:-}
declare -i trace=${TRACE:-}

declare -r REPO='https://github.com/srcshelton/docker-gentoo-build.git'
declare -r INIT='gentoo-init.docker'

# Provide a wrapper to try to run mkdir/rm/etc. as the current user, and then
# via the 'sudo' binary if this fails.  Note that this is intended for atomic
# operations without side-effects, rather than as a universal 'sudo'
# replacement...
#
sudo() {
	"${@:-}" ||
		"$( type -pf sudo )" "${@:-}"
}
export -f sudo

(( trace )) && set -o xtrace

export LANG=C
export LC_ALL=C

declare MACHINE='podman-machine-default'
declare MACHINE_SOCKET='/var/run/podman/podman.sock'
declare MACHINE_KEY="${HOME}/.ssh/id_rsa"
declare MACHINE_KEY_TYPE='ed25519'
declare REMOTE_HOME='/var/home'
declare REMOTE_USER='core'
declare LOCAL_SSH_KEY='id_ed25519'
declare ARCH=''

declare -i reserved_memory=12
declare -i reserved_disk=25

declare -i init=0 xfer=0 cores=4 local_install=0
declare -i run_on_vm=-1 need_explicit_mount=0
declare -i create_vm=0

if [[ "$( uname -s )" == 'Darwin' ]]; then
	if ! type -pf jq; then
		echo >&2 "FATAL: 'jq' binary is required on Darwin"
		exit 1
	fi

	# Darwin/BSD lacks GNU readlink - either realpath or perl's Cwd module
	# will do at a pinch, although both lack the additional options of GNU
	# binaries...
	#
	readlink() {
		if type -pf realpath >/dev/null 2>&1; then
			realpath "${2}"
		else
			# The perl statement below returns $PWD if the supplied
			# path doesn't exist :(
			[[ -e "${2}" ]] || return 1
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
				)" )" ||
				! [[ -d "${REMOTE_HOME}/${REMOTE_USER}" ]]
			then
				echo >&2 "FATAL: Unable to determine home" \
					"directory for user" \
					"'${REMOTE_USER:-}': ${?}"
				exit 1
			else
				echo >&2 "INFO:  Using home '${REMOTE_HOME}'" \
					"for user '${REMOTE_USER}' ..."
			fi
			;;
	esac
fi

if type -pf portageq >/dev/null 2>&1; then
	ARCH="$( portageq envvar ARCH )"
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
	total=$(( $( # <- Syntax
			sysctl -n machdep.cpu.core_count ||
				sysctl -n machdep.cpu.core_total
		) ))

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
	cores="$( nproc ||
			grep -- 'cpu cores' /proc/cpuinfo |
				tail -n 1 |
				awk -F': ' '{print $2}'
		)"
fi

cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

declare arg=''
for arg in "${@:-}"; do
	case "${arg:-}" in
		-h|--help)
			#                                3         4         5         6         7         8
			#     1234567                    012345678901234567890123456789012345678901234567890
			echo "Usage: $( basename "${0}" ) [--machine=<name>] [--cores=<${cores}>]"
			#              1         2         3         4         5         6         7         8
			#     12345678901234567890123456789012345678901234567890123456789012345678901234567890
			echo "                              [--memory=<${reserved_memory}>]"
			echo "                              [--disk=<${reserved_disk}>]"
			echo "                              [--force-run-on-vm]"
			echo "                              [--init] [--transfer-cache]"
			exit 0
			;;
		-c|--cores)
			cores="${arg#*"-"}"
			;;
		--host)
			if ! [[ "${*:-}" == '--host' ]]; then
				echo >&2 "FATAL: '--host' cannot be used" \
					"with any other options"
				exit 1
			fi
			local_install=1
			;;
		-i|--init)
			init=1
			;;
		-M=*|--machine=*)
			MACHINE="${arg#*"="}"
			;;
		-m=*|--memory=*)
			reserved_memory="${arg#*=}"
			;;
		-d=*|--disk=*)
			reserved_disk="${arg#*=}"
			;;
		-f|--force-run-on-vm)
			run_on_vm=0
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
		sudo tar -xp \
			-f "${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar" \
			-C /var/cache/

	sudo mkdir -p /var/cache/portage &&
		sudo chown "${REMOTE_USER}:root" /var/cache/portage &&
		sudo chmod ug+rwX /var/cache/portage

	sudo mkdir -p "/var/cache/portage/pkg/${ARCH:-"${arch}"}/${PKGHOST:-"container"}" &&
		sudo chown "${REMOTE_USER}:root" \
			"/var/cache/portage/pkg/${ARCH:-"${arch}"}/${PKGHOST:-"container"}" &&
		sudo chmod ug+rwX \
			"/var/cache/portage/pkg/${ARCH:-"${arch}"}/${PKGHOST:-"container"}"

	if ! [[ -x sync-portage.sh ]]; then
		echo >&2 "WARN:  Cannot locate 'sync-portage.sh' - please" \
			"run this script manually in order to populate" \
			"'/etc/portage'"
	else
		sudo ./sync-portage.sh &&
			sudo mkdir -p /etc/portage &&
			sudo cp gentoo-base/etc/portage/make.conf /etc/portage/

		echo >&2 "INFO:  Please review the settings in" \
			"'/etc/portage/make.conf'"
	fi
else
	# From podman-4.0.3, if $HOME is mounted to the 'podman machine'
	# virtual machine then volumes can be mounted from the host to the
	# container :)
	#
	# TODO: Does this only work for volumes beneath $HOME, or does having
	#       $HOME mounted enable remote-mounts from any part of the
	#       filesystem?
	#
	declare version=''
	version="$( podman --version |
			grep -o 'version.*$' |
			cut -d' ' -f 2-
		)"
	if (( run_on_vm == -1 )); then
		if [[ '4.0.3' == "$( # <- Syntax
					xargs -n 1 printf '4.0.3\n%s\n' \
							<<<"${version}" |
						sort -V |
						head -n 1
				)" ]]
		then
			# podman version is prior to 4.0.3
			run_on_vm=1
		else
			# podman version is 4.0.3 or greater
			run_on_vm=0
		fi
	fi

	if (( run_on_vm == 1 )); then
		if [[ '4.1.0' == "$( # <- Syntax
					xargs -n 1 printf '4.1.0\n%s\n' \
							<<<"${version}" |
						sort -V |
						head -n 1
				)" ]]
		then
			# podman version is prior to 4.1.0
			need_explicit_mount=1
		fi
	fi

	for LOCAL_SSH_KEY in id_ed25519 id_ecdsa id_rsa; do
		if [[ -f ~/.ssh/${LOCAL_SSH_KEY} ]] &&
				[[ -s ~/.ssh/${LOCAL_SSH_KEY} ]]
		then
			break
		fi
	done
	if ! [[ -f ~/.ssh/${LOCAL_SSH_KEY} && -s ~/.ssh/${LOCAL_SSH_KEY} ]]
	then
		echo >&2 "FATAL: No ssh private key in '${HOME}/.ssh' found"
		exit 1
	fi

	if ! podman machine list | grep -q -- "^${MACHINE}"; then
		if ! (( create_vm )); then
			echo >&2 "FATAL: No 'podman machine' named" \
				"'${MACHINE}' defined - please create this" \
				"first"
			exit 1
		else
			#podman machine init --cpus "${cores}" --disk-size 25 \
			#	-m $(( 12 * 1024 )) "${MACHINE}"
			declare -a volume=()
			if (( need_explicit_mount )); then
				volume=( --volume "${HOME}:${HOME}" )
			fi
			podman machine init \
					--cpus ${cores} \
					--disk-size ${reserved_disk} \
					--memory $((reserved_memory * 1024)) \
					"${volume[@]:-}" \
				"${MACHINE}"
			unset volume
		fi
	fi
	if ! podman machine list |
			grep -q -- "^${MACHINE}.*Currently running"
	then
		if ! (( create_vm )); then
			echo >&2 "FATAL: No 'podman machine' named" \
				"'${MACHINE}' running - please start this" \
				"first"
			exit 1
		else
			podman machine start "${MACHINE}"
		fi
	fi

	# Check that our `podman machine` is actually usable...
	echo -n "Waiting for running 'podman machine' named '${MACHINE}' ..."
	until [[ "$( # <- Syntax
				podman machine list --noheading \
						--format '{{.Name}} {{.LastUp}}' |
					grep -- "^${MACHINE}[* ]"
			)" =~ ^${MACHINE}\*?\ Currently\ running$ ]]
	do
		printf '.'
		sleep 0.1
	done
	echo
	echo -n "Waiting for accessible 'podman machine' named '${MACHINE}' ..."
	until podman machine ssh "${MACHINE}" 'true'; do
		printf '.'
		sleep 0.1
	done
	echo ; echo

	MACHINE_SOCKET="$( # <- Syntax
			podman machine inspect |
				jq -Mr '.[].ConnectionInfo.PodmanSocket.Path'
		)"
	MACHINE_KEY="$( # <- Syntax
			podman machine inspect |
				jq -Mr '.[].SSHConfig.IdentityPath'
		)"

	if ! (( run_on_vm )); then
		if [[ -s ~/.ssh/authorized_keys ]] &&
				grep -Fq -- "$( < "${MACHINE_KEY}.pub" )" \
					~/.ssh/authorized_keys
		then
			:
		else
			mkdir -p ~/.ssh
			chmod 0700 ~/.ssh
			cat "${MACHINE_KEY}.pub" >> ~/.ssh/authorized_keys
			chmod 0600 ~/.ssh/authorized_keys
		fi

		if ! podman-remote system connection \
				add "$( id -un )" \
				--identity ~/.ssh/${LOCAL_SSH_KEY} \
				"${MACHINE_SOCKET}"
		then
			echo >&2 "FATAL: Could not update system connection" \
				"($?): is there a podman machine running?"
			exit 1
		fi

		podman machine ssh "${MACHINE}" <<-EOF
			cat - > ~/.ssh/id_${MACHINE_KEY_TYPE} &&
				chmod 0600 ~/.ssh/id_${MACHINE_KEY_TYPE}" \
					< "${MACHINE_KEY}"
		EOF
		podman machine ssh "${MACHINE}" <<-EOF
			cat - > ~/.ssh/id_${MACHINE_KEY_TYPE}.pub &&
				chmod 0600 ~/.ssh/id_${MACHINE_KEY_TYPE}.pub" \
					< "${MACHINE_KEY}.pub"
		EOF

		podman machine ssh "${MACHINE}" <<-EOF
			if ! test -d src/podman-gentoo-build; then
				mkdir -p src &&
					cd src &&
					git clone "${REPO}" podman-gentoo-build ;
			fi ;
			git config --system --replace-all safe.directory '*' ;
			cd ~/src/podman-gentoo-build &&
				git pull --all
		EOF

		for f in 'make.conf' 'local.sh' 'portage-cache.tar'; do
			if [[ -f "${f}" && -s "${f}" ]]; then
				case "${f}" in
					*.conf)
						dest="/etc/portage/" ;;
					*.sh)
						dest="${REMOTE_HOME}/${REMOTE_USER}/src/podman-gentoo-build/common/" ;;
					*.tar)
						dest="${REMOTE_HOME}/${REMOTE_USER}/" ;;
				esac
				podman machine ssh "${MACHINE}" <<-EOF
					sudo mkdir -p '${dest}' &&
						sudo scp -i ~/.ssh/${LOCAL_SSH_KEY} \
							-o StrictHostKeyChecking=no \
							'$( id -nu )@host.containers.internal:$( pwd )/${f}' '${dest}'"
				EOF
			fi
		done

		podman machine ssh "${MACHINE}" <<-EOF
			sudo mkdir -p /var/cache ;
			test -s ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar &&
				sudo tar -xp \
					-f ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar \
					-C /var/cache/ ||
				sudo mkdir -p /var/cache/portage ;
			sudo chown ${REMOTE_USER}:root /var/cache/portage &&
				sudo chmod ug+rwX /var/cache/portage
		EOF

		# Allow the host user to see/use 'core'-owned images from the
		# 'podman machine' VM...
		podman machine ssh "${MACHINE}" <<-EOF
			if ! grep -x '"/var/home/core/.local/share/containers/storage"' \
					/usr/share/containers/storage.conf
			then
				sudo mount /usr -o remount,rw,noatime &&
					sed -i /usr/share/containers/storage.conf \
						-e '0,/"/usr/lib/containers/storage",/a "/var/home/core/.local/share/containers/storage"'
			fi
		EOF

		if ! (( init || xfer )); then
			podman machine ssh "${MACHINE}"
		else
			if (( init )); then
				time podman machine ssh "${MACHINE}" <<-EOF
					${REMOTE_HOME}/${REMOTE_USER}/src/podman-gentoo-build/${INIT}
				EOF
			fi
			if (( xfer )); then
				podman machine ssh "${MACHINE}" <<-EOF
					cd /var/cache &&
						tar -cvpf - portage' > portage-cache.tar
				EOF
			fi
		fi
	fi
fi

# vi: set syntax=bash sw=8 ts=8:
