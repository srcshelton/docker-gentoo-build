#! /bin/sh

# Optional probes for tools/apple-container.sh. No lifecycle or route changes.
# Options and CLI settings are supplied by that caller, not by this library.
# shellcheck disable=SC2154
# Keep each external command in its own process so the timeout kills the actual
# CLI, not a shell function waiting for it. Guest probes also have an alarm.
apple_diagnostic_run() (
	diagnostic_child=''
	trap 'if [ -n "${diagnostic_child}" ]; then
		kill -s KILL "${diagnostic_child}" 2>/dev/null || :
		wait "${diagnostic_child}" 2>/dev/null || :
	fi' 0
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	if [ -n "${VERBOSE:-}" ]; then
		printf >&2 'VERBOSE: Diagnostic command:'
		printf >&2 ' <%s>' "${@}"
		printf >&2 '\n'
	fi
	( exec "${@}" ) </dev/null &
	diagnostic_child=${!}
	diagnostic_elapsed=0
	while kill -0 "${diagnostic_child}" 2>/dev/null; do
		if [ "${diagnostic_elapsed}" -ge "${diagnostic_timeout}" ]; then
			printf >&2 'Probe timed out after %ss: %s\n' \
				"${diagnostic_timeout}" "${1}"
			exit 124
		fi
		sleep 1
		diagnostic_elapsed=$(( diagnostic_elapsed + 1 ))
	done
	diagnostic_status=0
	wait "${diagnostic_child}" || diagnostic_status=${?}
	diagnostic_child=''
	exit "${diagnostic_status}"
)

apple_diagnostic_container() {
	if [ "${container_debug_option}" -ne 0 ]; then
		apple_diagnostic_run "${container_binary}" --debug "${@}"
	else
		apple_diagnostic_run "${container_binary}" "${@}"
	fi
}

apple_diagnostic_check() {
	diagnostic_label="${1}"
	shift
	if "${@}"; then
		output "PASS: ${diagnostic_label}"
	else
		diagnostic_result=${?}
		if [ "${diagnostic_result}" -eq 77 ]; then
			output "SKIP: ${diagnostic_label} (check unavailable)"
			diagnostic_incomplete=1
		else
			output "FAIL: ${diagnostic_label} (status ${diagnostic_result})"
			diagnostic_failed=1
		fi
	fi
}

apple_diagnostic_ipv4() {
	printf '%s\n' "${1}" | awk -F . '
		NF != 4 { exit 1 }
		{ for (i = 1; i <= 4; i++)
			if ($i !~ /^[0-9]+$/ || length($i) > 3 || $i + 0 > 255 ||
				(length($i) > 1 && substr($i, 1, 1) == "0")) exit 1 }
	'
}

apple_diagnostic_port_valid() {
	case "${1}" in
		''|0*|*[!0-9]*) return 1 ;;
	esac
	[ "${#1}" -le 5 ] && [ "${1}" -le 65535 ]
}

apple_diagnostic_http() {
	# Read the complete response: a TCP handshake (or just HTTP headers) can
	# succeed at a forwarder while the application behind it remains stalled.
	# Ignore curlrc and proxies so this probes the supplied host endpoint directly.
	if ! diagnostic_http_status="$(
		apple_diagnostic_run curl -q -4 --silent --show-error --globoff \
			--proxy '' --noproxy '*' --proto '=http,https' \
			--connect-timeout "$(( diagnostic_timeout - 1 ))" \
			--max-time "$(( diagnostic_timeout - 1 ))" \
			--output /dev/null --write-out '%{http_code}' \
			--url "${diagnostic_published_url}"
	)"; then
		# Curl's error 77 is a CA-file problem, not our unavailable-tool sentinel.
		return 1
	fi
	output "Published endpoint returned HTTP ${diagnostic_http_status}"
	case "${diagnostic_http_status}" in
		2[0-9][0-9]) return 0 ;;
		*) return 1 ;;
	esac
}

apple_diagnostic_guest() {
	apple_diagnostic_container exec "${diagnostic_container}" \
		python3 -I -c '
import signal
import socket
import sys

# Use the kernel default action even if a resolver stalls in native code.
signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(int(sys.argv[1]))
try:
    if sys.argv[2] == "dns":
        addresses = socket.getaddrinfo(sys.argv[3], None, socket.AF_INET,
                                       socket.SOCK_STREAM)
        print("IPv4 answers: " + ", ".join(sorted({a[4][0] for a in addresses})))
    else:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
            connection.settimeout(int(sys.argv[1]))
            connection.connect((sys.argv[3], int(sys.argv[4])))
except (OSError, TimeoutError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
' "$(( diagnostic_timeout - 1 ))" "${@}"
}

apple_diagnostic_route() {
	if ! diagnostic_route="$(
		apple_diagnostic_run route -n get "${diagnostic_ip}"
	)"; then
		return 1
	fi
	printf '%s\n' "${diagnostic_route}"
	diagnostic_interface="$( printf '%s\n' "${diagnostic_route}" |
		awk '$1 == "interface:" { print $2; exit }' )"
	# Find the actual bridge from its gateway address; bridge100 is not fixed.
	diagnostic_expected="$( printf '%s\n' "${diagnostic_interfaces}" |
		awk -v gateway="${diagnostic_gateway}" '
			/^[^ \t]/ { interface=$1; sub(/:$/, "", interface) }
			$1 == "inet" && $2 == gateway { print interface; exit }
		' )"
	if [ -z "${diagnostic_expected}" ]; then
		output "No host interface owns gateway ${diagnostic_gateway}; route comparison unavailable"
		return 77
	fi
	if [ "${diagnostic_interface}" != "${diagnostic_expected}" ]; then
		warn "Route uses '${diagnostic_interface:-unknown}'; gateway belongs to '${diagnostic_expected}'"
		return 1
	fi
}

apple_container_diagnose() {
	case "${diagnostic_container}" in
		''|-*|*[!a-zA-Z0-9_.-]*) die 'Invalid diagnostic container name' ;;
	esac
	case "${diagnostic_timeout}" in
		''|0*|*[!0-9]*) die 'Probe timeout must be an integer from 2 to 300' ;;
	esac
	if [ "${#diagnostic_timeout}" -gt 3 ] ||
		[ "${diagnostic_timeout}" -lt 2 ] || [ "${diagnostic_timeout}" -gt 300 ]; then
		die 'Probe timeout must be an integer from 2 to 300'
	fi
	if [ -n "${diagnostic_port}" ] &&
		! apple_diagnostic_port_valid "${diagnostic_port}"; then
		die 'Service port must be an integer from 1 to 65535'
	fi
	apple_diagnostic_port_valid "${diagnostic_outbound_port}" ||
		die 'Outbound port must be an integer from 1 to 65535'
	apple_diagnostic_ipv4 "${diagnostic_address}" ||
		die 'Outbound address must be a numeric IPv4 address'
	case "${diagnostic_dns}" in
		''|-*|*[!a-zA-Z0-9_.-]*) die 'Invalid DNS probe name' ;;
	esac
	for diagnostic_tool in jq route ifconfig nc; do
		command -v "${diagnostic_tool}" >/dev/null 2>&1 ||
			die "Diagnostic requires host tool '${diagnostic_tool}'"
	done
	if [ -n "${diagnostic_published_url}" ]; then
		case "${diagnostic_published_url}" in
			http://?*|https://?*) : ;;
			*) die 'Published URL must start with http:// or https://' ;;
		esac
		case "${diagnostic_published_url}" in
			*[[:space:][:cntrl:]]*) die 'Published URL cannot contain whitespace or control characters' ;;
		esac
		command -v curl >/dev/null 2>&1 || die 'Published URL check requires host curl'
	fi

	diagnostic_version="$( apple_diagnostic_container --version )" ||
		die 'Unable to query Apple container version within the probe timeout'
	diagnostic_version="$( printf '%s\n' "${diagnostic_version}" |
		awk '$1 == "container" && $2 == "CLI" && $3 == "version" &&
			$4 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { print $4; exit }' )"
	[ -n "${diagnostic_version}" ] || die 'Unrecognised Apple container version'
	version_at_least "${diagnostic_version}" "${APPLE_CONTAINER_MIN_VERSION}" ||
		die "Apple container ${APPLE_CONTAINER_MIN_VERSION} or later is required"
	if ! version_at_least "${APPLE_CONTAINER_LAST_VALIDATED_VERSION}" "${diagnostic_version}"; then
		warn "Apple container ${diagnostic_version} is newer than validated release ${APPLE_CONTAINER_LAST_VALIDATED_VERSION}"
	fi
	output "Diagnosing '${diagnostic_container}' with Apple container ${diagnostic_version} (IPv4)"
	output "DNS target: ${diagnostic_dns}; outbound TCP target: ${diagnostic_address}:${diagnostic_outbound_port}"
	output 'TCP checks establish connections only; they do not verify application responses.'

	diagnostic_metadata="$( apple_diagnostic_container inspect "${diagnostic_container}" )" ||
		die 'Unable to inspect target container; no services were started'
	# 1.4.1 serializes ManagedContainer with status.state/status.networks.
	if ! printf '%s\n' "${diagnostic_metadata}" | jq -e \
		'length == 1 and .[0].status.state == "running"' >/dev/null; then
		die 'Target container must already be running'
	fi
	diagnostic_failed=0
	diagnostic_incomplete=0
	diagnostic_interfaces=''
	if ! diagnostic_interfaces="$( apple_diagnostic_run ifconfig -a )"; then
		output 'FAIL: Unable to inspect host interfaces'
		diagnostic_failed=1
	fi
	diagnostic_count="$( printf '%s\n' "${diagnostic_metadata}" |
		jq -er '.[0].status.networks | length' )" || die 'Invalid network metadata'
	diagnostic_index=0
	if [ "${diagnostic_count}" -eq 0 ]; then
		output 'SKIP: No IPv4 network attachments to probe'
		diagnostic_incomplete=1
	fi
	while [ "${diagnostic_index}" -lt "${diagnostic_count}" ]; do
		diagnostic_attachment="$( printf '%s\n' "${diagnostic_metadata}" |
			jq -c --argjson index "${diagnostic_index}" '.[0].status.networks[$index]' )"
		diagnostic_ip="$( printf '%s\n' "${diagnostic_attachment}" |
			jq -er '.ipv4Address | split("/")[0]' )" || die 'Missing container IPv4 address'
		diagnostic_gateway="$( printf '%s\n' "${diagnostic_attachment}" |
			jq -er '.ipv4Gateway' )" || die 'Missing container IPv4 gateway'
		apple_diagnostic_ipv4 "${diagnostic_ip}" &&
			apple_diagnostic_ipv4 "${diagnostic_gateway}" || die 'Invalid network IPv4 address'
		apple_diagnostic_check "Host route to ${diagnostic_ip} (lookup/interface comparison)" \
			apple_diagnostic_route
		if [ -n "${diagnostic_port}" ]; then
			apple_diagnostic_check "Host to container TCP ${diagnostic_ip}:${diagnostic_port}" \
				apple_diagnostic_run nc -4 -n -z -G "${diagnostic_timeout}" \
				-w "${diagnostic_timeout}" "${diagnostic_ip}" "${diagnostic_port}"
		fi
		diagnostic_index=$(( diagnostic_index + 1 ))
	done
	if [ -z "${diagnostic_port}" ]; then
		output 'SKIP: Host-to-container and guest-loopback TCP (supply --port)'
		diagnostic_incomplete=1
	fi
	apple_diagnostic_check 'Host outbound TCP (comparison for guest probe)' \
		apple_diagnostic_run nc -4 -n -z -G "${diagnostic_timeout}" \
			-w "${diagnostic_timeout}" "${diagnostic_address}" "${diagnostic_outbound_port}"
	if [ -n "${diagnostic_published_url}" ]; then
		apple_diagnostic_check "Host published HTTP(S) endpoint ${diagnostic_published_url}" \
			apple_diagnostic_http
	else
		output 'Published-port forwarding not tested (supply --published-url for an HTTP(S) service).'
	fi

	# Check exec independently: a hung exec is not proof of a network failure.
	if apple_diagnostic_container exec "${diagnostic_container}" /bin/sh -c ':'; then
		output 'PASS: Guest exec transport and /bin/sh'
		if apple_diagnostic_container exec "${diagnostic_container}" /bin/sh -c \
			'command -v python3 >/dev/null || exit 77'; then
			if [ -n "${diagnostic_port}" ]; then
				apple_diagnostic_check "Guest loopback TCP 127.0.0.1:${diagnostic_port}" \
					apple_diagnostic_guest tcp 127.0.0.1 "${diagnostic_port}"
			fi
			apple_diagnostic_check "Guest name resolution (DNS/NSS) ${diagnostic_dns}" \
				apple_diagnostic_guest dns "${diagnostic_dns}"
			apple_diagnostic_check 'Guest outbound TCP (numeric address; independent of DNS)' \
				apple_diagnostic_guest tcp "${diagnostic_address}" "${diagnostic_outbound_port}"
		else
			diagnostic_runtime_status=${?}
			if [ "${diagnostic_runtime_status}" -eq 77 ]; then
				output 'SKIP: Guest network probes require Python 3; nothing was installed'
				diagnostic_incomplete=1
			else
				output "FAIL: Guest runtime check (status ${diagnostic_runtime_status}); network probes unavailable"
				diagnostic_failed=1
			fi
		fi
	else
		output 'FAIL: Guest exec or /bin/sh unavailable; guest network state is undetermined'
		diagnostic_failed=1
	fi
	output 'These checks do not validate IPv6 or builder networking.'
	output 'A failure does not identify its cause; compare routing, exec, DNS and TCP results.'
	if [ "${diagnostic_failed}" -ne 0 ]; then
		return 1
	fi
	if [ "${diagnostic_incomplete}" -ne 0 ]; then
		return 2
	fi
	return 0
}

# vi: set cc=80 sw=4 ts=4:
