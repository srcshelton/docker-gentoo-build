#! /usr/bin/env bash

set -euo pipefail

readonly pkgcache_writable='/var/cache/portage/pkg'
readonly pkgcache_seed='/var/cache/portage/pkg-seed'
readonly pkgcache_expected="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gentoo-pkgdir-compatibility.metadata"

pkgcache_identity() {
	local expected='' expected_tmp='' identity=''
	local label='' profile='' schema=''

	identity="$( ./gentoo-init.docker --print-pkgdir-cache-affinity )"
	printf '%s\n' "${identity}"
	expected="$( sed '/^PROFILE=/,$d' <<<"${identity}" )"
	label="$( awk -F= '$1 == "CACHE_LABEL" {
		print substr($0, index($0, "=") + 1)
	}' <<<"${identity}" )"
	profile="$( awk -F= '$1 == "PROFILE" {
		print substr($0, index($0, "=") + 1)
	}' <<<"${identity}" )"
	schema="$( awk -F= '$1 == "CACHE_SCHEMA" { print $2 }' \
		<<<"${identity}" )"
	[[ -n "${expected}" && -n "${label}" && -n "${profile}" &&
			"${schema}" =~ ^[0-9]+$ ]]
	expected_tmp="$( mktemp "${pkgcache_expected}.XXXXXX" )"
	if ! printf '%s\n' "${expected}" >"${expected_tmp}" ||
			! mv -f "${expected_tmp}" "${pkgcache_expected}"
	then
		rm -f "${expected_tmp}"
		return 1
	fi
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'label=%s\nprofile-version=%s\nschema=%s\n' \
			"${label}" "${profile%%/*}" "${schema}" >>"${GITHUB_OUTPUT}"
	fi
}  # pkgcache_identity

pkgcache_normalize_ownership() {
	sudo chown -R "$( id -u ):$( id -g )" \
		"${pkgcache_writable}" "${pkgcache_seed}"
}  # pkgcache_normalize_ownership

pkgcache_validate_metadata() {
	local actual='' expected='' metadata_path=''

	if [[ -s "${pkgcache_expected}" ]]; then
		expected="$(<"${pkgcache_expected}")"
	else
		printf >&2 'Initial PKGDIR compatibility identity is unavailable; recomputing it\n'
		expected="$( # <- Syntax
			./gentoo-init.docker --print-pkgdir-cache-affinity |
				sed '/^PROFILE=/,$d'
		)"
	fi
	[[ -n "${expected}" ]] || return 1
	while IFS= read -r -d '' metadata_path; do
		actual="$(<"${metadata_path}")"
		if [[ "${actual}" != "${expected}" ]]; then
			printf >&2 "PKGDIR metadata '%s' does not match the active compiler target\n" \
				"${metadata_path}"
			if command -v diff >/dev/null 2>&1; then
				diff -u \
					<( printf '%s\n' "${actual}" ) \
					<( printf '%s\n' "${expected}" ) >&2 || :
			fi
			return 1
		fi
	done < <(find "${pkgcache_writable}" -type f -name .metadata -print0)
}  # pkgcache_validate_metadata

pkgcache_stage_save() {
	local ready=false

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'ready=false\n' >>"${GITHUB_OUTPUT}"
	fi
	if [[ ! -d "${pkgcache_writable}" ]]; then
		printf >&2 'No writable PKGDIR generation exists; skipping cache save\n'
		return 0
	fi
	if [[ -z "$( find "${pkgcache_writable}" -type f \
			-name Packages -size +0c -print -quit )" ]]
	then
		printf >&2 'Writable PKGDIR has no non-empty package index; skipping cache save\n'
		return 0
	fi
	if [[ -z "$( find "${pkgcache_writable}" -type f \
			-name .metadata -size +0c -print -quit )" ]]
	then
		printf >&2 'Writable PKGDIR has no metadata; skipping cache save\n'
		return 0
	fi
	if ! pkgcache_validate_metadata; then
		printf >&2 'Writable PKGDIR metadata is incompatible; skipping cache save\n'
		return 0
	fi
	if [[ -n "$( find "${pkgcache_writable}" -type f \
			-name '*.partial' -print -quit )" ]]
	then
		printf >&2 'Writable PKGDIR contains partial files; skipping cache save\n'
		return 0
	fi

	sudo rm -rf "${pkgcache_seed}"
	sudo mv "${pkgcache_writable}" "${pkgcache_seed}"
	sudo chown -R "$( id -u ):$( id -g )" "${pkgcache_seed}"
	ready=true
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf 'ready=%s\n' "${ready}" >>"${GITHUB_OUTPUT}"
	fi
}  # pkgcache_stage_save

case "${1:-}" in
	identity)
		pkgcache_identity
		;;
	normalize-ownership)
		pkgcache_normalize_ownership
		;;
	stage-save)
		pkgcache_stage_save
		;;
	*)
		printf >&2 'Usage: %s {identity|normalize-ownership|stage-save}\n' \
			"${0##*/}"
		exit 64
		;;
esac
