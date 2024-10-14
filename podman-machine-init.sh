#! /usr/bin/env bash

set -eu  # x

declare -i debug=${DEBUG:-}
declare -i trace=${TRACE:-}

(( trace )) && set -o xtrace

export LANG=C
export LC_ALL=C

declare MACHINE='podman'
declare REMOTE_HOME='/var/home'
declare REMOTE_USER='core'
# FIXME: Improve this logic to find a generic REMOTE_USER
case "$( id -un )" in
	'mixtile')
		REMOTE_USER='mixtile'
		;;
	*)	echo >&2 "WARN:  Unknown user '$( id -un )', using current" \
			"home '$( eval "readlink -e ~$( id -un )" )' ..."
		REMOTE_USER="$( id -un )"
		;;
esac
declare -i init=0 xfer=0 cores=4 local_install=0

if [[ "$( uname -s )" == 'Darwin' ]]; then
	readlink() {
		perl -MCwd -le 'print Cwd::abs_path shift' "${2}"
	}

	case "$( sysctl -n machdep.cpu.brand_string )" in
		'Apple M1 Ultra')
			cores="$(( $( sysctl -n machdep.cpu.core_count ) - 4 ))" ;;
		'Apple M1 Pro'|'Apple M1 Max')
			cores="$(( $( sysctl -n machdep.cpu.core_count ) - 2 ))" ;;
		'Apple M1')
			cores="$(( $( sysctl -n machdep.cpu.core_count ) / 2 ))" ;;
		'Intel'*)
			cores="$( sysctl -n machdep.cpu.core_count )" ;;
	esac
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
		test -s ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar &&
		sudo tar -xpf ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar -C /var/cache/

	sudo mkdir -p /var/cache/portage &&
		sudo chown ${REMOTE_USER}:root /var/cache/portage &&
		sudo chmod ug+rwX /var/cache/portage

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

	if [[ -s ~/.ssh/authorized_keys ]] && grep -Fq -- "$( < ~/.ssh/"${MACHINE}.pub" )" ~/.ssh/authorized_keys; then
		:
	else
		mkdir -p ~/.ssh
		chmod 0700 ~/.ssh
		cat ~/.ssh/"${MACHINE}.pub" >> ~/.ssh/authorized_keys
		chmod 0600 ~/.ssh/authorized_keys
	fi

	podman machine ssh "${MACHINE}" 'cat - > ~/.ssh/id_ed25519 && chmod 0600 ~/.ssh/id_ed25519' < ~/.ssh/"${MACHINE}"
	podman machine ssh "${MACHINE}" 'cat - > ~/.ssh/id_ed25519.pub && chmod 0600 ~/.ssh/id_ed25519.pub' < ~/.ssh/"${MACHINE}.pub"

	podman machine ssh "${MACHINE}" <<-EOF
		test -d src/docker-gentoo-build || {
			mkdir -p src &&
			cd src &&
			git clone https://github.com/srcshelton/docker-gentoo-build.git ;
		} ;
		git config --system --replace-all safe.directory '*' ;
		cd ~/src/docker-gentoo-build && git pull --all
	EOF

	for f in 'local.sh' 'portage-cache.tar'; do
		if [[ -f "${f}" && -s "${f}" ]]; then
			case "${f}" in
				*.sh)
					dest="${REMOTE_HOME}/${REMOTE_USER}/src/docker-gentoo-build/common/" ;;
				*.tar)
					dest="${REMOTE_HOME}/${REMOTE_USER}/" ;;
			esac
			podman machine ssh "${MACHINE}" "scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -v '$( id -nu )@$( hostname -s ).seventytwo.miltonroad.net:$( pwd )/${f}' '${dest}'"
		fi
	done

	podman machine ssh "${MACHINE}" "sudo mkdir -p /var/cache ; test -s ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar && sudo tar -xpf ${REMOTE_HOME}/${REMOTE_USER}/portage-cache.tar -C /var/cache/ || sudo mkdir -p /var/cache/portage ; sudo chown ${REMOTE_USER}:root /var/cache/portage && sudo chmod ug+rwX /var/cache/portage"

	if ! (( init || xfer )); then
		podman machine ssh "${MACHINE}"
	else
		if (( init )); then
			time podman machine ssh "${MACHINE}" "${REMOTE_HOME}/${REMOTE_USER}/src/docker-gentoo-build/gentoo-init.docker"
		fi
		if (( xfer )); then
			podman machine ssh "${MACHINE}" 'cd /var/cache && tar -cvpf - portage' > portage-cache.tar
		fi
	fi
fi

# vi: set syntax=bash:
