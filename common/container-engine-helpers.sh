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

container_engine_configure_tmpdir() {
	cet_base=''
	cet_graphroot="${1:-}"
	cet_explicit="${PODMAN_TMPDIR:-}"
	cet_previous="${TMPDIR:-${TMP:-/tmp}}"
	cet_base="${cet_explicit:-${cet_graphroot}}"

	if [ -z "${cet_base}" ]; then
		printf >&2 'FATAL: Cannot determine container-engine temporary directory\n'
		unset cet_base cet_explicit cet_graphroot cet_previous
		return 1
	fi
	cet_tmp="${cet_base%/}/tmp"
	if mkdir -p "${cet_tmp}" 2>/dev/null && [ -w "${cet_tmp}" ]; then
		TMPDIR="${cet_tmp}"
		TMP="${cet_tmp}"
		export TMPDIR TMP
		unset cet_base cet_explicit cet_graphroot cet_previous cet_tmp
		return 0
	fi

	if [ -n "${cet_explicit}" ]; then
		printf >&2 "FATAL: PODMAN_TMPDIR temporary directory '%s' is not writable\n" \
			"${cet_tmp}"
		unset cet_base cet_explicit cet_graphroot cet_previous cet_tmp
		return 1
	fi

	printf >&2 "WARN:  Container-engine storage temporary directory '%s' is not writable; retaining '%s'\n" \
		"${cet_tmp}" "${cet_previous}"
	unset cet_base cet_explicit cet_graphroot cet_previous cet_tmp
	return 0
}

# vi: set colorcolumn=80 syntax=sh sw=4 ts=4:
