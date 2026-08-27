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

	cpu_target_proc_features() (
		cpuinfo_path="${1:-/proc/cpuinfo}"
		cpuinfo_features=''

		[ -r "${cpuinfo_path}" ] || return 0
		cpuinfo_features="$( # <- Syntax
			awk -F': ' '/^(flags|Features)[[:space:]]*:/ { value = $2 }
				END { print value }' "${cpuinfo_path}" 2>/dev/null
		)"
		cpu_target_normalize_words "${cpuinfo_features}"
	)  # cpu_target_proc_features

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
		candidate='' candidates='' flag='' line='' selected=''

		[ -n "${available}" ] && [ -s "${description_path}" ] || return 0
		while IFS= read -r line; do
			case "${line}" in
				*' - '*) : ;;
				*) continue ;;
			esac
			flag="${line%% *}"
			candidates="${flag} $( # <- Syntax
					printf '%s\n' "${line}" |
						grep -Eo '\[[^][]+\]' |
						tr -d '[]' |
						xargs -r
				)"
			for candidate in ${candidates}; do
				if cpu_target_feature_present "${available}" "${candidate}"; then
					selected="${selected:+${selected} }${flag}"
					break
				fi
			done
		done <"${description_path}"
		cpu_target_normalize_words "${selected}"
	)  # cpu_target_gentoo_flags

	# Return the minimum exposed feature set needed before a model-derived
	# target is accepted.  This is intentionally based on the instructions the
	# selected compiler target may emit, not merely the marketing model string.
	cpu_target_required_features() (
		selected_cpu="${1:-}" selected_opts="${2:-}"
		selected_use_flags="${3:-}" selected_use_arch="${4:-}"
		required=''

		if [ "${selected_use_arch}" = 'x86' ]; then
			required="${selected_use_flags}"
			case "${selected_cpu}" in
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
				required='aes asimd sha1 sha2'
				;;
			cortex-a720) required='aes asimd sha2 sha3 sm4 sve2' ;;
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
