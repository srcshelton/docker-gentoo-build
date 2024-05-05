#! /bin/sh
# shellcheck disable=SC2030,SC2031

# entrypoint.sh

set -eu

# shellcheck disable=SC2034
debug=${DEBUG:-}
# shellcheck disable=SC2034
trace=${TRACE:-}

DEFAULT_JOBS="${DEFAULT_JOBS:-"__JOBS__"}"
DEFAULT_MAXLOAD="${DEFAULT_MAXLOAD:-"__MAXLOAD__"}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-"__PROFILE__"}"
stage3_flags_file="${stage3_flags_file:-"__FLAGSFILE__"}"
environment_file="${environment_file:-"__ENVFILE__"}"
environment_filter="${environment_filter:-"__ENVFILTER__"}"

python_default_targets='python3_11'
stage3_flags=''

export arch="${ARCH}"
unset -v ARCH

die() {
	printf >&2 'FATAL: %s\n' "${*:-"Unknown error"}"
	exit 1
}  # die

warn() {
	[ -z "${*:-}" ] && echo || printf >&2 'WARN:  %s\n' "${*}"
}  # warn

info() {
	[ -z "${*:-}" ] && echo || printf 'INFO:  %s\n' "${*}"
}  # info

print() {
	if [ -n "${DEBUG:-}" ]; then
		if [ -z "${*:-}" ]; then
			echo >&2
		else
			printf >&2 'DEBUG: %s\n' "${*}"
		fi
	fi
}  # print

# POSIX sh doesn't support 'export -f'...
format_fn_code="$( cat <<'EOF'
format() {
	format_spaces='' format_string=''

	# Pad $format_variable to $format_padding trailing spaces
	#
	format_variable="${1:-}"
	format_padding="${2:-"20"}"

	[ -n "${format_variable:-}" ] || return 1

	format_variable="$( # <- Syntax
		echo "${format_variable}" | xargs -rn 1 | sort -d | xargs -r
	)"
	format_spaces="$( printf "%${format_padding}s" )"
	format_string="%-${format_padding}s= \"%s\"\\n"

	# shellcheck disable=SC2059
	printf "${format_string}" "${format_variable}" "$( # <- Syntax
		cat - |
			grep -- "^${format_variable}=" |
			cut -d'"' -f 2 |
			fmt -w $(( ${COLUMNS:-"80"} - ( format_padding + 3 ) )) |
			sed "s/^/   ${format_spaces}/ ; 1 s/^\s\+//"
	)"

	unset format_string format_spaces format_padding format_variable

	return 0
}  # format
EOF
)"
export format_fn_code
eval "${format_fn_code}"

check() {
	#inherit ROOT
	check_rc="${1:-}" ; shift

	# Check that a given check_pkg (with build result code $check_rc) is
	# actually installed...
	#
	[ -n "${check_rc:-}" ] || return 1

	check_pkg='' check_arg=''

	if [ $(( check_rc )) -eq 0 ]; then
		# Process first package of list only...
		#
		for check_arg in "${@}"; do
			case "${check_arg}" in
				-*)	continue ;;
				*)	check_pkg="${check_arg}" ; break ;;
			esac
		done
		check_pkg="$( echo "${check_pkg}" | sed -r 's/^[^a-z]+([a-z])/\1/' )"
		if echo "${check_pkg}" | grep -Fq -- '/'; then
			if ! ls -1d \
					"${ROOT:-}/var/db/pkg/${check_pkg%"::"*}"* >/dev/null 2>&1
			then
				die "emerge indicated success but package" \
					"'${check_pkg%"::"*}' does not appear to be installed"
			fi
		else
			if ! ls -1d \
					"${ROOT:-}/var/db/pkg"/*/"${check_pkg%"::"*}"* >/dev/null 2>&1
			then
				die "emerge indicated success but package" \
					"'${check_pkg%"::"*}' does not appear to be installed"
			fi
		fi
	fi

	unset check_pkg check_arg

	# shellcheck disable=SC2086
	return ${check_rc}
}  # check

get_stage3() {
	# Extract a given list of get_values from the saved stage3 data...
	#
	get_arg='' get_type='' get_cache=0 get_values=0

	for get_arg in "${@:-}"; do
		case "${get_arg}" in
			--cache|--cache-only|-c)
				get_cache=1 ;;
			--values|--values-only|-v)
				get_values=1 ;;
			USE|STAGE3_USE)
				get_type='USE' ;;
			PYTHON_SINGLE_TARGET|STAGE3_PYTHON_SINGLE_TARGET)
				get_type='PYTHON_SINGLE_TARGET' ;;
			PYTHON_TARGETS|STAGE3_PYTHON_TARGETS)
				get_type='PYTHON_TARGETS' ;;
			*)
				warn "Invalid 'stage3' variable '${get_type}' from arguments" \
					"'${*:-}'"
				return 1
				;;
		esac
	done

	unset get_arg

	if [ $(( get_cache )) -eq 0 ] && [ -z "${get_type:-}" ]; then
		return 1
	fi

	get_result=''

	if [ -z "${stage3_flags:-}" ]; then
		stage3_flags="$( cat "${stage3_flags_file}" )"
		export stage3_flags

		print "Caching stage3 data ..."
	else
		print "Using get_cached stage3 data ..."
	fi

	if [ $(( get_cache )) -ne 0 ]; then
		return 0
	fi
	unset get_cache

	get_result="$( # <- Syntax
		echo "${stage3_flags}" |
			grep -- "^STAGE3_${get_type}=" |
			cut -d'"' -f 2
	)" # ' # <- Syntax
	print "get_stage3 get_result for '${get_type}' is '${get_result}'"

	if [ "${get_type}" = 'USE' ]; then
		# Remove USE flags which apply to multiple packages, but can only be
		# present for one package per installation ROOT...
		get_result="$( # <- Syntax
			get_exclude='cet|cpudetection|egrep-fgrep|ensurepip|fortran|hostname|installkernel|kill|pcre16|pcre32|pop3|qmanifest|qtegrity|smartcard|su|test-rust|tmpfiles|tofu'
			echo "${get_result}" |
				xargs -rn 1 |
				grep -Ev "^(${get_exclude})$" |
				xargs -r
			unset get_exclude
		)"
		print "get_stage3 get_result for USE('${get_type}') after filter is '${get_result}'"

		entries='' entry=''
		entries="$( # <- Syntax
			echo "${stage3_flags}" |
				grep -- '^STAGE3_PYTHON_SINGLE_TARGET=' |
				cut -d'"' -f 2
		)" # ' # <- Syntax
		print "get_stage3 entries for SINGLE_TARGET is '${entries}'"

		for entry in ${entries}; do
			get_result="${get_result:+"${get_result} "}python_single_target_${entry}"
		done
		print "get_stage3 get_result for USE('${get_type}') after single is '${get_result}'"

		entries="$( # <- Syntax
			echo "${stage3_flags}" |
				grep -- '^STAGE3_PYTHON_TARGETS=' |
				cut -d'"' -f 2
		)" # ' # <- Syntax
		print "get_stage3 entries for TARGETS is '${entries}'"

		for entry in ${entries}; do
			get_result="${get_result:+"${get_result} "}python_targets_${entry}"
		done
		print "get_stage3 get_result for USE('${get_type}') after targets is '${get_result}'"

		unset entry entires
	fi

	if [ -z "${get_result:-}" ]; then
		unset get_result get_values get_type
		return 1
	fi
	if [ $(( get_values )) -eq 0 ]; then
		printf '%s="%s"\n' "${get_type}" "${get_result}"
	else
		echo "${get_result}"
	fi

	unset get_result get_values get_type

	return 0
}  # get_stage3

resolve_python_flags() {
	# Ensure that USE, PYTHON_SINGLE_TARGET, and PYTHON_TARGETS are all in sync
	# with each other...
	#
	resolve_use="${1:-}"
	resolve_python_single_target="${2:-}"
	resolve_python_targets="${3:-}"

	#extern USE PYTHON_SINGLE_TARGET PYTHON_TARGETS python_targets

	resolve_info='' resolve_target=''
	resolve_info="$( # <- Syntax
		LC_ALL='C' SYSROOT="${ROOT:-"/"}" PORTAGE_CONFIGROOT="${ROOT:-"/"}" \
			emerge --info --verbose=y
	)"

	# We seem to have a weird situation where USE and PYTHON_*
	# variables are not in sync with each other...?
	resolve_use="${USE:+"${USE} "}${resolve_use:+"${resolve_use} "}$( # <- Syntax
		echo "${resolve_info}" | grep -- "^USE=" | cut -d'"' -f 2
	)" # ' # <- Syntax
	resolve_python_single_target="${PYTHON_SINGLE_TARGET:-} ${resolve_python_single_target:-} $( # <- Syntax
		echo "${resolve_info}" | grep -- "^PYTHON_SINGLE_TARGET=" | cut -d'"' -f 2
	)${python_targets:+" ${python_targets%%" "*}"}" # ' # <- Syntax
	resolve_python_targets="${PYTHON_TARGETS:-} ${resolve_python_targets:-} $( # <- Syntax
		echo "${resolve_info}" | grep -- "^PYTHON_TARGETS=" | cut -d'"' -f 2
	) ${python_targets:-}" # ' # <- Syntax

	for resolve_target in ${resolve_python_single_target:-}; do
		resolve_target="python_single_target_${resolve_target}"
		if ! echo "${resolve_use:-}" | grep -q -- "${resolve_target}"; then
			resolve_use="${resolve_use:+"${resolve_use} "}${resolve_target}"
		fi
	done
	for resolve_target in ${resolve_python_targets:-}; do
		resolve_target="python_targets_${resolve_target}"
		if ! echo "${resolve_use:-}" | grep -q -- "${resolve_target}"; then
			resolve_use="${resolve_use:+"${resolve_use} "}${resolve_target}"
		fi
	done

	for resolve_target in ${USE:-}; do
		case "${resolve_target}" in
			python_single_target_*)
				resolve_target="$( echo "${resolve_target}" | sed 's/^python_single_target_//' )"
				if ! echo " ${resolve_python_single_target:-} " |
						grep -q -- " ${resolve_target} "
				then
					resolve_python_single_target="${resolve_python_single_target:+"${resolve_python_single_target} "}${resolve_target}"
				fi
				;;
			python_targets_*)
				resolve_target="$( echo "${resolve_target}" | sed 's/^python_targets_//' )"
				if ! echo " ${resolve_python_targets} " |
						grep -q -- " ${resolve_target} "
				then
					resolve_python_targets="${resolve_python_targets:+"${resolve_python_targets} "}${resolve_target}"
				fi
				;;
		esac
	done
	printf '%s="%s"\n' 'USE' "$( # <- Syntax
		echo "${resolve_use}" | xargs -rn 1 | sort | uniq | xargs -r
	)"
	printf '%s="%s"\n' 'PYTHON_SINGLE_TARGET' "$( # <- Syntax
		echo "${resolve_python_single_target}" | xargs -rn 1 | sort -V | uniq |
			tail -n 1
	)"
	printf '%s="%s"\n' 'PYTHON_TARGETS' "$( # <- Syntax
		echo "${resolve_python_targets}" | xargs -rn 1 | sort | uniq | xargs -r
	)"

	unset resolve_target resolve_info resolve_python_targets \
		resolve_python_single_target resolve_use

	return 0
}  # resolve_python_flags

do_emerge() {
	emerge_arg=''
	emerge_opts=''
	#emerge_features=''
	emerge_rc=0

	[ "${#}" -gt 0 ] || return 1

	if [ -n "${ROOT:-}" ] && [ "${ROOT}" != '/' ]; then
		# N.B.: --root-deps only affects ebuilds with EAPI=6 and prior...
		#
		emerge_opts='--root-deps'
	fi

	# --keep-going is universal
	set -- "${@}" \
		--keep-going=y

	for emerge_arg in "${@}"; do
		shift
		case "${emerge_arg:-}" in
			'')
				:
				;;

			'--unmerge-defaults')
				set -- "${@}" \
					--implicit-system-deps=n \
					--verbose=n \
					--with-bdeps=n \
					--with-bdeps-auto=n \
					--unmerge
				;;

			'--depclean-defaults')
				set -- "${@}" \
					--implicit-system-deps=n \
					--verbose=n \
					--with-bdeps=n \
					--with-bdeps-auto=n \
					--depclean
				;;

			'--defaults'|--*-defaults)
				set -- "${@}" \
					--binpkg-respect-use=y \
					--quiet-build=y \
					  ${opts:-} \
					--verbose=y \
					--verbose-conflicts \
					  ${emerge_opts}

				case "${emerge_arg}" in
					'--defaults')
						:
						;;

					# --with-bdeps*=y
					'--build-defaults')
						# shellcheck disable=SC2086
						set -- "${@}" \
							  ${parallel} \
							--binpkg-changed-deps=y \
							--buildpkg=n \
							--deep \
							--usepkg=y \
							--with-bdeps=y \
							--with-bdeps-auto=y
						;;

					# --buildpkg=n
					'--once-defaults'|'--single-defaults'|'--chost-defaults'| \
					'--initial-defaults')
						set -- "${@}" \
							--buildpkg=n \
							--usepkg=y \
							--with-bdeps=n \
							--with-bdeps-auto=n

						case "${emerge_arg}" in
							'--once-defaults')
								set -- "${@}" \
									--binpkg-changed-deps=y \
									--oneshot
								#emerge_features='-preserve-libs'
								;;
							'--single-defaults')
								set -- "${@}" \
									--binpkg-changed-deps=y
								#emerge_features='-preserve-libs'
								;;
							'--chost-defaults')
								# shellcheck disable=SC2086
								set -- "${@}" \
									  ${parallel} \
									--binpkg-changed-deps=y \
									--update
								;;
							'--initial-defaults')
								# shellcheck disable=SC2086
								set -- "${@}" \
									  ${parallel} \
									--binpkg-changed-deps=n \
									--update
								;;
						esac
						;;

					# --buildpkg=y
					'--multi-defaults'|'--rebuild-defaults'| \
					'--system-defaults'|'--preserved-defaults')
						# shellcheck disable=SC2086
						set -- "${@}" \
							  ${parallel} \
							--binpkg-changed-deps=y \
							--buildpkg=y \
							--with-bdeps=n \
							--with-bdeps-auto=n

						case "${emerge_arg}" in
							'--rebuild-defaults')
								set -- "${@}" \
									--oneshot \
									--usepkg=y
								;;
							'--system-defaults')
								set -- "${@}" \
									--rebuild-if-new-slot=y \
									--rebuilt-binaries=y \
									--update \
									--usepkg=y

									# --deep is causing USE='openmp' dependency
									# resolution problems...
									#
									#--deep \
									#
									#--oneshot \
									# Did '--emptytree' and '--update' ever
									# made sense here?
									#--emptytree \
								;;
							'--preserved-defaults')
								set -- "${@}" \
									--oneshot \
									--usepkg=n
									#--buildpkg=n \
									#--emptytree \
									#--usepkg=y \
								;;
						esac
						;;

					*)
						warn "Unknown emerge defaults set '${emerge_arg}'"
						;;
				esac
				;;

			*)
				set -- "${@}" "${emerge_arg}"
				;;
		esac
	done

	print "Running \"emerge ${*}\"${USE:+" with USE='${USE}'"}" \
		"${ROOT:+" with ROOT='${ROOT}'"}"
	#FEATURES="${emerge_features:-}" \
	emerge --ignore-default-opts --color=y "${@:-}" || emerge_rc="${?}"

	if [ $(( emerge_rc )) -eq 0 ]; then
		[ -f /etc/._cfg0000_hosts ] && rm -f /etc/._cfg0000_hosts
		etc-update -q --automode -5
		LC_ALL='C' eselect --colour=no news read >/dev/null 2>&1
	fi

	unset emerge_opts emerge_arg

	return ${emerge_rc}
}  # do_emerge

fix_sh_symlink() {
	symlink_root="${1:-"${ROOT:-}"}"
	symlink_msg="${2:-}"  # expected 'pre-deploy' or '@system'

	# Ensure we have a valid /bin/sh symlink in our ROOT ...
	if ! [ -x "${symlink_root}"/bin/sh ]; then
		echo " * Fixing ${symlink_msg:+"${symlink_msg} "}'/bin/sh' symlink ..."
		[ ! -e "${symlink_root}"/bin/sh ] || rm "${symlink_root}"/bin/sh
		ln -sf bash "${symlink_root}"/bin/sh
	fi
}  # fix_sh_symlink

if [ -n "${DEV_MODE:-}" ]; then
	cat <<EOF

*******************************************************************************
*                                                                             *
* OPERATING IN DEV_MODE                                                       *
*                                                                             *
* This script is running as it exists on-disk, overriding the container image *
* contents.  Do not use the output of this mode for reliable builds.          *
*                                                                             *
*******************************************************************************

EOF
fi

[ -n "${trace:-}" ] && set -o xtrace

if set | grep -q -- '=__[A-Z]\+__$'; then
	die "Unexpanded variable(s) in environment: $( # <- Syntax
		set | grep -- '=__[A-Z]\+__$' | cut -d'=' -f 1 | xargs -r
	)"
fi

if [ -f /etc/env.d/50baselayout ] && [ -s /etc/env.d/50baselayout ]; then
	changed=0
	if ! grep 'PATH.*[":]/sbin[":]' /etc/env.d/50baselayout; then
		sed -e '/PATH/s|:/opt/bin"|:/sbin:/opt/bin"|' \
			-i /etc/env.d/50baselayout
		changed=1
	fi
	if ! grep 'PATH.*[":]/bin[":]' /etc/env.d/50baselayout; then
		sed -e '/PATH/s|:/opt/bin"|:/bin:/opt/bin"|' \
			-i /etc/env.d/50baselayout
		changed=1
	fi
	if [ $(( changed )) -eq 1 ]; then
		cp /etc/ld.so.conf /etc/ld.so.conf.saved
		LC_ALL='C' env-update || :
		mv /etc/ld.so.conf.saved /etc/ld.so.conf
	fi
	unset changed
fi

# shellcheck disable=SC1091
[ -s /etc/profile ] && . /etc/profile

[ -n "${environment_filter:-}" ] ||
	die "'environment_filter' not inherited from docker environment"

if printf '%s' " ${*:-} " | grep -Fq -- ' --verbose-build '; then
	parallel='--jobs=1 --quiet-build=n'
else
	if [ -n "${JOBS:-}" ]; then
		case "${JOBS}" in
			0|1)
				parallel=''
				;;
			'*')
				parallel='--jobs'
				;;
			[0-9]*)
				parallel="--jobs=${JOBS}"
				;;
			*)
				parallel="--jobs=${DEFAULT_JOBS}"
				;;
		esac
	else
		parallel="--jobs=${DEFAULT_JOBS}"
	fi
fi

if [ -z "${MAXLOAD:-}" ] || [ "${MAXLOAD:-}" != '0' ]; then
	parallel="${parallel:+"${parallel} "}--load-average=${MAXLOAD:-"${DEFAULT_MAXLOAD}"}"
fi

# Specify our installation ROOT...
#
service_root='/build'

COLLISION_IGNORE="$( echo "${COLLISION_IGNORE:-"/lib/modules/*"}
	/bin/cpio
	/etc/env.d/04gcc-x86_64-pc-linux-gnu
	/etc/env.d/gcc/config-x86_64-pc-linux-gnu
	/usr/bin/awk
	/usr/bin/bc
	/usr/bin/dc
	/usr/bin/lexx
	/usr/bin/ninja
	/usr/bin/yacc
	/usr/lib/locale/locale-archive
	/var/lib/portage/home/*
	/build/bin/awk
	/build/bin/bunzip2
	/build/bin/bzcat
	/build/bin/bzip2
	/build/bin/gunzip
	/build/bin/gzip
	/build/bin/sh
	/build/bin/tar
	/build/bin/zcat
	${service_root}/bin/*
	${service_root}/etc/php/*/ext-active/*
	${service_root}/sbin/*
	${service_root}/usr/bin/*
	${service_root}/usr/share/*/*
	${service_root}/var/lib/*/*
" | xargs -r )"
export COLLISION_IGNORE

post_pkgs='' post_use='' python_targets="${python_default_targets:-}" rc=0
for arg in "${@}"; do
	#print "Read argument '${arg}'"

	shift
	case "${arg}" in
		--post-pkgs=*)
			post_pkgs="$( # <- Syntax
				printf '%s' "${arg}" | sed -z 's/^[^=]*=//' | tr -d '\n'
			)"
			continue
			;;
		--post-use=*)
			post_use="$( # <- Syntax
				printf '%s' "${arg}" | sed -z 's/^[^=]*=//' | tr -d '\n'
			)"
			continue
			;;
		--python-target=*|--python-targets=*)
			python_targets="$( # <- Syntax
				printf '%s' "${arg}" | sed -z 's/^[^=]*=//' | tr -d '\n'
			)"
			continue
			;;
		--verbose-build)
			continue
			;;
		--with-use=*)
			warn "Option '--with-use' is not valid during initial build stage"
			continue
			;;
		*)
			set -- "${@}" "${arg}"
			;;
	esac
done
print "'python_targets' is '${python_targets:-}'"

if [ -e /etc/portage/repos.conf.host ]; then
	echo
	info "Mirroring host repos.conf to container ..."
	if [ -e /etc/portage/repos.conf ]; then
		if [ -d /etc/portage/repos.conf ]; then
			for f in /etc/portage/repos.conf/*; do
				umount -q "${f}" || :
			done
		fi
		umount -q /etc/portage/repos.conf || :
		rm -rf /etc/portage/repos.conf || :

		[ -e /etc/portage/repos.conf ] &&
			mv /etc/portage/repos.conf /etc/portage/repos.conf.disabled
	fi
	cp -a /etc/portage/repos.conf.host /etc/portage/repos.conf ||
		die "Can't copy host repos.conf: ${?}"
fi

#warn >&2 "Inherited USE-flags: '${USE:-}'"

# post_use should be based on the original USE flags, without --with-use
# additions...
# (... even though we're not using those here!)
#
if [ -n "${post_use:-}" ]; then
	if ! printf ' %s ' "${post_use:-}" | grep -Fq -- ' -* '; then
		post_use="${USE:+"${USE} "}${post_use:-}"
	fi
else
	post_use="${USE:-}"
fi
if [ -n "${use_essential:-}" ]; then
	if ! echo "${post_use:-}" |
			grep -Fq -- "${use_essential}"
	then
		post_use="${post_use:+"${post_use} "}${use_essential}"
	fi
fi

# At the point we're executed, we expect to be in a stage3 with appropriate
# repositories mounted...
#
[ -s "${stage3_flags_file}" ] ||
	die "'${stage3_flags_file}' is missing or empty"
[ -d /var/db/repo/gentoo/profiles ] ||
	die "default repo ('gentoo') is missing"
[ -d /etc/portage ] ||
	die "'/etc/portage' is missing or not a directory"
[ -s /etc/portage/package.use ] || [ -d /etc/portage/package.use ] ||
	die "'/etc/portage/package.use' is missing"
[ -s /etc/locale.gen ] ||
	warn "'/etc/locale.gen' is missing or empty"
if ! [ -s "${PKGDIR}"/Packages ] || ! [ -d "${PKGDIR}"/virtual ]; then
	warn "'${PKGDIR}/Packages' or '${PKGDIR}/virtual' are missing - package" \
		"cache appears invalid"
fi

env | grep -F -- 'DIR=' | cut -d'=' -f 2- | while read -r d; do
	if ! [ -d "${d}" ]; then
		warn "Creating missing directory '${d}' ..."
		mkdir -p "${d}" || die "mkdir() on '${d}' failed: ${?}"
	fi
	if [ "$( stat -Lc '%G' "${d}" )" != 'portage' ]; then
		warn "Resetting permissions on '${d}' ..."
		if chgrp "${d}" portage 2>/dev/null; then
			chmod ug+rwx "${d}" || die "chmod() on '${d}' failed: ${?}"
		else
			chmod ugo+rwx "${d}" || die "chmod() on '${d}' failed: ${?}"
		fi
	fi
done

touch "${PKGDIR}/Packages" ||
	die "Unable to write to file '${PKGDIR}/Packages': ${?}"

get_stage3 --cache-only
info="$( # <- Syntax
	eval "export $( get_stage3 USE )"
	eval "export $( get_stage3 PYTHON_SINGLE_TARGET )"
	eval "export $( get_stage3 PYTHON_TARGETS )"
	eval "$( # <- Syntax
		resolve_python_flags \
			"${USE}" \
			"${PYTHON_SINGLE_TARGET}" \
			"${PYTHON_TARGETS}"
	)"
	LC_ALL='C' emerge --info --verbose=y
)"
echo
echo 'Resolved build variables for stage3:'
echo '-----------------------------------'
echo
echo "ROOT                = $( # <- Syntax
	echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
)"
echo "SYSROOT             = $( # <- Syntax
	echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
)"
echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
	echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
)"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
echo "${info}" | format 'USE'
echo "${info}" | format 'PYTHON_SINGLE_TARGET'
echo "${info}" | format 'PYTHON_TARGETS'
echo "MAKEOPTS            = $( # <- Syntax
	echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2-
)"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( # <- Syntax
	echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2-
)"
echo "PKGDIR              = $( # <- Syntax
	echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2-
)"
echo "PORTAGE_LOGDIR      = $( # <- Syntax
	echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2-
)"
echo
unset info

# Report stage3 tool versions (because some are masked from the arm64 stage3!)
#
file=''
for file in /lib*/libc.so.6; do
	"${file}" || :
done
unset file
gcc --version || :
ld --version || :

# We should *definitely* have this...
package='virtual/libc'
opts='--tree'
if printf ' %s ' "${*}" | grep -Fq -- ' --nodeps '; then
	opts=''
fi

LC_ALL='C' eselect --colour=yes profile list | grep 'stable'
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" # 2>/dev/null
info "Selected profile '$( # <- Syntax
	LC_ALL='C' eselect --colour=yes profile show | tail -n 1
)'"

LC_ALL='C' emaint --fix binhost

# TODO: Is there any benefit in showing stage3 news?
#
# Update: Let's show all news in one go, at the end of the process...
#         ... but still run 'news read' now, to prevent annoying notices from
#         'emerge' saying that news is pending!
#LC_ALL='C' emerge --check-news
LC_ALL='C' eselect --colour=no news read >/dev/null 2>&1
#printf '\n---\n\n'

#set -o xtrace

# As-of sys-libs/zlib-1.2.11-r3, zlib builds without error but then the portage
# merge process aborts with 'unable to read SONAME from libz.so' in src_install
#
# To try to work around this, snapshot the current stage3 version...
#quickpkg --include-config y --include-unmodified-config y sys-libs/zlib

( # <- Syntax
	mkdir -p /var/lib/portage
	echo 'virtual/libc' > /var/lib/portage/world

	USE="-* $( get_stage3 --values-only USE ) -udev"
	export USE
	export FEATURES="${FEATURES:+"${FEATURES} "}-fakeroot"
	list='virtual/dev-manager virtual/tmpfiles'
	if LC_ALL='C' portageq get_repos / | grep -Fq -- 'srcshelton'; then
		list="${list:-} sys-apps/systemd-utils"
	fi
	# 'dhcpcd' is now built with USE='udev'...
	#
	do_emerge --once-defaults net-misc/dhcpcd

	# To make the following output potentially clearer, attempt to remove any
	# masked packages which exist in the image we're building from...
	#
	echo
	echo
	echo " * Attempting to remove masked packages from stage3 ..."
	echo
	echo

	# shellcheck disable=SC2086
	do_emerge --unmerge-defaults ${list} || :

	#virtual/udev-217-r3 pulled in by:
	#    sys-apps/hwids-20210613-r1 requires virtual/udev
	#    sys-fs/udev-init-scripts-34 requires >=virtual/udev-217
	#    virtual/dev-manager-0-r2 requires virtual/udev
	list="$( # <- Syntax
		{
			sed 's/#.*$//' /etc/portage/package.mask/* |
				grep -v -- 'gentoo-functions'

			sed 's/#.*$//' /etc/portage/package.mask/* |
				grep -Eow -- '((virtual|sys-fs)/)?e?udev' &&
			printf 'sys-apps/hwids sys-fs/udev-init-scripts'
		} |
			grep -Fv -- '::' |
			sort -V |
			xargs -r
	)"
	echo "Package list: ${list}"
	echo
	# shellcheck disable=SC2086
	do_emerge --depclean-defaults ${list}
)

if portageq get_repos / | grep -Fq -- 'srcshelton'; then
	echo
	echo " * Building linted 'sys-apps/gentoo-functions' package for stage3 ..."
	echo
	(
		USE="-* $( get_stage3 --values-only USE )"
		export USE
		export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean -fakeroot"
		do_emerge --single-defaults 'sys-apps/gentoo-functions::srcshelton'
	)
fi

echo
echo " * Building 'sys-apps/fakeroot' package for stage3 ..."
echo
( # <- Syntax
	USE="-* $( get_stage3 --values-only USE )"
	export USE
	export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean -fakeroot"
	do_emerge --single-defaults sys-apps/fakeroot
)
export FEATURES="${FEATURES:+"${FEATURES} "}fakeroot"
export FEATURES="${FEATURES} -preserve-libs"

export QA_XLINK_ALLOWED='*'


if ! [ -d "/usr/${CHOST}" ]; then
	echo
	echo " * CHOST change detected - ensuring stage3 is up to date ..."
	echo

	# chost_change() {

	# This process may be fragile if there are updates available for installed
	# stage3 packages...
	(
		# Rebuilding with all active USE flags pulls in additional flags (and
		# packages) which weren't previously set :(
		#
		# The intent, however, is to rebuild as closely to the original stage3
		# state as possible.
		#
		# ('livecd' for patched busybox)
		USE="-* livecd nptl $( get_stage3 --values-only USE )"
		export USE
		export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
		do_emerge --chost-defaults '@system' '@world'
	)
	LC_ALL='C' etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

	echo
	echo " * CHOST change detected - building stage3 compiler suite ..."
	echo

	oldchost="$( # <- Syntax
		find /usr \
				-mindepth 1 \
				-maxdepth 1 \
				-type d \
				-name '*-*-*' \
				-exec basename {} ';' |
			head -n 1
	)"
	for pkg in 'sys-devel/binutils' 'sys-devel/gcc' 'sys-libs/glibc'; do
		(
			USE="-* nptl $( get_stage3 --values-only USE )"
			export USE
			export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
			do_emerge --single-defaults "${pkg}"
		)
		LC_ALL='C' etc-update --quiet --preen
		find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
		case "${pkg}" in
			*binutils*)
				binutils-config -l 2>/dev/null || :
				binutils-config 1 2>/dev/null || :
				;;
			*gcc*)
				gcc-config -l 2>/dev/null || :
				gcc-config 1 2>/dev/null || :
				;;
		esac
		# shellcheck disable=SC1091
		[ -s /etc/profile ] && { . /etc/profile || : ; }
	done
	unset pkg
	rm -r "/usr/${oldchost:?}" "/usr/bin/${oldchost:?}"*
	#find \
	#		/bin/ \
	#		/sbin/ \
	#		/usr/bin/ \
	#		/usr/sbin/ \
	#		/usr/libexec/ \
	#		/usr/local/ \
	#	-name "*${oldchost}*" \
	#	-exec ls -Fhl --color=always {} +
	#find /usr/ \
	#	-mindepth 1 \
	#	-maxdepth 1 \
	#	-name "*${oldchost}*" \
	#	-exec ls -dFhl --color=always {} +
	grep -l -- "${oldchost}" /etc/env.d/0*gcc* /etc/env.d/0*binutils* |
		xargs -r rm
	find /etc/env.d/ -name "*${oldchost}*" -delete
	LC_ALL='C' env-update || :
	binutils-config 1 2>/dev/null || :
	gcc-config 1 2>/dev/null || :
	# shellcheck disable=SC1091
	[ -s /etc/profile ] && . /etc/profile
	echo
	echo " * Switched from CHOST '${oldchost}' to '${CHOST}'":
	echo
	#ls -lAR /etc/env.d/
	#grep -HR --colour -- '^.*$' /etc/env.d/
	#binutils-config -l
	#gcc-config -l

	#for pkg in 'dev-libs/libgpg-error' 'dev-build/libtool'; do
	# shellcheck disable=SC2041
	for pkg in 'dev-build/libtool'; do
		(
			USE="-* $( get_stage3 --values-only USE )"
			export USE
			export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
			do_emerge --single-defaults "${pkg}"
		)
		LC_ALL='C' etc-update --quiet --preen
		find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
	done
	unset pkg
	[ -x /usr/sbin/fix_libtool_files.sh ] &&
		/usr/sbin/fix_libtool_files.sh "$( gcc -dumpversion )" \
			--oldarch "${oldchost}"

	(
		USE="-* nptl $( get_stage3 --values-only USE )"
		export USE
		export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"

		# clashing USE flags can't be resolved with current level of
		# command-line fine-grained package flag control :(
		exclude='sys-apps/coreutils sys-apps/net-tools sys-apps/util-linux sys-process/procps sys-apps/shadow'

		do_emerge --once-defaults --exclude "${exclude}" dev-libs/libgpg-error
		#ls -l "/usr/bin/${CHOST}-gpg-error-config"
		#cat /var/db/pkg/dev-libs/libgpg-error*/CONTENTS

		# shellcheck disable=SC2012,SC2046
		do_emerge --preserved-defaults --exclude "${exclude}" $( # <- Syntax
				for object in \
						"/usr/bin/${oldchost}-"* \
						"/usr/include/${oldchost}" \
						/usr/lib/llvm/*/bin/"${oldchost}"-*
				do
					if [ -e "${object}" ]; then
						printf '%s ' "${object}"
					fi
				done
			)dev-lang/perl "=$( # <- Syntax
				ls /var/db/pkg/dev-lang/python-3* -1d |
					cut -d'/' -f 5-6 |
					sort -V |
					head -n 1
			)" '@preserved-rebuild'
	)
	#if LC_ALL='C' eselect --colour=yes news read new |
	#		grep -Fv -- 'No news is good news.'
	#then
	#	printf '\n---\n\n'
	#fi

	LC_ALL='C' etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

	# }  # chost_change
fi

echo
echo
echo " * Installing stage3 prerequisites to allow for flexible filesystem" \
	"configurations ..."
echo

( # <- Syntax
	export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
	# shellcheck disable=SC2046
	USE='-gmp ssl' \
	do_emerge --single-defaults dev-build/libtool sys-libs/pam $(
		# sys-devel/gcc is a special case with a conditional gen_usr_ldscript
		# call...
		# N.B. Using 'grep -lm 1' and so having to read the whole file where
		#      there is no match is about twice as fast as finding the
		#      'inherit' line only and then checking for 'usr-ldscript' but
		#      having to invoke 'sed', 'grep', and 'cut' (with a cold cache)
		{
			grep -lm 1 '^inherit[^#]\+usr-ldscript' \
					"$( portageq vdb_path )"/*/*/*.ebuild |
				rev |
				cut -d'/' -f 3,4 |
				rev
			if LC_ALL='C' portageq get_repos / |
					grep -Fq -- 'srcshelton'
			then
				grep -lm 1 '^inherit[^#]\+usr-ldscript' \
						"$( portageq get_repo_path / srcshelton )"/*/*/*.ebuild |
					rev |
					cut -d'/' -f 2,3 |
					rev
			fi
		} |
			sort |
			uniq |
			grep -Fxv 'sys-devel/gcc' |
			while read -r ebuild; do
				for file in "$( portageq vdb_path )/${ebuild}"-*/CONTENTS; do
					if [ -f "${file}" ]; then
						grep -Eqm 1 -- '(sym|obj) /lib(x?32|64)' "${file}" ||
							echo "${ebuild}"
					fi
				done
			done
	)
	do_emerge --single-defaults '@preserved-rebuild'
)

echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source" \
	"package ..."
echo

# Some packages require prepared kernel sources ...
#
( # <- Syntax
	USE="-* $( get_stage3 --values-only USE ) symlink"
	# Since app-alternatives/* packages are now mandatory, the USE flags these
	# packages rely upon must also be set in order to avoid REQUIRED_USE
	# errors.
	#
	# TODO: Fix this better...
	#
	#USE="${USE} gawk gnu"
	export USE
	export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
	do_emerge --single-defaults sys-kernel/gentoo-sources
)

echo
echo ' * Configuring stage3 kernel sources ...'
echo

#pushd >/dev/null /usr/src/linux  # bash only
src_cwd="${PWD}"
cd /usr/src/linux/
make defconfig prepare
#popd >/dev/null  # bash only
cd "${src_cwd}"
unset src_cwd

# Certain @system packages incorrectly fail to find ROOT-installed
# dependencies, and so require prior package installation directly into the
# stage3 environment...
#
# (... and busybox is struggling with libxcrypt, so we'll throw that in here
# too!)
#
for pkg in \
		'sys-libs/libxcrypt' \
		'virtual/libcrypt' \
		'sys-libs/libcap' \
		'sys-process/audit' \
		'dev-perl/libintl-perl' \
		'dev-perl/Locale-gettext' \
		'dev-libs/libxml2' \
		'app-editors/vim' \
		'app-admin/eselect' \
		'sys-apps/gawk' \
		'app-alternatives/awk' \
		'sys-devel/gcc' \
		'app-crypt/libb2'
		#'app-eselect/eselect-awk' \
		#'virtual/awk' \
do
	echo
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		USE="-* $( get_stage3 --values-only USE )"
		# Add 'xml' to prevent an additional python install/rebuild for
		# sys-process/audit (which pulls-in dev-lang/python without USE='xml')
		# vs. dev-libs/libxml2 (which requires dev-lang/python[xml])
		#
		# shellcheck disable=SC2154
		USE="${USE} ${use_essential_gcc} xml"
		if [ "${arch}" = 'arm64' ]; then
			USE="${USE} gold"
		fi
		export USE
		export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
		case "${pkg}" in
			#app-alternatives/awk)
			#	USE="-busybox ${USE} gawk"
			#	;;
			dev-libs/libxml2)
				USE="${USE} -lzma -python_targets_python3_10"
				;;
			#sys-devel/gcc|app-crypt/libb2)
			#	USE="${USE} openmp"
			#	;;
			sys-libs/libcap)
				USE="${USE} -tools"
				;;
			#sys-libs/libxcrypt|virtual/libcrypt)
			#	USE="${USE} static-libs"
			#	;;
			sys-process/audit)
				# sys-process/audit is the first package which can pull-in an
				# older python release, which causes preserved libraries...
				USE="${USE} -berkdb -ensurepip -gdbm -ncurses -readline -sqlite"
				;;
		esac
		do_emerge --single-defaults "${pkg}"
	)
	#if LC_ALL='C' eselect --colour=yes news read new |
	#		grep -Fv -- 'No news is good news.'
	#then
	#	printf '\n---\n\n'
	#fi

	LC_ALL='C' etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done  # for pkg in ...
unset pkg
#LC_ALL='C' eselect awk set gawk || :

# Now we can build our ROOT environment ...
#
echo
echo
echo ' * Creating build root ...'
echo

rm "${stage3_flags_file}"

# (ARCH should now be safe)
export ARCH="${arch}"
unset -v arch

export ROOT="${service_root}"
export SYSROOT="${ROOT}"
export PORTAGE_CONFIGROOT="${SYSROOT}"

# Relocate /usr/src/linux* to ${ROOT}/usr/src/ and symlink back to original
# location...
#
if [ ! -d "${ROOT}"/usr/src/linux ] || [ ! -L /usr/src/linux ]; then
	[ -d "${ROOT}"/usr/src ] && rm -r "${ROOT}"/usr/src
	mkdir -p "${ROOT}"/usr/src/
	mv /usr/src/linux* "${ROOT}"/usr/src/
	ln -s ../../"${ROOT}"/usr/src/linux /usr/src/
fi

# We could keep SYSROOT/PORTAGE_CONFIGROOT set to '/', but embedding the active
# configuration in the build-image feels like a better overall option...
#
mkdir -p "${SYSROOT}"/etc

# FIXME: Do we want to unconditionally copy everything across, or instead
#        select a minimal set here and rely on mounting the appropriate files
#        into the container?
#
cp -r /etc/portage "${SYSROOT}"/etc/
#f='' d=''
#for f in color.map make.conf suidctl.conf; do
#	cp /etc/portage/"${f}" "${SYSROOT}"/etc/portage/
#done
#for dir in profile repos.conf savedconfig; do
#	cp -r /etc/portage/"${d}" "${SYSROOT}"/etc/portage/
#done
#unset d f

[ -e "${SYSROOT}"/etc/portage/package.use ] ||
	die "Mirroring /etc/portage to '${SYSROOT}' failed"

mkdir -p "${ROOT}"/etc
cp /etc/etc-update.conf "${ROOT}"/etc/
cp /etc/group "${ROOT}"/etc/
cp /etc/locale.gen "${ROOT}"/etc/
cp /etc/timezone "${ROOT}"/etc/

path="${PATH}"
PATH="${PATH}:${ROOT}$( echo "${PATH}" | sed "s|:|:${ROOT}|g" )"
export PATH

if command -v env-update >/dev/null 2>&1; then
	cp /etc/ld.so.conf /etc/ld.so.conf.saved
	LC_ALL='C' env-update || :
	mv /etc/ld.so.conf.saved /etc/ld.so.conf
fi
file=''
for file in /etc/profile "${ROOT}"/etc/profile; do
	# shellcheck disable=SC1090,SC1091
	[ -s "${file}" ] && . "${file}"
done
unset file
echo "Setting profile for architecture '${ARCH}'..."
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" 2>&1 |
	grep -v -- 'Warning:' || :

LC_ALL='C' emerge --check-news

# It seems we never actually defined USE if not passed-in externally, and yet
# somehow on amd64 gcc still gets 'nptl'.  On arm64, however, this doesn't
# happen and everything breaks :(
#
# Let's try to fix that...
#
# Update: 'nptl' USE-flag now seems to have been removed from current ebuilds,
# but this can't do much harm...
#
export USE="${USE:+"${USE} "}${use_essential} nptl"

# FIXME: Expose this somewhere?
features_libeudev=0
features_eudev=1

# Do we need to rebuild the root packages as well?
#
# This can be required if the upstream stage image is significantly old
# compared to the current portage tree...
#extra_root='/'

# sys-apps/help2man with USE 'nls' requires Locale-gettext, which depends
# on sys-apps/help2man;
#
# sys-libs/libcap can USE pam, which requires libcap;
#
# sys-apps/help2man requires dev-python/setuptools which must have been built
# with the same PYTHON_*TARGET* flags as are currently active...
#
pkg_initial='sys-apps/fakeroot sys-libs/libcap sys-process/audit sys-apps/util-linux app-shells/bash sys-apps/help2man dev-perl/Locale-gettext sys-libs/libxcrypt virtual/libcrypt app-editors/vim'
pkg_initial_use='-nls -pam -perl -python -su minimal'
pkg_exclude=''
if [ $(( features_eudev )) -eq 1 ]; then
	pkg_initial="${pkg_initial:+"${pkg_initial} "}sys-fs/eudev virtual/libudev"
	pkg_exclude="${pkg_exclude:+"${pkg_exclude} "}--exclude=sys-libs/libeudev"
elif [ $(( features_libeudev )) -eq 1 ]; then
	# libudev-251 and above require at least sys-fs/eudev-3.2.14, and aren't
	# supported by sys-libs/libeudev...
	pkg_initial="${pkg_initial:+"${pkg_initial} "}sys-libs/libeudev <virtual/libudev-251"
	pkg_exclude="${pkg_exclude:+"${pkg_exclude} "}--exclude=virtual/udev"
fi

if [ -n "${pkg_initial:-}" ]; then
	export python_targets PYTHON_SINGLE_TARGET PYTHON_TARGETS
	print "'python_targets' is '${python_targets:-}', 'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}', 'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"

	(
		export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"

		export USE="${pkg_initial_use}${use_essential:+" ${use_essential}"}"
		if [ "${ROOT:-"/"}" = '/' ]; then
			if [ -z "${stage3_flags:-}" ]; then
				USE="${USE:+"${USE} "}$( get_stage3 --values-only USE )"
				PYTHON_SINGLE_TARGET="${PYTHON_SINGLE_TARGET:+"${PYTHON_SINGLE_TARGET} "}$( get_stage3 --values-only PYTHON_SINGLE_TARGET )"
				PYTHON_TARGETS="${PYTHON_TARGETS:+"${PYTHON_TARGETS} "}$( get_stage3 --values-only PYTHON_TARGETS )"
				eval "$( # <- Syntax
					resolve_python_flags \
							"${USE}" \
							"${PYTHON_SINGLE_TARGET}" \
							"${PYTHON_TARGETS}"
				)"
			fi
		else
			print "'python_targets' is '${python_targets:-}', 'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}', 'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"
			PYTHON_SINGLE_TARGET="${python_targets:+"${python_targets%%" "*}"}"
			PYTHON_TARGETS="${python_targets:-}"
			eval "$( # <- Syntax
				resolve_python_flags \
						"${USE:-}" \
						"${PYTHON_SINGLE_TARGET}" \
						"${PYTHON_TARGETS}"
			)"
			export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS
			print "'python_targets' is '${python_targets:-}', 'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}', 'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"
		fi

		info="$( LC_ALL='C' emerge --info --verbose=y )"
		echo
		echo 'Resolved build variables for initial packages:'
		echo '---------------------------------------------'
		echo
		echo "ROOT                = $( # <- Syntax
			echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
		)"
		echo "SYSROOT             = $( # <- Syntax
			echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
		)"
		echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
			echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
		)"
		echo
		echo "${info}" | format 'FEATURES'
		echo "${info}" | format 'ACCEPT_LICENSE'
		echo "${info}" | format 'ACCEPT_KEYWORDS'
		echo "${info}" | format 'USE'
		echo "${info}" | format 'PYTHON_SINGLE_TARGET'
		echo "${info}" | format 'PYTHON_TARGETS'
		echo "MAKEOPTS            = $( # <- Syntax
			echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2-
		)"
		echo
		echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
		echo
		echo "DISTDIR             = $( # <- Syntax
			echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2-
		)"
		echo "PKGDIR              = $( # <- Syntax
			echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2-
		)"
		echo "PORTAGE_LOGDIR      = $( # <- Syntax
			echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2-
		)"
		echo
		unset info

		echo
		echo ' * Building initial packages ...'
		echo

		for pkg in ${pkg_initial:-}; do
			for ROOT in $( # <- Syntax
					echo "${extra_root:-}" "${ROOT}" |
						xargs -rn 1 |
						sort -u |
						xargs -r
			); do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"

				#case "${pkg}" in
				#	*libcrypt|*libxcrypt)
				#		USE="${USE:-} static-libs"
				#		;;
				#esac

				# First package in '${pkg_initial}' to have python deps...
				#
				# TODO: It'd be nice to have a had_deps() function here to
				#       remove this hard-coding...
				#
				#       (There is 'equery depgraph', but it is unreliable with
				#       unlimmited depth)
				#
				if [ "${pkg}" = 'sys-apps/help2man' ]; then
					(
						ROOT='/'
						SYSROOT="${ROOT}"
						PORTAGE_CONFIGROOT="${SYSROOT}"
						export ROOT SYSROOT PORTAGE_CONFIGROOT

						eval "$( # <- Syntax
							resolve_python_flags \
									"${USE:-} ${use_essential} ${use_essential_gcc}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
						)"
						if [ "${ARCH}" = 'arm64' ]; then
							USE="${USE:-} gold"
						fi
						export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS

						info="$( LC_ALL='C' emerge --info --verbose=y )"
						echo
						echo 'Resolved build variables for python builddeps:'
						echo '---------------------------------------------'
						echo
						echo "ROOT                = $( # <- Syntax
							echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
						)"
						echo "SYSROOT             = $( # <- Syntax
							echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
						)"
						echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
							echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
						)"
						echo
						echo "${info}" | format 'FEATURES'
						echo "${info}" | format 'ACCEPT_LICENSE'
						echo "${info}" | format 'ACCEPT_KEYWORDS'
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_SINGLE_TARGET'
						echo "${info}" | format 'PYTHON_TARGETS'
						echo "MAKEOPTS            = $( # <- Syntax
							echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2-
						)"
						echo
						echo "DISTDIR             = $( # <- Syntax
							echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2-
						)"
						echo "PKGDIR              = $( # <- Syntax
							echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2-
						)"
						echo "PORTAGE_LOGDIR      = $( # <- Syntax
							echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2-
						)"
						echo
						unset info

						#USE="static-libs" \
						#do_emerge --build-defaults \
						#	sys-libs/libxcrypt virtual/libcrypt

						# FIXME: --emptytree is needed if that upstream stage3
						#        image is built against a different python
						#        version to what we're now trying to build, but
						#        use of this option is fragile when binary
						#        packages don't already exist.
						#        Perhaps we need to pre-build all dependents as
						#        binary packages in a more controlled
						#        environment first?
						#
						do_emerge --build-defaults app-crypt/libmd dev-libs/libbsd dev-python/setuptools # || :
					)
					# Install same dependencies again within our build ROOT...
					(
						eval "$( # <- Syntax
							resolve_python_flags \
									"${USE:-} ${use_essential} ${use_essential_gcc}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
						)"
						if [ "${ARCH}" = 'arm64' ]; then
							USE="${USE:-} gold"
						fi
						export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS

						do_emerge --build-defaults app-crypt/libmd dev-libs/libbsd dev-python/setuptools # || :
					)
				fi  # [ "${pkg}" = 'sys-apps/help2man' ]

				#if [ "${pkg}" = 'sys-apps/util-linux' ]; then
				#	(
				#	#USE="-busybox ${USE:-} gawk"
				#
				#	# shellcheck disable=SC2086
				#	do_emerge --initial-defaults ${pkg} ${pkg_exclude:-} # || :
				#	)
				#else
					# shellcheck disable=SC2086
					do_emerge --initial-defaults ${pkg} ${pkg_exclude:-} # || :
				#fi

				etc-update --quiet --preen
				find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

				if echo " ${pkg} " | grep -q -- ' app-shells/bash '; then
					fix_sh_symlink "${ROOT}" 'pre-deploy'
				fi
			done  # for ROOT in $(...)
		done  # for pkg in ${pkg_initial:-}
		unset pkg
	)
fi  # [ -n "${pkg_initial:-}" ]

echo
echo ' * Building @system packages ...'
echo

( # <- Syntax
	#set -x

	# sys-apps/shadow is needed for /sbin/nologin;
	#
	# dev-libs/icu is needed for circular dependencies on icu -> python -> ...
	#	sqlite -> icu;
	#
	# libarchive is a frequent dependency, and so quicker to pull-in here
	#
	pkg_system="@system sys-devel/gcc sys-apps/shadow dev-libs/icu app-arch/libarchive ${pkg_initial:-} ${pkg_exclude:-}"

	export FEATURES="${FEATURES:+"${FEATURES} "}fail-clean"
	USE="${USE:+"${USE} "}${use_essential_gcc}"
	if
		  echo " ${USE} " | grep -q -- ' -nptl ' ||
		! echo " ${USE} " | grep -q -- ' nptl '
	then
		warn "USE flag 'nptl' missing from or disabled in \$USE"
		USE="${USE:+"$( echo "${USE}" | sed 's/ \?-\?nptl \?/ /' ) "}nptl"
		info "USE is now '${USE}'"
	fi
	export USE
	for ROOT in $( # <- Syntax
			echo '/' "${extra_root:-}" "${ROOT}" |
				xargs -rn 1 |
				sort -u
	); do
		export ROOT
		export SYSROOT="${ROOT}"
		export PORTAGE_CONFIGROOT="${SYSROOT}"

		eval "${format_fn_code}"

		info="$( LC_ALL='C' emerge --info --verbose=y )"
		echo
		echo "Resolved build variables for @system in ROOT '${ROOT}':"
		echo '------------------------------------'
		echo
		echo "ROOT                = $( # <- Syntax
			echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
		)"
		echo "SYSROOT             = $( # <- Syntax
			echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
		)"
		echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
			echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
		)"
		echo
		echo "${info}" | format 'FEATURES'
		echo "${info}" | format 'ACCEPT_LICENSE'
		echo "${info}" | format 'ACCEPT_KEYWORDS'
		echo "${info}" | format 'USE'
		echo "${info}" | format 'PYTHON_SINGLE_TARGET'
		echo "${info}" | format 'PYTHON_TARGETS'
		echo "MAKEOPTS            = $( # <- Syntax
			echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2-
		)"
		echo
		echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
		echo
		echo "DISTDIR             = $( # <- Syntax
			echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2-
		)"
		echo "PKGDIR              = $( # <- Syntax
			echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2-
		)"
		echo "PORTAGE_LOGDIR      = $( # <- Syntax
			echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2-
		)"
		echo
		unset info

		echo
		echo " * Ensuring we have sys-apps/baselayout ..."
		echo
		[ ! -f "${ROOT%"/"}/var/lock" ] || rm "${ROOT%"/"}/var/lock"
		#	DEBUG=1 \
		do_emerge --system-defaults sys-apps/baselayout

		# portage is tripping over sys-devel/gcc[openmp] :(
		#
		echo
		echo " * Ensuring we have sys-devel/gcc ..."
		echo
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}openmp" \
		do_emerge --system-defaults sys-devel/gcc
		#echo
		#echo " * Ensuring we have sys-devel/gcc & app-crypt/libb2 (for" \
		#	"USE='openmp') ..."
		#echo
		#	DEBUG=1 \
		#	USE="${USE:+"${USE} "}openmp" \
		#do_emerge --rebuild-defaults sys-devel/gcc app-crypt/libb2

		# ... likewise sys-apps/net-tools[hostname] (for which the recommended
		# fix is sys-apps/coreutils[hostname]?)
		#
		echo
		echo " * Ensuring we have sys-apps/coreutils ..."
		echo
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}-hostname" \
		do_emerge --system-defaults sys-apps/coreutils

		echo
		echo " * Ensuring we have sys-apps/net-tools ..."
		echo
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}hostname" \
		do_emerge --system-defaults sys-apps/net-tools

		# Try to prevent preserved rebuilds being required...
		#
		# -gmp blocks gnutls...
		#
		echo
		echo " * Trying to avoid preserved libraries ..."
		echo
		# shellcheck disable=SC2086
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}asm cxx -ensurepip -gdbm gmp minimal -ncurses openssl -readline -sqlite -zstd" \
		do_emerge --once-defaults \
			net-libs/gnutls \
			dev-libs/nettle \
			dev-lang/python \
			dev-lang/perl \
			sys-libs/gdbm

		root_use='' arm64_use=''
		if [ -z "${ROOT:-}" ] || [ "${ROOT}" = '/' ]; then
			root_use='-acl compat -bzip2 -e2fsprogs -expat -iconv -lzma -lzo -nettle -xattr -zstd'
		fi
		# These packages seem to include sys-process/procps, which is breaking
		# due to (forced) USE='unicode' requiring USE='ncurses' ...
		#
		[ "${ARCH:-}" = 'arm64' ] && arm64_use='ncurses'

		# For some reason, portage is selecting dropbear to satisfy
		# virtual/ssh?
		#
		#echo
		#echo " * Ensuring we have sys-devel/gcc & app-crypt/libb2 built with" \
		#	"the required USE-flags ..."
		#echo
		# shellcheck disable=SC2086
		#	DEBUG=1 \
		#	USE="${USE:+"${USE} "}${root_use:+"${root_use} "}cxx -extra-filters gmp ${arm64_use:+"${arm64_use} "}-nettle -nls openmp openssl" \
		#do_emerge \
		#		--system-defaults \
		#	sys-devel/gcc app-crypt/libb2
		echo
		echo " * Ensuring we have system packages ..."
		echo
		# shellcheck disable=SC2086
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}${root_use:+"${root_use} "}cxx -extra-filters gmp ${arm64_use:+"${arm64_use} "}-nettle -nls openmp openssl" \
		do_emerge \
				--exclude='dev-libs/libtomcrypt' \
				--exclude='net-misc/dropbear' \
				--exclude='sys-apps/net-tools' \
				--system-defaults \
			${pkg_system} dev-libs/nettle net-libs/gnutls dev-lang/python \
				dev-libs/libxml2 sys-devel/gettext
			#${pkg_system} $( # <- Syntax
			#	find "${ROOT%"/"}/var/db/pkg/" \
			#			-mindepth 3 \
			#			-maxdepth 3 \
			#			-type f \
			#			-name 'IUSE' \
			#			-print0 |
			#		xargs -r0 grep -Flw -- 'openmp' |
			#		sed 's|^.*/var/db/pkg/|>=| ; s|/IUSE$||' |
			#		xargs -r
			#) dev-libs/nettle net-libs/gnutls dev-lang/python \
			#	dev-libs/libxml2 sys-devel/gettext
		unset root_use

		echo
		echo " * Rebuilding any preserved dependencies ..."
		echo
		# We're hitting errors here that dev-libs/nettle[gmp] is required...
		#	DEBUG=1 \
			USE="${USE:+"${USE} "}asm -ensurepip -gdbm -ncurses openssl -readline -sqlite -zstd" \
		do_emerge --preserved-defaults '@preserved-rebuild'
	done  # for ROOT in $(...)
)  # @system

LC_ALL='C' etc-update --quiet --preen
find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

# Ensure we have a valid /bin/sh symlink in our ROOT ...
#
fix_sh_symlink "${ROOT}" '@system'

# ... and fix the default bash prompt setup w.r.t. 'screen' window names!
#
if [ -s /etc/bash/bashrc.patch ]; then
	if ! command -v patch >/dev/null; then
		warn "@system build has not installed package 'sys-devel/patch'"
	else
		#pushd >/dev/null "${ROOT}"/etc/bash/  # bash only
		src_cwd="${PWD}"
		cd "${ROOT}"/etc/bash/

		if [ -s bashrc ]; then
			echo ' * Patching /etc/bash/bashrc ...'
			patch -p1 -r - -s </etc/bash/bashrc.patch ||
				die "Applying patch to bashrc failed: ${?}"
			rm /etc/bash/bashrc.patch
		else
			warn "'${ROOT%"/"}/etc/bash/bashrc' does not exist or is empty"
		fi

		#popd >/dev/null  # bash only
		cd "${src_cwd}"
		unset src_cwd
	fi
fi

echo
echo ' * Cleaning up ...'
echo

# Save failed build logs ...
# (e.g. /var/tmp/portage/app-misc/mime-types-9/temp/build.log)
#
# shellcheck disable=SC2012
if [ -n "$( # <- Syntax
			ls -1 "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log 2>/dev/null |
				head -n 1
		)" ]
then
	mkdir -p "${PORTAGE_LOGDIR}"/failed
	file='' cat='' pkg=''
	for file in "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log; do
		cat="$( echo "${file}" | rev | cut -d'/' -f 4 | rev )"
		pkg="$( echo "${file}" | rev | cut -d'/' -f 3 | rev )"
		mkdir -p "${PORTAGE_LOGDIR}/failed/${cat}"
		mv "${file}" "${PORTAGE_LOGDIR}/failed/${cat}/${pkg}.log"
	done
	unset pkg cat file
fi

# Cleanup any failed bulids/temporary files ...
#
[ ! -f "${ROOT}"/etc/portage/profile/package.provided ] ||
	rm "${ROOT}"/etc/portage/profile/package.provided
[ ! -f "${ROOT}"/etc/portage/profile/packages ] ||
	rm "${ROOT}"/etc/portage/profile/packages
[ ! -e "${ROOT}"/usr/src/linux ] ||
	rm -r "${ROOT}"/usr/src/linux*
[ ! -d "${ROOT}/${PORTAGE_TMPDIR}/portage" ] ||
	rm -r "${ROOT}/${PORTAGE_TMPDIR}/portage"
[ ! -d "${PORTAGE_TMPDIR}/portage" ] ||
	rm -r "${PORTAGE_TMPDIR}/portage"

echo
echo ' * System deployment complete'
echo
echo

# Check for ROOT news ...
#if LC_ALL='C' eselect --colour=yes news read new |
#		grep -Fv -- 'No news is good news.'
#then
#	printf '\n---\n\n'
#fi

# At this point, we should have a fully-built @system!

export EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS:+"${EMERGE_DEFAULT_OPTS} "} --with-bdeps=y --with-bdeps-auto=y"

info="$( LC_ALL='C' emerge --info --verbose=y )"
echo
echo 'Resolved build variables after init stage:'
echo '-----------------------------------------'
echo
echo "ROOT                = $( # <- Syntax
	echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
)"
echo "SYSROOT             = $( # <- Syntax
	echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
)"
echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
	echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
)"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
echo "${info}" | format 'USE'
echo "${info}" | format 'PYTHON_SINGLE_TARGET'
echo "${info}" | format 'PYTHON_TARGETS'
echo "MAKEOPTS            = $( # <- Syntax
	echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2-
)"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( # <- Syntax
	echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2-
)"
echo "PKGDIR              = $( # <- Syntax
	echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2-
)"
echo "PORTAGE_LOGDIR      = $( # <- Syntax
	echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2-
)"
echo
unset info

export PATH="${path}"
unset path

# Keep environment tidy - multi-line function definitions in the environment
# will break 'environment.sh' variable-passing below, and lead to difficult
# to diagnose build failures!
unset format_fn_code

unset QA_XLINK_ALLOWED
export FEATURES="${FEATURES% -preserve-libs}"

# Save environment for later docker stages...
printf "#FILTER: '%s'\n\n" \
	"${environment_filter}" > "${ROOT}${environment_file}"
export -p |
		grep -E -- '^(declare -x|export) .*=' |
		grep -Ev -- "${environment_filter%")="}|format_fn_code)=" | \
		sed -r 's/\s+/ /g ; s/^(export [a-z][a-z0-9_]+=")\s+/\1/i' | \
		grep -v \
				-e '^export [a-z_]' \
				-e '=""$' \
	>> "${ROOT}${environment_file}" || :
test -e "${ROOT}${environment_file}" ||
	warn "'${ROOT%"/"}${environment_file}' does not exist"
test -s "${ROOT}${environment_file}" ||
	warn "'${ROOT%"/"}${environment_file}' is empty"
grep -- ' ROOT=' "${ROOT}${environment_file}" &&
	die "Invalid 'ROOT' directive in '${ROOT%"/"}${environment_file}'"
#printf ' * Initial propagated environment:\n\n%s\n\n' "$( # <- Syntax
#	cat "${ROOT}${environment_file}"
#)"

case "${1:-}" in
	'')
		echo
		echo " * Building default '${package}' package ..."
		echo

		(
			for ROOT in $( # <- Syntax
					echo "${extra_root:-}" "${ROOT}" |
						xargs -rn 1 |
						sort -u |
						xargs -r
			); do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"
				do_emerge --once-defaults "${package}" || rc=${?}
				if [ $(( rc )) -ne 0 ]; then
					break
				fi
			done
			exit ${rc}
		) || rc=${?}

		check ${rc} "${package}"

		exit ${rc}
		;;

	sh|/bin/sh)
		[ -n "${2:-}" ] && shift

		exec /bin/sh "${@}"
		;;

	bash|/bin/bash)
		[ -n "${2:-}" ] && shift

		exec /bin/bash "${@}"
		;;

	*)
		echo
		if [ -z "${post_pkgs:-}" ]; then
			echo " * Building requested '$( # <- Syntax
				printf '%s' "${*}" | sed 's/--[^ ]\+ //g'
			)' packages ..."
			echo

			(
				for ROOT in $( # <- Syntax
						echo "${extra_root:-}" "${ROOT}" |
							xargs -rn 1 |
							sort -u |
							xargs -r
				); do
					export ROOT
					export SYSROOT="${ROOT}"
					export PORTAGE_CONFIGROOT="${SYSROOT}"
					do_emerge --multi-defaults "${@}" || rc=${?}
					if [ $(( rc )) -ne 0 ]; then
						break
					fi
				done
				exit ${rc}
			) || rc=${?}

			check ${rc} "${@}"

			exit ${rc}

		else # [ -n "${post_pkgs:-}" ]
			echo " * Building requested '$( # <- Syntax
				printf '%s' "${*}" |
					sed 's/--[^ ]\+ //g'
			)' packages (with post-package list) ..."
			echo

			(
				for ROOT in $( # <- Syntax
						echo "${extra_root:-}" "${ROOT}" |
							xargs -rn 1 |
							sort -u |
							xargs -r
				); do
					export ROOT
					export SYSROOT="${ROOT}"
					export PORTAGE_CONFIGROOT="${SYSROOT}"
					# shellcheck disable=SC2086
					do_emerge --defaults ${parallel} --usepkg=y "${@}" ||
						rc=${?}
					if [ $(( rc )) -ne 0 ]; then
						break
					fi
				done
				exit ${rc}
			) || rc=${?}

			check ${rc} "${@}"

			echo
			echo " * Building specified post-installation '${post_pkgs}'" \
				"packages ${post_use:+"with USE='${post_use}' "}..."
			echo

			[ -n "${post_use:-}" ] && export USE="${post_use}"
			eval "$( # <- Syntax
				resolve_python_flags \
					"${USE:-}" \
					"${PYTHON_SINGLE_TARGET:-}" \
					"${PYTHON_TARGETS:-}"
			)"
			export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS

			info="$( LC_ALL='C' emerge --info --verbose=y )"

			echo
			echo 'Resolved build variables for post-installation packages:'
			echo '-------------------------------------------------------'
			echo
			#echo "ROOT                = $( # <- Syntax
			#	echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
			#)"
			#echo "SYSROOT             = $( # <- Syntax
			#	echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
			#)"
			#echo "${info}" | format 'FEATURES'
			echo "${info}" | format 'USE'
			echo "${info}" | format 'PYTHON_SINGLE_TARGET'
			echo "${info}" | format 'PYTHON_TARGETS'
			echo
			unset info

			if [ -n "${EMERGE_OPTS:-}" ] &&
				echo " ${EMERGE_OPTS} " | grep -Eq -- ' --single(-post)? '
			then
				flags=''
				for arg in "${@}" ${post_pkgs}; do
					case "${arg}" in
						-*)
							flags="${flags:+"${flags} "}${arg}"
							;;
					esac
				done
				#first=''
				for arg in ${post_pkgs}; do
					case "${arg}" in
						-*)	continue ;;
						*)
							#if [ -z "${first:-}" ]; then
							#	first="${arg}"
							#	if echo " ${EMERGE_OPTS} " |
							#			grep -Eq -- ' --swap(-post)? '
							#	then
							#		continue
							#	fi
							#fi
							echo
							echo " * Building single post-package '${arg}'" \
								"from '${post_pkgs}' ..."
							echo
							(
								export FEATURES='-fail-clean'
								for ROOT in $( # <- Syntax
										echo "${extra_root:-}" "${ROOT}" |
											xargs -rn 1 |
											sort -u |
											xargs -r
								); do
									export ROOT
									export SYSROOT="${ROOT}"
									export PORTAGE_CONFIGROOT="${SYSROOT}"
									# shellcheck disable=SC2086
									do_emerge --defaults ${parallel} \
										--usepkg=y ${flags:-} ${arg} || rc=${?}
									if [ $(( rc )) -ne 0 ]; then
										break
									fi
								done
								exit ${rc}
							) || rc=${?}
							;;
					esac
				done  # for arg in ${post_pkgs}

			else # grep -Eq -- ' --single(-post)? ' <<<" ${EMERGE_OPTS} "
				(
					for ROOT in $( # <- Syntax
							echo "${extra_root:-}" "${ROOT}" |
								xargs -rn 1 |
								sort -u |
								xargs -r
					); do
						export ROOT
						export SYSROOT="${ROOT}"
						export PORTAGE_CONFIGROOT="${SYSROOT}"
						echo
						echo " * Building post-packages '${post_pkgs}' to ROOT '${ROOT:-"/"}' ..."
						echo

						# shellcheck disable=SC2086
							USE='compile-locales -gmp minimal -openmp' \
						do_emerge --defaults ${parallel} --usepkg=y \
								app-crypt/libb2 \
								sys-apps/coreutils \
								sys-devel/gcc \
								sys-devel/gettext \
								sys-libs/glibc ||
							rc=${?}
						# shellcheck disable=SC2086
							USE='compile-locales gmp minimal' \
						do_emerge --defaults ${parallel} --usepkg=y \
							${post_pkgs} || rc=${?}

						if [ $(( rc )) -ne 0 ]; then
							break
						fi
					done
					exit ${rc}
				) || rc=${?}
			fi

			check ${rc} "${@}"
		fi # [ -n "${post_pkgs:-}" ]

		# Attempt to clean-up Python packages/versions...
		#

		if [ -z "${stage3_flags:-}" ]; then
			die "No cached stage3 data - cannot clean-up Python packages"
		fi

		BUILD_USE="${USE:-}"
		BUILD_PYTHON_SINGLE_TARGET="${python_targets:+"${python_targets%%" "*}"}"
		BUILD_PYTHON_TARGETS="${python_targets:-}"
		eval "$( # <- Syntax
			resolve_python_flags \
					"${BUILD_USE}" \
					"${BUILD_PYTHON_SINGLE_TARGET}" \
					"${BUILD_PYTHON_TARGETS}" |
				sed 's/^/BUILD_/'
		)"
		export BUILD_USE BUILD_PYTHON_SINGLE_TARGET BUILD_PYTHON_TARGETS

		ROOT_USE="${USE:+"${USE} "}$( get_stage3 --values-only USE )"
		ROOT_PYTHON_SINGLE_TARGET="${PYTHON_SINGLE_TARGET:+"${PYTHON_SINGLE_TARGET} "}$( get_stage3 --values-only PYTHON_SINGLE_TARGET )"
		ROOT_PYTHON_TARGETS="${PYTHON_TARGETS:+"${PYTHON_TARGETS} "}$( get_stage3 --values-only PYTHON_TARGETS )"
		eval "$( # <- Syntax
			resolve_python_flags \
					"${ROOT_USE}" \
					"${ROOT_PYTHON_SINGLE_TARGET}" \
					"${ROOT_PYTHON_TARGETS}" |
				sed 's/^/ROOT_/'
		)"
		# FIXME: ROOT_PYTHON_SINGLE_TARGET, ROOT_PYTHON_TARGETS unused
		export ROOT_USE ROOT_PYTHON_SINGLE_TARGET ROOT_PYTHON_TARGETS

		print "Checking for multiple 'python_target'(s) in USE ('${ROOT_USE}') ..."
		if [ $(( $( # <- Syntax
				echo "${ROOT_USE}" |
					xargs -rn 1 |
					grep -c -e 'python_single_target_' -e 'python_targets_'
		) )) -gt 2 ]
		then
			target='' targetpkg='' targets='' remove=''
			target="$( # <- Syntax
				echo "${ROOT_USE}" |
					xargs -rn 1 |
					grep -- 'python_single_target_python' |
					sed 's/python_single_target_//' |
					sort -V |
					tail -n 1
			)"
			# python3_11 -> dev-lang/python-3.11
			targetpkg="dev-lang/$( # <- Syntax
				echo "${target}" | sed 's/^python/python-/ ; s/_/./'
			)"
			print "python target '${target}', package '${targetpkg}'"

			targets="$( # <- Syntax
				echo "${ROOT_USE}" |
					grep -o -- 'python_targets_python[^ ]\+' |
					sed 's/python_targets_//'
			)"
			print "targets: '${targets}'"

			remove="$( # <- Syntax
				echo "${targets}" |
					xargs -rn 1 |
					grep -vx -- "${target}"
			)"
			print "remove: '${remove}'"

			if [ -n "${remove:-}" ]; then
				echo
				echo " * Cleaning old python targets '$( # <- Syntax
					echo "${remove}" | xargs -r
				)' ..."
				echo
				(
					arg='' use='' pkgs=''

					# Add prefix to each item in ${remove}...
					for arg in ${remove}; do
						use="${use:+"${use} "}python_targets_${arg}"
					done
					remove="${use}" use=''

					# loop to allow 'break'...
					# shellcheck disable=SC2066
					for ROOT in $( # <- Syntax
							echo '/' "${ROOT}" |
								xargs -rn 1 |
								sort -u |
								xargs -r
					); do
						SYSROOT="${ROOT}"
						PORTAGE_CONFIGROOT="${SYSROOT}"
						export ROOT SYSROOT PORTAGE_CONFIGROOT

						PYTHON_SINGLE_TARGET="${BUILD_PYTHON_SINGLE_TARGET}"
						if [ "${ROOT}" = '/' ]; then
							USE="$( get_stage3 --values-only USE )"
							PYTHON_TARGETS="$( get_stage3 --values-only PYTHON_TARGETS )"
							export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS
							eval "$( # <- Syntax
								resolve_python_flags \
									"${USE}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
							)"
						else
							USE="${BUILD_USE}"
							PYTHON_TARGETS="${BUILD_PYTHON_TARGETS}"
							export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS
							eval "$( # <- Syntax
								resolve_python_flags \
									"${USE}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
							)"
						fi

						use=''
						for arg in ${USE}; do
							print "Checking for '${arg}' in '${remove}' ..."

							if echo "${remove}" | grep -qw -- "${arg}"; then
								use="${use:+"${use} "}-${arg}"
								print "Matched - 'use' is now '${use}'"

								pkgs="${pkgs:-} $( # <- Syntax
									#grep -Flw -- "${arg}" "${ROOT%"/"}"/var/db/pkg/*/*/IUSE |
									find "${ROOT%"/"}/var/db/pkg/" \
											-mindepth 3 \
											-maxdepth 3 \
											-type f \
											-name 'IUSE' \
											-print0 |
										xargs -r0 grep -Flw -- "${arg}" |
										sed 's|^.*/var/db/pkg/|>=| ; s|/IUSE$||' |
										xargs -r
								)"
								pkgs="$(
									echo "${pkgs}" |
										xargs -rn 1 |
										sort -V |
										uniq
								)"
								print "'pkgs' is now '${pkgs}'"
							else
								print "No match"

								case "${arg}" in
									python_single_target_*)
										continue
										;;
								esac
								use="${use:+"${use} "}${arg}"
								print "Added term - 'use' is now '${use}'"
							fi
						done  # arg in ${USE}
						print "use: '${use}'"

						USE="$( # <- Syntax
							echo "${use:-} python_single_target_${PYTHON_SINGLE_TARGET}" |
								xargs -rn 1 |
								sort -V |
								uniq |
								xargs -r
						)"
						export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS
						eval "$( # <- Syntax
							resolve_python_flags \
								"${USE}" \
								"${PYTHON_SINGLE_TARGET}" \
								"${PYTHON_TARGETS}"
						)"
						pkgs="${pkgs:-} $( # <- Syntax
							#ls -1d "${ROOT%"/"}"/var/db/pkg/dev-python/* |
							find "${ROOT%"/"}/var/db/pkg/dev-python/" \
									-mindepth 1 \
									-maxdepth 1 \
									-type d \
									-print |
								sed 's|^.*/var/db/pkg/|>=| ; s|/$||'
						)"

						info="$( # <- Syntax
								LC_ALL='C' \
								SYSROOT="${ROOT}" \
								PORTAGE_CONFIGROOT="${ROOT}" \
							emerge --info --verbose=y
						)"
						echo
						echo "Resolved build variables for python cleanup stage 1 in ROOT '${ROOT}':"
						echo '---------------------------------------------------'
						echo
						echo "ROOT                = $( # <- Syntax
							echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2-
						)"
						echo "SYSROOT             = $( # <- Syntax
							echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2-
						)"
						echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
							echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2-
						)"
						echo
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_SINGLE_TARGET'
						echo "${info}" | format 'PYTHON_TARGETS'
						print "pkgs: '${pkgs}'"

						# These packages seem to break dependencies, stating
						# that gcc[openmp] is not present when it actually
						# is...
						#
						# At one point, we hit a problem with USE='ssp', but we
						# really don't want to leave this permanently disabled,
						# so let's try bringing it back... ?
						#
						#for root in $( echo '/' "${ROOT:-}" | xargs -n 1 | sort | uniq ); do
						#	arm64_pkgs=''
						#	# '>=dev-python/cython-3.0.6' is failing on arm64 :(
						#	#
						#	[ "${ARCH:-}" = 'arm64' ] && arm64_pkgs='>=dev-python/cython-3.0.6'
						#
						#	for pkg in \
						#			${arm64_pkgs:-} \
						#			sys-devel/gcc \
						#			app-crypt/libb2 \
						#			app-portage/portage-utils
						#	do
						#			ROOT="${root}" \
						#			SYSROOT="${root}" \
						#			USE="$( # <- Syntax
						#				echo " ${USE} " |
						#					sed -r \
						#						-e 's/ python_targets_[^ ]+ / /g' \
						#						-e 's/ python_single_target_([^ ]+) / python_single_target_\1 python_targets_\1 /g' \
						#						-e 's/^ // ; s/ $//'
						#			#) -fortran graphite -jit -nls openmp -sanitize -ssp" \
						#			) -fortran graphite -jit -nls openmp -sanitize" \
						#			PYTHON_TARGETS="${PYTHON_SINGLE_TARGET}" \
						#		do_emerge \
						#					--rebuild-defaults \
						#					--deep \
						#				"${pkg}" ||
						#			rc=${?}
						#		if [ $(( rc )) -ne 0 ]; then
						#			echo "ERROR: Stage 1a cleanup for root '${ROOT}': ${rc}"
						#			break
						#		fi
						#	done  # pkg in ...
						#	unset pkg
						#done  # root in $(...)
						#unset root
						# shellcheck disable=SC2015,SC2086
							USE="$( # <- Syntax
								echo " ${USE} " |
									sed -r \
										-e 's/ python_targets_[^ ]+ / /g' \
										-e 's/ python_single_target_([^ ]+) / python_single_target_\1 python_targets_\1 /g' \
										-e 's/^ // ; s/ $//'
							) openmp" \
							PYTHON_TARGETS="${PYTHON_SINGLE_TARGET}" \
						do_emerge --rebuild-defaults --deep ${pkgs} ||
							rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							echo "ERROR: Stage 1b cleanup for root '${ROOT}': ${rc}"
							break
						fi

						export USE="${USE} -tmpfiles"
						export PYTHON_TARGETS="${BUILD_PYTHON_TARGETS}"

						info="$( # <- Syntax
								LC_ALL='C' \
								SYSROOT="${ROOT}" \
								PORTAGE_CONFIGROOT="${ROOT}" \
							emerge --info --verbose=y
						)"
						echo
						echo "Resolved build variables for python cleanup stage 2 in ROOT '${ROOT}':"
						echo '---------------------------------------------------'
						echo
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_TARGETS'

						# If we clear 'pkgs' then we hit all manner of
						# dependency problems - even though the roots are
						# independent, and identifying the packages built
						# against old python versions should be
						# exhaustive...
						#pkgs=''
						for arg in ${USE}; do
							print "Checking for '${arg}' in '${remove}' ..."

							if echo "${remove}" | grep -qw -- "${arg}"; then
								pkgs="${pkgs:-} $( # <- Syntax
									#grep -Flw -- "${arg}" "${ROOT}"/var/db/pkg/*/*/IUSE |
									find "${ROOT%"/"}/var/db/pkg/" \
											-mindepth 3 \
											-maxdepth 3 \
											-type f \
											-name 'IUSE' \
											-print0 |
										grep -Flw -- "${arg}" |
										sed 's|^.*/var/db/pkg/|=| ; s|/IUSE$||' |
										xargs -r
								)"
								pkgs="$(
									echo "${pkgs}" |
										xargs -rn 1 |
										sort -V |
										uniq
								)"
								print "'pkgs' is now '${pkgs}'"
							fi
						done
						pkgs="${pkgs:-} $( # <- Syntax
							#ls -1d "${ROOT}"/var/db/pkg/dev-python/* |
							find "${ROOT%"/"}/var/db/pkg/dev-python/" \
									-mindepth 1 \
									-maxdepth 1 \
									-type d \
									-print |
								sed 's|^.*/var/db/pkg/|=| ; s|/$||'
						)"
						if
									ROOT='/' \
									SYSROOT='/' \
									PORTAGE_CONFIGROOT='/' \
								portageq get_repos / |
									grep -Fq -- 'srcshelton'
						then
							pkgs="${pkgs:-} virtual/tmpfiles::srcshelton"
						fi
						print "pkgs: '${pkgs}'"

						#USE="${USE:+"${USE} "}-acl -cxx -fortran graphite -jit -ncurses -nls openmp -sanitize" \
						#	do_emerge --rebuild-defaults \
						#			app-crypt/libb2 app-portage/portage-utils \
						#			sys-devel/gcc sys-devel/gettext ||
						#		rc=${?}
						#if [ $(( rc )) -ne 0 ]; then
						#	echo "ERROR: Stage 2 pre-cleanup for root '${ROOT}': ${rc}"
						#	break
						#fi

						# shellcheck disable=SC2086
						do_emerge --rebuild-defaults --update ${pkgs} ||
							rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							echo "ERROR: Stage 2 cleanup for root '${ROOT}': ${rc}"
							break
						fi

						if [ $(( $(
							resolve_python_flags |
								grep -- '^PYTHON_TARGETS=' |
								cut -d'=' -f 2- |
								xargs -rn 1 |
								wc -l
						) )) -gt 1 ]; then
							do_emerge --depclean-defaults "<${targetpkg}" ||
								rc=${?}
							if [ $(( rc )) -ne 0 ]; then
								echo "ERROR: Stage 2 package depclean: ${rc}"
								break
							fi
						fi

						do_emerge --depclean-defaults || rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							echo "ERROR: Stage 2 world depclean: ${rc}"
							break
						fi
					done  # for ROOT in $(...)

					exit ${rc}
				) || rc=${?}

				if [ $(( rc )) -ne 0 ]; then
					echo "ERROR: Old python targets: ${rc}"
				fi
			fi # [ -n "${remove:-}" ]
		fi # multiple python targets

		# TODO: The following package-lists are manually maintained :(
		#
		echo
		echo 'Final package cleanup for root '${ROOT}':'
		echo '---------------------'
		echo
		do_emerge --unmerge-defaults \
			dev-build/meson dev-build/meson-format-array || :
		do_emerge --depclean-defaults dev-libs/icu app-portage/gemato || :
		# shellcheck disable=SC2046
		set -- $( find "${ROOT}"/var/db/pkg/dev-python/ \
				-mindepth 1 \
				-maxdepth 1 \
				-type d |
			rev |
			cut -d'/' -f 1-2 |
			rev |
			sed 's/^/=/' |
			grep -v 'pypy3'
		)
		if [ -n "${*:-}" ]; then
			do_emerge --depclean-defaults "${@:-}"
		fi

		if [ $(( rc )) -ne 0 ]; then
			echo "ERROR: Final package cleanup: ${rc}"
		else
			set +e
			ROOT='/' SYSROOT='/' LC_ALL='C' emerge --check-news
			ROOT='/' SYSROOT='/' LC_ALL='C' eselect --colour=yes news read |
				grep -Fv -- 'No news is good news.'
			printf '\n---\n\n'
			LC_ALL='C' emerge --check-news
			LC_ALL='C' eselect --colour=yes news read |
				grep -Fv -- 'No news is good news.'
		fi

		exit ${rc}
	;;
esac

#[ -n "${trace:-}" ] && set +o xtrace

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker syntax=sh sw=4 ts=4:
