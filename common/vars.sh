#! /bin/sh
#shellcheck disable=SC2034

# Since we're now using 'podman info' to determine the graphRoot directory, we
# need to be root simply to setup the environment appropriately :(
if [ $(( $( id -u ) )) -ne 0 ]; then
	echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
fi

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
# (General:				ipv6 openssl ssl threads)
#
if command -v cpuid2cpuflags >/dev/null 2>&1; then
	#cpuid2cpuflags | cut -d':' -f 2- | sed 's/ / cpu_flags_x86_/g'
	#use_cpu_flags="$( cpuid2cpuflags | cut -d':' -f 2- | sed 's/ / cpu_flags_x86_/g' )"
	use_cpu_arch="$( uname -m | cut -c 1-3 | sed 's/aar/arm/' )"
	use_cpu_flags="$( cpuid2cpuflags | cut -d':' -f 2- )"
else
	description="$( grep -E '(model name|Raspberry)' /proc/cpuinfo | sort | tail -n 1 )"
	case "${description}" in
		*': Intel(R) Atom(TM) CPU '*' 330 '*' @ '*)
			use_cpu_arch='x86'
			use_cpu_flags="mmx mmxext sse sse2 sse3 ssse3" ;;
		*': Intel(R) Core(TM) i3-21'*' CPU @ '*)
			use_cpu_arch='x86'
			use_cpu_flags="avx mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3" ;;
		*': Intel(R) Xeon(R) CPU E3-'*' v5 @ '*)
			use_cpu_arch='x86'
			use_cpu_flags="aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 ssse3" ;;

		*': AMD G-T40E '*)
			use_cpu_arch='x86'
			use_cpu_flags="mmx mmxext popcnt sse sse2 sse3 sse4a ssse3" ;;
		*': AMD GX-412TC '*)
			use_cpu_arch='x86'
			use_cpu_flags="aes avx f16c mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3" ;;

		*': Raspberry Pi 2 '*)
			use_cpu_arch='arm'
			use_cpu_flags="edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 v4 v5 v6 v7 thumb2" ;;
		*': Raspberry Pi 3 '*)
			use_cpu_arch='arm'
			use_cpu_flags="edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 crc32 v4 v5 v6 v7 thumb2" ;;
		*': Raspberry Pi 4 '*)
			use_cpu_arch='arm'
			use_cpu_flags="edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 crc32 v4 v5 v6 v7 thumb2" ;;

		*)
			echo >&2 "Unknown CPU '$( echo "${description}" | cut -d':' -f 2- | sed 's/^\s*// ; s/\s*$//' )' - not enabling model-specific CPU flags" ;;
	esac
fi
if [ -n "${use_cpu_flags:-}" ]; then
	use_cpu_flags="$(
		echo "${use_cpu_flags}" |
		sed "s/^/cpu_flags_${use_cpu_arch:-x86}_/ ; s/ / cpu_flags_${use_cpu_arch:-x86}_/g"
	)"
fi
use_essential="asm ipv6 ithreads mdev nptl openssl ssl threads tls-heartbeat zlib${use_cpu_flags:+ ${use_cpu_flags}}"

case "$( uname -m )" in
	x86_64|i686)
		# Enable pypy support for Portage accleration of ~35%!
		use_pypy_pre="dev-python/pypy dev-python/pypy-exe-bin"
		use_pypy="dev-python/pypy3"
		use_pypy_use="bzip2 jit"
		;;
esac

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
jobs="$( echo "$( nproc ) 0.75 * p" | dc | cut -d'.' -f 1 )"
: $(( load = $( nproc ) - 1 ))
export JOBS="${jobs}"
export MAXLOAD="${load}.00"
unset load jobs

# Are we using docker or podman?
if ! command -v podman >/dev/null 2>&1; then
	docker='docker'

	#extra_build_args=''
	docker_readonly='readonly'
else
	docker='podman'

	#extra_build_args='--format docker'
	# From release 2.0.0, podman should accept docker 'readonly' attributes
	docker_readonly='ro=true'
fi

# Optional override to specify alternative build temporary directory
#export TMPDIR=/var/tmp
tmp="$( $docker info | grep 'graphRoot:' | cut -d':' -f 2- | awk '{ print $1 }' )/tmp"
mkdir -p "${tmp:=/var/lib/containers/storage/tmp}"
export TMPDIR="${tmp}"

# vi: set nowrap sw=4 ts=4:
