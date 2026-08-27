#! /usr/bin/env bash

# Shared Portage binary-package namespace and cache-identity helpers.  Callers
# provide error(), warn(), and the architecture/profile variables resolved by
# common/vars.sh and _docker_setup().

if [[ -z "${__COMMON_PKG_INCLUDED:-}" ]]; then
	declare -gr __COMMON_PKG_INCLUDED=1

	pkgdir_sha256() {
		if command -v sha256sum >/dev/null 2>&1; then
			sha256sum | awk '{print $1}'
		elif command -v shasum >/dev/null 2>&1; then
			shasum -a 256 | awk '{print $1}'
		elif command -v openssl >/dev/null 2>&1; then
			openssl dgst -sha256 | awk '{print $NF}'
		else
			error 'No SHA-256 implementation is available for PKGDIR identity'
			return 1
		fi
	}  # pkgdir_sha256

	pkgdir_slug() {
		LC_ALL='C' tr '[:upper:]' '[:lower:]' |
			sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
	}  # pkgdir_slug

	pkgdir_normalize_words() {
		if [[ -n "${1:-}" ]]; then
			xargs -rn 1 <<<"${1}" |
				LC_ALL='C' sort -u |
				xargs -r
		fi
	}  # pkgdir_normalize_words

	# Describe the universal compatibility boundary for a writable PKGDIR.
	# Portage does not distinguish packages by compiler flags, so exact default
	# compiler targets belong here.  Deliberate GENTOO_BUILD_* experiments stay
	# caller-managed and are intentionally excluded.
	pkgdir_compatibility_metadata() {
		local metadata_arch="${ARCH:-"${arch:-}"}"
		local metadata_chost="${chost:-}"
		local metadata_compiler="${compiler_family:-gcc}"
		local metadata_cpu="${target_cpu:-}"
		local metadata_value=''

		for metadata_value in \
			"${metadata_arch}" "${metadata_chost}" "${metadata_compiler}" \
			"${metadata_cpu}" \
			"${cc_target_opts:-}" "${rust_target_opts:-}"
		do
			if [[ -z "${metadata_value}" ]]; then
				error 'PKGDIR compatibility value is empty'
				return 1
			fi
			if printf '%s' "${metadata_value}" |
					LC_ALL='C' grep -q '[[:cntrl:]]'
			then
				error 'PKGDIR compatibility value contains a control character'
				return 1
			fi
		done

		printf '%s\n' \
			'CACHE_SCHEMA=3' \
			'TARGET_OS=linux' \
			"ARCH=${metadata_arch}" \
			"CHOST=${metadata_chost}" \
			"COMPILER=${metadata_compiler}" \
			"CPU=${metadata_cpu}" \
			"CC_TARGET_OPTS=${cc_target_opts:-}" \
			"RUST_TARGET_OPTS=${rust_target_opts:-}"
	}  # pkgdir_compatibility_metadata

	# Select a useful immutable CI generation.  PROFILE and CPU_FLAGS_* can
	# reduce cache misses and stale payload, but do not broaden the writable
	# compatibility boundary above: Portage validates them as package policy.
	pkgdir_generation_affinity_metadata() {
		local metadata_cpu_flags_name="CPU_FLAGS_${use_cpu_arch^^}"
		local metadata_cpu_flags=''
		local metadata_profile="${profile:-}"
		local metadata_value=''

		[[ -n "${use_cpu_arch:-}" ]] ||
			metadata_cpu_flags_name='CPU_FLAGS_UNKNOWN'
		metadata_cpu_flags="$( pkgdir_normalize_words \
			"${use_cpu_flags_raw:-}" )"
		[[ -n "${metadata_profile}" ]] || {
			error 'PKGDIR generation-affinity profile is empty'
			return 1
		}
		for metadata_value in \
			"${metadata_profile}" "${metadata_cpu_flags_name}" \
			"${metadata_cpu_flags}"
		do
			if printf '%s' "${metadata_value}" |
					LC_ALL='C' grep -q '[[:cntrl:]]'
			then
				error 'PKGDIR generation-affinity value contains a control character'
				return 1
			fi
		done
		pkgdir_compatibility_metadata || return ${?}
		printf '%s\n' \
			"PROFILE=${metadata_profile}" \
			"CPU_FLAGS_NAME=${metadata_cpu_flags_name}" \
			"CPU_FLAGS=${metadata_cpu_flags}"
	}  # pkgdir_generation_affinity_metadata

	pkgdir_generation_affinity_label() {
		local metadata_digest=''
		local label_arch='' label_chost='' label_profile='' label_cpu=''

		metadata_digest="$( # <- Syntax
			pkgdir_generation_affinity_metadata | pkgdir_sha256
		)" ||
			return 1
		label_arch="$( printf '%s' "${ARCH:-"${arch:-unknown}"}" |
			pkgdir_slug )"
		label_chost="$( printf '%s' "${chost:-unknown}" | pkgdir_slug )"
		label_profile="$( printf '%s' "${profile:-unknown}" | pkgdir_slug )"
		label_cpu="$( printf '%s' "${target_cpu:-unknown}" | pkgdir_slug )"

		printf 'linux-%s-%s-%s-%s-%s-%s\n' \
			"${label_arch:-unknown}" "${label_chost:-unknown}" \
			"${label_profile:-unknown}" "${compiler_family:-gcc}" \
			"${label_cpu:-unknown}" \
			"${metadata_digest:0:16}"
	}  # pkgdir_generation_affinity_label

	write_pkgdir_metadata() {
		local metadata_path="${1:-}"
		local metadata_tmp=''

		[[ -n "${metadata_path:-}" ]] || return 1
		metadata_tmp="$( mktemp "${metadata_path}.tmp.XXXXXX" )" || return 1
		if pkgdir_compatibility_metadata >"${metadata_tmp}" &&
				mv -f "${metadata_tmp}" "${metadata_path}"
		then
			return 0
		fi
		rm -f "${metadata_tmp}"
		return 1
	}  # write_pkgdir_metadata

	# Schema 2 writable caches recorded only ARCH and CPU.  That format was
	# produced after named CPU targets became deterministic, so it is safe to
	# upgrade only when both values exactly match the active target.  A cache
	# containing any other or additional legacy state remains incompatible.
	migrate_legacy_pkgdir_metadata_file() {
		local metadata_path="${1:-}"
		local actual='' legacy=''

		[[ -s "${metadata_path:-}" ]] || return 1
		actual="$(<"${metadata_path}")"
		legacy="$( printf '%s\n' \
			"ARCH=${ARCH:-"${arch:-}"}" \
			"CPU=${target_cpu:-}" )"
		[[ "${actual}" == "${legacy}" ]] || return 1

		write_pkgdir_metadata "${metadata_path}"
	}  # migrate_legacy_pkgdir_metadata_file

	validate_pkgdir_metadata_file() {
		local metadata_path="${1:-}"
		local actual='' expected=''

		[[ -s "${metadata_path:-}" ]] || return 1
		actual="$(<"${metadata_path}")"
		expected="$( pkgdir_compatibility_metadata )" || return ${?}
		[[ "${actual}" == "${expected}" ]] && return 0

		error "PKGDIR metadata in '${metadata_path}' is incompatible with" \
			'the active compiler target'
		if command -v diff >/dev/null 2>&1; then
			diff -u \
				<( printf '%s\n' "${actual}" ) \
				<( printf '%s\n' "${expected}" ) >&2 || :
		fi
		error 'Use a separate GENTOO_PKGHOST (with the default PKGDIR) or' \
			'PKGDIR for this target, or move aside only the cache subtree' \
			"containing '${metadata_path}'"
		error 'The shared parent package cache does not need to be removed'
		return 1
	}  # validate_pkgdir_metadata_file
fi
