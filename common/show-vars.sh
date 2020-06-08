#! /bin/sh

image="${1:-}"

if [ -z "${image:-}" ]; then
	echo >&2 "Usage: $( basename "${0}" ) <image>"
	exit 1
elif echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo >&2 "Usage: $( basename "${0}" ) <image>"
	exit 0
fi

if type -pf podman >/dev/null 2>&1; then
	docker='podman'
fi

# The 'inspect' command works with containers (and container IDs) too...
if [ "$( "${docker}" image ls "${image}" | wc -l )" != '2' ]; then
	echo >&2 "WARN:  Cannot determine unique image '${image}'"
	#exit 1
fi

"${docker}" inspect -f '{{ .Config.Env }}' "${image}" | tr $'\t' ' ' | tr -s '[:space:]' | sed -r 's/^\[(.*)\]$/\1/' | sed -r 's/ ([A-Za-z][A-Za-z0-9_-]*)=/\n\1=/g'
