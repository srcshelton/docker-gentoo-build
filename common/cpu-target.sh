#! /bin/sh
# shellcheck disable=SC2034 # cpu_target_set_generic() returns globals to caller.

# Deterministic compiler-target selection and host-capability checks.  The
# caller owns the target variables; these helpers deliberately do not inspect
# environment-variable overrides or package-cache policy.

if [ -z "${__COMMON_CPU_TARGET_INCLUDED:-}" ]; then
	readonly __COMMON_CPU_TARGET_INCLUDED=1

	cpu_target_normalize_words() (
		if [ -n "${1:-}" ]; then
			printf '%s\n' "${1}" |
				xargs -rn 1 |
				LC_ALL='C' sort -u |
				xargs -r
		fi
	)  # cpu_target_normalize_words

	cpu_target_remove_feature() (
		words="${1:-}" omitted="${2:-}" word='' retained=''

		for word in ${words}; do
			[ "${word}" = "${omitted}" ] ||
				retained="${retained:+${retained} }${word}"
		done
		printf '%s\n' "${retained}"
	)  # cpu_target_remove_feature

	cpu_target_proc_features() (
		cpuinfo_path="${1:-/proc/cpuinfo}"
		cpuinfo_features=''

		[ -r "${cpuinfo_path}" ] || return 0
		cpuinfo_features="$( # <- Syntax
			awk -F':' '
				/^(flags|Features)[[:space:]]*:/ {
					delete current
					count = split($2, words, /[[:space:]]+/)
					for (word = 1; word <= count; word++) {
						if (words[word] != "") current[words[word]] = 1
					}
					if (records++ == 0) {
						for (feature in current) common[feature] = 1
					} else {
						for (feature in common) {
							if (!(feature in current)) delete common[feature]
						}
					}
				}
				END {
					for (feature in common) print feature
				}' "${cpuinfo_path}" 2>/dev/null
		)" || return ${?}
		cpu_target_normalize_words "${cpuinfo_features}"
	)  # cpu_target_proc_features

	# glibc exposes the kernel's effective hardware-capability masks without a
	# compiler or a private helper binary.  Keep the values as diagnostics: GCC
	# remains the authority which maps them, CPUID and /proc data to flags it
	# actually supports.
	cpu_target_auxv_capabilities() (
		if command -v getconf >/dev/null 2>&1; then
			getconf AT_HWCAP 2>/dev/null |
				sed 's/^/AT_HWCAP=/'
			getconf AT_HWCAP2 2>/dev/null |
				sed 's/^/AT_HWCAP2=/'
		fi
		if command -v env >/dev/null 2>&1 && [ -x /bin/true ]; then
			env LD_SHOW_AUXV=1 /bin/true 2>&1 |
				awk '$1 == "AT_HWCAP:" { print "AT_HWCAP=" $2 }
					$1 == "AT_HWCAP2:" { print "AT_HWCAP2=" $2 }
					$1 == "AT_HWCAP3:" { print "AT_HWCAP3=" $2 }'
		fi | LC_ALL='C' sort -u
	)  # cpu_target_auxv_capabilities

	# GCC expands its native target to an explicit cc1 option list.  Accept only
	# target switches which are safe to pass back to that compiler, canonicalise
	# their order, and reject any result which would defer interpretation until
	# a later package build or distcc worker.  This is an intermediate expansion:
	# the caller must remove switches which do not change the named CPU target
	# before persisting it in CFLAGS or package-cache metadata.
	cpu_target_parse_gcc_native() (
		probe_arch="${1:-}" probe_output='' probe_options=''
		primary='' tune='' option='' feature_options='' expect_param=0

		probe_output="$( cat )"
		case "${probe_output}" in
			*'COLLECT_GCC_OPTIONS='*) : ;;
			*) return 1 ;;
		esac
		probe_options="$( # <- Syntax
			if printf '%s\n' "${probe_output}" | grep -q '/cc1 '; then
				printf '%s\n' "${probe_output}" |
					sed -n '/\/cc1 /p' |
					tail -n 1 |
					tr -d '"' |
					xargs -rn 1
			else
				printf '%s\n' "${probe_output}" |
					sed -n 's/^COLLECT_GCC_OPTIONS=//p' |
					tail -n 1 |
					tr "'" '\n'
			fi
		)"

		# GCC's native expansion includes host cache geometry as --param values.
		# That is machine topology, not part of the deterministic named CPU target,
		# so consume these options but never persist them.
		while IFS= read -r option; do
			[ -n "${option}" ] || continue
			if [ "${expect_param}" -eq 1 ]; then
				expect_param=0
				continue
			fi
			case "${option}" in
				*-march=native*|*-mcpu=native*|*-mtune=native*) return 1 ;;
				--param) expect_param=1 ;;
				--param=*) : ;;
				-march=*|-mcpu=*)
					case "${option}" in
						*[!A-Za-z0-9_+.,=:-]*) return 1 ;;
					esac
				primary="${option}"
				;;
				-mtune=*)
					case "${option}" in
						*[!A-Za-z0-9_+.,=:-]*) return 1 ;;
					esac
					tune="${option}"
				;;
				-mno-*|-m[a-zA-Z0-9]* )
					case "${option}" in
						-mabi=*|-m32|-m64|-mx32|-mbig-endian|-mlittle-endian) continue ;;
						*[!A-Za-z0-9_+.,=:-]*) return 1 ;;
					 esac
					feature_options="${feature_options}${feature_options:+\n}${option}"
					;;
			esac
		done <<EOF
${probe_options}
EOF

		[ -n "${primary}" ] || return 1
		case "${probe_arch}" in
			x86_64|amd64|i?86|x86)
				case "${primary}" in -march=*) : ;; *) return 1 ;; esac
				;;
			aarch64|arm64|arm*)
				case "${primary}" in -mcpu=*|-march=*) : ;; *) return 1 ;; esac
				;;
		esac

		printf '%s' "${primary}"
		[ -z "${tune}" ] || printf ' %s' "${tune}"
		if [ -n "${feature_options}" ]; then
			printf '%b\n' "${feature_options}" |
				LC_ALL='C' sort -u |
				while IFS= read -r option; do
					printf ' %s' "${option}"
				done
		fi
		printf '\n'
	)  # cpu_target_parse_gcc_native

	# Validate an already-tokenised compiler target before a caller passes its
	# words to a compiler.  In particular, metadata must never reintroduce a
	# host-dependent native target or GCC response-file syntax.
	cpu_target_options_safe() (
		compiler_options="${1:-}" option='' primary=0

		[ -n "${compiler_options}" ] || return 1
		for option in ${compiler_options}; do
			case "${option}" in
				-march=*|-mcpu=*)
					case "${option}" in
						*-march=native*|*-mcpu=native*|*[!A-Za-z0-9_+.,=:-]*)
							return 1
							;;
					esac
					primary=$(( primary + 1 ))
					;;
				-mtune=*)
					case "${option}" in
						*-mtune=native*|*[!A-Za-z0-9_+.,=:-]*) return 1 ;;
					esac
					;;
				-mno-*|-m[a-zA-Z0-9]*)
					case "${option}" in
						-mabi=*|-m32|-m64|-mx32|-mbig-endian|-mlittle-endian)
							return 1
							;;
						*[!A-Za-z0-9_+.,=:-]*) return 1 ;;
					esac
					;;
				*) return 1 ;;
			esac
		done
		[ "${primary}" -eq 1 ]
	)  # cpu_target_options_safe

	# Render GCC's complete effective target state.  The named target and any
	# genuine capability masks affect --help=target; native cache geometry and
	# other target parameters affect --help=params.  Comparing both avoids
	# mistaking a newly verbose driver expansion for a new package ABI boundary.
	cpu_target_gcc_fingerprint() (
		compiler_options="${1:-}"

		cpu_target_options_safe "${compiler_options}" || return 1
		set -f
		# shellcheck disable=SC2086 # Validated compiler-option tokens.
		set -- ${compiler_options}
		LC_ALL='C' gcc "${@}" -Q --help=target \
			-S -x c /dev/null -o /dev/null || return ${?}
		LC_ALL='C' gcc "${@}" -Q --help=params \
			-S -x c /dev/null -o /dev/null
	)  # cpu_target_gcc_fingerprint

	# Start with the named -march/-mcpu option and add an expanded option only
	# when it changes the effective state accumulated so far.  Approaching the
	# native state from the named baseline avoids persisting the many explicit
	# enabled and disabled switches which merely restate that baseline.
	cpu_target_reduce_gcc_options() (
		compiler_options="${1:-}" expected='' primary='' remaining=''
		reduced='' reduced_fingerprint='' option='' trial=''
		trial_fingerprint=''

		cpu_target_options_safe "${compiler_options}" || return 1
		expected="$( cpu_target_gcc_fingerprint \
			"${compiler_options}" )" || return ${?}
		primary="${compiler_options%% *}"
		remaining="${compiler_options#"${primary}"}"
		reduced="${primary}"
		reduced_fingerprint="$( cpu_target_gcc_fingerprint \
			"${primary}" )" || return ${?}
		for option in ${remaining}; do
			trial="${reduced} ${option}"
			trial_fingerprint="$( cpu_target_gcc_fingerprint \
				"${trial}" )" || return ${?}
			if [ "${trial_fingerprint}" != "${reduced_fingerprint}" ]; then
				reduced="${trial}"
				reduced_fingerprint="${trial_fingerprint}"
			fi
		done
		[ "${reduced_fingerprint}" = "${expected}" ] || return 1
		printf '%s\n' "${reduced}"
	)  # cpu_target_reduce_gcc_options

	cpu_target_from_compiler_options() (
		compiler_options="${1:-}" compiler_target=''

		for compiler_target in ${compiler_options}; do
			case "${compiler_target}" in
				-mcpu=*|-march=*)
					compiler_target="${compiler_target#*=}"
					printf '%s\n' "${compiler_target%%+*}"
					return 0
					;;
			esac
		done
		return 1
	)  # cpu_target_from_compiler_options

	cpu_target_rust_known_cpu() (
		case "${1:-}" in
			bonnell|sandybridge|ivybridge|skylake|icelake-server|\
			btver1|btver2|znver2|znver3|znver4|\
			arm1176jzf-s|cortex-a7|cortex-a53|cortex-a55|cortex-a72|\
			cortex-a76|cortex-a720|apple-m1|neoverse-n1|neoverse-n2|\
			neoverse-v1|neoverse-v2)
				return 0
				;;
			*) return 1 ;;
		esac
	)  # cpu_target_rust_known_cpu

	cpu_target_rust_mask_supported() (
		compiler_cpu="${1:-}" missing_features="${2:-}" feature=''

		for feature in ${missing_features}; do
			case "${compiler_cpu}:${feature}" in
				icelake-server:sgx|icelake-server:pku|\
				icelake-server:pconfig|icelake-server:wbnoinvd|\
				neoverse-n2:mte|neoverse-n2:rng|neoverse-n2:ssbs)
					: ;;
				*) return 1 ;;
			esac
		done
		return 0
	)  # cpu_target_rust_mask_supported

	cpu_target_rust_from_gcc() (
		compiler_options="${1:-}" compiler_cpu="${2:-generic}"
		rust_cpu="${3:-generic}" option='' disabled='' rust_feature=''
		modifiers='' modifier=''

		[ "${compiler_cpu}" = "${rust_cpu}" ] || rust_cpu='generic'
		if [ "${rust_cpu}" = 'generic' ]; then
			printf '%s\n' '-C target-cpu=generic'
			return 0
		fi
		for option in ${compiler_options}; do
			case "${option}" in
				-mno-*) rust_feature="${option#-mno-}" ;;
				-mcpu=*+no*)
					modifiers="${option#*+}"
					while IFS= read -r modifier; do
						case "${modifier}" in
							no*) rust_feature="${modifier#no}" ;;
							*) continue ;;
						 esac
						case "${rust_feature}" in
							memtag) rust_feature='mte' ;;
							rng) rust_feature='rand' ;;
						 esac
						case "${compiler_cpu}:${rust_feature}" in
							neoverse-n2:mte|neoverse-n2:rand|neoverse-n2:ssbs) : ;;
							*) continue ;;
						 esac
						disabled="${disabled}${disabled:+,}-${rust_feature}"
					done <<EOF
$( printf '%s\n' "${modifiers}" | tr '+' '\n' )
EOF
					continue
					;;
				*) continue ;;
			esac
			case "${compiler_cpu}:${rust_feature}" in
				icelake-server:sgx|icelake-server:pku|\
				icelake-server:pconfig|icelake-server:wbnoinvd) : ;;
				*) continue ;;
			esac
			disabled="${disabled}${disabled:+,}-${rust_feature}"
		done

		printf '%s' "-C target-cpu=${rust_cpu}"
		[ -z "${disabled}" ] || printf ' -C target-feature=%s' "${disabled}"
		printf '\n'
	)  # cpu_target_rust_from_gcc

	cpu_target_feature_present() (
		available=" ${1:-} " required="${2:-}"

		case "${required}" in
			asimd)
				case "${available}" in
					*' asimd '*|*' neon '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			fma)
				case "${available}" in
					*' fma '*|*' fma3 '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			fma3)
				case "${available}" in
					*' fma '*|*' fma3 '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			mmxext)
				case "${available}" in
					*' mmxext '*|*' sse '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			pclmul)
				case "${available}" in
					*' pclmul '*|*' pclmulqdq '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			popcnt)
				case "${available}" in
					*' abm '*|*' popcnt '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			prefetchw)
				case "${available}" in
					*' 3dnowprefetch '*|*' prefetchw '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			sha)
				case "${available}" in
					*' sha '*|*' sha_ni '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			sse3)
				case "${available}" in
					*' pni '*|*' sse3 '*) return 0 ;;
					*) return 1 ;;
				esac
				;;
			*)
				case "${available}" in
					*" ${required} "*) return 0 ;;
					*) return 1 ;;
				esac
				;;
		esac
	)  # cpu_target_feature_present

	cpu_target_missing_features() (
		available="${1:-}" required_words="${2:-}"
		feature='' missing=''

		for feature in ${required_words}; do
			cpu_target_feature_present "${available}" "${feature}" ||
				missing="${missing:+${missing} }${feature}"
		done
		printf '%s\n' "${missing}"
	)  # cpu_target_missing_features

	cpu_target_gentoo_flags() (
		available="${1:-}" description_path="${2:-}"
		candidate='' candidates='' flag='' line='' remaining='' selected=''

		[ -n "${available}" ] || return 0
		[ -r "${description_path}" ] && [ -s "${description_path}" ] ||
			return 1
		while IFS= read -r line; do
			case "${line}" in
				*' - '*) : ;;
				*) continue ;;
			esac
			flag="${line%% *}"
			candidates="${flag}"
			remaining="${line}"
			while :; do
				case "${remaining}" in
					*'['*']'*)
						remaining="${remaining#*'['}"
						candidate="${remaining%%']'*}"
						[ -n "${candidate}" ] || return 1
						candidates="${candidates} ${candidate}"
						remaining="${remaining#*']'}"
						;;
					*'['*|*']'*) return 1 ;;
					*) break ;;
				esac
			done
			for candidate in ${candidates}; do
				if cpu_target_feature_present "${available}" "${candidate}"; then
					selected="${selected:+${selected} }${flag}"
					break
				fi
			done
		done <"${description_path}" || return ${?}
		cpu_target_normalize_words "${selected}"
	)  # cpu_target_gentoo_flags

	# Return the minimum exposed feature set needed before a model-derived
	# target is accepted.  This is intentionally based on the instructions the
	# selected compiler target may emit, not merely the marketing model string.
	cpu_target_required_features() (
		selected_cpu="${1:-}" selected_opts="${2:-}"
		selected_use_flags="${3:-}" selected_use_arch="${4:-}"
		required='' selected_opt='' disabled_feature=''

		if [ "${selected_use_arch}" = 'x86' ]; then
			required="${selected_use_flags}"
			case "${selected_cpu}" in
			icelake-server)
				# This is the complete named-target boundary.  Runtime masks are
				# represented by the stage3 GCC probe, never by a host-specific
				# permanent exception in the model table.
				required="${required:+${required} }abm adx clflushopt clwb cx16"
				required="${required} fsgsbase fxsr gfni hle lahf_lm movbe"
				required="${required} pconfig pku prefetchw rdpid rdseed sgx"
				required="${required} vaes wbnoinvd xsave xsavec xsaves"
				;;
			znver3)
				# GCC's -march=znver3 enables ISA extensions which do not all
				# have Gentoo CPU_FLAGS_X86 names.  Require the complete
				# compiler-target boundary before accepting a virtual CPU's
				# marketing model.
				required="${required:+${required} }abm adx aes avx avx2 bmi1"
				required="${required} bmi2 clflushopt clwb clzero cx16 f16c"
				required="${required} fma fsgsbase mmx movbe mwaitx pclmulqdq"
				required="${required} pku popcnt prefetchw rdpid rdseed sha"
				required="${required} sse sse2 sse3 sse4_1 sse4_2 sse4a"
				required="${required} ssse3 vaes vpclmulqdq wbnoinvd xsavec xsaves"
				;;
			esac
		else
			case "${selected_cpu}" in
			arm1176jzf-s) required='vfp' ;;
			cortex-a7) required='neon vfpv4' ;;
			cortex-a53|cortex-a72) required='asimd crc32' ;;
			cortex-a76|cortex-a76.cortex-a55)
				required='aes asimd crc32 sha1 sha2'
				;;
			cortex-a720) required='aes asimd crc32 sha2 sha3 sm4 sve2' ;;
			apple-m1) required='asimd asimddp' ;;
			neoverse-n1) required='aes asimd atomics crc32 sha1 sha2' ;;
			neoverse-n2)
				required='asimd asimddp asimdfhm asimdhp asimdrdm atomics'
				required="${required} bf16 crc32 fcma flagm flagm2 fphp frint"
				required="${required} i8mm ilrcpc jscvt mte paca pacg rng sb"
				required="${required} ssbs sve sve2 svebitperm"
				;;
			neoverse-v1) required='aes asimd sha1 sha2 sve' ;;
			neoverse-v2) required='asimd sve2' ;;
			esac
		fi

		case "${selected_opts}" in
			*+nomemtag*)
				required="$( cpu_target_remove_feature "${required}" mte )"
				;;
		esac
		case "${selected_opts}" in
			*+norng*)
				required="$( cpu_target_remove_feature "${required}" rng )"
				;;
		esac
		case "${selected_opts}" in
			*+nossbs*)
				required="$( cpu_target_remove_feature "${required}" ssbs )"
				;;
		esac

		case " ${selected_opts} " in
			*+crypto*) required="${required:+${required} }aes sha1 sha2" ;;
		esac
		case " ${selected_opts} " in
			*' -maes '*) required="${required:+${required} }aes" ;;
		esac
		case " ${selected_opts} " in
			*+crc*) required="${required:+${required} }crc32" ;;
		esac
		case " ${selected_opts} " in
			*sha3*) required="${required:+${required} }sha3" ;;
		esac
		case " ${selected_opts} " in
			*sm4*) required="${required:+${required} }sm4" ;;
		esac
		case " ${selected_opts} " in
			*sve2*) required="${required:+${required} }sve2" ;;
		esac
		for selected_opt in ${selected_opts}; do
			case "${selected_opt}" in
				-mno-*) disabled_feature="${selected_opt#-mno-}" ;;
				*) continue ;;
			esac
			required="$( cpu_target_remove_feature \
				"${required}" "${disabled_feature}" )"
		done

		cpu_target_normalize_words "${required}"
	)  # cpu_target_required_features

	# Set a portable target when the CPU is unknown or a model-derived target
	# requires instructions which the build runner does not expose.  Empty
	# compiler target options are preferable to native detection for target
	# profiles whose ABI already supplies the portable baseline.
	cpu_target_set_generic() {
		ctsg_machine_arch="${1:-}"

		case "${ctsg_machine_arch}" in
			x86_64|amd64)
				use_cpu_arch='x86'
				target_cpu='x86-64'
				cc_target_opts='-march=x86-64 -mtune=generic'
				rust_target_opts='-C target-cpu=generic'
				cpu_target_baseline_flags='mmx sse sse2'
				;;
			i?86|x86)
				use_cpu_arch='x86'
				target_cpu='i686'
				cc_target_opts='-march=i686 -mtune=generic'
				rust_target_opts='-C target-cpu=generic'
				cpu_target_baseline_flags=''
				;;
			aarch64|arm64)
				use_cpu_arch='arm'
				target_cpu='armv8-a'
				cc_target_opts='-march=armv8-a -mtune=generic'
				rust_target_opts='-C target-cpu=generic'
				cpu_target_baseline_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 v4 v5 v6 v7 v8 thumb2'
				;;
			armv7*|arm/v7)
				use_cpu_arch='arm'
				target_cpu='armv7-a'
				cc_target_opts='-march=armv7-a'
				rust_target_opts='-C target-cpu=generic'
				cpu_target_baseline_flags='edsp thumb vfp vfpv3 v4 v5 v6 v7 thumb2'
				;;
			armv6*|arm/v6|arm*)
				use_cpu_arch='arm'
				target_cpu='armv6'
				cc_target_opts='-march=armv6'
				rust_target_opts='-C target-cpu=generic'
				cpu_target_baseline_flags='edsp thumb vfp v4 v5 v6'
				;;
			*)
				printf >&2 "FATAL: No deterministic compiler target is defined for architecture '%s'\n" \
					"${ctsg_machine_arch:-unknown}"
				return 1
				;;
		esac
		unset ctsg_machine_arch
	}  # cpu_target_set_generic
fi

# vi: set colorcolumn=80 syntax=bash sw=4 ts=4:
