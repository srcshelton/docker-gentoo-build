#! /usr/bin/env bash

set -euo pipefail

repository_root="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
if [[ "$(uname -s)" != Darwin ]]; then
	printf '%s\n' 'SKIP: Apple container diagnostic CLI fixtures require macOS'
	exit 0
fi
mkdir -p "${repository_root}/.worktrees"
test_root="$(mktemp -d "${repository_root}/.worktrees/apple-container-diagnostics-${CODEX_SESSION_ID:-$$}.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
printf 'Fixture scratch (removed on exit): %s\n' "${test_root}"
for test_command in container route ifconfig nc curl; do
	ln -s "${repository_root}/.github/test-data/apple-container-diagnostic-command.sh" \
		"${test_root}/${test_command}"
done
export TEST_REAL_PATH="${PATH}"
export PATH="${test_root}:${PATH}"
unset CONTAINER_DEBUG CONTAINER_START_TIMEOUT CONTAINER_STOP_TIMEOUT
unset CONTAINER_BUILDER_CPUS CONTAINER_BUILDER_MEMORY

run_case() {
	local expected_status="${1}" expected_text="${2}" actual_status=0
	shift 2
	test_output="$(sh "${repository_root}/tools/apple-container.sh" "${@}" 2>&1)" || actual_status=${?}
	if [[ "${actual_status}" != "${expected_status}" || "${test_output}" != *"${expected_text}"* ||
		"${test_output}" == *'FORBIDDEN'* ]]; then
		printf >&2 'Unexpected result for %s: exit %s, expected %s\n%s\n' \
			"${TEST_CASE}" "${actual_status}" "${expected_status}" "${test_output}"
		exit 1
	fi
	printf 'PASS: %s\n' "${TEST_CASE}"
}

export TEST_CASE=success
run_case 0 'PASS: Guest outbound TCP' --diagnose fixture --port 8080 --probe-timeout 2
[[ "${test_output}" == *'PASS: Guest name resolution'* ]]
[[ "${test_output}" == *'PASS: Guest loopback TCP'* ]]
[[ "${test_output}" == *'PASS: Host route'* ]]
[[ "${test_output}" == *'Published-port forwarding not tested'* ]]

TEST_CASE=published-success
run_case 0 'PASS: Host published HTTP(S) endpoint' --diagnose fixture --port 8080 \
	--published-url http://127.0.0.1:18080/health
for TEST_CASE in published-error published-redirect published-cert vpn-filter; do
	run_case 1 'FAIL: Host published HTTP(S) endpoint' --diagnose fixture --port 8080 \
		--published-url http://127.0.0.1:18080/health
	[[ "${test_output}" == *'PASS: Host route'* ]]
	[[ "${test_output}" == *'PASS: Guest loopback TCP'* ]]
	if [[ "${TEST_CASE}" == vpn-filter ]]; then
		[[ "${test_output}" == *'FAIL: Guest outbound TCP'* ]]
	fi
done
TEST_CASE=bad-url
run_case 1 'Published URL must start with' --diagnose fixture --published-url file:///etc/hosts
TEST_CASE=empty-url
run_case 1 'Published URL cannot be empty' --diagnose fixture --published-url ''
TEST_CASE=unscoped-url
run_case 1 'Diagnostic options require' --published-url http://127.0.0.1:18080/

TEST_CASE=wrong-route
run_case 1 "Route uses 'utun4'; gateway belongs to 'bridge107'" --diagnose fixture --port 8080
[[ "${test_output}" == *'PASS: Guest outbound TCP'* ]]
TEST_CASE=dns-fail
run_case 1 'FAIL: Guest name resolution' --diagnose fixture --port 8080
[[ "${test_output}" == *'PASS: Guest outbound TCP'* ]]
TEST_CASE=outbound-fail
run_case 1 'FAIL: Guest outbound TCP' --diagnose fixture --port 8080
[[ "${test_output}" == *'PASS: Guest name resolution'* ]]
TEST_CASE=loopback-fail
run_case 1 'FAIL: Guest loopback TCP' --diagnose fixture --port 8080
TEST_CASE=host-tcp-fail
run_case 1 'FAIL: Host to container TCP' --diagnose fixture --port 8080
TEST_CASE=missing-python
run_case 2 'SKIP: Guest network probes require Python 3' --diagnose fixture --port 8080
TEST_CASE=omitted-port
run_case 2 'SKIP: Host-to-container and guest-loopback TCP' --diagnose fixture
TEST_CASE=unknown-gateway
run_case 2 'SKIP: Host route' --diagnose fixture --port 8080
[[ "${test_output}" != *'PASS: Host route'* ]]

for TEST_CASE in inspect-hang exec-hang published-hang; do
	test_start=${SECONDS}
	run_case 1 'Probe timed out after 2s' --diagnose fixture --port 8080 --probe-timeout 2 \
		--published-url http://127.0.0.1:18080/health
	(( SECONDS - test_start < 25 ))
	test_pid="$(printf '%s\n' "${test_output}" | sed -n 's/^FIXTURE_PID=//p')"
	[[ -n "${test_pid}" ]]
	if kill -0 "${test_pid}" 2>/dev/null; then
		printf >&2 'Timed-out diagnostic process %s survived\n' "${test_pid}"
		exit 1
	fi
done
TEST_CASE=stopped
export TEST_STATE=stopped
run_case 1 'Target container must already be running' --diagnose fixture
unset TEST_STATE
TEST_CASE=old-version
export TEST_VERSION=1.3.0
run_case 1 '1.4.1 or later is required' --diagnose fixture
unset TEST_VERSION
TEST_CASE=bad-port
run_case 1 'Service port must be' --diagnose fixture --port 99999
TEST_CASE=bad-address
run_case 1 'Outbound address must be' --diagnose fixture --probe-address 1.2.3.999
TEST_CASE=conflicting-mode
run_case 1 'cannot be combined' --diagnose fixture --restart
TEST_CASE=unscoped-option
run_case 1 'Diagnostic options require' --port 8080
TEST_CASE=unrelated-settings
export CONTAINER_BUILDER_CPUS=invalid CONTAINER_START_TIMEOUT=1
run_case 0 'PASS: Guest outbound TCP' --diagnose fixture --port 8080
unset CONTAINER_BUILDER_CPUS CONTAINER_START_TIMEOUT

# Execute the actual embedded guest Python against a local socket, without a
# VM or Internet access. This catches Python syntax/argument and socket errors
# that the CLI fixtures above deliberately cannot exercise.
python3 - "${repository_root}" <<'PY'
import socket
import signal
import subprocess
import sys
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

script = r'''
set -eu
. "$1/common/apple-container-diagnostics.sh"
diagnostic_container=fixture
diagnostic_timeout=3
apple_diagnostic_container() { shift 2; "$@"; }
shift
apple_diagnostic_guest "$@"
'''

def probe(*arguments, command=script):
    return subprocess.run(["sh", "-c", command, "sh", sys.argv[1], *arguments],
                          capture_output=True, text=True, timeout=5)

assert probe("dns", "localhost").returncode == 0
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = str(listener.getsockname()[1])
    result = probe("tcp", "127.0.0.1", port)
    assert result.returncode == 0, result.stderr
    connection, _ = listener.accept()
    connection.close()
# Bind without listening so the failed connection targets a reserved port.
with socket.socket() as closed:
    closed.bind(("127.0.0.1", 0))
    result = probe("tcp", "127.0.0.1", str(closed.getsockname()[1]))
    # The host may drop rather than reject traffic to a non-listening socket;
    # both a socket error and the guest deadline must report failure.
    assert result.returncode in (1, -signal.SIGALRM, 128 + signal.SIGALRM), result.stderr
# Exercise the guest deadline even when resolution itself never completes.
stalled = script.replace('shift\napple_diagnostic_guest', r'''
apple_diagnostic_container() {
    shift 5
    python3 -c '
import socket, sys, time
socket.getaddrinfo = lambda *args: time.sleep(60)
program = sys.argv.pop(1)
exec(program)
' "$@"
}
shift
apple_diagnostic_guest''')
result = probe("dns", "localhost", command=stalled)
assert result.returncode in (-signal.SIGALRM, 128 + signal.SIGALRM), result.stderr
print("PASS: real guest Python DNS/TCP probes on host loopback")

# Test the actual curl invocation, including a forwarder-like response that
# sends valid headers but never completes its body. No Internet access needed.
http_script = r'''
set -eu
. "$1/common/apple-container-diagnostics.sh"
output() { printf '%s\n' "$*"; }
diagnostic_timeout=3
diagnostic_published_url=$2
apple_diagnostic_http
'''
requests = []
release_stall = threading.Event()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        requests.append(self.path)
        status = {"/error": 503, "/redirect": 302, "/empty": 204}.get(self.path, 200)
        self.send_response(status)
        self.send_header("Content-Length", "0" if status == 204 else "2")
        if status == 302:
            self.send_header("Location", "/ok")
        self.end_headers()
        self.wfile.flush()
        if self.path == "/stall":
            release_stall.wait(10)
        if status != 204:
            try:
                self.wfile.write(b"OK")
            except OSError:
                pass

environment = dict(os.environ, PATH=os.environ["TEST_REAL_PATH"],
                   http_proxy="http://127.0.0.1:1", HTTP_PROXY="http://127.0.0.1:1",
                   all_proxy="http://127.0.0.1:1", ALL_PROXY="http://127.0.0.1:1",
                   no_proxy="", NO_PROXY="")
with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        for path, expected in [("/ok", 0), ("/empty", 0), ("/error", 1),
                               ("/redirect", 1), ("/stall", 1)]:
            requests.clear()
            url = f"http://127.0.0.1:{server.server_port}{path}"
            result = subprocess.run(["sh", "-c", http_script, "sh", sys.argv[1], url],
                                    capture_output=True, text=True, timeout=6,
                                    env=environment)
            assert result.returncode == expected, (path, result.stdout, result.stderr)
            assert requests == [path], requests
            if path == "/stall":
                assert "timed out" in result.stderr.lower(), result.stderr
    finally:
        release_stall.set()
        server.shutdown()
        server_thread.join()
print("PASS: real HTTP success, error, redirect, stalled-body and proxy-bypass probes")
PY

printf '%s\n' 'Apple container diagnostic CLI fixtures passed'
