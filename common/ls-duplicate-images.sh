#! /bin/sh

output="$(
	podman image ls									|
		cut -d' ' -f 1								|
		grep -v '<none>'							|
		sort									|
		uniq -c									|
		awk '( $1 > 1 ) { print $2 }'						|
		while read -r name; do
			podman image ls "${name}"
		done									|
		tr -s '[:space:]'							|
		sed -r 's/IMAGE ID/IMAGE_ID/ ; s/ ([0-9]+) ([^ ]+) ago / \1_\2_ago /'	|
		sort -rV								|
		uniq									|
		column -t								|
		sed -r 's/IMAGE_ID/IMAGE ID/ ; s/([0-9]+)_([^_]+)_ago/\1 \2 ago/'
)"

echo "${output}" | tail -n 1

echo "${output}" | head -n -1
