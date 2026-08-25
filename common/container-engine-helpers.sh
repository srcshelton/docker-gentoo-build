#! /bin/sh

# Preserve the script's diagnostic stream so VERBOSE output remains visible
# when an individual probe deliberately suppresses the engine's stderr.
if [ -n "${VERBOSE:-}" ]; then
	exec 3>&2
fi

container_engine_run() {
	[ $(( ${#} )) -gt 0 ] || return 2

	if [ -n "${VERBOSE:-}" ]; then
		printf >&3 'VERBOSE: Container engine command:'
		for _container_engine_arg in "${@}"; do
			printf >&3 " '"
			printf '%s' "${_container_engine_arg}" |
				sed >&3 "s/'/'\"'\"'/g"
			printf >&3 "'"
		done
		printf >&3 '\n'
		unset _container_engine_arg
		command "${@}" 3>&-
	else
		command "${@}"
	fi
}

container_engine_help() {
	cat <<'EOF'

Environment:
  CONTAINER_ENGINE  Select 'auto', 'container', 'podman', 'docker',
                    or an exact executable path (default: 'auto')
  VERBOSE           Show engine selection and every container-engine command
  TRACE             Enable shell execution tracing when non-empty
EOF
}

# vi: set colorcolumn=80 syntax=sh sw=4 ts=4:
