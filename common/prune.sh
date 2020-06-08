#! /bin/sh

set -eu

trace=${TRACE:-}

[ -n "${trace:-}" ] && set -x

docker='docker'
if type -pf podman >/dev/null 2>&1; then
	docker='podman'
fi

$docker ps -a | tr -cd '[[:print:]\n]' | rev | cut -d' ' -f 1 | rev | grep '^[a-z]_[a-z]$' | xargs -r $docker rm

$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r $docker image rm || :
#while $docker image ls | grep -q '^<none>\s\+<none>'; do
#	$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r $docker image rm -f || :
#done

$docker image ls --filter 'dangling=true' | tail -n +2 | awk '{ print $3 }' | xargs -r $docker image rm

set +x
