#! /usr/bin/env bash

# Resolve compiler and linker variables consistently across Gentoo, other
# Linux hosts, and macOS.  This file is sourced by gentoo-init.docker after the
# common output and error helpers have been loaded.

if [[ -z "${__COMMON_BUILD_FLAGS_INCLUDED:-}" ]]; then
	declare -gr __COMMON_BUILD_FLAGS_INCLUDED=1
	declare -agr gentoo_build_flag_vars=(
		CPPFLAGS CFLAGS CXXFLAGS FFLAGS FCFLAGS FLFLAGS LDFLAGS
		CGO_CPPFLAGS CGO_CFLAGS CGO_CXXFLAGS CGO_FFLAGS CGO_LDFLAGS
		GOFLAGS RUSTFLAGS
	)

	resolve_non_gentoo_build_flags() (
		# Compiler flags from macOS describe Apple's host compiler and are not
		# safe inputs for a Linux target.  Linux-host values are meaningful Linux
		# build overrides and retain the traditional behaviour.  On every host,
		# GENTOO_BUILD_<FLAG> is the unambiguous per-variable override and
		# GENTOO_USE_HOST_COMPILER_FLAGS=1 opts in all unprefixed values.
		local flag_var explicit_var host_os displayed_value ARCH GENTOO_PKGHOST
		local -a override_names=() override_values=()
		local -i flag_index=0
		host_os="$( uname -s )"

		case "${GENTOO_USE_HOST_COMPILER_FLAGS:-0}" in
			0|1)	: ;;
			*)	printf >&2 '%s\n' \
					"FATAL: GENTOO_USE_HOST_COMPILER_FLAGS must be either 0 or 1"
				return 64
				;;
		esac

		for flag_var in "${gentoo_build_flag_vars[@]}"; do
			explicit_var="GENTOO_BUILD_${flag_var}"
			if declare -p "${explicit_var}" >/dev/null 2>&1; then
				printf -v displayed_value '%q' "${!explicit_var}"
				printf >&2 "INFO:  Using %s ('%s') as build %s override\n" \
					"${explicit_var}" "${displayed_value}" "${flag_var}"
				override_names+=( "${flag_var}" )
				override_values+=( "${!explicit_var}" )
			elif [[ "${GENTOO_USE_HOST_COMPILER_FLAGS:-0}" == 1 ]] &&
					declare -p "${flag_var}" >/dev/null 2>&1
			then
				printf -v displayed_value '%q' "${!flag_var}"
				printf >&2 "INFO:  Retaining host %s ('%s') because %s\n" \
					"${flag_var}" "${displayed_value}" \
					'GENTOO_USE_HOST_COMPILER_FLAGS=1'
				override_names+=( "${flag_var}" )
				override_values+=( "${!flag_var}" )
			elif [[ "${host_os}" == 'Linux' ]] &&
					declare -p "${flag_var}" >/dev/null 2>&1
			then
				printf -v displayed_value '%q' "${!flag_var}"
				printf >&2 \
					"INFO:  Honouring Linux host %s ('%s') as a build override\n" \
					"${flag_var}" "${displayed_value}"
				override_names+=( "${flag_var}" )
				override_values+=( "${!flag_var}" )
			elif declare -p "${flag_var}" >/dev/null 2>&1; then
				printf -v displayed_value '%q' "${!flag_var}"
				printf >&2 "WARN:  %s ('%s') will be ignored; set %s or %s\n" \
					"${flag_var}" "${displayed_value}" \
					"GENTOO_BUILD_${flag_var}" \
					'GENTOO_USE_HOST_COMPILER_FLAGS=1 to preserve this host override'
			fi
			unset "${flag_var}"
		done

		# These defaults are consumed while sourcing make.conf below.
		# shellcheck disable=SC2034
		case "${arch:-"$( uname -m )"}" in
			amd64|ppc64|x86)
				LDFLAGS='-Wl,-O1 -Wl,--as-needed -Wl,-z,pack-relative-relocs'
				;;
			*)
				LDFLAGS='-Wl,-O1 -Wl,--as-needed'
				;;
		esac
		# shellcheck disable=SC2030
		ARCH="${ARCH:-"${arch:-"$( uname -m )"}"}"
		# shellcheck disable=SC2030
		GENTOO_PKGHOST="${GENTOO_PKGHOST:-container}"
		if [[ -s etc/portage/make.conf ]]; then
			# shellcheck disable=SC1091
			. etc/portage/make.conf
		elif [[ -s /etc/portage/make.conf ]]; then
			# shellcheck disable=SC1091
			. /etc/portage/make.conf
		fi

		for (( flag_index=0; flag_index < ${#override_names[@]}; flag_index++ )); do
			printf -v "${override_names[flag_index]}" '%s' \
				"${override_values[flag_index]}"
			export "${override_names[flag_index]}"
		done

		# Emit shell-escaped lowercase assignments for the caller's locals.
		for flag_var in "${gentoo_build_flag_vars[@]}"; do
			if declare -p "${flag_var}" >/dev/null 2>&1; then
				printf '%s=%q;\n' "${flag_var,,}" "${!flag_var}"
			fi
		done
	)  # resolve_non_gentoo_build_flags

	resolve_gentoo_build_flags() (
		# Query Portage once for the complete flag snapshot.  A status of one is
		# normal when requested variables are unset, provided portageq returned
		# the assignments it knows about.
		local flag_var explicit_var displayed_value portage_env=''
		local -i portage_status=0

		case "${GENTOO_USE_HOST_COMPILER_FLAGS:-0}" in
			0|1)	: ;;
			*)	printf >&2 '%s\n' \
					"FATAL: GENTOO_USE_HOST_COMPILER_FLAGS must be either 0 or 1"
				return 64
				;;
		esac

		for flag_var in "${gentoo_build_flag_vars[@]}"; do
			explicit_var="GENTOO_BUILD_${flag_var}"
			if ! declare -p "${explicit_var}" >/dev/null 2>&1 &&
					declare -p "${flag_var}" >/dev/null 2>&1
			then
				printf -v displayed_value '%q' "${!flag_var}"
				printf >&2 \
					"INFO:  Honouring Gentoo host %s ('%s') through Portage\n" \
					"${flag_var}" "${displayed_value}"
			fi
		done

		set +e
		portage_env="$( LC_ALL='C' portageq envvar -v \
			"${gentoo_build_flag_vars[@]}" )"
		portage_status=${?}
		set -e
		if (( portage_status > 1 )); then
			printf >&2 'FATAL: portageq envvar failed with status %d\n' \
				"${portage_status}"
			return "${portage_status}"
		fi

		for flag_var in "${gentoo_build_flag_vars[@]}"; do
			unset "${flag_var}"
		done
		eval "${portage_env}"

		# The prefixed form deliberately has higher precedence than Portage's own
		# environment resolution.  Ordinary Linux variables have already been
		# incorporated according to Portage's normal precedence rules.
		for flag_var in "${gentoo_build_flag_vars[@]}"; do
			explicit_var="GENTOO_BUILD_${flag_var}"
			if declare -p "${explicit_var}" >/dev/null 2>&1; then
				printf -v displayed_value '%q' "${!explicit_var}"
				printf >&2 "INFO:  Using %s ('%s') as build %s override\n" \
					"${explicit_var}" "${displayed_value}" "${flag_var}"
				printf -v "${flag_var}" '%s' "${!explicit_var}"
			fi
			if declare -p "${flag_var}" >/dev/null 2>&1; then
				printf '%s=%q;\n' "${flag_var,,}" "${!flag_var}"
			fi
		done
	)  # resolve_gentoo_build_flags
fi
