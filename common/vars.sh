#! /bin/sh
#shellcheck disable=SC2034

# Since we're now using 'podman system info' to determine the graphRoot directory, we
# need to be root simply to setup the environment appropriately :(
if [ $(( $( id -u ) )) -ne 0 ]; then
	echo >&2 "FATAL: Please re-run '$( basename "${0}" )' as user 'root'"
	exit 1
fi

# Alerting options...
mail_domain='localhost'
mail_from="portage@${mail_domain}"
mail_to='root@localhost'
mail_mta='localhost'

# Set docker image names...
#
env_name="localhost/gentoo-env"
stage3_name="localhost/gentoo-stage3"
init_name="localhost/gentoo-init"
base_name="localhost/gentoo-base"
build_name="localhost/gentoo-build"

# Set Containerfile, configuration, and entrypoint script relative filesystem
# location...
#
# (N.B. This is different to 'base_name', above)
#
base_dir='gentoo-base'
if ! [ -d "${base_dir}" ]; then
	base_dir=''
fi

# Default environment-variable filter
#
environment_filter='^(declare -x|export) (COLUMNS|EDITOR|GENTOO_PROFILE|HOME|HOSTNAME|LESS(OPEN)?|LINES|LS_COLORS|(MAN)?PAGER|(OLD)?PWD|PATH|(|SYS|PORTAGE_CONFIG)ROOT|SHLVL|TERM)='

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
		*': Intel(R) Core(TM) i5-24'*' CPU @ '*)
			use_cpu_arch='x86'
			use_cpu_flags="aes avx mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3" ;;
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
			echo >&2 "Unknown CPU '$( echo "${description}" | cut -d':' -f 2- | sed 's/^\s*// ; s/\s*$//' )' and 'cpuid2cpuflags' not installed - not enabling model-specific CPU flags" ;;
	esac
fi
if [ -n "${use_cpu_flags:-}" ]; then
	use_cpu_flags_raw="${use_cpu_flags}"
	use_cpu_flags="$(
		echo "${use_cpu_flags_raw}" |
		sed "s/^/cpu_flags_${use_cpu_arch:-x86}_/ ; s/ / cpu_flags_${use_cpu_arch:-x86}_/g"
	)"
fi

# Define essential USE flags
#
# WARNING: Any values defined here will be written into container environment,
#          meaning that they will not be able to be modified without changing
#          the portage USE-flag order of precadence, which has other knock-on
#          effects.
#          Since there are some builds which bring in sizable dependencies when
#          USE="ssl" is active but will never be communicating outside their
#          container or over any network (principally because pacakges depend
#          upon virtual/mta but will actually be using 'postfix' in their own
#          container rather than any container-local binaries) then we may wish
#          not to force this flag here...
#
#  dev-lang/perl:		ithreads
#  dev-libs/openssl:	asm tls-heartbeat zlib
#  net-misc/curl:	   ~curl_ssl_openssl~
#  sys-apps/busybox:	mdev
#  sys-devel/gcc:		nptl
# (General:				ipv6 ~openssl~ ~ssl~ threads)
#
use_essential="asm ipv6 ithreads mdev nptl threads tls-heartbeat zlib${use_cpu_flags:+ ${use_cpu_flags}}"

case "$( uname -m )" in
	x86_64|i686)
		# Enable pypy support for Portage accleration of ~35%!
		use_pypy="dev-python/pypy3"
		use_pypy_use="bzip2 jit"
		if [ $(( $( grep -m 1 'MemTotal:' /proc/meminfo | awk '{ print $2 }' ) / 1024 / 1024 )) -gt 6 ]; then
			use_pypy="${use_pypy} dev-python/pypy3-exe"
		else
			use_pypy="${use_pypy} dev-python/pypy3-exe-bin"
			use_pypy_use="${use_pypy_use} low-memory"
		fi
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

# Allow a separate image directory for persistent images...
#store="$( $docker system info | grep -F 'overlay.imagestore:' | cut -d':' -f 2- | awk '{ print $1 }' )"
#if [ -n "${store}" ]; then
#	export IMAGE_ROOT="${store}"
#	store="$( $docker system info | grep 'graphRoot:' | cut -d':' -f 2- | awk '{ print $1 }' )"
#	if [ -n "${store}" ]; then
#		export GRAPH_ROOT="${store}"
#	fi
#fi
#unset store

# Optional override to specify alternative build temporary directory
#export TMPDIR=/var/tmp
tmp="$( $docker system info | grep 'graphRoot:' | cut -d':' -f 2- | awk '{ print $1 }' )/tmp"
mkdir -p "${tmp:=/var/lib/containers/storage/tmp}"
export TMPDIR="${tmp}"

python_default_target='python3_9'

if [ -f common/local.sh ]; then
	# shellcheck disable=SC1091
	. common/local.sh
	export JOBS MAXJOBS TMPDIR
fi

# vi: set nowrap sw=4 ts=4:
