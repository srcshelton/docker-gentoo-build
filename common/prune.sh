#! /bin/sh

set -eu

trace=${TRACE:-}

[ -n "${trace:-}" ] && set -x

docker='docker'
if command -v podman >/dev/null 2>&1; then
	docker='podman'
fi

trap '' INT

# Remove images with generated temporary names...
$docker ps -a | tr -cd '[:print:]\n' | rev | cut -d' ' -f 1 | rev | grep '^[a-z]\+_[a-z]\+$' | xargs -r $docker rm --volumes

# Remove images classed as 'dangling'...
$docker image ls --filter 'dangling=true' | tail -n +2 | awk '{ print $3 }' | xargs -r $docker image rm || :

# Try to remove remaining untagged images...
$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r $docker image rm || :
$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r buildah rmi || :

# Forcing image removal leads to greater problems :(
#while $docker image ls | grep -q '^<none>\s\+<none>'; do
#	$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r $docker image rm -f || :
#done

# Podman's 'image prune' operation should now be internally recursive...
#while $docker image ls | grep -q -- '^<none>\s\+<none>'; do
	$docker image prune -f && while [ -n "$( $docker image prune -f | tee /dev/stderr )" ]; do
		echo
		sleep 0.1
	done && {
		# The first of these should be implicit in the previous operation, the
		# other - as above - can lead to corruption of the internal image
		# registry...
#		$docker image ls |
#			grep '^<none>\s\+<none>' |
#			awk '{ print $3 }' |
#			xargs -rn 1 --  $docker image rm ||
#		$docker image ls |
#			grep '^<none>\s\+<none>' |
#			awk '{ print $3 }' |
#			xargs -rn 1 -- $docker image rm -f
		$docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r buildah rmi || :
	}
#done

trap - INT

set +x
