#!/bin/sh

# This file is sourced by 'entrypoint.sh.service' when selected by
# ${service_cmd_entrypoint} for net-misc/unifi-controller-bin containers.
#
# Keep the entrypoint alive after UniFi's Java process exits so that the
# embedded MongoDB process can complete a clean shutdown.

# 'entrypoint.sh.service' enables errexit, but this supervisor must inspect
# child exit statuses and complete cleanup after a non-zero Java exit.
#
set +e
set -u

java_pid=''
stop_requested=0

log() {
	printf 'unifi-lifecycle: %s\n' "${*}" >&2
}

is_mongod() {
	pid="${1:-}"
	comm=''

	case "${pid:-}" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ $(( pid )) -gt 1 ] 2>/dev/null || return 1
	[ -r "/proc/${pid}/comm" ] || return 1
	IFS= read -r comm < "/proc/${pid}/comm" || return 1
	[ "${comm}" = 'mongod' ]
}

find_mongod_pids() {
	pid=''
	comm_file=''

	if [ -r /var/run/unifi/mongod.pid ]; then
		IFS= read -r pid < /var/run/unifi/mongod.pid || pid=''
		if is_mongod "${pid:-}"; then
			printf '%s\n' "${pid}"
			return 0
		elif [ -n "${pid:-}" ]; then
			log "Ignoring stale or invalid MongoDB PID '${pid}'" \
				"from '/var/run/unifi/mongod.pid'"
		fi
	fi

	# UniFi may remove its PID file before MongoDB has actually exited.
	# The container has a private PID namespace, so an exact comm match is
	# a suitably narrow fallback.
	#
	for comm_file in /proc/[0-9]*/comm; do
		[ -r "${comm_file}" ] || continue
		IFS= read -r comm < "${comm_file}" || continue
		[ "${comm}" = 'mongod' ] || continue
		pid="${comm_file#"/proc/"}"
		printf '%s\n' "${pid%"/comm"}"
	done
}

# Invoked by trap.
# shellcheck disable=SC2329
request_stop() {
	stop_requested=1

	log 'Received a stop signal, requesting UniFi shutdown'
	if ! : > /var/run/unifi/server.stop; then
		log "Unable to create /var/run/unifi/server.stop: ${?}"
	fi

	# A normal OpenRC stop creates server.stop before signalling the
	# container.  Receiving TERM here therefore represents the fallback
	# path.
	if [ -n "${java_pid:-}" ] && kill -0 "${java_pid}" 2>/dev/null; then
		kill -TERM "${java_pid}" 2>/dev/null || :
	fi
}

stop_mongod() {
	mongod_pids="$( find_mongod_pids )"

	if [ -z "${mongod_pids}" ]; then
		log 'MongoDB is not running'
		return 0
	fi

	for mongod_pid in ${mongod_pids}; do
		is_mongod "${mongod_pid}" || continue
		log "Requesting clean MongoDB shutdown for PID '${mongod_pid}'"
		if ! kill -TERM "${mongod_pid}" 2>/dev/null &&
				is_mongod "${mongod_pid}"
		then
			log "Unable to signal MongoDB PID ${mongod_pid}," \
				"waiting for it to exit"
		fi

		waited=0
		while is_mongod "${mongod_pid}"; do
			sleep 1
			waited=$(( waited + 1 ))
			if [ $(( waited )) -ge 60 ]; then
				log "... still waiting for MongoDB PID" \
					"'${mongod_pid}' to exit"
				waited=0
			fi
		done
		log "MongoDB PID '${mongod_pid}' has stopped"
	done
}

trap request_stop TERM INT

/usr/bin/java "${@}" &
java_pid=${!}
log "Started UniFi Java process as PID '${java_pid}'"

# POSIX wait may be interrupted after a trapped signal. Repeat it while the
# Java process remains alive so that its real exit status is collected.
while :; do
	wait "${java_pid}"
	java_status=${?}
	kill -0 "${java_pid}" 2>/dev/null || break
done

log "UniFi Java process exited with status ${java_status}"
[ ! -e /var/run/unifi/server.stop ] || stop_requested=1
stop_mongod

trap - TERM INT

# An intentional container stop is successful once both processes are gone.
# Otherwise retain Java's status so '--restart=on-failure' still handles a real
# application failure.  Exit so the outer entrypoint cannot launch Java again.
if [ $(( stop_requested )) -eq 1 ]; then
	exit 0
fi

exit "${java_status}"

# vim: set cc=80 sw=8 ts=8:
