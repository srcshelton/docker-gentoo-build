#! /bin/sh

set -eu

trace=${TRACE:-}

[ -n "${trace:-}" ] && set -x

_command='docker'
if command -v podman >/dev/null 2>&1; then
	_command='podman'
fi

trap '' INT

# Remove images with generated temporary names...
#
$_command container ps -a |
	tr -cd '[:print:]\n' |
	rev |
	cut -d' ' -f 1 |
	rev |
	grep '^[a-z]\+_[a-z]\+$' |
	xargs -r $_command container rm --volumes

# Remove images classed as 'dangling'...
#
$_command image ls --filter 'dangling=true' |
	tail -n +2 |
	awk '{ print $3 }' |
	xargs -r $_command image rm || :

# Try to remove remaining untagged images...
#
$_command image ls |
	grep '^<none>\s\+<none>' |
	awk '{ print $3 }' |
	xargs -r $_command image rm || :
$_command image ls |
	grep '^<none>\s\+<none>' |
	awk '{ print $3 }' |
	xargs -r buildah rmi || :

# Forcing image removal leads to greater problems :(
#
#while $_command image ls | grep -q '^<none>\s\+<none>'; do
#	$_command image ls |
#		grep '^<none>\s\+<none>' |
#		awk '{ print $3 }' |
#		xargs -r $_command image rm -f || :
#done

# Podman's 'image prune' operation should now be internally recursive...
#
#while $_command image ls | grep -q -- '^<none>\s\+<none>'; do
	$_command image prune -f && while [ -n "$( $_command image prune -f | tee /dev/stderr )" ]; do
		echo
		sleep 0.1
	done && {
		# The first of these should be implicit in the previous operation, the
		# other - as above - can lead to corruption of the internal image
		# registry...
#		$_command image ls |
#			grep '^<none>\s\+<none>' |
#			awk '{ print $3 }' |
#			xargs -rn 1 --  $_command image rm ||
#		$_command image ls |
#			grep '^<none>\s\+<none>' |
#			awk '{ print $3 }' |
#			xargs -rn 1 -- $_command image rm -f
		$_command image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r buildah rmi || :
	}
#done

trap - INT

set +x
