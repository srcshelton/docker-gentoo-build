#! /bin/sh
# shellcheck disable=SC2030,SC2031

# entrypoint.sh

set -eu

# shellcheck disable=SC2034
debug=${DEBUG:-}
# shellcheck disable=SC2034
trace=${TRACE:-}

DEFAULT_JOBS="${DEFAULT_JOBS:-__JOBS__}"
DEFAULT_MAXLOAD="${DEFAULT_MAXLOAD:-__MAXLOAD__}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-__PROFILE__}"
stage3_flags_file="${stage3_flags_file:-__FLAGSFILE__}"
environment_file="${environment_file:-__ENVFILE__}"
environment_filter="${environment_filter:-__ENVFILTER__}"

python_default_targets='python3_11'
stage3_flags=''

export arch="${ARCH}"
unset -v ARCH

die() {
	printf >&2 'FATAL: %s\n' "${*:-Unknown error}"
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
	# Pad $fmt_var with $fmt_pad trailing spaces
	#
	fmt_var="${1:-}"
	fmt_pad="${2:-20}"

	[ -n "${fmt_var:-}" ] || return 1

	fmt_spaces='' fmt_str=''

	fmt_var="$( echo "${fmt_var}" | xargs -rn 1 | sort -d | xargs -r )"
	fmt_spaces="$( printf "%${fmt_pad}s" )"
	fmt_str="%-${fmt_pad}s= \"%s\"\\n"

	# shellcheck disable=SC2059
	printf "${fmt_str}" "${fmt_var}" "$(
		cat - |
			grep -- "^${fmt_var}=" |
			cut -d'"' -f 2 |
			fmt -w $(( ${COLUMNS:-80} - ( fmt_pad + 3 ) )) |
			sed "s/^/   ${fmt_spaces}/ ; 1 s/^\s\+//"
	)"

	unset fmt_str fmt_spaces fmt_pad fmt_var

	return 0
}  # format
EOF
)"
export format_fn_code
eval "${format_fn_code}"

check() {
	# Check that a given check_pkg (with build result code $check_rc) is actually
	# installed...
	#
	check_rc="${1:-}" ; shift

	[ -n "${check_rc:-}" ] || return 1

	check_pkg='' check_arg=0

	if [ $(( check_rc )) -eq 0 ]; then
		# Process first package of list only...
		for check_arg in "${@}"; do
			case "${check_arg}" in
				-*)	continue ;;
				*)	check_pkg="${check_arg}" ; break ;;
			esac
		done
		check_pkg="$( echo "${check_pkg}" | sed -r 's/^[^a-z]+([a-z])/\1/' )"
		if echo "${check_pkg}" | grep -Fq -- '/'; then
			if ! ls -1d \
				"${ROOT:-}/var/db/pkg/${check_pkg%::*}"* >/dev/null 2>&1
			then
				die "emerge indicated success but check_pkg '${check_pkg%::*}'" \
					"does not appear to be installed"
			fi
		else
			if ! ls -1d \
				"${ROOT:-}/var/db/pkg"/*/"${check_pkg%::*}"* >/dev/null 2>&1
			then
				die "emerge indicated success but check_pkg '${check_pkg%::*}'" \
					"does not appear to be installed"
			fi
		fi
	fi

	unset check_pkg check_arg

	return $(( check_rc ))
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
	)" # ' # <- Syntax highlight failure
	print "get_stage3 get_result for '${get_type}' is '${get_result}'"

	if [ "${get_type}" = 'USE' ]; then
		# Remove USE flags which apply to multiple packages, but can only be
		# present for one package per installation ROOT...
		get_result="$( # <- Syntax
			echo "${get_result}" |
				xargs -rn 1 |
				grep -vw -e 'hostname' -e 'su' -e 'kill' |
				xargs -r
		)"
		print "get_stage3 get_result for USE('${get_type}') after filter is '${get_result}'"

		entries='' entry=''
		entries="$( # <- Syntax
			echo "${stage3_flags}" |
				grep -- "^STAGE3_PYTHON_SINGLE_TARGET=" |
				cut -d'"' -f 2
		)" # ' # <- Syntax highlight failure
		print "get_stage3 entries for SINGLE_TARGET is '${entries}'"

		for entry in ${entries}; do
			get_result="${get_result:+"${get_result} "}python_single_target_${entry}"
		done
		print "get_stage3 get_result for USE('${get_type}') after single is '${get_result}'"

		entries="$( # <- Syntax
			echo "${stage3_flags}" |
				grep -- "^STAGE3_PYTHON_TARGETS=" |
				cut -d'"' -f 2
		)" # ' # <- Syntax highlight failure
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
		LC_ALL='C' SYSROOT="${ROOT:-/}" PORTAGE_CONFIGROOT="${ROOT:-/}" \
			emerge --info --verbose
	)"

	# We seem to have a weird situation where USE and PYTHON_*
	# variables are not in sync with each other...?
	resolve_use="${USE:+"${USE} "}${resolve_use:+"${resolve_use} "}$( # <- Syntax
		echo "${resolve_info}" | grep -- "^USE=" | cut -d'"' -f 2
	)" # ' # <- Syntax highlight failure
	resolve_python_single_target="${PYTHON_SINGLE_TARGET:-} ${resolve_python_single_target:-} $( # <- Syntax
		echo "${resolve_info}" | grep -- "^PYTHON_SINGLE_TARGET=" | cut -d'"' -f 2
	)${python_targets:+" ${python_targets%% *}"}" # ' # <- Syntax highlight failure
	resolve_python_targets="${PYTHON_TARGETS:-} ${resolve_python_targets:-} $( # <- Syntax
		echo "${resolve_info}" | grep -- "^PYTHON_TARGETS=" | cut -d'"' -f 2
	) ${python_targets:-}" # ' # <- Syntax highlight failure

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
* This script is running as it exists on-disk, overriding the Docker image    *
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
	parallel="${parallel:+${parallel} }--load-average=${MAXLOAD:-${DEFAULT_MAXLOAD}}"
fi

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
if [ -n "${post_use:-}" ]; then
	if ! printf ' %s ' "${post_use:-}" | grep -Fq -- ' -* '; then
		post_use="${USE:+${USE} }${post_use:-}"
	fi
else
	post_use="${USE:-}"
fi
if [ -n "${use_essential:-}" ] && ! echo "${post_use:-}" |
		grep -Fq -- "${use_essential}"
then
	post_use="${post_use:+${post_use} }${use_essential}"
fi

# At the point we're executed, we expect to be in a stage3 with appropriate
# repositories mounted...

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
# shellcheck disable=SC2166
[ -s "${PKGDIR}"/Packages -a -d "${PKGDIR}"/virtual ] ||
	warn "'${PKGDIR}/Packages' or '${PKGDIR}/virtual' are missing - package" \
		"cache appears invalid"

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
	LC_ALL='C' emerge --info --verbose
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
# shellcheck disable=SC2015
printf ' %s ' "${*}" | grep -Fq -- ' --nodeps ' && opts='' || :

LC_ALL='C' eselect --colour=yes profile list
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" # 2>/dev/null

LC_ALL='C' emaint --fix binhost

LC_ALL='C' emerge --check-news
LC_ALL='C' eselect --colour=yes news read

#set -o xtrace

# As-of sys-libs/zlib-1.2.11-r3, zlib builds without error but then the portage
# merge process aborts with 'unable to read SONAME from libz.so' in src_install
#
# To try to work around this, snapshot the current stage3 version...
#quickpkg --include-config y --include-unmodified-config y sys-libs/zlib

# To make the following output potentially clearer, attempt to remove any
# masked packages which exist in the image we're building from...
echo
echo " * Attempting to remove masked packages from stage3 ..."
echo
(
	mkdir -p /var/lib/portage
	echo 'virtual/libc' > /var/lib/portage/world

	USE="-* $( get_stage3 --values-only USE )"
	export USE
	export FEATURES="${FEATURES:+${FEATURES} }-fakeroot"
	export LC_ALL='C'
	list='virtual/dev-manager'
	if portageq get_repos / | grep -Fq -- 'srcshelton'; then
		list="${list:-} sys-apps/systemd-utils"
	fi
	# 'dhcpcd' is now built with USE='udev'...
	#
	# shellcheck disable=SC2012,SC2086,SC2046
	emerge \
			--ignore-default-opts \
			--binpkg-changed-deps=y \
			--binpkg-respect-use=y \
			--buildpkg=n \
			--color=y \
			--keep-going=y \
			--oneshot \
			--quiet-build=y \
			${opts:-} \
			--usepkg=y \
			--verbose=y \
			--verbose-conflicts \
			--with-bdeps=n \
			--with-bdeps-auto=n \
		net-misc/dhcpcd
	# shellcheck disable=SC2086
	emerge \
			--ignore-default-opts \
			--color=y \
			--implicit-system-deps=n \
			--keep-going=y \
			--verbose=n \
			--with-bdeps-auto=n \
			--with-bdeps=n \
			--unmerge \
		${list} || :
	#virtual/udev-217-r3 pulled in by:
	#    sys-apps/hwids-20210613-r1 requires virtual/udev
	#    sys-fs/udev-init-scripts-34 requires >=virtual/udev-217
	#    virtual/dev-manager-0-r2 requires virtual/udev
	list="$( # <- Syntax
		{
			sed 's/#.*$//' /etc/portage/package.mask/* |
				grep -v -- 'gentoo-functions'

			sed 's/#.*$//' /etc/portage/package.mask/* |
				grep -Eow -- '((virtual|sys-fs)/)?udev' &&
			printf 'sys-apps/hwids sys-fs/udev-init-scripts'
		} |
			grep -Fv -- '::' |
			sort -V |
			xargs -r
	)"
	echo "Package list: ${list}"
	echo
	# shellcheck disable=SC2046,SC2086
	emerge \
			--ignore-default-opts \
			--color=y \
			--implicit-system-deps=n \
			--keep-going=y \
			--verbose=y \
			--with-bdeps-auto=n \
			--with-bdeps=n \
			--depclean \
		${list}
)

if portageq get_repos / | grep -Fq -- 'srcshelton'; then
	echo
	echo " * Building linted 'sys-apps/gentoo-functions' package for stage3 ..."
	echo
	(
		USE="-* $( get_stage3 --values-only USE )"
		export USE
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean -fakeroot"
		export LC_ALL='C'
		# shellcheck disable=SC2086
		emerge \
				--ignore-default-opts \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=n \
				--color=y \
				--keep-going=y \
				--quiet-build=y \
				${opts:-} \
				--usepkg=y \
				--verbose-conflicts \
				--verbose=y \
				--with-bdeps-auto=n \
				--with-bdeps=n \
			'sys-apps/gentoo-functions::srcshelton'
	)
fi

echo
echo " * Building 'sys-apps/fakeroot' package for stage3 ..."
echo
(
	USE="-* $( get_stage3 --values-only USE )"
	export USE
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean -fakeroot"
	export LC_ALL='C'
	# shellcheck disable=SC2086
	emerge \
			--ignore-default-opts \
			--binpkg-changed-deps=y \
			--binpkg-respect-use=y \
			--buildpkg=n \
			--color=y \
			--keep-going=y \
			--quiet-build=y \
			${opts:-} \
			--usepkg=y \
			--verbose-conflicts \
			--verbose=y \
			--with-bdeps-auto=n \
			--with-bdeps=n \
		sys-apps/fakeroot
)
export FEATURES="${FEATURES:+${FEATURES} }fakeroot"

if ! [ -d "/usr/${CHOST}" ]; then
	echo
	echo " * CHOST change detected - ensuring stage3 is up to date ..."
	echo

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
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
		export LC_ALL='C'
		# shellcheck disable=SC2086
		emerge \
				--ignore-default-opts \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=n \
				--color=y \
				--keep-going=y \
				--quiet-build=y \
				${opts:-} \
				--update \
				--usepkg=y \
				--verbose-conflicts \
				--verbose=y \
				--with-bdeps-auto=n \
				--with-bdeps=n \
			'@system' '@world'
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
			export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
			export LC_ALL='C'
			# shellcheck disable=SC2086
			emerge \
					--ignore-default-opts \
					--binpkg-changed-deps=y \
					--binpkg-respect-use=y \
					--buildpkg=n \
					--color=y \
					--keep-going=y \
					--quiet-build=y \
					${opts:-} \
					--usepkg=y \
					--verbose=y \
					--verbose-conflicts \
					--with-bdeps=n \
					--with-bdeps-auto=n \
				"${pkg}"
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
	env-update || :
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

	# shellcheck disable=SC2041
	#for pkg in 'dev-libs/libgpg-error' 'sys-devel/libtool'; do
	for pkg in 'sys-devel/libtool'; do
		(
			USE="-* $( get_stage3 --values-only USE )"
			export USE
			export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
			export LC_ALL='C'
			# shellcheck disable=SC2086
			emerge \
					--ignore-default-opts \
					--binpkg-changed-deps=y \
					--binpkg-respect-use=y \
					--buildpkg=n \
					--color=y \
					--keep-going=y \
					--quiet-build=y \
					${opts:-} \
					--usepkg=y \
					--verbose=y \
					--verbose-conflicts \
					--with-bdeps=n \
					--with-bdeps-auto=n \
				"${pkg}"
		)
		LC_ALL='C' etc-update --quiet --preen
		find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
	done
	[ -x /usr/sbin/fix_libtool_files.sh ] &&
		/usr/sbin/fix_libtool_files.sh "$( # <- Syntax
			gcc -dumpversion
		)" --oldarch "${oldchost}"

	(
		USE="-* nptl $( get_stage3 --values-only USE )"
		export USE
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
		export LC_ALL='C'

		# clashing USE flags can't be resolved with current level of
		# command-line fine-grained package flag control :(
		exclude='sys-apps/coreutils sys-apps/net-tools sys-apps/util-linux sys-process/procps sys-apps/shadow'

		# shellcheck disable=SC2012,SC2086,SC2046
		emerge \
				--ignore-default-opts \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=n \
				--color=y \
				--exclude "${exclude}" \
				--keep-going=y \
				--oneshot \
				--quiet-build=y \
				${opts:-} \
				--usepkg=y \
				--verbose=y \
				--verbose-conflicts \
				--with-bdeps=n \
				--with-bdeps-auto=n \
			dev-libs/libgpg-error
		#ls -l "/usr/bin/${CHOST}-gpg-error-config"
		#cat /var/db/pkg/dev-libs/libgpg-error*/CONTENTS

		# shellcheck disable=SC2012,SC2086,SC2046
		emerge \
				--ignore-default-opts \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=n \
				--color=y \
				--emptytree \
				--exclude "${exclude}" \
				--keep-going=y \
				--oneshot \
				--quiet-build=y \
				${opts:-} \
				--usepkg=y \
				--verbose=y \
				--verbose-conflicts \
				--with-bdeps=n \
				--with-bdeps-auto=n \
			$( # <- Syntax
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
	LC_ALL='C' eselect --colour=yes news read new |
		grep -Fv -- 'No news is good news.' || :
	LC_ALL='C' etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
fi

echo
echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source" \
	"package ..."
echo

# Some packages require prepared kernel sources ...
#
(
	USE="-* $( get_stage3 --values-only USE ) symlink"
	# Since app-alternatives/* packages are now mandatory, the USE flags these
	# packages rely upon must also be set in order to avoid REQUIRED_USE
	# errors.
	# TODO: Fix this better...
	USE="${USE} gnu gawk"
	export USE
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
	export LC_ALL='C'
	# shellcheck disable=SC2086
	emerge \
			--ignore-default-opts \
			--binpkg-changed-deps=y \
			--binpkg-respect-use=y \
			--buildpkg=n \
			--color=y \
			--keep-going=y \
			--quiet-build=y \
			${opts:-} \
			--usepkg=y \
			--verbose=y \
			--verbose-conflicts \
			--with-bdeps=n \
			--with-bdeps-auto=n \
		sys-kernel/gentoo-sources
)

echo
echo ' * Configuring stage3 kernel sources ...'
echo

#pushd >/dev/null /usr/src/linux
src_cwd="${PWD}"
cd /usr/src/linux/
make defconfig prepare
#popd >/dev/null
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
		'sys-devel/gcc'
		#'app-eselect/eselect-awk' \
		#'virtual/awk' \
do
	echo
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		USE="-* $( get_stage3 --values-only USE )"
		# shellcheck disable=SC2154
		USE="${USE} ${use_essential_gcc} gawk"
		if [ "${arch}" = 'arm64' ]; then
			USE="${USE} gold"
		fi
		#case "${pkg}" in
		#	*libcrypt|*libxcrypt)
		#		USE="${USE} static-libs"
		#		;;
		#esac
		export USE
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
		export LC_ALL='C'
		# shellcheck disable=SC2086
		emerge \
				--ignore-default-opts \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=n \
				--color=y \
				--keep-going=y \
				--quiet-build=y \
				${opts:-} \
				--usepkg=y \
				--verbose=y \
				--verbose-conflicts \
				--with-bdeps=n \
				--with-bdeps-auto=n \
			"${pkg}"
	)
	LC_ALL='C' eselect --colour=yes news read new |
		grep -Fv -- 'No news is good news.' || :
	LC_ALL='C' etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done
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

export ROOT="/build"
export SYSROOT="${ROOT}"
export PORTAGE_CONFIGROOT="${SYSROOT}"

if [ ! -d "${ROOT}"/usr/src/linux ] || [ ! -L /usr/src/linux ]; then
	[ -d "${ROOT}"/usr/src ] && rm -r "${ROOT}"/usr/src
	mkdir -p "${ROOT}"/usr/src/
	mv /usr/src/linux* "${ROOT}"/usr/src/
	ln -s ../../"${ROOT}"/usr/src/linux /usr/src/
fi

mkdir -p "${ROOT}"/etc
cp -r /etc/portage "${ROOT}"/etc/
cp /etc/locale.gen "${ROOT}"/etc/
cp /etc/timezone "${ROOT}"/etc/
cp /etc/etc-update.conf "${ROOT}"/etc/

path="${PATH}"
PATH="${PATH}:${ROOT}$( echo "${PATH}" | sed "s|:|:${ROOT}|g" )"
export PATH

if command -v env-update >/dev/null 2>&1; then
	LC_ALL='C' env-update
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
# somehow on amd64 gcc still gets 'nptl'.  An arm64, however, this doesn't
# happen and everything breaks :(
#
# Let's try to fix that...
export USE="${USE:+${USE} }${use_essential} nptl"

# FIXME: Expose this somewhere?
features_libeudev=1

# Do we need to rebuild the root packages as well?
#
# This can be required if the upstream stage image is significantly old
# compared to the current portage tree...
#extra_root='/'

# sys-apps/help2man with USE 'nls' requires Locale-gettext, which depends
# on sys-apps/help2man;
# sys-libs/libcap can USE pam, which requires libcap;
# sys-apps/help2man requires dev-python/setuptools which must have been built
# with the same PYTHON_*TARGET* flags as are currently active...
pkg_initial='sys-apps/fakeroot sys-libs/libcap sys-process/audit sys-apps/util-linux app-shells/bash sys-apps/help2man dev-perl/Locale-gettext sys-libs/libxcrypt virtual/libcrypt app-editors/vim'
pkg_initial_use='-nls -pam -perl -python -su'
pkg_exclude=''
if [ -n "${features_libeudev}" ]; then
	pkg_initial="${pkg_initial:+${pkg_initial} }sys-libs/libeudev virtual/libudev"
	pkg_exclude="${pkg_exclude:+${pkg_exclude} }--exclude=virtual/udev"
fi

if [ -n "${pkg_initial:-}" ]; then
	export python_targets PYTHON_SINGLE_TARGET PYTHON_TARGETS
	print "'python_targets' is '${python_targets:-}', 'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}', 'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"
	(
		export LC_ALL='C'

		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"

		export USE="${pkg_initial_use}${use_essential:+ ${use_essential}}"
		if [ "${ROOT:-/}" = '/' ]; then
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
			PYTHON_SINGLE_TARGET="${python_targets:+"${python_targets%% *}"}"
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
		#case "${pkg}" in
		#	*libcrypt|*libxcrypt)
		#		USE="${USE} static-libs"
		#		;;
		#esac

		info="$( emerge --info --verbose )"
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

				# First package in '${pkg_initial}' to have python deps...
				# TODO: It'd be nice to have a had_deps() function here to
				#       remove this hard-coding...
				if [ "${pkg}" = 'sys-apps/help2man' ]; then
					(
						ROOT='/'
						SYSROOT="${ROOT}"
						PORTAGE_CONFIGROOT="${SYSROOT}"
						export ROOT SYSROOT PORTAGE_CONFIGROOT

						eval "$( # <- Syntax
							resolve_python_flags \
									"${USE:-}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
						)"
						export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS

						info="$( emerge --info --verbose )"
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

						# shellcheck disable=SC2086
						emerge \
								--ignore-default-opts \
								${parallel} \
								--binpkg-respect-use=y \
								--binpkg-changed-deps=y \
								--buildpkg=n \
								--color=y \
								--deep \
								--emptytree \
								--keep-going=y \
								--quiet-build=y \
								${opts:-} \
								--usepkg=y \
								--verbose=y \
								--verbose-conflict \
								--with-bdeps=y \
								--with-bdeps-auto=y \
							dev-python/setuptools # || :
					)
					# Install same dependencies again within our build ROOT...
					(
						# shellcheck disable=SC2086
						emerge \
								--ignore-default-opts \
								${parallel} \
								--binpkg-respect-use=y \
								--binpkg-changed-deps=y \
								--buildpkg=n \
								--color=y \
								--deep \
								--emptytree \
								--keep-going=y \
								--quiet-build=y \
								${opts:-} \
								--usepkg=y \
								--verbose=y \
								--verbose-conflict \
								--with-bdeps=y \
								--with-bdeps-auto=y \
							dev-python/setuptools # || :
					)
				fi

				# shellcheck disable=SC2086
				emerge \
						--ignore-default-opts \
						${parallel} \
						--binpkg-changed-deps=n \
						--binpkg-respect-use=y \
						--buildpkg=n \
						--color=y \
						--keep-going=y \
						--quiet-build=y \
						${opts:-} \
						--usepkg=y \
						--verbose=y \
						--verbose-conflict \
						--with-bdeps=n \
						--with-bdeps-auto=n \
					${pkg} ${pkg_exclude:-} # || :

				etc-update --quiet --preen
				find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

				if echo " ${pkg} " | grep -q -- ' app-shells/bash '; then
					fix_sh_symlink "${ROOT}" 'pre-deploy'
				fi
			done
		done
	)
fi

echo
echo ' * Building @system packages ...'
echo

(
	#set -x
	# sys-apps/shadow is needed for /sbin/nologin
	# dev-libs/icu is needed for circular dependencies on icu -> python -> ...
	#	sqlite -> icu
	# libarchive is a frequent dependency, and so quicker to pull-in here
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
	USE="${USE:+${USE} }${use_essential_gcc}"
	if
		  echo " ${USE} " | grep -q -- ' -nptl ' ||
		! echo " ${USE} " | grep -q -- ' nptl '
	then
		warn "USE flag 'nptl' missing from or disabled in \$USE"
		USE="${USE:+$( echo "${USE}" | sed 's/ \?-\?nptl \?/ /' ) }nptl"
		info "USE is now '${USE}'"
	fi
	export USE
	export LC_ALL='C'
	for ROOT in $( # <- Syntax
			echo "${extra_root:-}" "${ROOT}" |
				xargs -rn 1 |
				sort -u
	); do
		export ROOT
		export SYSROOT="${ROOT}"
		export PORTAGE_CONFIGROOT="${SYSROOT}"

		eval "${format_fn_code}"

		info="$( LC_ALL='C' emerge --info --verbose )"
		echo
		echo 'Resolved build variables for @system:'
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

		# shellcheck disable=SC2086
		emerge \
				--ignore-default-opts \
				${parallel} \
				--binpkg-changed-deps=y \
				--binpkg-respect-use=y \
				--buildpkg=y \
				--color=y \
				--deep \
				--emptytree \
				--keep-going=y \
				--rebuild-if-new-slot=y \
				--rebuilt-binaries=y \
				--quiet-build=y \
				--root-deps \
				${opts:-} \
				--usepkg=y \
				--verbose=y \
				--verbose-conflicts \
				--with-bdeps=n \
				--with-bdeps-auto=n \
			@system sys-devel/gcc sys-apps/shadow dev-libs/icu \
				app-arch/libarchive ${pkg_initial} ${pkg_exclude:-} # || :
	done
)
LC_ALL='C' etc-update --quiet --preen
find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

# Ensure we have a valid /bin/sh symlink in our ROOT ...
fix_sh_symlink "${ROOT}" '@system'

# ... and fix the default bash prompt setup w.r.t. 'screen' window names!
if [ -s /etc/bash/bashrc.patch ]; then
	if ! command -v patch >/dev/null; then
		warn "@system build has not installed package 'sys-devel/patch'"
	else
		#pushd >/dev/null "${ROOT}"/etc/bash/
		src_cwd="${PWD}"
		cd "${ROOT}"/etc/bash/

		if [ -s bashrc ]; then
			echo ' * Patching /etc/bash/bashrc ...'
			patch -p1 -r - -s </etc/bash/bashrc.patch || :
		else
			warn "'${ROOT%/}/etc/bash/bashrc' does not exist or is empty"
		fi

		#popd >/dev/null
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
	file=''
	for file in "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log; do
		cat="$( echo "${file}" | rev | cut -d'/' -f 4 | rev )"
		pkg="$( echo "${file}" | rev | cut -d'/' -f 3 | rev )"
		mkdir -p "${PORTAGE_LOGDIR}/failed/${cat}"
		mv "${file}" "${PORTAGE_LOGDIR}/failed/${cat}/${pkg}.log"
	done
	unset file
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
LC_ALL='C' eselect --colour=yes news read new

# At this point, we should have a fully-built @system!

export EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS:+${EMERGE_DEFAULT_OPTS} } --with-bdeps=y --with-bdeps-auto=y"

info="$( LC_ALL='C' emerge --info --verbose )"
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

# Save environment for later docker stages...
printf "#FILTER: '%s'\n\n" \
	"${environment_filter}" > "${ROOT}${environment_file}"
export -p |
		grep -E -- '^(declare -x|export) .*=' |
		grep -Ev -- "${environment_filter%)=}|format_fn_code)=" | \
		sed -r 's/\s+/ /g ; s/^(export [a-z][a-z0-9_]+=")\s+/\1/i' | \
		grep -v \
				-e '^export [a-z_]' \
				-e '=""$' \
	>> "${ROOT}${environment_file}" || :
test -e "${ROOT}${environment_file}" ||
	warn "'${ROOT%/}${environment_file}' does not exist"
test -s "${ROOT}${environment_file}" ||
	warn "'${ROOT%/}${environment_file}' is empty"
grep -- ' ROOT=' "${ROOT}${environment_file}" &&
	die "Invalid 'ROOT' directive in '${ROOT%/}${environment_file}'"
#printf " * Initial propagated environment:\n\n%s\n\n" "$( # <- Syntax
#	<"${ROOT}${environment_file}"
#)"

case "${1:-}" in
	'')
		echo
		echo " * Building default '${package}' package ..."
		echo

		print "Running default 'emerge" \
			"${parallel:+${parallel} }${opts:+${opts} }--usepkg=y" \
			"\"${package}\"'"

		(
			export LC_ALL='C'
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
				emerge ${parallel} ${opts} --usepkg=y "${package}" || rc=${?}
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

			# shellcheck disable=SC2016
			print "Running 'emerge" \
				"${parallel:+${parallel} }${opts:+${opts} }--usepkg=y" \
				"${*}'${USE:+ with USE='${USE}'}"
			(
				export LC_ALL='C'
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
					emerge ${parallel} ${opts} --usepkg=y "${@}" || rc=${?}
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

			# shellcheck disable=SC2016
			print "Running 'emerge" \
				"${parallel:+${parallel} }${opts:+${opts} }--usepkg=y" \
				"${*}'${USE:+ with USE='${USE}'}"
			(
				export LC_ALL='C'
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
					emerge ${parallel} ${opts} --usepkg=y "${@}" || rc=${?}
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

			info="$( LC_ALL='C' emerge --info --verbose )"

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

			if [ -n "${EMERGE_OPTS:-}" ] && echo " ${EMERGE_OPTS} " |
					grep -Eq -- ' --single(-post)? '
			then
				flags=''
				for arg in "${@}" ${post_pkgs}; do
					case "${arg}" in
						-*)
							flags="${flags:+${flags} }${arg}"
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
							# shellcheck disable=SC2016
							print "Running 'emerge" \
								"${parallel:+${parallel} }${opts:+${opts} }--usepkg=y" \
								"${arg}'${USE:+ with USE='${USE}'}"
							(
								export LC_ALL='C'
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
									emerge ${parallel} ${opts} \
										--usepkg=y ${flags:-} ${arg} || rc=${?}
									if [ $(( rc )) -ne 0 ]; then
										break
									fi
								done
								exit ${rc}
							) || rc=${?}
							;;
					esac
				done
			else # grep -Eq -- ' --single(-post)? ' <<<" ${EMERGE_OPTS} "
				echo
				echo " * Building post-packages '${post_pkgs}' ..."
				echo
				# shellcheck disable=SC2016
				print "Running 'emerge" \
					"${parallel:+${parallel} }${opts:+${opts} }--usepkg=y" \
					"${post_pkgs}'${USE:+ with USE='${USE}'}"
				(
					export LC_ALL='C'
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
						emerge ${parallel} ${opts} \
								--usepkg=y \
							${post_pkgs} || rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							break
						fi
					done
					exit ${rc}
				) || rc=${?}
			fi

			check ${rc} "${@}"

			if [ -z "${stage3_flags:-}" ]; then
				die "No cached stage3 data - cannot clean-up Python packages"
			fi

			BUILD_USE="${USE:-}"
			BUILD_PYTHON_SINGLE_TARGET="${python_targets:+"${python_targets%% *}"}"
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

						export LC_ALL='C'

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
									print "Matched - use is now '${use}'"

									pkgs="${pkgs:-} $( # <- Syntax
										#grep -Flw -- "${arg}" "${ROOT%/}"/var/db/pkg/*/*/IUSE |
										find "${ROOT%/}/var/db/pkg/" \
												-mindepth 3 \
												-maxdepth 3 \
												-type f \
												-name 'IUSE' \
												-print0 |
											xargs -r0 grep -Flw -- "${arg}" |
											sed 's|^.*/var/db/pkg/|>=| ; s|/IUSE$||'
									)"
									print "pkgs is now '${pkgs}'"
								else
									print "No match"

									case "${arg}" in
										python_single_target_*)
											continue ;;
									esac
									use="${use:+"${use} "}${arg}"
									print "Added term - use is now '${use}'"
								fi
							done
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
								#ls -1d "${ROOT%/}"/var/db/pkg/dev-python/* |
								find "${ROOT%/}/var/db/pkg/dev-python/" \
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
									emerge --info --verbose
							)"
							echo
							echo 'Resolved build variables for python cleanup stage 1:'
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

							# shellcheck disable=SC2086
							USE="$( # <- Syntax
								echo " ${USE} " |
									sed -r \
										-e 's/ python_targets_[^ ]+ / /g' \
										-e 's/ python_single_target_([^ ]+) / python_single_target_\1 python_targets_\1 /g' \
										-e 's/^ // ; s/ $//'
							)" \
							PYTHON_TARGETS="${PYTHON_SINGLE_TARGET}" \
							emerge ${parallel} ${opts} \
									--usepkg=y \
								${pkgs} || rc=${?}
							if [ $(( rc )) -ne 0 ]; then
								echo "ERROR: Stage 1 cleanup: ${rc}"
								break
							fi

							export USE="${USE} -tmpfiles"
							export PYTHON_TARGETS="${BUILD_PYTHON_TARGETS}"

							info="$( # <- Syntax
								LC_ALL='C' \
								SYSROOT="${ROOT}" \
								PORTAGE_CONFIGROOT="${ROOT}" \
									emerge --info --verbose
							)"
							echo
							echo 'Resolved build variables for python cleanup stage 2:'
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
										find "${ROOT%/}/var/db/pkg/" \
												-mindepth 3 \
												-maxdepth 3 \
												-type f \
												-name 'IUSE' \
												-print0 |
											grep -Flw -- "${arg}" |
											sed 's|^.*/var/db/pkg/|=| ; s|/IUSE$||'
									)"
									print "pkgs is now '${pkgs}'"
								fi
							done
							pkgs="${pkgs:-} $( # <- Syntax
								#ls -1d "${ROOT}"/var/db/pkg/dev-python/* |
								find "${ROOT%/}/var/db/pkg/dev-python/" \
										-mindepth 1 \
										-maxdepth 1 \
										-type d \
										-print |
									sed 's|^.*/var/db/pkg/|=| ; s|/$||'
							)"
							if ROOT="/" SYSROOT="/" PORTAGE_CONFIGROOT="/" portageq get_repos / | grep -Fq -- 'srcshelton'; then
								pkgs="${pkgs:-} virtual/tmpfiles::srcshelton"
							fi
							print "pkgs: '${pkgs}'"

							# shellcheck disable=SC2086
							emerge ${parallel} ${opts} \
									--usepkg=y \
								${pkgs} || rc=${?}
							if [ $(( rc )) -ne 0 ]; then
								echo "ERROR: Stage 2 cleanup: ${rc}"
								break
							fi

							if [ $(( $( resolve_python_flags | grep -- '^PYTHON_TARGETS=' | cut -d'=' -f 2- | xargs -rn 1 | wc -l ) )) -gt 1 ]; then
								# shellcheck disable=SC2086
								emerge ${parallel} ${opts} \
										--depclean \
									"<${targetpkg}" || rc=${?}
								if [ $(( rc )) -ne 0 ]; then
									echo "ERROR: Stage 2 package depclean: ${rc}"
									break
								fi
							fi

							# shellcheck disable=SC2086
							emerge ${parallel} ${opts} \
									--depclean || rc=${?}
							if [ $(( rc )) -ne 0 ]; then
								echo "ERROR: Stage 2 world depclean: ${rc}"
								break
							fi
						done

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
			echo 'Final package cleanup:'
			echo '---------------------'
			echo
			# shellcheck disable=SC2086
			emerge ${parallel} ${opts} \
					--unmerge dev-util/meson dev-util/meson-format-array || :
			# shellcheck disable=SC2086
			emerge ${parallel} ${opts} \
					--depclean dev-libs/icu app-portage/gemato || :
			# shellcheck disable=SC2046,SC2086
			find "${ROOT}"/var/db/pkg/dev-python/ \
					-mindepth 1 \
					-maxdepth 1 \
					-type d |
				rev |
				cut -d'/' -f 1-2 |
				rev |
				sed 's/^/=/' |
				grep -v 'pypy3' |
				xargs -r emerge ${parallel} ${opts} --depclean || :

			if [ $(( rc )) -ne 0 ]; then
				echo "ERROR: Final package cleanup: ${rc}"
			fi
			exit ${rc}
		fi # [ -n "${post_pkgs:-}" ]
		;;
esac

#[ -n "${trace:-}" ] && set +o xtrace

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker syntax=sh sw=4 ts=4:
