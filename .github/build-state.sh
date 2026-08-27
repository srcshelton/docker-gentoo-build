#! /usr/bin/env bash

set -euo pipefail

build_state_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}  # build_state_sha256

build_state_fingerprint() {
	local runner_arch="${1:-}"
	local overlay_path="${2:-.ci-repos/srcshelton}"
	local overlay_commit='' portage_commit='' stage3_digest=''
	local fingerprint=''

	[[ "${runner_arch}" =~ ^(amd64|arm64)$ ]]
	[[ -d "${overlay_path}/.git" || -f "${overlay_path}/.git" ]]
	overlay_commit="$( git -C "${overlay_path}" rev-parse HEAD )"
	portage_commit="$( # <- Syntax
		grep -E '^[0-9a-f]{40}$' "${overlay_path}/.portage_commit" |
			head -n 1
	)"
	stage3_digest="$( # <- Syntax
		awk -v arch="${runner_arch}" '$1 == arch { print $2; exit }' \
			"${overlay_path}/.image_digests"
	)"
	[[ "${overlay_commit}" =~ ^[0-9a-f]{40}$ ]]
	[[ "${portage_commit}" =~ ^[0-9a-f]{40}$ ]]
	[[ "${stage3_digest}" =~ ^sha256:[0-9a-f]{64}$ ]]

	fingerprint="$( # <- Syntax
		{
			printf '%s\n' \
				'BUILD_STATE_SCHEMA=1' \
				"RUNNER_ARCH=${runner_arch}" \
				"OVERLAY_COMMIT=${overlay_commit}" \
				"PORTAGE_COMMIT=${portage_commit}" \
				"STAGE3_DIGEST=${stage3_digest}"
			git ls-files -s -- \
				.github/build-state.sh \
				.github/cpu-diagnostics.sh \
				.github/pkgcache.sh \
				.github/workflows/gentoo-build.yml \
				common gentoo-base gentoo-init.docker tools
		} | build_state_sha256
	)"

	printf '%s\n' \
		"BUILD_STATE_SCHEMA=1" \
		"RUNNER_ARCH=${runner_arch}" \
		"OVERLAY_COMMIT=${overlay_commit}" \
		"PORTAGE_COMMIT=${portage_commit}" \
		"STAGE3_DIGEST=${stage3_digest}" \
		"FINGERPRINT=${fingerprint}" \
		"SUCCESS_KEY=gentoo-build-success-v1-${runner_arch}-${fingerprint}"

	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		printf '%s\n' \
			"fingerprint=${fingerprint}" \
			"portage-commit=${portage_commit}" \
			"stage3-digest=${stage3_digest}" \
			"success-key=gentoo-build-success-v1-${runner_arch}-${fingerprint}" \
			>>"${GITHUB_OUTPUT}"
	fi
}  # build_state_fingerprint

case "${1:-}" in
	fingerprint)
		build_state_fingerprint "${2:-}" "${3:-}"
		;;
	*)
		printf >&2 'Usage: %s fingerprint {amd64|arm64} [overlay-path]\n' \
			"${0##*/}"
		exit 64
		;;
esac

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
