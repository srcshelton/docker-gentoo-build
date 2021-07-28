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

#arch="${ARCH:-amd64}"
arch="${ARCH}"
unset -v ARCH

# Even though we want a minimal set of flags during this stage, gcc's flags are
# significant since they'll affect the compiler facilities available to all
# packages built later...
# FIXME: Source these flags from package.use
gcc_use="graphite nptl openmp pch sanitize ssp vtv zstd"

die() {
	printf >&2 'FATAL: %s\n' "${*:-Unknown error}"
	exit 1
} # die

warn() {
	[ -z "${*:-}" ] && echo || printf >&2 'WARN:  %s\n' "${*}"
} # warn

print() {
	if [ -n "${DEBUG:-}" ]; then
		if [ -z "${*:-}" ]; then
			echo >&2
		else
			printf >&2 'DEBUG: %s\n' "${*}"
		fi
	fi
} # print

format() {
	# Pad $variable to $padding trailing spaces
	#
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
	# Check that a given package (with build result code $crc) is actually installed
	#
	crc=${1:-} ; shift

	[ -n "${crc:-}" ] || return 1

	if [ "${crc}" -eq 0 ]; then
		# Process first package of list only...
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

post_pkgs='' post_use='' rc=0
for arg in "${@}"; do
	#print "Read argument '${arg}'"
	shift
	case "${arg}" in
		--post-pkgs=*)
			post_pkgs="$( printf '%s' "${arg}" | sed -z 's/^[^=]*=//' | tr -d '\n' )"
			continue
			;;
		--post-use=*)
			post_use="$( printf '%s' "${arg}" | sed -z 's/^[^=]*=//' | tr -d '\n' )"
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

if [ -e /etc/portage/repos.conf.host ]; then
	echo
	warn "Mirroring host repos.conf to container ..."
	if [ -e /etc/portage/repos.conf ]; then
		if [ -d /etc/portage/repos.conf ]; then
			for f in /etc/portage/repos.conf/*; do
				umount -q "${f}" || :
			done
		fi
		umount -q /etc/portage/repos.conf || :
		rm -rf /etc/portage/repos.conf || :

		[ -e /etc/portage/repos.conf ] && mv /etc/portage/repos.conf /etc/portage/repos.conf.disabled
	fi
	cp -a /etc/portage/repos.conf.host /etc/portage/repos.conf || die "Can't copy host repos.conf: ${?}"
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
if [ -n "${use_essential:-}" ] && ! echo "${post_use:-}" | grep -Fq -- "${use_essential}"; then
	post_use="${post_use:+${post_use} }${use_essential}"
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
echo '-----------------------------------'
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

# Report stage3 tool versions (because some are masked from the arm64 stage3!)
file=''
for file in /lib*/libc.so.6; do
	"${file}"
done
unset file
gcc --version
ld --version

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

if portageq get_repos / | grep -Fq -- 'srcshelton'; then
	echo
	echo " * Building linted 'sys-apps/gentoo-functions' package for stage3 ..."
	echo
	(
		USE="-* $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
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
	USE="-* $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
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
		USE="-* livecd nptl $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"  # 'livecd' for busybox
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
	LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

	echo
	echo " * CHOST change detected - building stage3 compilers suite ..."
	echo

	oldchost="$( find /usr -mindepth 1 -maxdepth 1 -type d -name '*-*-*' -exec basename {} \; | head -n 1 )"
	for pkg in 'sys-devel/binutils' 'sys-devel/gcc' 'sys-libs/glibc'; do
		(
			USE="-* nptl $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
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
		LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
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
	rm -r "/usr/${oldchost}" "/usr/bin/${oldchost}"*
	#find /bin/ /sbin/ /usr/bin/ /usr/sbin/ /usr/libexec/ /usr/local/ -name "*${oldchost}*" -exec ls -Fhl --color=always {} +
	#find /usr/ -mindepth 1 -maxdepth 1 -name "*${oldchost}*" -exec ls -dFhl --color=always {} +
	grep -l "${oldchost}" /etc/env.d/0*gcc* /etc/env.d/0*binutils* | xargs -r rm
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
	#grep -HR --colour '^.*$' /etc/env.d/
	#binutils-config -l
	#gcc-config -l

	# shellcheck disable=SC2041
	#for pkg in 'dev-libs/libgpg-error' 'sys-devel/libtool'; do
	for pkg in 'sys-devel/libtool'; do
		(
			USE="-* $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
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
		LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
	done
	[ -x /usr/sbin/fix_libtool_files.sh ] && /usr/sbin/fix_libtool_files.sh "$( gcc -dumpversion )" --oldarch "${oldchost}"

	(
		USE="-* nptl $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
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
			$(
				for object in "/usr/bin/${oldchost}-"* "/usr/include/${oldchost}" /usr/lib/llvm/*/bin/"${oldchost}"-* ;do
					if [ -e "${object}" ]; then
						printf '%s ' "${object}"
					fi
				done
			)dev-lang/perl "=$(
				ls /var/db/pkg/dev-lang/python-3* -1d |
				cut -d'/' -f 5-6 |
				sort -V |
				head -n 1
			)" '@preserved-rebuild'
	)
	LC_ALL='C' eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
	LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
fi

# Certain @system packages incorrectly fail to find ROOT-installed
# dependencies, and so require prior package installation directly into the
# stage3 environment...
#
# (For some reason, sys-apps/gentoo-functions::gentoo is very sticky)
#
for pkg in \
		'sys-libs/libcap' \
		'sys-process/audit' \
		'dev-perl/libintl-perl' \
		'dev-perl/Locale-gettext' \
		'dev-libs/libxml2' \
		'app-editors/vim' \
		'app-admin/eselect' \
		'app-eselect/eselect-awk' \
		'sys-apps/gawk' \
		'sys-devel/gcc' \
		'virtual/awk'
do
	echo
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		USE="-* $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 )"
		USE="${USE} ${gcc_use}"
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
	LC_ALL='C' eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
	LC_ALL='C' etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done
LC_ALL='C' eselect awk set gawk || :

echo
echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source package ..."
echo

# Some packages require prepared kernel sources ...
#
(
	USE="-* $( grep -- '^USE=' /usr/libexec/stage3.info | cut -d'"' -f 2 ) symlink"
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
file=''
for file in /etc/profile "${ROOT}"/etc/profile; do
	# shellcheck disable=SC1090,SC1091
	[ -s "${file}" ] && . "${file}"
done
unset file
echo "Setting profile for architeceture '${ARCH}'..."
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" 2>&1 | grep -v -- 'Warning:' || :

# It seems we never actually defined USE if not passed-in externally, and yet
# somehow on amd64 gcc still gets 'nptl'.  An arm64, however, this doesn't
# happen and everything breaks :(
# Let's try to fix that...
export USE="${USE:+${USE} }${use_essential} nptl"

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

# Do we need to rebuild the root packages as well?
#
# This can be required if the upstream stage image is significantly old
# compared to the current portage tree...
#extra_root='/'

# sys-apps/help2man with USE 'nls' requires Locale-gettext, which depends on sys-apps/help2man;
# sys-libs/libcap can USE pam, which requires libcap ...
pkg_initial='sys-apps/fakeroot sys-libs/libcap sys-process/audit sys-apps/util-linux app-shells/bash sys-apps/help2man dev-perl/Locale-gettext app-editors/vim'
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
		(
			#set -x
			export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
			export USE="${pkg_initial_use}${use_essential:+ ${use_essential}}"
			export LC_ALL='C'
			for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"
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
					${pkg} ${pkg_exclude:-} || :
			done
		)
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

(
	#set -x
	# sys-apps/shadow is needed for /sbin/nologin
	# dev-libs/icu is needed for circular dependencies on icu -> python -> sqlite -> icu
	# libarchive is a frequent dependency, and so quicker to pull-in here
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
	USE="${USE:+${USE} }${gcc_use}"
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
	for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u ); do
		export ROOT
		export SYSROOT="${ROOT}"
		export PORTAGE_CONFIGROOT="${SYSROOT}"
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
			@system sys-devel/gcc sys-apps/shadow dev-libs/icu app-arch/libarchive ${pkg_initial} ${pkg_exclude:-} || :
	done
)
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
		warn "@system build has not installed package 'sys-devel/patch'"
	else
		#pushd >/dev/null "${ROOT}"/etc/bash/
		src_cwd="${PWD}"
		cd "${ROOT}"/etc/bash/

		if [ -s bashrc ]; then
			echo ' * Patching /etc/bash/bashrc ...'
			patch -p1 </etc/bash/bashrc.patch >/dev/null
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
if [ -n "$( ls -1 "${PORTAGE_TMPDIR}"/portage/*/*/temp/build.log 2>/dev/null | head -n 1 )" ]; then
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
echo '-----------------------------------------'
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
test -e "${ROOT}"/usr/libexec/environment.sh || warn "'${ROOT%/}/usr/libexec/environment.sh' does not exist"
test -s "${ROOT}"/usr/libexec/environment.sh || warn "'${ROOT%/}/usr/libexec/environment.sh' is empty"
grep -- ' ROOT=' "${ROOT}"/usr/libexec/environment.sh && die "Invalid 'ROOT' directive in '${ROOT%/}/usr/libexec/environment.sh'"
#printf " * Initial propagated environment:\n\n%s\n\n" "$( <"${ROOT}"/usr/libexec/environment.sh )"

case "${1:-}" in
	'')
		echo
		echo " * Building default '${package}' package ..."
		echo

		print "Running default 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y \"${package}\"'"

		(
			export LC_ALL='C'
			for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
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
			echo " * Building requested '$( printf '%s' "${*}" | sed 's/--[^ ]\+ //g' )' packages ..."
			echo

			# shellcheck disable=SC2016
			print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${*}'${USE:+ with USE='${USE}'}"
			(
				export LC_ALL='C'
				for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
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
		else
			echo " * Building requested '$( printf '%s' "${*}" | sed 's/--[^ ]\+ //g' )' packages (with post-package list) ..."
			echo

			# shellcheck disable=SC2016
			print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${*}'${USE:+ with USE='${USE}'}"
			(
				export LC_ALL='C'
				for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
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

			if [ -n "${EMERGE_OPTS:-}" ] && echo " ${EMERGE_OPTS} " | grep -Eq -- ' --single(-post)? '; then
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
							#	if echo " ${EMERGE_OPTS} " | grep -Eq -- ' --swap(-post)? '; then
							#		continue
							#	fi
							#fi
							echo
							echo " * Building single post-package '${arg}' from '${post_pkgs}' ..."
							echo
							# shellcheck disable=SC2016
							print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${arg}'${USE:+ with USE='${USE}'}"
							(
								export LC_ALL='C'
								export FEATURES='-fail-clean'
								for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
									export ROOT
									export SYSROOT="${ROOT}"
									export PORTAGE_CONFIGROOT="${SYSROOT}"
									# shellcheck disable=SC2086
									emerge ${parallel} ${opts} --usepkg=y ${flags:-} ${arg} || rc=${?}
									if [ $(( rc )) -ne 0 ]; then
										break
									fi
								done
								exit ${rc}
							) || rc=${?}
							;;
					esac
				done
			else
				# shellcheck disable=SC2016
				print "Running 'emerge ${parallel:+${parallel} }${opts:+${opts} }--usepkg=y ${post_pkgs}'${USE:+ with USE='${USE}'}"
				(
					export LC_ALL='C'
					for ROOT in $( echo "${extra_root:-}" "${ROOT}" | xargs -n 1 | sort -u | xargs ); do
						export ROOT
						export SYSROOT="${ROOT}"
						export PORTAGE_CONFIGROOT="${SYSROOT}"
						# shellcheck disable=SC2086
						emerge ${parallel} ${opts} --usepkg=y ${post_pkgs} || rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							break
						fi
					done
					exit ${rc}
				) || rc=${?}
			fi

			check ${rc} "${@}"

			exit ${rc}
		fi
		;;
esac

#[ -n "${trace:-}" ] && set +o xtrace

# vi: set syntax=sh sw=4 ts=4:
