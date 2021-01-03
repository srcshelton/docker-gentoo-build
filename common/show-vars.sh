#! /bin/sh

image="${1:-}"

if [ -z "${image:-}" ]; then
	echo >&2 "Usage: $( basename "${0}" ) <image>"
	exit 1
elif echo " ${*:-} " | grep -Eq -- ' -(h|-help) '; then
	echo >&2 "Usage: $( basename "${0}" ) <image>"
	exit 0
fi

if [ $(( $( id -u ) )) -ne 0 ]; then
        echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
        exit 1
fi

if command -v podman >/dev/null 2>&1; then
	docker='podman'
fi

tab="$( printf '\t' )"

# The 'inspect' command works with containers (and container IDs) too...
if [ "$( "${docker}" image ls -n "${image}" | wc -l )" != '1' ]; then
	echo >&2 "WARN:  Cannot determine unique image '${image}'"
	#exit 1
fi

# See https://github.com/containers/podman/issues/8785
#"${docker}" inspect -f '{{ .Config.Env }}' "${image}" | tr "${tab}" ' ' | tr -s '[:space:]' | sed -r 's/^\[(.*)\]$/\1/' | sed -r 's/ ([A-Za-z][A-Za-z0-9_-]*)=/\n\1=/g'
buildah inspect --format '{{ .OCIv1.Config.Env }}' "${image}" | tr "${tab}" ' ' | tr -s '[:space:]' | sed -r 's/^\[(.*)\]$/\1/' | sed -r 's/ ([A-Za-z][A-Za-z0-9_-]*)=/\n\1=/g' ; echo
