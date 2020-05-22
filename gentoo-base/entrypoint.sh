#! /bin/sh

set -eu
set -o pipefail

DEFAULT_JOBS='__JOBS__'
DEFAULT_MAXLOAD='__MAXLOAD__'
DEFAULT_PROFILE='__PROFILE__'
environment_filter='__ENVFILTER__'

arch="${ARCH:-amd64}"
unset -v ARCH

die() {
	echo -e "FATAL: ${*:-Unknown error}"
	exit 1
} # die

warn() {
	[ -z "${*:-}" ] && echo || echo -e "WARN:  ${*}"
} # die

[ -n "${environment_filter:-}" ] || die "'environment_filter' not inherited from docker environment"

if echo " ${*:-} " | grep -Fq -- ' --verbose-build '; then
	parallel='--jobs=1 --quiet-build=n'
else
	if [ -n "${JOBS:-}" ]; then
		case "${JOBS}" in
			0)
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

# At the point we're executed, we expect to be in a stage3 with appropriate
# repositories mounted...

[ -s /usr/libexec/stage3.info ] || die "'/usr/libexec/stage3.info' is missing or empty"
[ -d /var/db/repo/gentoo/profiles ] || die "default repo ('gentoo') is missing"
[ -d /etc/portage ] || die "'/etc/portage' is missing or not a directory"
[ -s /etc/portage/package.use ] || [ -d /etc/portage/package.use ] || die "'/etc/portage/package.use' is missing"
[ -s /etc/locale.gen ] || warn "'/etc/locale.gen' is missing or empty"
[ -s "${PKGDIR}"/Packages -a -d "${PKGDIR}"/virtual ] || warn "'${PKGDIR}/Packages' or '${PKGDIR}/virtual' are missing - package cache appears invalid"

info="$( emerge --info --verbose )"
echo
echo 'Resolved build variables for stage3:'
echo '------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "FEATURES            = $( echo "${info}" | grep -- '^FEATURES=' | cut -d'=' -f 2- )"
echo "ACCEPT_LICENSE      = $( echo "${info}" | grep -- '^ACCEPT_LICENSE=' | cut -d'=' -f 2- )"
echo "ACCEPT_KEYWORDS     = $( echo "${info}" | grep -- '^ACCEPT_KEYWORDS=' | cut -d'=' -f 2- )"
echo "USE                 = \"$( cat /usr/libexec/stage3.info | grep -- '^USE=' | cut -d'"' -f 2 )\""
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "EMERGE_DEFAULT_OPTS = $( echo "${info}" | grep -- '^EMERGE_DEFAULT_OPTS=' | cut -d'=' -f 2- )"
echo
echo "DISTDIR             = $( echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2- )"
echo "PKGDIR              = $( echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2- )"
echo "PORTAGE_LOGDIR      = $( echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2- )"
echo
unset info

eselect --colour=yes profile list
eselect --colour=yes profile set "${DEFAULT_PROFILE}" # 2>/dev/null

emaint --fix binhost

emerge --check-news
eselect --colour=yes news read

#set -o xtrace

echo " * Building stage3 'sys-apps/fakeroot' package ..."
echo

(
	export USE="$( cat /usr/libexec/stage3.info | grep -- '^USE=' | cut -d'"' -f 2 )"
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean -fakeroot"
	emerge --ignore-default-opts --binpkg-respect-use=y --buildpkg=n --color=y --keep-going=y --quiet-build=y --usepkg=y --with-bdeps=n --with-bdeps-auto=n sys-apps/fakeroot
)
eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

export FEATURES="${FEATURES:+${FEATURES} }fakeroot"

# Certain @system packages incorrectly fail to find ROOT-installed
# dependencies, and so require prior package installation directly into the
# stage3 environment...
#
for pkg in 'sys-libs/libcap' 'sys-process/audit' 'dev-perl/Locale-gettext' 'dev-libs/libxml2'; do
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		export USE="$( cat /usr/libexec/stage3.info | grep -- '^USE=' | cut -d'"' -f 2 )"
		export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
		emerge --ignore-default-opts --binpkg-respect-use=y --buildpkg=n --color=y --keep-going=y --quiet-build=y --usepkg=y --with-bdeps=n --with-bdeps-auto=n "${pkg}"
	)
	eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
	etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done

echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source package ..."
echo

# Some packages require prepared kernel sources ...
#
(
	export USE="$( cat /usr/libexec/stage3.info | grep -- '^USE=' | cut -d'"' -f 2 ) symlink"
	export FEATURES="${FEATURES:+${FEATURES} }fail-clean"
	emerge --ignore-default-opts --buildpkg=n --color=y --keep-going=y --quiet-build=y --usepkg=n --with-bdeps=n --with-bdeps-auto=n sys-kernel/gentoo-sources
)
eselect --colour=yes news read new | grep -Fv -- 'No news is good news.' || :
etc-update --quiet --preen ; find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

echo
echo ' * Configuring stage3 kernel sources ...'
echo

pushd >/dev/null /usr/src/linux
make defconfig prepare
popd >/dev/null

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
mv /etc/portage "${ROOT}"/etc/
ln -s ../"${ROOT}"/etc/portage /etc/
cp /etc/locale.gen "${ROOT}"/etc/
cp /etc/timezone "${ROOT}"/etc/
cp /etc/etc-update.conf "${ROOT}"/etc/

path="${PATH}"
export PATH="${PATH}:${ROOT}${PATH//:/:${ROOT}}"

env-update
. /etc/profile
eselect --colour=yes profile set "${DEFAULT_PROFILE}" 2>&1 | grep -v -- 'Warning:' || :

info="$( emerge --info --verbose )"
echo
echo 'Resolved build variables for @system:'
echo '-------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "FEATURES            = $( echo "${info}" | grep -- '^FEATURES=' | cut -d'=' -f 2- )"
echo "ACCEPT_LICENSE      = $( echo "${info}" | grep -- '^ACCEPT_LICENSE=' | cut -d'=' -f 2- )"
echo "ACCEPT_KEYWORDS     = $( echo "${info}" | grep -- '^ACCEPT_KEYWORDS=' | cut -d'=' -f 2- )"
echo "USE                 = \"$( echo "${info}" | grep -- '^USE=' | cut -d'"' -f 2 )\""
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "EMERGE_DEFAULT_OPTS = $( echo "${info}" | grep -- '^EMERGE_DEFAULT_OPTS=' | cut -d'=' -f 2- )"
echo
echo "DISTDIR             = $( echo "${info}" | grep -- '^DISTDIR=' | cut -d'=' -f 2- )"
echo "PKGDIR              = $( echo "${info}" | grep -- '^PKGDIR=' | cut -d'=' -f 2- )"
echo "PORTAGE_LOGDIR      = $( echo "${info}" | grep -- '^PORTAGE_LOGDIR=' | cut -d'=' -f 2- )"
echo
unset info

emerge --check-news

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
	echo ' * Building initial packacges ...'
	echo

	for pkg in ${pkg_initial:-}; do
		#set -x
		FEATURES="${FEATURES:+${FEATURES} }fail-clean" \
		USE="${pkg_initial_use}" \
			emerge ${parallel} --ignore-default-opts --binpkg-changed-deps=n --binpkg-respect-use=y --buildpkg=n --color=y --keep-going=y --quiet-build=y --tree --usepkg=y --verbose=y --verbose-conflict --with-bdeps=n --with-bdeps-auto=n \
				${pkg} ${pkg_exclude:-} || :
		set +x
		etc-update --quiet --preen ; find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

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
echo ' * Building @system packacges ...'
echo

#set -x
FEATURES="${FEATURES:+${FEATURES} }fail-clean" \
	emerge ${parallel} --ignore-default-opts --binpkg-changed-deps=y --binpkg-respect-use=y --buildpkg=y --color=y --deep --emptytree --keep-going=y --rebuild-if-new-slot=y --rebuilt-binaries=y --quiet-build=y --root-deps --tree --usepkg=y --verbose=y --verbose-conflicts --with-bdeps=y --with-bdeps-auto=n \
		@system ${pkg_exclude:-} || :
set +x
etc-update --quiet --preen ; find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

# Ensure we have a valid /bin/sh symlink in our ROOT ...
if ! [ -x "${ROOT}"/bin/sh ]; then
	echo " * Fixing @system '/bin/sh' symlink ..."
	[ ! -e "${ROOT}"/bin/sh ] || rm "${ROOT}"/bin/sh
	ln -sf bash "${ROOT}"/bin/sh
fi

echo
echo ' * Cleaning up ...'
echo

# Save failed build logs ...
# (e.g. /var/tmp/portage/app-misc/mime-types-9/temp/build.log)
#
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

# Check for ROOT news ...
eselect --colour=yes news read new

# At this point, we should have a fully-built @system!

export EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS:+${EMERGE_DEFAULT_OPTS} } --with-bdeps=y --with-bdeps-auto=y"

info="$( emerge --info --verbose )"
echo
echo 'Resolved build variables after init stage:'
echo '----------------------------------------'
echo
echo "ROOT                = $( echo "${info}" | grep -- '^ROOT=' | cut -d'=' -f 2- )"
echo "SYSROOT             = $( echo "${info}" | grep -- '^SYSROOT=' | cut -d'=' -f 2- )"
echo "PORTAGE_CONFIGROOT  = $( echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' | cut -d'=' -f 2- )"
echo
echo "FEATURES            = $( echo "${info}" | grep -- '^FEATURES=' | cut -d'=' -f 2- )"
echo "ACCEPT_LICENSE      = $( echo "${info}" | grep -- '^ACCEPT_LICENSE=' | cut -d'=' -f 2- )"
echo "ACCEPT_KEYWORDS     = $( echo "${info}" | grep -- '^ACCEPT_KEYWORDS=' | cut -d'=' -f 2- )"
echo "USE                 = \"$( echo "${info}" | grep -- '^USE=' | cut -d'"' -f 2 )\""
echo "MAKEOPTS            = $( echo "${info}" | grep -- '^MAKEOPTS=' | cut -d'=' -f 2- )"
echo
echo "EMERGE_DEFAULT_OPTS = $( echo "${info}" | grep -- '^EMERGE_DEFAULT_OPTS=' | cut -d'=' -f 2- )"
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
	grep -Ev -- "${environment_filter}" \
	>> "${ROOT}"/usr/libexec/environment.sh
test -e "${ROOT}"/usr/libexec/environment.sh || echo "WARN: '${ROOT%/}/usr/libexec/environment.sh' does not exist"
test -s "${ROOT}"/usr/libexec/environment.sh || echo "WARN: '${ROOT%/}/usr/libexec/environment.sh' is empty"
cat "${ROOT}"/usr/libexec/environment.sh | grep -- ' ROOT=' && die "Invalid 'ROOT' directive in '${ROOT%/}/usr/libexec/environment.sh'"
#printf " * Initial propagated environment:\n\n%s\n\n" "$( < "${ROOT}"/usr/libexec/environment.sh )"

if [ -z "${*:-}" ]; then
	# We should *definitely* have this...
	package='virtual/libc'

	#set -x
	# shellcheck disable=SC2086
	exec emerge ${parallel} --usepkg=y "${package}"
else
	#set -x
	# shellcheck disable=SC2086
	exec emerge ${parallel} "${@}"
fi
