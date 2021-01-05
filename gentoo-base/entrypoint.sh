#! /bin/sh
# shellcheck disable=SC2030,SC2031

set -eu

# shellcheck disable=SC2034
debug=${DEBUG:-}
# shellcheck disable=SC2034
trace=${TRACE:-}

DEFAULT_JOBS='__JOBS__'
DEFAULT_MAXLOAD='__MAXLOAD__'
DEFAULT_PROFILE='__PROFILE__'
environment_filter='__ENVFILTER__'

arch="${ARCH:-amd64}"
unset -v ARCH

die() {
	printf 'FATAL: %s\n' "${*:-Unknown error}"
	exit 1
} # die

warn() {
	[ -z "${*:-}" ] && echo || printf 'WARN:  %s\n' "${*}"
} # warn

print() {
	#if [ -n "${DEBUG:-}" ]; then
		[ -z "${*:-}" ] && echo || printf >&2 'DEBUG: %s\n' "${*}"
	#fi
} # print

format() {
	variable="${1:-}"
	padding=${2:-20}

	[ -n "${variable:-}" ] || return 1

	spaces="$( printf "%${padding}s" )"
	string="%-${padding}s= \"%s\"\\n"

	# shellcheck disable=SC2059
	printf "${string}" "${variable}" "$(
		cat - | grep -- "^${variable}=" | cut -d'"' -f 2 | fmt -w $(( ${COLUMNS:-80} - ( padding + 3 ) )) | sed "s/^/   ${spaces}/ ; 1 s/^\s\+//"
	)"
} # format

check() {
	crc=${1:-} ; shift

	[ -n "${crc:-}" ] || return 1

	if [ "${crc}" -eq 0 ]; then
		for arg in "${@}"; do
			case "${arg}" in
				-*)	continue ;;
				*)	package="${arg}" ; break ;;
			esac
		done
		package="$( echo "${package}" | sed -r 's/^[^a-z]+([a-z])/\1/' )"
		if echo "${package}" | grep -Fq -- '/'; then
			if ! ls -1d "${ROOT:-}/var/db/pkg/${package%::*}"* >/dev/null 2>&1; then
				die "emerge indicated success but package '${package%::*}' does not appear to be installed"
			fi
		else
			if ! ls -1d "${ROOT:-}/var/db/pkg"/*/"${package%::*}"* >/dev/null 2>&1; then
				die "emerge indicated success but package '${package%::*}' does not appear to be installed"
			fi
		fi
	fi

	# shellcheck disable=SC2086
	return ${crc}
} # check

[ -n "${environment_filter:-}" ] || die "'environment_filter' not inherited from docker environment"

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

#TUSE='' post_pkgs='' post_use='' rc=0
post_pkgs='' post_use='' rc=0
for arg in "${@}"; do
	#print "Read argument '${arg}'"
	shift
	case "${arg}" in
		--post-pkgs=*)
			post_pkgs="$( printf '%s' "${arg}" | cut -d'=' -f 2- )"
			continue
			;;
		--post-use=*)
			post_use="$( printf '%s' "${arg}" | cut -d'=' -f 2- )"
			continue
			;;
		--verbose-build)
			continue
			;;
		--with-use=*)
			if false; then # Not valid here
			#TUSE="$( printf '%s' "${arg}" | cut -d'=' -f 2- )"
			:
			fi
			warn "Option '--with-use' is not valid during initial build stage"
			continue
			;;
		*)
			set -- "${@}" "${arg}"
			;;
	esac
done

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
if [ -n "${use_essential:-}" ] && ! echo "${post_use:-}" | grep -Fq -- "${use_essential}"; then
	post_use="${post_use:+${post_use} }${use_essential}"
fi

if false; then # Not valid here
#if [ -n "${TUSE:-}" ]; then
#	if ! printf '%s' " ${TUSE} " | grep -Fq -- ' -* '; then
#		TUSE="${USE:+${USE} }${TUSE}"
#	fi
#	if [ -n "${use_essential:-}" ] && echo "${TUSE}" | grep -Fq -- "${use_essential}"; then
#		USE="${TUSE}"
#	else
#		USE="${TUSE}${use_essential:+ ${use_essential}}"
#	fi
#	export USE
#fi
:
fi

# At the point we're executed, we expect to be in a stage3 with appropriate
# repositories mounted...

[ -s /usr/libexec/stage3.info ] || die "'/usr/libexec/stage3.info' is missing or empty"
[ -d /var/db/repo/gentoo/profiles ] || die "default repo ('gentoo') is missing"
[ -d /etc/portage ] || die "'/etc/portage' is missing or not a directory"
[ -s /etc/portage/package.use ] || [ -d /etc/portage/package.use ] || die "'/etc/portage/package.use' is missing"
[ -s /etc/locale.gen ] || warn "'/etc/locale.gen' is missing or empty"
# shellcheck disable=SC2166
[ -s "${PKGDIR}"/Packages -a -d "${PKGDIR}"/virtual ] || warn "'${PKGDIR}/Packages' or '${PKGDIR}/virtual' are missing - package cache appears invalid"

info="$( LC_ALL='C' emerge --info --verbose )"
echo
echo 'Resolved build variables for stage3:'
echo '------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
format 'USE' </usr/libexec/stage3.info
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2- )"
echo "PKGDIR              = $( echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2- )"
echo "PORTAGE_LOGDIR      = $( echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2- )"
echo
unset info

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

echo
echo " * Building stage3 'sys-apps/fakeroot' package ..."
echo
(
	USE="$( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
	export USE
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean -fakeroot"
	export LC_ALL='C'
	# shellcheck disable=SC2086
	emerge \
			--ignore-default-opts \
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
		sys-apps/fakeroot
)
LC_ALL='C' eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

export FEATURES="${FEATURES:+${FEATURES} }fakeroot"

# Certain @system packages incorrectly fail to find ROOT-installed
# dependencies, and so require prior package installation directly into the
# stage3 environment...
#
# (For some reason, sys-apps/gentoo-functions::gentoo is very sticky)
#
for pkg in 'sys-apps/gentoo-functions::srcshelton' 'sys-libs/libcap' 'sys-process/audit' 'dev-perl/Locale-gettext' 'dev-libs/libxml2' 'app-editors/vim'; do
	echo
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		USE="$( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
		export USE
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
		export LC_ALL='C'
		# shellcheck disable=SC2086
		emerge \
				--ignore-default-opts \
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
	LC_ALL='C' eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
	LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done

echo
echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source package ..."
echo

# Some packages require prepared kernel sources ...
#
(
	USE="$( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 ) symlink"
	export USE
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
	export LC_ALL='C'
	# shellcheck disable=SC2086
	emerge \
			--ignore-default-opts \
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
LC_ALL='C' eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

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

echo
echo
echo ' * Creating build root ...'
echo

# Now we can build our ROOT environment ...
#
rm /usr/libexec/stage3.info

# (ARCH should now be safe)
export ARCH="${arch}"

export ROOT="/build"
export SYSROOT="${ROOT}"
export PORTAGE_CONFIGROOT="${SYSROOT}"

mkdir -p "${ROOT}"/usr/src/
mv /usr/src/linux* "${ROOT}"/usr/src/
ln -s ../../"${ROOT}"/usr/src/linux /usr/src/

mkdir -p "${ROOT}"/etc
cp -r /etc/portage "${ROOT}"/etc/
cp /etc/locale.gen "${ROOT}"/etc/
cp /etc/timezone "${ROOT}"/etc/
cp /etc/etc-update.conf "${ROOT}"/etc/

path="${PATH}"
#export PATH="${PATH}:${ROOT}${PATH//:/:${ROOT}}"
PATH="${PATH}:${ROOT}$( echo "${PATH}" | sed "s|:|:${ROOT}|g" )"
export PATH

if command -v env-update >/dev/null 2>&1; then
	LC_ALL='C' env-update
fi
# shellcheck disable=SC1091
. /etc/profile
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" 2>&1 | grep -v -- 'Warning:' || :

info="$( LC_ALL='C' emerge --info --verbose )"
echo
echo 'Resolved build variables for @system:'
echo '------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
echo "${info}" | format 'USE'
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2- )"
echo "PKGDIR              = $( echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2- )"
echo "PORTAGE_LOGDIR      = $( echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2- )"
echo
unset info

LC_ALL='C' emerge --check-news

# FIXME: Expose this somewhere?
features_libeudev=1

# sys-libs/libcap can USE pam, which requires libcap ...
pkg_initial='sys-apps/fakeroot sys-libs/libcap sys-process/audit sys-apps/util-linux app-shells/bash dev-perl/Locale-gettext app-editors/vim'
pkg_initial_use='-nls -pam -perl -python'
pkg_exclude=''
if [ -n "${features_libeudev}" ]; then
	pkg_initial="${pkg_initial:+${pkg_initial} }sys-libs/libeudev virtual/libudev"
	pkg_exclude="${pkg_exclude:+${pkg_exclude} }--exclude=virtual/udev"
fi

if [ -n "${pkg_initial:-}" ]; then
	echo
	echo ' * Building initial packages ...'
	echo

	for pkg in ${pkg_initial:-}; do
		#set -x
		# shellcheck disable=SC2086
		FEATURES="${FEATURES:+${FEATURES} }fail-clean" \
		USE="${pkg_initial_use}${use_essential:+ ${use_essential}}" \
		LC_ALL='C' \
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
				${pkg} ${pkg_exclude:-} || :
		set +x
		LC_ALL='C' etc-update --quiet --preen ; find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

		if echo " ${pkg} " | grep -q -- ' app-shells/bash '; then
			# Ensure we have a valid /bin/sh symlink in our ROOT ...
			if ! [ -x "${ROOT}"/bin/sh ]; then
				echo " * Fixing pre-deploy '/bin/sh' symlink ..."
				[ ! -e "${ROOT}"/bin/sh ] || rm "${ROOT}"/bin/sh
				ln -sf bash "${ROOT}"/bin/sh
			fi
		fi
	done
fi

echo
echo ' * Building @system packages ...'
echo

#set -x
# sys-apps/shadow is needed for /sbin/nologin
# dev-libs/icu is needed for circular dependencies on icu -> python -> sqlite -> icu
# libarchive is a frequent dependency, and so quicker to pull-in here
# shellcheck disable=SC2086
FEATURES="${FEATURES:+${FEATURES} }fail-clean" \
USE="${pkg_initial_use}${use_essential:+ ${use_essential}}" \
LC_ALL='C' \
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
		@system sys-apps/shadow dev-libs/icu app-arch/libarchive ${pkg_exclude:-} || :
set +x
LC_ALL='C' etc-update --quiet --preen ; find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

# Ensure we have a valid /bin/sh symlink in our ROOT ...
if ! [ -x "${ROOT}"/bin/sh ]; then
	echo " * Fixing @system '/bin/sh' symlink ..."
	[ ! -e "${ROOT}"/bin/sh ] || rm "${ROOT}"/bin/sh
	ln -sf bash "${ROOT}"/bin/sh
fi

# ... and fix the default bash prompt setup w.r.t. 'screen' window names!
if [ -s /etc/bash/bashrc.patch ]; then
	if ! command -v patch >/dev/null; then
		echo "WARN: @system build has not installed package 'sys-devel/patch'"
	else
		#pushd >/dev/null "${ROOT}"/etc/bash/
		src_cwd="${PWD}"
		cd "${ROOT}"/etc/bash/

		if [ -s bashrc ]; then
			echo ' * Patching /etc/bash/bashrc ...'
			patch -p1 </etc/bash/bashrc.patch >/dev/null
		else
			echo "WARN: '${ROOT%/}/etc/bash/bashrc' does not exist or is empty"
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
if [ -n "$( ls -1 "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log 2>/dev/null | head -n 1 )" ]; then
	mkdir -p "${PORTAGE_LOGDIR}"/failed 
	for file in "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log; do
            cat="$( echo "${file}" | rev | cut -d'/' -f 4 | rev )"
            pkg="$( echo "${file}" | rev | cut -d'/' -f 3 | rev )"
            mkdir -p "${PORTAGE_LOGDIR}/failed/${cat}"
            mv "${file}" "${PORTAGE_LOGDIR}/failed/${cat}/${pkg}.log"
	done
fi

# Cleanup any failed bulids/temporary files ...
#
[ ! -f "${ROOT}"/etc/portage/profile/package.provided ] || rm "${ROOT}"/etc/portage/profile/package.provided
[ ! -f "${ROOT}"/etc/portage/profile/packages ] || rm "${ROOT}"/etc/portage/profile/packages
[ ! -e "${ROOT}"/usr/src/linux ] || rm -r "${ROOT}"/usr/src/linux*
[ ! -d "${ROOT}/${PORTAGE_TMPDIR}/portage" ] || rm -r "${ROOT}/${PORTAGE_TMPDIR}/portage"
[ ! -d "${PORTAGE_TMPDIR}/portage" ] || rm -r "${PORTAGE_TMPDIR}/portage"

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
echo '----------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
echo "${info}" | format 'USE'
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2- )"
echo "PKGDIR              = $( echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2- )"
echo "PORTAGE_LOGDIR      = $( echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2- )"
echo
unset info

export PATH="${path}"
unset path

# Save environment for later docker stages...
printf "#FILTER: '%s'\n\n" "${environment_filter}" > "${ROOT}"/usr/libexec/environment.sh
export -p |
	grep -- '=' |
	grep -Ev -- "${environment_filter}" | \
	sed -r 's/\s+/ /g' | \
	grep -v '^export [a-z_]' \
	>> "${ROOT}"/usr/libexec/environment.sh
test -e "${ROOT}"/usr/libexec/environment.sh || echo "WARN: '${ROOT%/}/usr/libexec/environment.sh' does not exist"
test -s "${ROOT}"/usr/libexec/environment.sh || echo "WARN: '${ROOT%/}/usr/libexec/environment.sh' is empty"
grep -- ' ROOT=' "${ROOT}"/usr/libexec/environment.sh && die "Invalid 'ROOT' directive in '${ROOT%/}/usr/libexec/environment.sh'"
#printf " * Initial propagated environment:\n\n%s\n\n" "$( <"${ROOT}"/usr/libexec/environment.sh )"

case "${1:-}" in
	'')
		echo
		echo " * Building default '${package}' package ..."
		echo

		print "Running default 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y \"${package}\"'"

		# shellcheck disable=SC2086
		LC_ALL='C' emerge ${parallel} ${opts} --usepkg=y "${package}" || rc=${?}

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
		if [ -z "${post_pkgs:-}" ]; then
			echo
			echo " * Building requested '$( printf '%s' "${*}" | sed 's/--[^ ]\+ //g' )' packages ..."
			echo

			# shellcheck disable=SC2016
			print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${*}'${USE:+ with USE='${USE}'}"
			# shellcheck disable=SC2086
			LC_ALL='C' emerge ${parallel} ${opts} --usepkg=y "${@}" || rc=${?}

			check ${rc} "${@}"

			exit ${rc}
		else
			echo
			echo " * Building requested '$( printf '%s' "${*}" | sed 's/--[^ ]\+ //g' )' packages ..."
			echo

			# shellcheck disable=SC2016
			print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${*}'${USE:+ with USE='${USE}'}"
			# shellcheck disable=SC2086
			LC_ALL='C' emerge ${parallel} ${opts} --usepkg=y "${@}" || rc=${?}

			check ${rc} "${@}"

			echo
			echo " * Building specified post-installation '${post_pkgs}' packages ..."
			echo

			[ -n "${post_use:-}" ] && export USE="${post_use}"

			info="$( LC_ALL='C' emerge --info --verbose )"
			echo
			echo 'Resolved build variables for post-installation packages:'
			echo '-------------------------------------------------------'
			echo
			#echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
			#echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
			#echo "${info}" | format 'FEATURES'
			echo "${info}" | format 'USE'
			echo
			unset info

			# shellcheck disable=SC2016
			print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${post_pkgs}'${USE:+ with USE='${USE}'}"
			# shellcheck disable=SC2086
			LC_ALL='C' emerge ${parallel} ${opts} --usepkg=y ${post_pkgs} || rc=${?}

			check ${rc} "${@}"

			exit ${rc}
		fi
		;;
esac
