#! /bin/sh
# shellcheck disable=SC2034

# Are we using docker or podman?
#
# N.B. This is overridden if/when common/run.sh is included
#
if [ -z "${_command:-}" ]; then
	if command -v podman >/dev/null 2>&1; then
		_command='podman'

		#extra_build_args='--format docker'
		# From release 2.0.0, podman should accept docker 'readonly'
		# attributes
		docker_readonly='ro=true'
	elif command -v docker >/dev/null 2>&1; then
		_command='docker'

		#extra_build_args=''
		docker_readonly='readonly'
	else
		echo >&2 "FATAL: Cannot find 'docker' or 'podman' executable in path" \
			"in common/vars.sh"
		exit 1
	fi
	export _command docker_readonly
fi

# Since we're now using '${_command} system info' to determine the graphRoot
# directory, we need to be root solely to setup the environment
# appropriately :(
#
_output=''
rc=0
if ! [ -x "$( command -v "${_command}" )" ]; then
	echo >&2 "FATAL: Cannot locate binary '${_command}'"
	exit 1
elif ! _output="$( "${_command}" info 2>&1 )"; then
	"${_command}" info 2>&1 || rc=${?}
	if [ "${_command}" = 'podman' ]; then
		echo >&2 "FATAL: Unable to successfully execute '${_command}'" \
			"(${rc}) - do you need to run '${_command} machine start' or" \
			"re-run '$( basename "${0}" )' as 'root'?"
	else
		echo >&2 "FATAL: Unable to successfully execute '${_command}'" \
			"(${rc}) - do you need to re-run '$( basename "${0}" )' as 'root'?"
	fi
	exit 1
elif [ "$( uname -s )" != 'Darwin' ] &&
		[ $(( $( id -u ) )) -ne 0 ] &&
		echo "${_output}" | grep -Fq -- 'rootless: false'
then
	echo >&2 "FATAL: Please re-run '$( basename "${0}")' as user 'root'"
	exit 1
fi
unset _output

# Guard to ensure that we don't accidentally reset the values below through
# multiple inclusion - 'unset __COMMON_VARS_INCLUDED' if this is explcitly
# required...
#
if [ -z "${__COMMON_VARS_INCLUDED:-}" ]; then
	export __COMMON_VARS_INCLUDED=1

	# Optional override to specify alternative build-only temporary
	# directory...
	#
	# N.B. If 'pam_mktemp.so' is in-use then there will always be a set 'TMP'
	#      and 'TMPDIR' in the environment.
	#
	if [ "$( uname -s )" != 'Darwin' ]; then
		graphroot=''

		if [ -n "${PODMAN_TMPDIR:-}" ]; then
			[[ -z "${debug:-}" ]] ||
				echo >&2 "DEBUG: Setting PODMAN_TMPDIR ('${PODMAN_TMPDIR}')" \
					"as temporary directory ..."
		else
			# Since we're now using '${_command} system info' to determine the
			# graphRoot directory, we need to be rootless or root solely to setup
			# the environment appropriately :(
			#
			_output=''
			if ! [ -x "$( command -v "${_command}" )" ]; then
				echo >&2 "FATAL: Cannot locate binary '${_command}'"
				exit 1
			elif ! _output="$( "${_command}" system info 2>&1 )"; then
				if [ "${_command}" = 'podman' ]; then
					echo >&2 "FATAL: Unable to successfully execute '${_command}' - do" \
						"you need to run '${_command} machine start' or re-run" \
						"'$( basename "${0}" )' as 'root'?"
				else
					echo >&2 "FATAL: Unable to successfully execute '${_command}' - do" \
						"you need to re-run '$( basename "${0}" )' as 'root'?"
				fi
				exit 1
			elif [ $(( $( id -u ) )) -ne 0 ] &&
					echo "${_output}" | grep -Fq -- 'rootless: false'
			then
				echo >&2 "FATAL: Please re-run '$( basename "${0}")' as user 'root'"
				exit 1
			fi

			graphroot="$( # <- Syntax
					echo "${_output}" |
						grep -E -- '(graphRoot|Docker Root Dir):' |
						cut -d':' -f 2- |
						awk '{ print $1 }'
				)" || :
			if [ -z "${graphroot:-}" ]; then
				echo >&2 "FATAL: Cannot determine ${_command} root directory"
				exit 1
			fi

			unset _output
		fi

		tmp="${PODMAN_TMPDIR:-"${graphroot}"}/tmp"
		mkdir -p "${tmp:="/var/lib/containers/storage/tmp"}"
		export TMPDIR="${tmp}"
		export TMP="${tmp}"
		unset tmp graphroot
	fi

	# Alerting options...
	#
	mail_domain='localhost'
	mail_from="portage@${mail_domain}"
	mail_to='root@localhost'
	mail_mta='localhost'
	export mail_domain mail_from mail_to mail_mta

	# Set docker image names...
	#
	env_name='localhost/gentoo-env'
	stage3_name='localhost/gentoo-stage3'
	init_name='localhost/gentoo-init'
	base_name='localhost/gentoo-base'
	build_name='localhost/gentoo-build'
	export env_name stage3_name init_name base_name build_name

	# Set locations for inherited data...
	#
	stage3_flags_file='/usr/libexec/stage3_flags.sh'
	environment_file='/usr/libexec/environment.sh'
	export stage3_flags_file environment_file

	# Default environment-variable filter
	#
	environment_filter='^(declare -x|export) (COLUMNS|EDITOR|GENTOO_PROFILE|HOME|HOSTNAME|LESS(OPEN)?|LINES|LS_COLORS|(MAN)?PAGER|(OLD)?PWD|PATH|(|SYS|PORTAGE_CONFIG)ROOT|SHLVL|TERM)='
	export environment_filter

	# Set Containerfile, configuration, and entrypoint script relative
	# filesystem location...
	#
	# (N.B. This is different to 'base_name', above)
	#
	base_dir='gentoo-base'
	export base_dir
	if ! [ -d "${base_dir}" ]; then
		#base_dir=''
		unset base_dir
	fi

	use_cpu_arch='' use_cpu_flags='' use_cpu_flags_raw=''
	gcc_target_opts='-march=native' description='' vendor='' sub_cpu_arch=''
	# rpi-cm rpi-cm2 rpi-cm3 rpi-cm4s
	# rpi0 rpi02 rpi2 rpi3 rpi4 rpi400 rpi-cm4 rpi5 rpi-cm5 rpi500
	rpi_model=''

	use_cpu_arch="$( uname -m | cut -c 1-3 | sed 's/aar/arm/' )"
	case "$( uname -m )" in
		aarch64)	sub_cpu_arch='arm64' ;;
		x86_64)		sub_cpu_arch='amd64' ;;
	esac
	if command -v cpuid2cpuflags >/dev/null 2>&1; then
		use_cpu_flags="$( cpuid2cpuflags | cut -d':' -f 2- )"
	else
		# N.B. 'uname -s' returns 'Linux' in Darwin podman-machine...
		if [ "$( uname -s )" = 'Darwin' ]; then
			description="$( sysctl -n machdep.cpu.brand_string )"
		elif [ -s /sys/firmware/devicetree/base/model ]; then
			description="$( # <- Syntax
				printf ': '
				tr -d '\0' < /sys/firmware/devicetree/base/model
			)" || :
		elif [ -s /proc/device-tree/model ]; then
			description="$( # <- Syntax
				printf ': '
				tr -d '\0' < /proc/device-tree/model
			)" || :
		else
			description="$( # <- Syntax
				grep -E '(model name|Raspberry)' /proc/cpuinfo |
					sort |
					tail -n 1
			)" || :
		fi
		if [ -z "${description:-}" ]; then
			# TODO: Is this a good UID to use (without further checks)?
			description="$( # <- Syntax
				grep -F 'CPU part' /proc/cpuinfo |
					sort |
					tail -n 1
			)" || :
		fi
		if [ -z "${description:-}" ] || echo "${description}" | grep -q '0x0\+'
		then
			description="$( # <- Syntax
				grep -F \
							-e 'CPU implementer' \
							-e 'CPU architecture' \
						/proc/cpuinfo |
					sort -r |
					uniq |
					cut -d':' -f 2 |
					awk '{print $1}' |
					xargs -r
			)" || :
		fi

		# Find '-march=native' flags:
		# diff <(g++ -march=<arch> -Q --help=target --help=params) <(g++ -march=native -Q --help=target --help=params)
		case "${description:-}" in
			*': Intel(R) Atom(TM) CPU '*' 330 '*' @ '*)
				use_cpu_arch='x86'
				use_cpu_flags='mmx mmxext sse sse2 sse3 ssse3'
				gcc_target_opts='-march=bonnell'
				rust_target_opts='-C target-cpu=bonnell' ;;
			*': Intel(R) Core(TM) i3-21'*' CPU @ '*)
				use_cpu_arch='x86'
				use_cpu_flags='avx mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3'
				gcc_target_opts='-march=sandybridge'
				rust_target_opts='-C target-cpu=sandybridge' ;;
			*': Intel(R) Core(TM) i5-24'*' CPU @ '*)
				use_cpu_arch='x86'
				use_cpu_flags='aes avx mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 ssse3'
				gcc_target_opts='-march=sandybridge -maes'
				rust_target_opts='-C target-cpu=sandybridge' ;;
			*': Intel(R) Xeon(R) CPU E5-'*' v2 @ '*)
				use_cpu_arch='x86'
				use_cpu_flags='aes avx f16c mmx mmxext pclmul popcnt rdrand sse sse2 sse4_1 sse4_2 ssse3'
				gcc_target_opts='-march=ivybridge -maes'
				rust_target_opts='-C target-cpu=ivybridge' ;;
			*': Intel(R) Xeon(R) CPU E3-'*' v5 @ '*)
				use_cpu_arch='x86'
				use_cpu_flags='aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sse sse2 sse3 sse4_1 sse4_2 ssse3'
				gcc_target_opts='-march=skylake -mabm'
				rust_target_opts='-C target-cpu=skylake' ;;

			*': AMD G-T40E '*)
				use_cpu_arch='x86'
				use_cpu_flags='mmx mmxext popcnt sse sse2 sse3 sse4a ssse3'
				gcc_target_opts='-march=btver1'
				rust_target_opts='-C target-cpu=btver1' ;;
			*': AMD GX-412TC '*)
				use_cpu_arch='x86'
				use_cpu_flags='aes avx f16c mmx mmxext pclmul popcnt sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3'
				gcc_target_opts='-march=btver2'
				rust_target_opts='-C target-cpu=btver2' ;;
			*': AMD EPYC 7R32')
				use_cpu_arch='x86'
				use_cpu_flags='aes avx avx2 f16c fma3 mmx mmxext pclmul popcnt rdrand sha sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3'
				gcc_target_opts='-march=znver2'
				rust_target_opts='-C target-cpu=znver2' ;;
			*': AMD EPYC 9R14')
				use_cpu_arch='x86'
				use_cpu_flags='aes avx avx2 avx512_bf16 avx512_bitalg avx512_vbmi2 avx512_vnni avx512_vpopcntdq avx512bw avx512cd avx512dq avx512f avx512ifma avx512vbmi avx512vl f16c fma3 mmx mmxext pclmul popcnt rdrand sha sse sse2 sse3 sse4_1 sse4_2 sse4a ssse3 vpclmulqdq'
				gcc_target_opts='-march=znver4'
				rust_target_opts='-C target-cpu=znver4' ;;

			# ARM CPUs: Only sci-libs/blis seems to make use of
			# v{x} flags, and v9 isn't yet referenced (although
			# 'sve' is...)
			#
			*': Raspberry Pi Zero W Rev 1.1'*)
				# ARMv6, 32bit
				use_cpu_arch='arm'
				use_cpu_flags='edsp thumb vfp v4 v5 v6'
				gcc_target_opts='-mcpu=arm1176jzf-s -mfpu=vfp'
				rust_target_opts='-C target-cpu=arm1176jzf-s'
				rpi_model='rpi0' ;;
			*': Raspberry Pi 2 '*)
				# ARMv7, 32bit
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 v4 v5 v6 v7 thumb2'
				gcc_target_opts='-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mneon-for-64bits -mthumb'
				rust_target_opts='-C target-cpu=cortex-a7'
				rpi_model='rpi2' ;;
			*': Raspberry Pi 3 '*|*': Raspberry Pi Zero 2 W '*)
				# ARMv8, 64bit (no longer needs '-mneon-for-64bits', '-mfpu=*')
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 crc32 v4 v5 v6 v7 thumb2'
				gcc_target_opts='-mcpu=cortex-a53+crc'
				rust_target_opts='-C target-cpu=cortex-a53'
				case "${description}" in
					*': Raspberry Pi 3 '*)
						rpi_model='rpi3' ;;
					*': Raspberry Pi Zero 2 W '*)
						rpi_model='rpi02' ;;
				esac ;;
			*': Raspberry Pi 4 '*|*': Raspberry Pi Compute Module 4 '*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 crc32 v4 v5 v6 v7 v8 thumb2'
				gcc_target_opts='-mcpu=cortex-a72+crc'
				rust_target_opts='-C target-cpu=cortex-a72'
				case "${description}" in
					*': Raspberry Pi 4 '*)
						rpi_model='rpi4' ;;
					*': Raspberry Pi Compute Module 4 '*)
						rpi_model='rpi-cm4' ;;
				esac ;;
			*': Raspberry Pi 400 '*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 crc32 v4 v5 v6 v7 v8 thumb2'
				gcc_target_opts='-mcpu=cortex-a72+crc'
				rust_target_opts='-C target-cpu=cortex-a72'
				rpi_model='rpi400' ;;
			*': Raspberry Pi 5 '*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp v4 v5 v6 v7 v8 thumb2'
				gcc_target_opts='-mcpu=cortex-a76+crc+crypto'
				rust_target_opts='-C target-cpu=cortex-a76'
				rpi_model='rpi5' ;;
			*': Raspberry Pi 500 '*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp v4 v5 v6 v7 v8 thumb2'
				gcc_target_opts='-mcpu=cortex-a76+crc+crypto'
				rust_target_opts='-C target-cpu=cortex-a76'
				rpi_model='rpi500' ;;

			*': Mixtile Blade 3'*|*': Rockchip RK3588')
				# ARMv8, big.LITTLE
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp v4 v5 v6 v7 v8 thumb2'
				gcc_target_opts='-mcpu=cortex-a76.cortex-a55+aes+crc+crypto+sha2'
				# Unlike gcc, clang/rust don't support heterogeneous systems
				# and so the best we can do is to optimise for the smallest
				# LITTLE core(s) and above, with a potential under-optimisation
				# of the big cores...
				rust_target_opts='-C target-cpu=cortex-a55' ;;

			*': 0xd07'|'0x61 8'|'Apple M1'*)
				use_cpu_arch='arm'
				use_cpu_flags='aes crc32 sha1 sha2'
				#gcc_target_opts='-march=armv8-a'
				rust_target_opts='-C target-cpu=apple-m1' ;;
			*': 0xd0c'|'Ampere Altra'*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp v4 v5 v6 v7 v8 thumb2'
				#gcc_target_opts='-march=armv8-a'
				rust_target_opts='-C target-cpu=neoverse-n1' ;;
			*': 0xd40'|'AWS Graviton 3'*)
				use_cpu_arch='arm'
				use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 sm4 asimddp sve i8mm v4 v5 v6 v7 v8 thumb2'
				# Requires GCC11+, clang14+
				gcc_target_opts='-march=zeus+crypto+sha3+sm4+nodotprod+noprofile+nossbs -mcpu=zeus'
				rust_target_opts='-C target-cpu=neoverse-v1' ;;
			*': 0xd4f'|'AWS Graviton 4'*)
				use_cpu_arch='arm'
				# Requires GCC13+, clang16+
				rust_target_opts='-C target-cpu=neoverse-v2'

				# We're at the limit of the data we can get from /proc/cpuinfo,
				# so let's see whether this is enough of a differentiator
				# before having to parse the output of 'lscpu'...
				case "$( grep 'CPU revision' /proc/cpuinfo | sort | uniq | cut -d':' -f 2 | awk '{print $1}' )" in
					'0')
						# GH200 (via qemu):
						gcc_target_opts='-mcpu=neoverse-v2+crypto+sve2-sm4+sve2-aes+sve2-sha3+norng+nomemtag+nopredres'
						use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 sm4 asimddp sve i8mm v4 v5 v6 v7 v8 thumb2' # v9
						;;
					'1')
						# AWS Graviton 4:
						gcc_target_opts='-mcpu=neoverse-v2+crc+sve2-aes+sve2-sha3+nossbs'
						use_cpu_flags='edsp neon thumb vfp vfpv3 vfpv4 vfp-d32 aes sha1 sha2 crc32 asimddp sve i8mm v4 v5 v6 v7 v8 thumb2' # v9
						;;
				esac
				;;
			*)
				description="$( # <- Syntax
					echo "${description}" |
						cut -d':' -f 2- |
						sed 's/^\s*// ; s/\s*$//'
				)"
				vendor="$( # <- Syntax
					grep -- '^vendor_id' /proc/cpuinfo |
						tail -n 1 |
						awk -F': ' '{ print $2 }'
				)" || :
				if [ -z "${vendor:-}" ]; then
					vendor="$( # <- Syntax
						grep -- '^CPU implementer' /proc/cpuinfo |
							tail -n 1 |
							awk -F': ' '{ print $2 }' |
							sed 's/^0x41$/Ampere/'
					)"
				fi
				if [ -r /proc/cpuinfo ]; then
					case "${vendor}" in
						GenuineIntel)
							#echo >&2 "Attempting to auto-discover CPU '${description}' capabilities..."
							use_cpu_arch='x86'

							if
								[ -f /var/db/repo/gentoo/profiles/desc/cpu_flags_x86.desc ] &&
								[ -s /var/db/repo/gentoo/profiles/desc/cpu_flags_x86.desc ]
							then
								use_cpu_flags=''

								# FIXME: Hard-coded /var/db/repo/gentoo...
								while read -r line; do
									echo "${line}" | grep -q -- ' - ' || continue

									flag="$( echo "${line}" | awk -F' - ' '{ print $1 }' )"
									if echo "${line}" | grep "^${flag} - " | grep -Fq -- '[' ; then
										count=2
										while true; do
											extra="$( # <- Syntax
												echo "${line}" |
													awk -F'[' "{ print \$${count} }" |
													cut -d']' -f 1
											)"
											if [ -n "${extra:-}" ]; then
												flag="${flag}|${extra}"
											else
												break
											fi
											: $(( count = count + 1 ))
										done
										unset extra count
									fi
									use_cpu_flags="${use_cpu_flags:-}$( # <- Syntax
										grep -E -- '^(Features|flags)' /proc/cpuinfo |
												tail -n 1 |
												awk -F': ' '{ print $2 }' |
												grep -Eq -- "${flag}" &&
											echo " ${flag}" | cut -d'|' -f 1
									)"
								done < /var/db/repo/gentoo/profiles/desc/cpu_flags_x86.desc

								use_cpu_flags="${use_cpu_flags#" "}"
								echo >&2 "Auto-discovered CPU feature-flags '${use_cpu_flags}'"
							fi
							;;
					esac
				fi

				if [ -z "${use_cpu_flags:-}" ]; then
					echo >&2 "Unknown CPU '${description}' and 'cpuid2cpuflags' not installed - not enabling model-specific CPU flags"
				fi
				;;
		esac
		unset vendor description
	fi
	if [ -n "${use_cpu_flags:-}" ]; then
		use_cpu_flags_raw="${use_cpu_flags}"
		use_cpu_flags="$( # <- Syntax
			echo "${use_cpu_flags_raw}" |
				sed "s/^/cpu_flags_${use_cpu_arch:-"x86"}_/ ; s/ / cpu_flags_${use_cpu_arch:-"x86"}_/g"
		)"
	fi
	case "${use_cpu_arch:-"x86"}" in
		arm)
			if [ -z "${sub_cpu_arch:-}" ]; then
				gcc_target_opts="${gcc_target_opts:+"${gcc_target_opts} "}-mfloat-abi=hard"
			fi
			;;
	esac
	export use_cpu_arch use_cpu_flags gcc_target_opts rust_target_opts

	# Define essential USE flags
	#
	# WARNING: Any values defined here will be written into container
	#          environment, meaning that they will not be able to be modified
	#          without changing the portage USE-flag order of precadence, which
	#          has other knock-on effects.
	#          Since there are some builds which bring in sizable dependencies
	#          when USE="ssl" is active but will never be communicating outside
	#          their container or over any network (principally because
	#          pacakges depend upon virtual/mta but will actually be using
	#          'postfix' in their own container rather than any container-local
	#          binaries) then we may wish not to force this flag here...
	#
	#  dev-lang/perl:	    perl_features_ithreads
	#  dev-libs/openssl:    asm ktls ~tls-heartbeat~ ~zlib~
	#  net-misc/curl:	   ~curl_ssl_openssl~
	#  sys-apps/busybox:    mdev
	#  sys-apps/portage:    native-extensions
	# (sys-devel/gcc:	   ~nptl~ ssp)
	#  sys-libs/glibc	    multiarch ssp
	# (General:			    ipv6 ~openssl~ split-usr ~ssl~ threads)
	#
	use_essential="${rpi_model:+"${rpi_model} "}asm ipv6 perl_features_ithreads ktls mdev multiarch native-extensions split-usr ssp threads${use_cpu_flags:+" ${use_cpu_flags}"}"
	export use_essential
	unset rpi_model

	# Even though we often want a minimal set of flags, gcc's flags are
	# significant since they may affect the compiler facilities available to
	# all packages built later...
	#
	# N.B. USE='graphite' pulls-in dev-libs/isl which we don't want for host
	#      packages, but is reasonable for build-containers.
	#
	# FIXME: Source these flags from package.use
	#
	use_essential_gcc="default-stack-clash-protection default-znow graphite -jit nptl openmp pch pie -sanitize ssp -vtv zstd"
	export use_essential_gcc

	case "$( uname -m )" in
		x86_64|i686)
			: $(( memtotal = $( grep -m 1 'MemTotal:' /proc/meminfo | awk '{ print $2 }' ) / 1024 / 1024 ))
			# memtotal is rounded-down, so 4GB systems have a memtotal of 3...
			if [ $(( memtotal )) -ge 4 ]; then
				# Enable pypy support for Portage accleration of ~35%!
				pkg_pypy="dev-lang/pypy"
				pkg_pypy_use="bzip2 jit"
				pkg_pypy_post_remove="dev-lang/python:2.7"
				# Update: dev-python/pypy3_10-exe-7.3.12_p2 now requires 10GB
				#         RAM in order to build successfully :(
				if [ $(( memtotal )) -gt 9 ]; then
					pkg_pypy="${pkg_pypy} dev-python/pypy3_10-exe"
				else
					# On a system with 4GB of memory and python3.11, the
					# install process for dev-python/pypy3-7.3.11_p1 now hangs
					# indefinitely after issuing a message reading:
					#concurrent.futures.process.BrokenProcessPool: A process in the process pool was terminated abruptly while the future was running or pending.
					pkg_pypy="${pkg_pypy} dev-python/pypy3_10-exe-bin"
					pkg_pypy_use="${pkg_pypy_use} low-memory"
				fi
				export pkg_pypy pkg_pypy_use pkg_pypy_post_remove
			fi
			unset memtotal
			;;
	esac

	# Colour options!
	#
	bold="$( printf '\e[1m' )"
	red="$( printf '\e[31m' )"
	green="$( printf '\e[32m' )"
	blue="$( printf '\e[34m' )"
	purple="$( printf '\e[35m' )"
	# Place 'reset' last to prevent coloured xtrace output!
	reset="$( printf '\e[0m' )"
	export bold red green blue purple reset

	# Export portage job-control variables...
	#
	: $(( jobs = $( nproc ) ))
	: $(( load = jobs ))
	if [ $(( jobs )) -ge 2 ]; then
		: $(( load = load - 1 ))

		if command -v dc >/dev/null 2>&1; then
			jobs="$( echo "${jobs} 0.75 * p" | dc | cut -d'.' -f 1 )"
		else
			: $(( jobs = jobs - 1 ))
		fi
	fi
	export JOBS="${EMERGE_JOBS:-"${jobs}"}"
	export MAXLOAD="${EMERGE_MAXLOAD:-"${load}.00"}"
	unset load jobs

	# Allow a separate image directory for persistent images...
	#store="$( $_command system info | grep -F 'overlay.imagestore:' | cut -d':' -f 2- | awk '{ print $1 }' )"
	#if [ -n "${store}" ]; then
	#	export IMAGE_ROOT="${store}"
	#	store="$( $_command system info | grep 'graphRoot:' | cut -d':' -f 2- | awk '{ print $1 }' )"
	#	if [ -n "${store}" ]; then
	#		export GRAPH_ROOT="${store}"
	#	fi
	#fi
	#unset store

	python_default_target='python3_12'
	export python_default_target

	php_default_target='php8-2'
	export php_default_target

	if [ -f common/local.sh ]; then
		# shellcheck disable=SC1091
		. common/local.sh
	fi
fi

# vi: set colorcolumn=80 nowrap sw=4 ts=4:
