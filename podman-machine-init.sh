#! /usr/bin/env bash

set -eux

declare -r MACHINE='podman'

if [[ "$( uname -s )" == 'Darwin' ]]; then
        readlink() {
                perl -MCwd -le 'print Cwd::abs_path shift' "${2}"
        }
fi
cd "$( dirname "$( readlink -e "${0}" )" )" || exit 1

if ! podman machine list | grep -q -- "^${MACHINE}"; then
	podman machine init --cpus 4 --disk-size 25 -m $(( 12 * 1024 )) "${MACHINE}"
fi
if ! podman machine list | grep -q -- "^${MACHINE}.*Currently running"; then
	podman machine start "${MACHINE}"
fi

if [[ -s ~/.ssh/authorized_keys ]] && grep -Fq -- "$( < ~/.ssh/podman.pub )" ~/.ssh/authorized_keys; then
	:
else
	mkdir -p ~/.ssh
	chmod 0700 ~/.ssh
	cat ~/.ssh/podman.pub >> ~/.ssh/authorized_keys
	chmod 0600 ~/.ssh/authorized_keys
fi

cat ~/.ssh/podman | podman machine ssh podman 'cat - > ~/.ssh/id_ed25519 && chmod 0600 ~/.ssh/id_ed25519'
cat ~/.ssh/podman.pub | podman machine ssh podman 'cat - > ~/.ssh/id_ed25519.pub && chmod 0600 ~/.ssh/id_ed25519.pub'

podman machine ssh podman <<EOF
	test -d src/docker-gentoo-build || {
		mkdir src &&
		cd src &&
		git clone https://github.com/srcshelton/docker-gentoo-build.git ;
	} ;
	cd ~/src/docker-gentoo-build && git pull --all
EOF

for f in 'local.sh' 'portage-cache.tar'; do
	if [[ -s "${f}" ]]; then
		case "${f}" in
			*.sh)
				dest="~core/src/docker-gentoo-build/common/" ;;
			*.tar)
				dest="~core/" ;;
		esac
		podman machine ssh podman scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -v "$( id -nu )@$( hostname -s ).seventytwo.miltonroad.net:$( pwd )/${f}" "${dest}"
	fi
done

podman machine ssh podman 'test -s ~core/portage-cache.tar && sudo mkdir -p /var/cache && sudo tar -xpf ~core/portage-cache.tar -C /var/cache/ && sudo chown core:root /var/cache/portage && sudo chmod ug+rwX /var/cache/portage'

podman machine ssh podman

# vi: set syntax=bash:
