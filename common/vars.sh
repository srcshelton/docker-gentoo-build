#! /bin/sh
#shellcheck disable=SC2034

# Set docker image names...
#
env_name="gentoo-env"
stage3_name="gentoo-stage3"
init_name="gentoo-init"
base_name="gentoo-base"
build_name="gentoo-build"

# Default environment-variable filter
#
environment_filter='^(declare -x|export) (COLUMNS|EDITOR|GENTOO_PROFILE|HOME|HOSTNAME|LESS(OPEN)?|LINES|LS_COLORS|(MAN)?PAGER|(OLD)?PWD|PATH|(|SYS|PORTAGE_CONFIG)ROOT|SHLVL|TERM)='

# Define essential USE flags
#
#  dev-lang/perl:		berkdb gdbm ithreads -debug -doc -perl-cleaner
#  dev-libs/openssl:	asm tls-heartbeat zlib
#  sys-apps/busybox:	mdev
# (General:				openssl ssl threads)
#
if command -v cpuid2cpuflags >/dev/null 2>&1; then
	#cpuid2cpuflags | cut -d':' -f 2- | sed 's/ / cpu_flags_x86_/g'
	use_cpu_flags="$( cpuid2cpuflags | cut -d':' -f 2- | sed 's/ / cpu_flags_x86_/g' )"
else
	description="$( grep -E '(model name|Raspberry)' /proc/cpuinfo | sort | tail -n 1 )"
	case "${description}" in
		*': Intel(R) Atom(TM) CPU '*' 330 '*' @ '*)
			use_cpu_flags="cpu_flags_x86_mmx cpu_flags_x86_mmxext cpu_flags_x86_sse cpu_flags_x86_sse2 cpu_flags_x86_sse3 cpu_flags_x86_ssse3" ;;
		*': Intel(R) Core(TM) i3-21'*' CPU @ '*)
			use_cpu_flags="cpu_flags_x86_avx cpu_flags_x86_mmx cpu_flags_x86_mmxext cpu_flags_x86_pclmul cpu_flags_x86_popcnt cpu_flags_x86_sse cpu_flags_x86_sse2 cpu_flags_x86_sse3 cpu_flags_x86_sse4_1 cpu_flags_x86_sse4_2 cpu_flags_x86_ssse3" ;;
		*': Intel(R) Xeon(R) CPU E3-'*' v5 @ '*)
			use_cpu_flags="cpu_flags_x86_aes cpu_flags_x86_avx cpu_flags_x86_avx2 cpu_flags_x86_f16c cpu_flags_x86_fma3 cpu_flags_x86_mmx cpu_flags_x86_mmxext cpu_flags_x86_pclmul cpu_flags_x86_popcnt cpu_flags_x86_rdrand cpu_flags_x86_sse cpu_flags_x86_sse2 cpu_flags_x86_sse3 cpu_flags_x86_sse4_1 cpu_flags_x86_sse4_2 cpu_flags_x86_ssse3" ;;
		*': AMD G-T40E '*)
			use_cpu_flags="cpu_flags_x86_mmx cpu_flags_x86_mmxext cpu_flags_x86_popcnt cpu_flags_x86_sse cpu_flags_x86_sse2 cpu_flags_x86_sse3 cpu_flags_x86_sse4a cpu_flags_x86_ssse3" ;;
		*': AMD GX-412TC '*)
			use_cpu_flags="cpu_flags_x86_aes cpu_flags_x86_avx cpu_flags_x86_f16c cpu_flags_x86_mmx cpu_flags_x86_mmxext cpu_flags_x86_pclmul cpu_flags_x86_popcnt cpu_flags_x86_sse cpu_flags_x86_sse2 cpu_flags_x86_sse3 cpu_flags_x86_sse4_1 cpu_flags_x86_sse4_2 cpu_flags_x86_sse4a cpu_flags_x86_ssse3" ;;
		*': Raspberry Pi 2 '*)
			use_cpu_flags="cpu_flags_arm_edsp cpu_flags_arm_neon cpu_flags_arm_thumb cpu_flags_arm_vfp cpu_flags_arm_vfpv3 cpu_flags_arm_vfpv4 cpu_flags_arm_vfp-d32 cpu_flags_arm_v4 cpu_flags_arm_v5 cpu_flags_arm_v6 cpu_flags_arm_v7 cpu_flags_arm_thumb2" ;;
		*': Raspberry Pi 3 '*)
			use_cpu_flags="cpu_flags_arm_edsp cpu_flags_arm_neon cpu_flags_arm_thumb cpu_flags_arm_vfp cpu_flags_arm_vfpv3 cpu_flags_arm_vfpv4 cpu_flags_arm_vfp-d32 cpu_flags_arm_crc32 cpu_flags_arm_v4 cpu_flags_arm_v5 cpu_flags_arm_v6 cpu_flags_arm_v7 cpu_flags_arm_thumb2" ;;
		*': Raspberry Pi 4 '*)
			use_cpu_flags="cpu_flags_arm_edsp cpu_flags_arm_neon cpu_flags_arm_thumb cpu_flags_arm_vfp cpu_flags_arm_vfpv3 cpu_flags_arm_vfpv4 cpu_flags_arm_vfp-d32 cpu_flags_arm_crc32 cpu_flags_arm_v4 cpu_flags_arm_v5 cpu_flags_arm_v6 cpu_flags_arm_v7 cpu_flags_arm_thumb2" ;;
		*)
			echo >&2 "Unknown CPU '$( echo "${description}" | cut -d':' -f 2- | sed 's/^\s*// ; s/\s*$//' )' - not enabling model-specific CPU flags" ;;
	esac
fi
use_essential="asm ipv6 ithreads mdev openssl ssl threads tls-heartbeat zlib${use_cpu_flags:+ ${use_cpu_flags}}"

# Enable pypy support for Portage accleration of ~35%!
use_pypy_pre="dev-python/pypy dev-python/pypy-exe-bin"
use_pypy="dev-python/pypy3"
use_pypy_use="bzip2 jit"

# Colour options!
#
bold="$( printf '\e[1m' )"
red="$( printf '\e[31m' )"
green="$( printf '\e[32m' )"
blue="$( printf '\e[34m' )"
# Place 'reset' last to prevent coloured xtrace output!
reset="$( printf '\e[0m' )"

# Export portage job-control variables...
#
export JOBS='6'
export MAXLOAD='7.0'

# Optional override to specify alternative build temporary directory
#export TMPDIR=/var/tmp
export TMPDIR=/space/podman/tmp

# Are we using docker or podman?
docker='docker'
#extra_build_args=''
docker_readonly='readonly'
