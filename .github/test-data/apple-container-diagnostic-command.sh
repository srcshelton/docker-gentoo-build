#! /bin/sh

set -eu

case "${0##*/}" in
	container)
		if [ "${1}" = '--debug' ]; then shift; fi
		case "${1}" in
			--version)
				printf 'container CLI version %s (build: fixture)\n' "${TEST_VERSION:-1.4.1}"
				;;
			inspect)
				if [ "${TEST_CASE}" = 'inspect-hang' ]; then
					printf >&2 'FIXTURE_PID=%s\n' "${$}"
					exec /bin/sleep 60
				fi
				jq -n --arg state "${TEST_STATE:-running}" '
					[{id:"fixture",status:{state:$state,networks:[
						{ipv4Address:"192.168.77.3/24",ipv4Gateway:"192.168.77.1"}
					]}}]'
				;;
			exec)
				shift 2
				if [ "${1}" = '/bin/sh' ]; then
					if [ "${3}" = ':' ]; then
						if [ "${TEST_CASE}" = 'exec-hang' ]; then
							printf >&2 'FIXTURE_PID=%s\n' "${$}"
							exec /bin/sleep 60
						fi
					elif [ "${TEST_CASE}" = 'missing-python' ]; then
						exit 77
					fi
				elif [ "${1}" = 'python3' ]; then
					# python3 -I -c PROGRAM TIMEOUT ACTION ADDRESS [PORT]
					if [ "${TEST_CASE}" = 'dns-fail' ] && [ "${6}" = 'dns' ]; then exit 1; fi
					if { [ "${TEST_CASE}" = 'outbound-fail' ] || [ "${TEST_CASE}" = 'vpn-filter' ]; } &&
						[ "${6}" = 'tcp' ] && [ "${7}" = '1.1.1.1' ]; then exit 1; fi
					if [ "${TEST_CASE}" = 'loopback-fail' ] && [ "${7}" = '127.0.0.1' ]; then exit 1; fi
				else
					exit 99
				fi
				;;
			*) printf >&2 'FORBIDDEN fixture container command: %s\n' "${*}"; exit 99 ;;
		esac
		;;
	route)
		if [ "${TEST_CASE}" = 'wrong-route' ]; then
			printf 'interface: utun4\n'
		else
			printf 'interface: bridge107\n'
		fi
		;;
	ifconfig)
		if [ "${TEST_CASE}" = 'unknown-gateway' ]; then
			printf 'bridge107: flags=8863\n\tinet 192.168.78.1 netmask 0xffffff00\n'
		else
			printf 'bridge107: flags=8863\n\tinet 192.168.77.1 netmask 0xffffff00\n'
		fi
		;;
	nc)
		if [ "${TEST_CASE}" = 'host-tcp-fail' ]; then exit 1; fi
		;;
	curl)
		case "${TEST_CASE}" in
			published-error) printf '503' ;;
			published-redirect) printf '302' ;;
			published-cert) exit 77 ;;
			vpn-filter) exit 28 ;;
			published-hang)
				printf >&2 'FIXTURE_PID=%s\n' "${$}"
				exec /bin/sleep 60
				;;
			*) printf '200' ;;
		esac
		;;
	*) exit 99 ;;
esac
