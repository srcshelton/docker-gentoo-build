#! /usr/bin/env bash

# CI-only diagnostics for an unrecognised or feature-masked build CPU.  The
# caller decides whether diagnostics are needed; known usable targets must not
# pay the download/build cost below.

set -euo pipefail

readonly cpuid2cpuflags_version='17'
readonly cpuid2cpuflags_sha256='72379619949d179ad1f8fb51c2833e3c248a7072bbefcd937991132032d7287c'
readonly cpuid2cpuflags_release_url='https://github.com/gentoo/cpuid2cpuflags/releases/download'
readonly cpuid2cpuflags_url="${cpuid2cpuflags_release_url}/v${cpuid2cpuflags_version}/cpuid2cpuflags-${cpuid2cpuflags_version}.tar.bz2"

printf '%s\n' 'Unrecognised build CPU diagnostics:'
lscpu || true
grep -E \
	'^(vendor_id|model name|flags|CPU implementer|CPU architecture|CPU part|CPU revision|Features)[[:space:]]*:' \
	/proc/cpuinfo | sort -u || true

if command -v cpuid2cpuflags >/dev/null 2>&1; then
	cpuid2cpuflags
	exit ${?}
fi

diagnostic_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}/docker-gentoo-build-cpu-diagnostics}"
mkdir -p "${diagnostic_parent}"
diagnostic_root="$(
	mktemp -d "${diagnostic_parent%/}/cpuid2cpuflags.XXXXXXXX"
)"
cleanup_cpu_diagnostics() {
	rm -rf -- "${diagnostic_root}"
}
trap cleanup_cpu_diagnostics EXIT

archive="${diagnostic_root}/cpuid2cpuflags-${cpuid2cpuflags_version}.tar.bz2"
curl --fail --location --silent --show-error \
	"${cpuid2cpuflags_url}" --output "${archive}"
printf '%s  %s\n' "${cpuid2cpuflags_sha256}" "${archive}" |
	sha256sum --check --status
tar -xjf "${archive}" -C "${diagnostic_root}"

source_root="${diagnostic_root}/cpuid2cpuflags-${cpuid2cpuflags_version}"
(
	cd "${source_root}"
	./configure --quiet
	make --quiet -j"$( nproc )"
	./cpuid2cpuflags
)

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
