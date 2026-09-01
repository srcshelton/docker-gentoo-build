#! /usr/bin/env bash

set -euo pipefail

repository_root="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
readonly repository_root
test_data_root="${repository_root}/.github/test-data"
readonly test_data_root

parse_gentoo_flags() {
	local available="${1}" description_path="${2}"

	bash --posix -c '
		set -eu
		set -o pipefail
		. "${1}/common/cpu-target.sh"
		cpu_target_gentoo_flags "${2}" "${3}"
	' sh "${repository_root}" "${available}" "${description_path}"
}  # parse_gentoo_flags

expected='aliased direct multi'
actual="$( # <- Syntax
	parse_gentoo_flags 'direct hardware_alias second_alias' \
		"${test_data_root}/cpu-flags-valid.desc"
)"
if [[ "${actual}" != "${expected}" ]]; then
	printf >&2 "CPU flag parser returned '%s'; expected '%s'\n" \
		"${actual}" "${expected}"
	exit 1
fi

if parse_gentoo_flags 'feature' \
		"${test_data_root}/cpu-flags-malformed.desc"
then
	printf >&2 'CPU flag parser accepted an unterminated alias\n'
	exit 1
fi

if bash --posix -c '
		set -eu
		set -o pipefail
		. "${1}/common/cpu-target.sh"
		cpu_target_gentoo_flags feature "${2}/missing-cpu-flags.desc"
	' sh "${repository_root}" "${test_data_root}"
then
	printf >&2 'CPU flag parser accepted a missing description file\n'
	exit 1
fi

printf '%s\n' 'CPU target helper tests passed'

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
