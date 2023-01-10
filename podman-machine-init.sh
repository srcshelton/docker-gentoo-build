#! /usr/bin/env bash

set -eu  # x

export LANG=C
export LC_ALL=C

declare MACHINE='podman'
declare -i init=0 xfer=0 cores=4

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
	cores="$( grep 'cpu cores' /proc/cpuinfo | tail -n 1 | awk -F': ' '{ print $2 }' )"
fi
cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

declare arg=''
for arg in "${@:-}"; do
	case "${arg:-}" in
		-h|--help)
			echo "Usage: $( basename "${0}" ) [--machine=<name>] [--cores=<${cores}>] [--init] [--transfer-cache]"
			exit 0
			;;
		-c|--cores)
			cores="${arg#*-}"
			;;
		-i|--init)
			init=1
			;;
		-m=*|--machine=*)
			MACHINE="${arg#*=}"
			;;
		-t|--xfer|--transfer|--transfer-cache)
			xfer=1
			;;
	esac
done
unset arg

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

podman machine ssh "${MACHINE}" <<EOF
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
				dest="/var/home/core/src/docker-gentoo-build/common/" ;;
			*.tar)
				dest="/var/home/core/" ;;
		esac
		podman machine ssh "${MACHINE}" "scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -v '$( id -nu )@$( hostname -s ).seventytwo.miltonroad.net:$( pwd )/${f}' '${dest}'"
	fi
done

podman machine ssh "${MACHINE}" 'sudo mkdir -p /var/cache ; test -s /var/home/core/portage-cache.tar && sudo tar -xpf /var/home/core/portage-cache.tar -C /var/cache/ || sudo mkdir -p /var/cache/portage ; sudo chown core:root /var/cache/portage && sudo chmod ug+rwX /var/cache/portage'

if ! (( init || xfer )); then
	podman machine ssh "${MACHINE}"
else
	if (( init )); then
		time podman machine ssh "${MACHINE}" '/var/home/core/src/docker-gentoo-build/gentoo-init.docker'
	fi
	if (( xfer )); then
		podman machine ssh "${MACHINE}" 'cd /var/cache && tar -cvpf - portage' > portage-cache.tar
	fi
fi

# vi: set syntax=bash:
