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

# N.B. If multiple python_default_targets are required, the primary version
#      must be listed *first*:
python_default_targets='python3_13'
stage3_flags=''

export arch="${ARCH}"
unset -v ARCH

portage_kv_cache_root=''
portage_kv_cache=''

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
	if [ -n "${debug:-}" ]; then
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
				sort |
				uniq |
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
	#extern ROOT
	check_rc="${1:-}" ; shift

	# Check that a given check_pkg (with build result code $check_rc) is
	# actually installed...
	#
	[ -n "${check_rc:-}" ] || return 1

	check_pkg='' check_fallback='' check_arg=''
	check_op='die'

	if [ $(( check_rc )) -eq 0 ]; then
		# Process first package of list only...
		#
		for check_arg in "${@}"; do
			case "${check_arg}" in
				-*)	continue ;;
				'*')
					[ -n "${check_fallback:-}" ] ||
						check_fallback="${check_arg}"
					;;
				*)	check_pkg="${check_arg}" ; break ;;
			esac
		done
		if [ -z "${check_pkg:-}" ]; then
			check_pkg="${check_fallback:-}"
			check_op='warn'
		fi
		check_pkg="$( echo "${check_pkg}" | sed -r 's/^[^a-z]+([a-z])/\1/' )"
		if echo "${check_pkg}" | grep -Fq -- '/'; then
			if ! ls -1d \
					"${ROOT:-}/var/db/pkg/${check_pkg%"::"*}"* >/dev/null 2>&1
			then
				${check_op:-"die"} "emerge indicated success but package" \
					"'${check_pkg%"::"*}' does not appear to be installed"
			fi
		else
			if ! ls -1d \
					"${ROOT:-}/var/db/pkg"/*/"${check_pkg%"::"*}"* >/dev/null 2>&1
			then
				${check_op:-"die"} "emerge indicated success but package" \
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
				if [ -n "${get_type:-}" ]; then
					error "Multiple 'stage3' variable types specified in" \
						"arguments '${*}'"
					return 1
				else
					get_type='USE'
				fi
				;;
			PYTHON_SINGLE_TARGET|STAGE3_PYTHON_SINGLE_TARGET)
				if [ -n "${get_type:-}" ]; then
					error "Multiple 'stage3' variable types specified in" \
						"arguments '${*}'"
					return 1
				else
					get_type='PYTHON_SINGLE_TARGET'
				fi
				;;
			PYTHON_TARGETS|STAGE3_PYTHON_TARGETS)
				if [ -n "${get_type:-}" ]; then
					error "Multiple 'stage3' variable types specified in" \
						"arguments '${*}'"
					return 1
				else
					get_type='PYTHON_TARGETS'
				fi
				;;
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
		# Remove USE flags which we know we don't want, or which
		# apply to multiple packages, but can (problematically) only be present
		# for one package per installation ROOT...
		get_result="$( # <- Syntax
				get_exclude='cet|cpudetection|egrep-fgrep|ensurepip|hostname|installkernel|kill|pcre16|pcre32|pop3|qmanifest|qtegrity|smartcard|su|test-rust|tmpfiles|tofu'
				echo "${get_result}" |
					xargs -rn 1 |
					grep -Ev "^(${get_exclude})$" |
					xargs -r
				unset get_exclude
			)"
		print "get_stage3 get_result for USE('${get_type}') after filter is" \
			"'${get_result}'"

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
		print "get_stage3 get_result for USE('${get_type}') after single is" \
			"'${get_result}'"

		entries="$( # <- Syntax
				echo "${stage3_flags}" |
					grep -- '^STAGE3_PYTHON_TARGETS=' |
					cut -d'"' -f 2
			)" # ' # <- Syntax
		print "get_stage3 entries for TARGETS is '${entries}'"

		for entry in ${entries}; do
			get_result="${get_result:+"${get_result} "}python_targets_${entry}"
		done
		print "get_stage3 get_result for USE('${get_type}') after targets is" \
			"'${get_result}'"

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

get_portage_flags() {
	gpf_cache='portage_kv_cache'
	gpf_key=''
	gpf_result=''

	#extern portage_kv_cache_root portage_kv_cache PORTAGE_CONFIGROOT SYSROOT

	if [ -n "${PORTAGE_CONFIGROOT:-}" ] &&
		[ "${PORTAGE_CONFIGROOT}" != "${SYSROOT:-}" ] &&
		[ "${PORTAGE_CONFIGROOT}" != '/' ]
	then
		warn "PORTAGE_CONFIGROOT has invalid value '${PORTAGE_CONFIGROOT}'" \
			"when SYSROOT='${SYSROOT:-}'"
		return 1
	fi
	if [ -z "${SYSROOT:-"${PORTAGE_CONFIGROOT:-""}"}" ] ||
		[ "${SYSROOT:-"${PORTAGE_CONFIGROOT:-""}"}" = '/' ]
	then
		if [ -z "${portage_kv_cache_root:-}" ]; then
			print "Generating ROOT='${ROOT:-}' portage K/V cache" \
				"'portage_kv_cache_root' ..."
			portage_kv_cache_root="$( # <- Syntax
					LC_ALL='C' emerge --info --verbose=y 2>&1 |
						grep -F -- '='
				)"
			readonly portage_kv_cache_root
			export portage_kv_cache_root
		fi
		gpf_cache='portage_kv_cache_root'
	else
		if [ -z "${portage_kv_cache:-}" ]; then
			print "Generating ROOT='${ROOT:-}' portage K/V cache" \
				"'portage_kv_cache' ..."
			portage_kv_cache="$( # <- Syntax
					LC_ALL='C' emerge --info --verbose=y 2>&1 |
						grep -F -- '='
				)"
			readonly portage_kv_cache
			export portage_kv_cache
		fi
		gpf_cache='portage_kv_cache'
	fi

	if [ -z "${*:-}" ]; then
		unset gpf_result gpf_key
		if [ -n "$( eval "echo \$${gpf_cache}" )" ]; then
			print "portage K/V cache '${gpf_cache:-}' contains $( # <- Syntax
					eval "echo \"\$${gpf_cache}\"" |
						wc -l
				) keys"
			unset gpf_result gpf_key gpf_cache
			return 0
		else
			warn "Unable to generate portage K/V cache '${gpf_cache:-}'"
			unset gpf_result gpf_key gpf_cache
			return 1
		fi
	else
		print "portage K/V cache '${gpf_cache:-}' contains $( # <- Syntax
				eval "echo \"\$${gpf_cache}\"" |
					wc -l
			) keys"
	fi

	if [ -z "${2:-}" ]; then
		print "Checking portage K/V cache '${gpf_cache:-}' for key '${1:-}'" \
			"..."
		gpf_key="${1}"
		gpf_result="$( # <- Syntax
				eval "echo \"\$${gpf_cache}\"" |
					grep -- "^${gpf_key}=" |
					awk -F'"' '{print $2}'
			)"
	else
		gpf_key="$( echo "${*}" | sed 's/\s\+/|/g' )"
		print "Checking portage K/V cache '${gpf_cache:-}' for composite" \
			"keys '${1:-}' ..."
		gpf_result="$( # <- Syntax
				eval "echo \"\$${gpf_cache}\"" |
					grep -E -- "^(${gpf_key})="
			)"
	fi

	if [ -z "${gpf_result:-}" ]; then
		print "No portage K/V result found for key(s) '${gpf_key:-}'"
	else
		if echo "${gpf_result}" | grep -Fq -- "'"; then
			warn "get_portage_flags(): Value incorrectly quoted for" \
				"variable '${gpf_key}'"
			gpf_result="$( echo "${gpf_result}" | sed "s/'//g" )"
		fi
	fi

	unset gpf_key gpf_cache
	if [ -n "${gpf_result:-}" ]; then
		echo "${gpf_result}"
		unset gpf_result
		return 0
	else
		unset gpf_result
		return 1
	fi
}  # get_portage_flags

get_package_flags() {
	gpfs_pkg="${1:-}"

	[ -n "${gpf_pkg:-}" ] || return 1

	emerge --ignore-default-opts --color=n --nodeps --pretend --verbose \
				"${gpfs_pkg}" 2>&1 |
			grep -F 'USE=' |
			awk -F'"' '{print $2}' |
			tr -d '()' |
			sed -r 's/[%\*]+( |$)/\1/g'

	unset gpfs_pkg
}  # get_package_flags

get_package_flag() {
	gpf_pkg="${1:-}"
	gpf_rc=0

	if [ -z "${2:-}" ]; then
		return 1
	fi
	shift
	if [ "${1}" = '--' ]; then
		if [ -z "${2:-}" ]; then
			return 1
		fi
		shift
	fi

	gpf_flags="$( echo "${*}" | sed 's/\s/|/g' )"
	echo " $( get_package_flags "${gpf_pkg}" ) " |
		sed 's/ /  /g' |
		grep -Eq " (${gpf_flags}) "
	gpf_rc=${?}

	unset gpf_pkg

	if [ $(( gpf_rc )) -eq 0 ]; then
		unset gpf_rc
		return 0
	else
		unset gpf_rc
		return 1
	fi
}  # get_package_flag

filter_portage_flags() {
	ftcf_env_only=0
	ftcf_flags=''
	ftcf_vars=''
	ftcf_var=''
	ftcf_val=''
	ftcf_corrected=0
	ftcf_match=''
	ftcf_rc=1

	if [ -n "${1:-}" ] && [ "${1}" = '--env-only' ]; then
		ftcf_env_only=1
		if [ -n "${2:-}" ]; then
			shift
		else
			set --
		fi
	fi

	while [ -n "${1:-}" ] && [ "${1}" != '--' ]; do
		ftcf_vars="${ftcf_vars:+"${ftcf_vars} "}${1}"
		if [ -n "${2:-}" ]; then
			shift
		else
			set --
		fi
	done
	[ "${1}" = '--' ] && shift

	[ -n "${ftcf_vars:-}" ] || return 0
	[ -n "${*:-}" ] || return 0

	for ftcf_var in ${ftcf_vars}; do
		if [ $(( ftcf_env_only )) -eq 0 ]; then
			ftcf_val="$( get_portage_flags "${ftcf_var}" )" || :
		else
			ftcf_val="$( eval "echo \"\$${ftcf_var}\"" )"
		fi
		print "portage variable '${ftcf_var:-}' has value '${ftcf_val:-}'"
		if echo "${ftcf_val}" | grep -Fq -- "'"; then
			warn "filter_portage_flags(): Value incorrectly quoted for" \
				"variable '${ftcf_var}'"
			ftcf_val="$( echo "${ftcf_val}" | sed "s/^'\+// ; s/'\+$//" )"
			ftcf_corrected=1
		fi

		ftcf_flags="$( # <- Syntax
				echo "${@:-}" |
					xargs -rn 1 |
					sort | uniq |
					xargs -r |
					sed 's/\s\+/|/g'
			)"
		if echo " ${ftcf_val} " | grep -Eq -- " (${ftcf_flags}) "; then
			print "Value '${ftcf_val}' for variable '${ftcf_var}' contains" \
				"to-be-filtered flags '${ftcf_flags}'"
			ftcf_rc=0
			case "${ftcf_var}" in
				*FLAGS)
					# Accept CFLAGS, etc. without prefix...
					ftcf_match='(-[fm])?' ;;
				*)
					ftcf_match='(-)?' ;;
			esac
			ftcf_val="$( # <- Syntax
					echo "${ftcf_val}" |
						xargs -rn 1 |
						grep -Ev -- "^${ftcf_match:-}(${ftcf_flags})$" |
						xargs -r
				)"
			if echo " ${ftcf_val} " | grep -Eq -- " (${ftcf_flags}) "; then
				warn "filter_portage_flags(): After filtering, variable" \
					"'${ftcf_var}' still contains flags to be removed"
			fi
			print "Updated variable '${ftcf_var}' has value" \
				"'${ftcf_val}' after removing flags '${ftcf_flags}'"
			echo "${ftcf_var}=\"${ftcf_val}\" ; export ${ftcf_var} ;"
		elif [ $(( ftcf_corrected )) -eq 1 ]; then
			print "Updated variable '${ftcf_var}' has value" \
				"'${ftcf_val}' after correcting quoting"
			echo "${ftcf_var}=\"${ftcf_val}\" ; export ${ftcf_var} ;"
		fi

		ftcf_corrected=0
		ftcf_match=''
	done

	unset ftcf_match ftcf_corrected ftcf_val ftcf_var ftcf_vars ftcf_flags \
		ftcf_env_only

	if [ $(( ftcf_rc )) -eq 0 ]; then
		unset ftcf_rc
		return 0
	else
		unset ftcf_rc
		return 1
	fi
}  # filter_portage_flags

filter_toolchain_flags() {
	if [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "${1}" = '--env-only' ]; then
		shift
		filter_portage_flags --env-only \
			CFLAGS CGO_CFLAGS \
			CXXFLAGS CGO_CXXFLAGS \
			FFLAGS FCFLAGS CGO_FFLAGS \
			LDFLAGS CGO_LDFLAGS FLFLAGS -- "${@:-}"
	else
		filter_portage_flags \
			CFLAGS CGO_CFLAGS \
			CXXFLAGS CGO_CXXFLAGS \
			FFLAGS FCFLAGS CGO_FFLAGS \
			LDFLAGS CGO_LDFLAGS FLFLAGS -- "${@:-}"
	fi
}  # filter_toolchain_flags

filter_use_flags() (
	if [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "${1}" = '--env-only' ]; then
		shift
		eval "$( filter_portage_flags --env-only USE -- "${@:-}" )"
	else
		eval "$( filter_portage_flags USE -- "${@:-}" )"
	fi
	echo "${USE:-}"
)  # filter_use_flags

filter_features_flags() (
	if [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "${1}" = '--env-only' ]; then
		shift
		eval "$( filter_portage_flags --env-only FEATURES -- "${@:-}" )"
	else
		eval "$( filter_portage_flags FEATURES -- "${@:-}" )"
	fi
	echo "${FEATURES:-}"
)  # filter_features_flags

map_p_to_pn() {
	arg=''

	if [ -z "${*:-}" ] || [ "${*:-}" = '-' ]; then
		# shellcheck disable=SC2046
		set -- $( cat - )
	fi

	[ -n "${*:-}" ] || return 1

	if command -v qatom >/dev/null 2>&1; then
		for arg in "${@}"; do
			qatom -CF '%{CATEGORY}/%{PN}' "${arg}"
		done
	else
		for arg in "${@}"; do
			echo "${arg}" |
				sed -r 's|^(.*)-[0-9].*$|\1|'
		done
	fi

	unset arg
}  # map_p_to_pn

resolve_python_flags() {
	# Ensure that USE, PYTHON_SINGLE_TARGET, and PYTHON_TARGETS are all in sync
	# with each other...
	#
	resolve_use="${1:-}"
	resolve_python_single_target="${2:-}"
	resolve_python_targets="${3:-}"

	#extern USE PYTHON_SINGLE_TARGET PYTHON_TARGETS python_targets

	resolve_target=''

	# We seem to have a weird situation where USE and PYTHON_*
	# variables are not in sync with each other...?
	resolve_use="${USE:+"${USE} "}${resolve_use:+"${resolve_use} "}$( # <- Syntax
			get_portage_flags 'USE'
		)"
	resolve_python_single_target="${PYTHON_SINGLE_TARGET:-} ${resolve_python_single_target:-} $( # <- Syntax
			get_portage_flags 'PYTHON_SINGLE_TARGET'
		)${python_targets:+" ${python_targets%%" "*}"}"
	resolve_python_targets="${PYTHON_TARGETS:-} ${resolve_python_targets:-} $( # <- Syntax
			get_portage_flags 'PYTHON_TARGETS'
		) ${python_targets:-}"

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
			echo "${resolve_use}" |
				xargs -rn 1 |
				sort |
				uniq |
				xargs -r
		)"
	# Auto-select greatest value... is this reasonable?
	printf '%s="%s"\n' 'PYTHON_SINGLE_TARGET' "$( # <- Syntax
			echo "${resolve_python_single_target}" |
				xargs -rn 1 |
				sort -V |
				uniq |
				tail -n 1
		)"
	printf '%s="%s"\n' 'PYTHON_TARGETS' "$( # <- Syntax
			echo "${resolve_python_targets}" |
				xargs -rn 1 |
				sort |
				uniq |
				xargs -r
		)"

	unset resolve_target resolve_python_targets resolve_python_single_target \
		resolve_use

	return 0
}  # resolve_python_flags

save_failed() {
	#extern PORTAGE_LOGDIR PORTAGE_LOGDIR
	sf_rc=0

	# Save failed build logs...
	# (e.g. /var/tmp/portage/app-misc/mime-types-9/temp/build.log)
	# (e.g. /var/tmp/portage/net-misc/dhcpcd-10.0.6-r2/work/dhcpcd-10.0.6/config.log)

	#[ -n "${trace:-}" ] || set -o xtrace

	sf_d=''
	sf_d="${PORTAGE_TMPDIR:-"$(get_portage_flags 'PORTAGE_TMPDIR')"}"
	sf_d="${sf_d%/}/portage"

	# We can't rely on findutils being present...
	#
	# shellcheck disable=SC2012
	if [ -n "$( # <- Syntax
				if command -v find >/dev/null 2>&1; then
					# shellcheck disable=SC2227
					find "${sf_d}" 2>/dev/null \
							-mindepth 4 \
							-maxdepth 5 \
							-name 'build.log' -or -name 'config.log' \
							-type f \
							-print |
						head -n 1 || :
				else
					ls -1 2>/dev/null \
							"${sf_d}"/*/*/temp/build.log \
							"${sf_d}"/*/*/work/*/config.log |
						head -n 1 || :
				fi
			)" ]
	then
		sf_l='' sf_f=''

		sf_l="${PORTAGE_LOGDIR:-"$(get_portage_flags 'PORTAGE_LOGDIR')"}"
		mkdir -p "${sf_l%/}"/failed

		for sf_f in $(
				if command -v find >/dev/null 2>&1; then
					# Assume that only at most one of each of these two files
					# may exist across these two levels...
					#
					# shellcheck disable=SC2227
					find "${sf_d}" 2>/dev/null \
							-mindepth 4 \
							-maxdepth 5 \
							-name 'build.log' -or -name 'config.log' \
							-type f \
							-print
				else
					ls -1 2>/dev/null \
							"${sf_d}"/*/*/temp/build.log \
							"${sf_d}"/*/*/work/*/config.log
				fi
			)
		do
			[ -e "${sf_f}" ] || continue

			sf_type='' sf_pkg='' sf_cat=''
			sf_rc=1
			sf_type="$( echo "${sf_f}" | rev | cut -d'/' -f 1 | rev )"
			case "${sf_type}" in
				build.log)
					sf_cat="$( echo "${sf_f}" | rev | cut -d'/' -f 4 | rev )"
					sf_pkg="$( echo "${sf_f}" | rev | cut -d'/' -f 3 | rev )"
					;;
				config.log)
					sf_cat="$( echo "${sf_f}" | rev | cut -d'/' -f 5 | rev )"
					sf_pkg="$( echo "${sf_f}" | rev | cut -d'/' -f 4 | rev )"
					;;
				*)
					warn "Unknown log type '${sf_type}'"
					continue
					;;
			esac
			mkdir --parents "${sf_l%/}/failed/${sf_cat}"
			mv 2>/dev/null --verbose "${sf_f}" \
				"${sf_l%/}/failed/${sf_cat}/${sf_pkg}-${sf_type}" || :
			rmdir \
					--ignore-fail-on-non-empty \
					--parents \
				"$( dirname "${sf_f}" )" "${sf_l%/}/failed/${sf_cat}" || :
			unset sf_type sf_pkg sf_cat
		done
		unset sf_f sf_l
	fi

	unset sf_d

	#[ -n "${trace:-}" ] || set +o xtrace

	return ${sf_rc}
}  # save_failed

do_emerge() {
	do_emerge_arg=''
	do_emerge_opts=''
	#do_emerge_features=''
	do_emerge_rc=0

	[ "${#}" -gt 0 ] || return 1

	# '--root-deps' also appears to be broken similarly to '--deep' and
	# '--usepkgonly', but is supposed only to affect packages with EAPI 6 and
	# earlier.  In actuality, it seems to prevent root dependencies from being
	# considered at all for EAPI 7 and 8 packages - which is broadly the
	# opposite of its stated function :o
	#
	#if [ -n "${ROOT:-}" ] && [ "${ROOT}" != '/' ]; then
	#	do_emerge_opts='--root-deps'
	#fi


	for do_emerge_arg in "${@}"; do
		shift
		case "${do_emerge_arg:-}" in
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
				# With '--verbose=n', if there's nothing to remove then we're
				# prompted to run again in reverse mode to see further
				# dependencies - but with '--verbose=y', if there *is* anything
				# to remove then every removed filesystem object is listed
				# individually... really, these options should be controlled by
				# two separate parameters :(
				set -- "${@}" \
					--implicit-system-deps=n \
					--verbose=n \
					--with-bdeps=n \
					--with-bdeps-auto=n \
					--depclean
				;;

			'--defaults'|'--'*'-defaults')
				# shellcheck disable=SC2086
				set -- "${@}" \
					--backtrack=100 \
					--binpkg-respect-use=y \
					--quiet-build=y \
					  ${opts:-} \
					--verbose=y \
					--verbose-conflicts \
					  ${do_emerge_opts}

				case "${do_emerge_arg}" in
					'--defaults')
						:
						;;

					# --with-bdeps*=y
					'--build-defaults')
						# shellcheck disable=SC2086
						set -- "${@}" \
							  ${parallel} \
							--binpkg-changed-deps=y \
							--buildpkg=y \
							--oneshot \
							--usepkg=y \
							--with-bdeps=y \
							--with-bdeps-auto=y
							#--buildpkg=n \
							# --usepkgonly and --deep are horribly broken :(
							#--deep \
						;;

					# --buildpkg=n (but no longer)
					'--once-defaults'|'--single-defaults'|'--chost-defaults'| \
					'--initial-defaults')
						set -- "${@}" \
							--buildpkg=y \
							--usepkg=y \
							--with-bdeps=n \
							--with-bdeps-auto=n

						case "${do_emerge_arg}" in
							'--once-defaults')
								set -- "${@}" \
									--binpkg-changed-deps=y \
									--oneshot
								#do_emerge_features='-preserve-libs'
								;;
							'--single-defaults')
								set -- "${@}" \
									--binpkg-changed-deps=y
								#do_emerge_features='-preserve-libs'
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

						case "${do_emerge_arg}" in
							'--multi-defaults')
								set -- "${@}" \
									--usepkg=y
								;;
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
						warn "Unknown emerge defaults set '${do_emerge_arg}'"
						;;
				esac
				;;

			*)
				set -- "${@}" "${do_emerge_arg}"
				;;
		esac
	done

	if ! [ -f /srv/host/var/lib/portage/eclass/linux-info/.keep ]; then
		warn "Running emerge with ROOT='${ROOT:-"/"}' without" \
			"'eclass/linux-info' mounted into '/srv/host/var/lib/portage' -" \
			"kernel configuration dependencies will not be recorded"
		if [ -n "${DEBUG:-}" ]; then
			warn
			warn "Mounts:"
			line=''
			findmnt --real --pairs |
				sort -V |
				awk -F '"' '{print $4 " on " $2 " type " $6}' |
				while read -r line; do
					warn "  ${line}"
				done
			unset line
		fi
	fi

	print "Running \"emerge ${*}\"${USE:+" with USE='${USE}'"}" \
		"${ROOT:+" with ROOT='${ROOT}'"}"
	#FEATURES="${do_emerge_features:-}" \
	emerge --ignore-default-opts --color=y "${@:-}" || do_emerge_rc="${?}"
	echo "   -> ${do_emerge_rc}"

	if [ $(( do_emerge_rc )) -eq 0 ]; then
		do_emerge_dir='var/lib/portage/eclass/linux-info'
		if [ -d "${ROOT:-}/${do_emerge_dir}/" ]; then
			if [ ! -d "/srv/host/${do_emerge_dir}" ]; then
				warn "'${ROOT:-}/${do_emerge_dir}/' exists but"
					"'/srv/host/${do_emerge_dir}' is not mounted"
			else
				do_emerge_li='' do_emerge_f='' do_emerge_s1=0 do_emerge_s2=0

				print "Looking for kernel configuration hints in" \
					"'${ROOT:-}/${do_emerge_dir}/' ..."

				for do_emerge_li in "${ROOT:-}/${do_emerge_dir}"/*; do
					do_emerge_f="$( basename "${do_emerge_li}" )"

					[ "${do_emerge_f}" = '.keep' ] &&
						continue

					print ".. found file '${do_emerge_f}'"

					do_emerge_s1="$( stat -c '%s' "${do_emerge_li}" )"
					if [ -s "/srv/host/${do_emerge_dir}/${do_emerge_f}" ]; then
						print ".... comparing to exisiting file" \
							"'/srv/host/${do_emerge_dir}/${do_emerge_f}'"

						do_emerge_s2="$(
								stat -c '%s' \
									"/srv/host/${do_emerge_dir}/${do_emerge_f}"
							)"
					else
						do_emerge_s2=0
					fi
					if [ $(( do_emerge_s1 )) -ne $(( do_emerge_s2 )) ]; then
						print ".... file size has changed, saving" \
							"'${do_emerge_f}'"

						cp -a "${do_emerge_li}" \
								"/srv/host/${do_emerge_dir}/${do_emerge_f}" ||
							die "Unable to copy '${do_emerge_li}' to" \
								"'/srv/host/${do_emerge_dir}/${do_emerge_f}':" \
								"${?}"
					else
						print "...... discarding identical file"
					fi
				done
				unset do_emerge_s2 do_emerge_s1 do_emerge_f do_emerge_li
			fi  # [ -d "/srv/host/${do_emerge_dir}" ]
		fi  # [ -d "${ROOT:-}/${do_emerge_dir}/" ]

		[ -f /etc/._cfg0000_hosts ] && rm -f /etc/._cfg0000_hosts

		# For some reason, after dealing with /usr/sbin being a symlink to
		# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
		# following line is encountered, despite both elements still appearing
		# in $PATH...
		LC_ALL='C' /usr/sbin/etc-update -q --automode -5
		LC_ALL='C' eselect --colour=no news read >/dev/null 2>&1
	elif ! echo "${*:-}" | grep -qw -e '--unmerge' -e '--depclean'; then
		warn "Build failed (${do_emerge_rc}):"
		warn "  USE='${USE:-}'"
		warn "  ROOT='${ROOT:-}'"
		warn "  \${*}='${*:-}'"
		warn "  PKGDIR='$( get_portage_flags 'PKGDIR' )'"
		warn "  CFLAGS='$( get_portage_flags 'CFLAGS' )'"
		warn "  CXXFLAGS='$( get_portage_flags 'CXXFLAGS' )'"
		warn "  CGO_CFLAGS='$( get_portage_flags 'CGO_CFLAGS' )'"
		warn "  CGO_CXXFLAGS='$( get_portage_flags 'CGO_CXXFLAGS' )'"
		warn "  LDFLAGS='$( get_portage_flags 'LDFLAGS' )'"
		warn "  CGO_LDFLAGS='$( get_portage_flags 'CGO_LDFLAGS' )'"
		warn "  RUSTFLAGS='$( get_portage_flags 'RUSTFLAGS' )'"
		de_d=''
		de_d="${PORTAGE_TMPDIR:-"$(get_portage_flags 'PORTAGE_TMPDIR')"}"
		de_d="${de_d%/}/portage"
		if [ -d "${de_d}" ]; then
			info "Looking for 'config.log' files beneath '${de_d}' ..."
			de_f=''
			find "${de_d}" -mindepth 5 -type f -name 'config.log' -print |
					while read -r de_f
			do
				warn
				warn "$( echo "${de_f}" | sed "s|^${de_d}/||" ):"
				cat "${de_f}"
			done
			save_failed
			#ls -lR "${de_d}/portage"
			unset de_f
		fi
		unset de_d
	fi

	unset do_emerge_opts do_emerge_arg

	return ${do_emerge_rc}
}  # do_emerge

# Modified from sys-apps/portage phase-helpers.sh:
get_libdir() {
	libdir_data="$( # <- Syntax
			LC_ALL='C' emerge --info --verbose=y 2>&1 |
				grep -e 'ABI=' -e '^LIBDIR'
		)"
	libdir_ABI="${ABI:-}"
	if [ -z "${libdir_ABI:-}" ]; then
		libdir_ABI="$( # <- Syntax
				echo "${libdir_data}" |
					grep -- '^ABI=' |
					cut -d'"' -f 2
			)"
	fi
	libdir="lib"

	if [ -n "${libdir_ABI}" ] &&
			echo "${libdir_data}" |
				grep -q "^LIBDIR_${libdir_ABI}="
	then
		libdir="$( # <- Syntax
				echo "${libdir_data}" |
					grep -- "^LIBDIR_${libdir_ABI}=" |
					cut -d'"' -f 2
			)"
	fi

	echo "${libdir}"
}  # get_libdir

# shellcheck disable=SC2120
validate_libgcc() {
	# With the 2025-06-09T01:12:14.538737447Z
	# docker.io/gentoo/stage3:arm64-openrc (807068a219e9) and
	# 2025-06-09T01:09:39.348232494Z
	# docker.io/gentoo/stage3:amd64-nomultilib-openrc (fbd632d5b57a) images
	# we're getting failures early in gentoo-base.log when trying to /unpack/
	# sys-devel/gcc due to libgcc_s.so apparently being missing - so let's
	# validate that we have the appropriate library and potentially also copy
	# it to a standard location...

	# Thinking about it, I wonder whether this is due to gcc-14.2 -> gcc-14.3,
	# and so env-update/ldconfig needing to be run in order to pick up the new
	# paths?  But why, then, is this happening in the sys-devel/gcc 'unpack'
	# stage?!
	#
	env-update >/dev/null 2>&1
	# shellcheck disable=SC1091
	. /etc/profile >/dev/null 2>&1 || :

	# sys-apps/sandbox is a dependency of sys-apps/portage, and also links
	# against libgcc_s...
	if [ -s "/usr/$(get_libdir)/libsandbox.so" ] &&
			ldd "/usr/$(get_libdir)/libsandbox.so" 2>&1 |
				grep -q -- 'libgcc_s.*not found'
	then
		warn 'libgcc_s.so.1 breakage encountered - attempting to relocate' \
			'library ...'

		libgcc_root='' libgcc_dir=''
		for libgcc_root in $(
					if [ -n "${*:-}" ]; then
						echo "${*}"
					else
						echo "${extra_root:-}" "${ROOT:-"/"}" "${SYSROOT:-}" \
								"${service_root:-}" |
							xargs -rn 1 |
							sort -u
					fi
				)
		do
			[ -d "${libgcc_root:-}" ] || continue

			if libgcc_dir="$( #
					find "${libgcc_root%"/"}/usr/lib/gcc/" \
							-mindepth 2 \
							-maxdepth 2 \
							-type d |
						sort -V |
						tail -n 1
				)" && [ -d "${libgcc_dir:-}" ]
			then
				cp -a "${libgcc_dir}"/libgcc_s.so* \
					"${libgcc_root%"/"}/usr/$(get_libdir)"/
			fi
		done
		unset libgcc_dir libgcc_root
	fi
}  # validate_libgcc

validate_python_installation() {
	vpi_stage="${*:-}"

	# shellcheck disable=SC2046
	if ! test -d $(
				printf '%s/var/db/pkg/dev-lang/%s*/.' \
					"${ROOT:+"${ROOT%"/"}"}" \
					"$( # <- Syntax
						echo "${python_default_targets%%" "*}" |
							sed 's/3_/-3./'
					)"
			)
	then
		warn "No installed package found for python_default_target" \
			"'${python_default_targets%%" "*}' in ROOT '${ROOT:-"/"}'"
	else
		for python_path in "${ROOT:+"${ROOT%"/"}"}/usr/lib/$( # <- Syntax
				echo "${python_default_targets%%" "*}" |
					sed 's/_/./'
			)" \
			"${ROOT:+"${ROOT%"/"}"}/usr/include/$( # <- Syntax
				echo "${python_default_targets%%" "*}" |
					sed 's/_/./'
			)"
		do
			if ! test -d "${python_path}"; then
				warn "python component path '${python_path}' not found"
			else
				if [ $(( $(
						find "${python_path}" -xtype f -perm 0 -print |
							wc -l
					) )) -gt 0 ]
				then
					echo >&2 "ERROR: Unreadable python files found in root" \
						"'${ROOT:-"/"}':"
					find "${python_path}" -xtype f -perm 0 -exec ls -l {} + |
						sed 's/^/ERROR:   /' >&2
					warn "python installation at '${python_path}' is" \
						"broken${vpi_stage:+" at stage '${vpi_stage}'"}"
					warn "Attempting in-place fix ..."
					find "${python_path}" -type f -perm 0 -exec chmod 0644 {} +
					find "${python_path}" -type d -perm 0 -exec chmod 0755 {} +
				fi
			fi
		done
		unset python_path
	fi
}  # validate_python_installation

fix_sh_symlink() {
	symlink_root="${1:-"${ROOT:-}"}"
	symlink_msg="${2:-}"  # expected 'pre-deploy' or '@system'

	# Ensure we have a valid /bin/sh symlink in our ROOT...
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
info "Starting 'gentoo-base/entrypoint.sh' ..."

[ -n "${trace:-}" ] && set -o xtrace

if set | grep -q -- '=__[A-Z]\+__$'; then
	die "Unexpanded variable(s) in environment: $( # <- Syntax
			echo
			set | grep -- '=__[A-Z]\+__$' | sed 's/^/  /'
		)"
fi

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

# For reasons I can't fathom, even with a verifiably correct
# /etc/portage/repos.conf structure in place, 'portageq get_repo_path / <repo>'
# is picking up '/var/db/repo/<repo>' rather than the 'location' from the file.
#
# Update: It's because PORTDIR in /etc/portage/make.conf overrides anything in
#         /etc/portage/repos.conf
#
repo_path=''
if sed 's/#.*$//' /etc/portage/make.conf |
		grep -Fq -- 'PORTDIR='
then
	warn "PORTDIR is set in /etc/portage/make.conf - please remove this" \
		"override to ensure correct operation"
	repo_path="$( portageq get_repo_path '/' gentoo )" || :
	if [ -n "${repo_path:-}" ]; then
		if ! sed 's/#.*$//' /etc/portage/make.conf |
				grep -q "PORTDIR=['\"]\?${repo_path%/}/\?['\"]/?\s*$"
		then
			die "portageq and /etc/portage/make.conf disagree about the" \
				"location of the default repo"
		fi
	fi
	repo_path=''
fi

# Let's symlink the actual location back regardless...
#
repo_name=''
: $(( created = 0 )) || :
for repo_name in $( portageq get_repos '/' ); do
	if ! [ -s "/etc/portage/repos.conf/${repo_name}.conf" ]; then
		warn "repo definition '${repo_name}.conf' is missing"
	else
		repo_path="$( # <- Syntax
				grep -i '^\s*location\s*=\s*' \
						"/etc/portage/repos.conf/${repo_name}.conf" |
					cut -d'=' -f 2- |
					awk '{print $1}' |
					tail -n 1
			)" || :
		if [ -z "${repo_path:-}" ]; then
			warn "Could not read 'location' from '${repo_name}.conf'"
		elif ! [ -d "${repo_path}" ]; then
			warn "location '${repo_path}' from '${repo_name}.conf' doesn't" \
				"exist"
		elif ! [ "${repo_path#"/var/db/repo/"}" = "${repo_name}" ]; then
			if [ -e "/var/db/repo/${repo_name}" ]; then
				warn "location '${repo_path}' is not in a default location," \
					"but '/var/db/repo/${repo_name}' already exists"
			else
				warn "Creating compatibility symlink" \
					"'/var/db/repo/${repo_name}' with target '${repo_path}'" \
					"..."
				mkdir -p /var/db/repo
				ln -s "${repo_path}" "/var/db/repo/${repo_name}"
				: $(( created = 1 )) || :
			fi
		fi
	fi
done
if [ $(( created )) -eq 1 ]; then
	print "/var/db/repo contents:"
	# shellcheck disable=SC2010
	ls -l /var/db/repo/ | grep -v '^total ' | while read -r repo_path; do
		print "  ${repo_path}"
	done
fi
unset created repo_path repo_name

# Pre-load keys...
get_portage_flags

print "Initial environment CFLAGS are \"${CFLAGS:-}\""
print "Initial portage CFLAGS are \"$( get_portage_flags 'CFLAGS' )\""

if [ -f /etc/env.d/50baselayout ] && [ -s /etc/env.d/50baselayout ]; then
	changed=0
	if ! grep -q -- 'PATH.*[":]/sbin[":]' /etc/env.d/50baselayout; then
		sed -e '/PATH/s|:/opt/bin"|:/sbin:/opt/bin"|' \
			-i /etc/env.d/50baselayout
		changed=1
	fi
	if ! grep -q -- 'PATH.*[":]/bin[":]' /etc/env.d/50baselayout; then
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

if echo "${MAXLOAD:-}" | grep -q -- '^0'; then
	# Assume NO_LOAD_LIMITS has been specified...
	parallel='--jobs'
else
	# MAXLOAD is either non-zero, or unset (in which case we'll default to
	# DEFAULT_MAXLOAD)
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

#warn >&2 "Inherited USE flags: '${USE:-}'"

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
[ -d /etc/portage ] ||
	die "'/etc/portage' is missing or not a directory"
[ -s /etc/portage/package.use ] || [ -d /etc/portage/package.use ] ||
	die "'/etc/portage/package.use' is missing"
default_repo_dir="$( portageq get_repo_path '/' gentoo )" || :
[ -d "${default_repo_dir:-}" ] ||
	die "default repo ('gentoo') directory '${default_repo_dir:-}' is missing"
unset default_repo_dir
[ -s /etc/locale.gen ] ||
	warn "'/etc/locale.gen' is missing or empty"
if ! [ -s "${PKGDIR}"/Packages ] || ! [ -d "${PKGDIR}"/virtual ]; then
	warn "'${PKGDIR}/Packages' or '${PKGDIR}/virtual' are missing - package" \
		"cache appears invalid"
fi

env | grep -F -- 'DIR=' | cut -d'=' -f 2- | while read -r d; do
	# Inherited environment values are appearing quoted, which is non-standard
	d="${d#'"'}" ; d="${d%'"'}"

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
		LC_ALL='C' emerge --info --verbose=y 2>&1
	)"
echo
echo 'Resolved build variables for stage3:'
echo '-----------------------------------'
echo
echo "${info}" | format 'CFLAGS'
echo "${info}" | format 'LDFLAGS'
echo
echo "ROOT                = $( # <- Syntax
		echo "${info}" |
			grep -- '^ROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "SYSROOT             = $( # <- Syntax
		echo "${info}" |
			grep -- '^SYSROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
		echo "${info}" |
			grep -- '^PORTAGE_CONFIGROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo
echo "${info}" | format 'FEATURES'
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
#echo "${info}" | format 'INSTALL_MASK'
echo "${info}" | format 'USE'
echo "${info}" | format 'PYTHON_SINGLE_TARGET'
echo "${info}" | format 'PYTHON_TARGETS'
echo "MAKEOPTS            = $( # <- Syntax
		echo "${info}" |
			grep -- '^MAKEOPTS=' |
			cut -d'=' -f 2- |
			uniq
	)"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( # <- Syntax
		echo "${info}" |
			grep -- '^DISTDIR=' |
			cut -d'=' -f 2- |
			uniq
	)"
echo "PKGDIR              = $( # <- Syntax
		echo "${info}" |
			grep -- '^PKGDIR=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "PORTAGE_LOGDIR      = $( # <- Syntax
		echo "${info}" |
			grep -- '^PORTAGE_LOGDIR=' |
			cut -d'=' -f 2- |
			uniq
	)"
echo
unset info

# Report stage3 tool versions (because some are masked from the arm64 stage3!)
#
file=''
for file in /lib*/libc.so.6; do
	printf '%4s: ' 'libc'
	"${file}" 2>&1 | head -n 1 || :
done
unset file
printf '%4s: ' 'gcc'
gcc --version 2>&1 | head -n 1 || :
printf '%4s: ' 'ld'
ld --version 2>&1 | head -n 1 || :

# We should *definitely* have this...
package='virtual/libc'
opts='--tree'
if printf ' %s ' "${*}" | grep -Fq -- ' --nodeps '; then
	opts=''
fi

LC_ALL='C' eselect --colour=yes profile list | grep -- 'stable'
LC_ALL='C' eselect --colour=yes profile set "${DEFAULT_PROFILE}" # 2>/dev/null
info "Selected profile '$( # <- Syntax
		LC_ALL='C' eselect --colour=yes profile show |
			tail -n 1 |
			sed 's/\s\+//'
	)'"

LC_ALL='C' emaint --fix binhost

# TODO: Is there any benefit in showing stage3 news?
#
# Update: Let's show all news in one go, at the end of the process...
#         ... but still run 'news read' now, to prevent annoying notices from
#         'emerge' saying that news is pending!
LC_ALL='C' eselect --colour=no news read >/dev/null 2>&1

#set -o xtrace

# Until we're rebuilt sys-devel/gcc ourselves, we can't rely on having
# 'graphite' functionality - therefore, we need to strip these flags to prevent
# build failures up to that point.
#
_o_CFLAGS='' _o_CXXFLAGS=''
_o_CGO_CFLAGS='' _o_CGO_CXXFLAGS=''
_o_FFLAGS='' _o_FCFLAGS='' _o_CGO_FFLAGS=''
_o_LDFLAGS='' _o_FLFLAGS='' _o_CGO_LDFLAGS=''
if [ -n "${CFLAGS:-}${CXXFLAGS:-}" ]; then
	if echo " ${CFLAGS:-} ${CXXFLAGS:-} " |
			grep -Eq -- '\s(-fgraphite|-floop-)'
	then
		_o_CFLAGS="${CFLAGS:-}"
		_o_CXXFLAGS="${CXXCFLAGS:-}"
		_o_CGO_CFLAGS="${CGO_CFLAGS:-}"
		_o_CGO_CXXFLAGS="${CGO_CXXFLAGS:-}"
		_o_FFLAGS="${FFLAGS:-}"
		_o_FCFLAGS="${FCFLAGS:-}"
		_o_CGO_FFLAGS="${CGO_FFLAGS:-}"
		_o_LDFLAGS="${LDFLAGS:-}"
		_o_CGO_LDFLAGS="${CGO_LDFLAGS:-}"
		_o_FLFLAGS="${FLFLAGS:-}"
		eval "$( # <- Syntax
				filter_toolchain_flags --env-only \
					-fgraphite -fgraphite-identity \
					-floop-nest-optimize -floop-parallelize-all
			)" || :
	fi
fi

# As-of sys-libs/zlib-1.2.11-r3, zlib builds without error but then the portage
# merge process aborts with 'unable to read SONAME from libz.so' in src_install
#
# To try to work around this, snapshot the current stage3 version...
#quickpkg --include-config y --include-unmodified-config y sys-libs/zlib

if portageq get_repos '/' | grep -Fq -- 'srcshelton'; then
	echo
	echo " * Building linted 'sys-apps/gentoo-functions' package for stage3 ..."
	echo
	(
		USE="-* $( get_stage3 --values-only USE )"
		export USE
		FEATURES="$( # <- Syntax
				filter_features_flags 'clean' 'fail-clean' 'fakeroot'
			) -clean -fail-clean -fakeroot"
		export FEATURES
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
		unset pkgdir
		do_emerge --single-defaults 'sys-apps/gentoo-functions::srcshelton'
	)
fi

# pre-removal python sanity-checks
#
validate_python_installation "pre-remove"

(
	mkdir -p /var/lib/portage
	echo 'virtual/libc' > /var/lib/portage/world

	# We're only removing packages here, but different USE flag combinations
	# may affect dependencies...
	#
	USE="-* $( get_stage3 --values-only USE ) -udev"
	export USE
	FEATURES="$( # <- Syntax
			filter_features_flags 'clean' 'fail-clean' 'fakeroot'
		) -clean -fail-clean -fakeroot"
	export FEATURES
	pkgdir="$( LC_ALL='C' portageq pkgdir )"
	export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
	unset pkgdir

	# 'dhcpcd' is now built with USE='udev', and libmd needs 'split-usr'...
	#
	# ... and /usr/$(get_libdir)/libmd.so is being preserved :(
	#
	(
		FEATURES="$( # <- Syntax
				filter_features_flags --env-only 'preserve-libs'
			) -preserve-libs"
		export FEATURES
		do_emerge --once-defaults app-crypt/libmd net-misc/dhcpcd
	)

	list='virtual/dev-manager virtual/tmpfiles'
	if LC_ALL='C' portageq get_repos '/' | grep -Fq -- 'srcshelton'; then
		list="${list:-} sys-apps/systemd-utils"
	fi
	if echo "${ARCH:-"${arch:-}"}" | grep -Fiq 'arm'; then
		# Give virtual/os-headers a chance to pull-in
		# sys-kernel/raspberrypi-headers or sys-kernel/rockchip-headers by
		# removing all preinstalled headers packages...
		list="${list:-} virtual/os-headers sys-kernel/linux-headers"
	fi

	# To make the following output potentially clearer, attempt to remove any
	# masked packages which might exist in the image we're building from...
	#
	echo
	echo
	echo " * Attempting to remove masked packages from stage3 ..."
	echo
	echo

	# shellcheck disable=SC2086
	do_emerge --unmerge-defaults ${list} || :

	# virtual/udev-217-r3 pulled in by:
	#    sys-apps/hwids-20210613-r1 requires virtual/udev
	#    sys-fs/udev-init-scripts-34 requires >=virtual/udev-217
	#    virtual/dev-manager-0-r2 requires virtual/udev
	list="$( # <- Syntax
			{
				sed 's/#.*$//' /etc/portage/package.mask/* |
						grep -v -- 'gentoo-functions'

				sed 's/#.*$//' /etc/portage/package.mask/* |
						grep -Eow -- '((virtual|sys-fs)/)?e?udev' &&
					echo 'sys-apps/hwids sys-fs/udev-init-scripts'

				echo "<dev-lang/$( # <- Syntax
						echo "${python_default_targets}" |
							sed 's/3_/-3./' |
							sort -V |
							tail -n 1
					)"
			} |
				grep -Fv -- '::' |
				sort -V |
				xargs -r
		)"
	echo "Package list: ${list}"
	echo
	# shellcheck disable=SC2086
	do_emerge --depclean-defaults ${list} || :
)

# pre-rebuild python sanity-checks
#
validate_python_installation "pre-rebuild"

if [ $(( $(
			find /var/db/pkg/dev-lang/ \
					-mindepth 1 -maxdepth 1 \
					-type d \
					-name 'python-3.*' \
					-print |
				wc -l
		) )) -gt 1 ]
then
	echo
	echo " * Multiple python interpreters present, attempting rebuild for" \
		"'${python_default_targets%%" "*}' ..."
	echo
	(
		# First, let's try to get a working 'qatom' for map_p_to_pn from
		# app-portage/portage-utils...
		export QA_XLINK_ALLOWED='*'
		FEATURES="$( # <- Syntax
				filter_features_flags 'clean' 'fail-clean' 'preserve-libs'
			) -clean -fail-clean -preserve-libs"
		export FEATURES
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/python"
		unset pkgdir
		export USE='-clang -openmp -qmanifest -static'
		eval "$( filter_toolchain_flags --env-only -fopenmp )" || :
		do_emerge --once-defaults \
			app-portage/portage-utils || :
	)
	(
		export QA_XLINK_ALLOWED='*'
		FEATURES="$( # <- Syntax
				filter_features_flags 'clean' 'fail-clean' 'preserve-libs'
			) -clean -fail-clean -preserve-libs"
		export FEATURES
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/python"
		unset pkgdir
		USE="-* $( get_stage3 --values-only USE ) -udev split-usr"
		USE="$( # <- Syntax
				echo "${USE}" |
					xargs -rn 1 |
					grep -v -e '^python_single_target_' -e 'python_targets_' |
					xargs -r
				echo "python_single_target_${python_default_targets%%" "*}"
				echo "python_targets_${python_default_targets%%" "*}"
			)"
		export USE
		export PYTHON_DEFAULT_TARGET="${python_default_targets%%" "*}"
		export PYTHON_TARGETS="${python_default_targets}"
		eval "$( # <- Syntax
				resolve_python_flags \
					"${USE}" \
					"python_single_target_${python_default_targets%%" "*}" \
					"python_targets_${python_default_targets%%" "*}"
			)"

		# FIXME: Nasty hack to avoid preserved libraries...
		# shellcheck disable=SC2046
		{
			rm -f /usr/"$(get_libdir)"/libuuid.so.1*
			rm -f /usr/lib/$(
					echo "${python_default_targets%%" "*}" | sed 's/_/./'
				)/lib-dynload/_uuid.cpython-*.so
		}

		# python3_13 -> dev-lang/python:3.13
		python_pkg="dev-lang/$( # <- Syntax
				echo "${python_default_targets%%" "*}" |
					sed 's/3_/:3./'
			)"
		# shellcheck disable=SC2046,SC2086
		#	debug=1 \
		do_emerge --once-defaults "${python_pkg}" $(
				# The 20240605 arm64 stage3 image contains several outdated
				# pakages which no longer exist in the portage tree :(
				#
				grep -- 'python_[^ ]*target' \
						"${ROOT:-}"/var/db/pkg/*/*/USE |
					grep -v "_${python_default_targets%%" "*}" |
					grep -- '_python3_' |
					grep -v 'backports' |
					cut -d':' -f 1 |
					rev |
					cut -d'/' -f 2-3 |
					rev |
					map_p_to_pn |
					xargs -r
			)
		unset python_pkg

		list="$( # <- Syntax
				{
					echo "<dev-lang/$(
						echo "${python_default_targets}" |
							sed 's/3_/-3./' |
							sort -V |
							tail -n 1
					)"
					grep -- 'python_[^ ]*target' \
							"${ROOT:-}"/var/db/pkg/*/*/USE |
						grep -v "_${python_default_targets%%" "*}" |
						grep -- '_python3_' |
						grep -- 'backports' |
						cut -d':' -f 1 |
						rev |
						cut -d'/' -f 2-3 |
						rev |
						map_p_to_pn |
						xargs -r
				} |
					grep -Fv -- '::' |
					sort -V |
					xargs -r
			)"

		echo "Package list: ${list}"
		echo
		# shellcheck disable=SC2086
		do_emerge --depclean-defaults ${list} || :

		do_emerge --preserved-defaults '@preserved-rebuild'
	)
fi

# post-rebuild python sanity-checks
#
validate_python_installation "post-rebuild"

echo
echo " * Building 'sys-apps/fakeroot' package for stage3 ..."
echo
(
	USE="-* $( get_stage3 --values-only USE )"
	export USE
	FEATURES="$( # <- Syntax
			filter_features_flags 'clean' 'fail-clean' 'fakeroot'
		) -clean -fail-clean -fakeroot"
	export FEATURES
	pkgdir="$( LC_ALL='C' portageq pkgdir )"
	export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
	unset pkgdir

	if echo " ${use_essential}" | grep -q -- ' rpi[0-9-]'; then
			USE="${USE} ${use_essential}" \
		do_emerge --single-defaults sys-kernel/raspberrypi-headers
	fi
		USE="${USE} ${use_essential}" \
	do_emerge --single-defaults virtual/os-headers

	do_emerge --single-defaults sys-apps/fakeroot
)
FEATURES="$( # <- Syntax
		filter_features_flags 'clean' 'fail-clean' 'fakeroot' 'preserve-libs'
	) -clean -fail-clean fakeroot -preserve-libs"
export FEATURES

export QA_XLINK_ALLOWED='*'

echo
echo " * Building 'sys-apps/portage' package for stage3 (in case of" \
	"downgrades) ..."
echo
(
	USE="-* $( get_stage3 --values-only USE ) ${use_essential}"
	export USE
	pkgdir="$( LC_ALL='C' portageq pkgdir )"
	export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
	unset pkgdir
	PYTHON_TARGETS="${python_default_targets}"
	PYTHON_SINGLE_TARGET="${python_default_targets%%" "*}"
	export PYTHON_TARGETS PYTHON_SINGLE_TARGET

	do_emerge --single-defaults 'sys-apps/portage'
)

usex() {
	usex_var="${1:-}"
	usex_true="${2:-}"
	usex_false="${3:-}"

	if [ -z "${usex_var:-}" ]; then
		printf '%s' "${usex_false:-}"
	else
		usex_value="$( eval echo "\$${usex_var}" )"
		if [ -n "${usex_value:-}" ]; then
			printf '%s' "${usex_true:-}"
		else
			printf '%s' "${usex_false:-}"
		fi
	fi
	unset usex_value usex_false usex_true usex_var
}  # usex

# We need to leave the system in a similar state to before we started, so build
# ithreads packages first, then reinstall the previous packages without
# ithreads
#
ithreads=''
for ithreads in 'ithreads' ''; do
	echo
	echo " * Building 'dev-lang/perl' package (with$(usex ithreads '' 'out')" \
		"ithreads) for stage3 ..."
	echo
	(
		USE="-* $( get_stage3 --values-only USE )"
		USE="$( # <- Syntax
				echo " berkdb gdbm $(usex ithreads 'perl_features_ithreads ' '')${USE}$(usex ithreads '' ' -perl_features_ithreads') " |
					sed "s/ $(usex ithreads '-' '')perl_features_ithreads / /g" |
					xargs -rn 1 |
					sort -u |
					xargs -r
			)"
		export USE
		export PERL_FEATURES="${ithreads:-}"
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
		unset pkgdir
		# shellcheck disable=SC2046
		do_emerge --single-defaults dev-lang/perl dev-perl/libintl-perl $(
				grep -lw 'perl_features_ithreads' \
						"${ROOT:-}"/var/db/pkg/*/*/IUSE |
					rev |
					cut -d'/' -f 2-3 |
					rev |
					sed 's/^/>=/' |
					xargs -r
			)
	)
done
unset ithreads usex


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
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
		unset pkgdir
		do_emerge --chost-defaults '@system' '@world'
	)
	# For some reason, after dealing with /usr/sbin being a symlink to
	# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
	# following line is encountered, despite both elements still appearing in
	# $PATH...
	LC_ALL='C' /usr/sbin/etc-update --quiet --preen
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
			pkgdir="$( LC_ALL='C' portageq pkgdir )"
			export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
			unset pkgdir
			if [ "${pkg}" = 'sys-devel/gcc' ]; then
				validate_libgcc
			fi
			do_emerge --single-defaults "${pkg}"
			if [ "${pkg}" = 'sys-devel/gcc' ]; then
				validate_libgcc
			fi
		)
		# For some reason, after dealing with /usr/sbin being a symlink to
		# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
		# following line is encountered, despite both elements still appearing
		# in $PATH...
		LC_ALL='C' /usr/sbin/etc-update --quiet --preen
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
			pkgdir="$( LC_ALL='C' portageq pkgdir )"
			export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
			unset pkgdir
			do_emerge --single-defaults "${pkg}"
		)
		# For some reason, after dealing with /usr/sbin being a symlink to
		# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
		# following line is encountered, despite both elements still appearing
		# in $PATH...
		LC_ALL='C' /usr/sbin/etc-update --quiet --preen
		find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
	done
	unset pkg
	[ -x /usr/sbin/fix_libtool_files.sh ] &&
		/usr/sbin/fix_libtool_files.sh "$( gcc -dumpversion )" \
			--oldarch "${oldchost}"

	(
		USE="-* nptl $( get_stage3 --values-only USE )"
		export USE
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
		unset pkgdir

		# clashing USE flags can't be resolved with current level of
		# command-line fine-grained package flag control :(
		exclude='sys-apps/coreutils sys-apps/net-tools sys-apps/util-linux sys-process/procps sys-apps/shadow'

		do_emerge --once-defaults --exclude "${exclude}" dev-libs/libgpg-error
		#ls -l "/usr/bin/${CHOST}-gpg-error-config"
		#cat /var/db/pkg/dev-libs/libgpg-error*/CONTENTS

		# shellcheck disable=SC2012,SC2046
		do_emerge --preserved-defaults --exclude "${exclude}" $(
					for object in \
							"/usr/bin/${oldchost}-"* \
							"/usr/include/${oldchost}" \
							/usr/lib/llvm/*/bin/"${oldchost}"-*
					do
						if [ -e "${object}" ]; then
							printf '%s ' "${object}"
						fi
					done
				)dev-lang/perl ">=$( # <- Syntax
						ls /var/db/pkg/dev-lang/python-3* -1d |
							cut -d'/' -f 5-6 |
							sort -V |
							head -n 1
					)" '@preserved-rebuild'
	)
	validate_python_installation "CHOST change"

	#if LC_ALL='C' eselect --colour=yes news read new |
	#		grep -Fv -- 'No news is good news.'
	#then
	#	printf '\n---\n\n'
	#fi

	# For some reason, after dealing with /usr/sbin being a symlink to
	# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
	# following line is encountered, despite both elements still appearing in
	# $PATH...
	LC_ALL='C' /usr/sbin/etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

	# }  # chost_change
fi

echo
echo
echo " * Installing stage3 prerequisites to allow for working 'split-usr'" \
	"setups ..."
echo

(
	pkgdir="$( LC_ALL='C' portageq pkgdir )"
	export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
	unset pkgdir

	# There's something weird happening with sys-libs/pam - if it's built
	# separately (albeit on our split-usr capable image) then everything works.
	# If the exact same package is built below, all of the shared objects end
	# up being linked to /usr/$(get_libdir)/libpam.so.0 which then (correctly)
	# triggers a QA violation.
	#
	# We also want to get a version of sys-libs/libxcrypt with libraries on the
	# root filesystem, but can't remove it entirely without a binpkg already
	# existing, as sys-libs/libxcrypt requires dev-lang/perl to build, whilst
	# perl is dynamically linked to libcrypt.so, and so won't start without
	# the library being present.
	#
	# Update: ... but on a fresh ARM64 system, removing sys-libs/libxcrypt as
	#         below without a pre-built alternative prevents perl from being
	#         able to be used, which in turn prevents the building of the
	#         replacement sys-libs/libxcrypt - so let's build a binary package
	#         first.
	#
	# shellcheck disable=SC2046
	(
		export USE='-gmp -nls ssl'
		do_emerge --single-defaults sys-libs/libxcrypt
	)
	do_emerge --unmerge-defaults sys-libs/pam sys-libs/libxcrypt
	rmdir -p --ignore-fail-on-non-empty /usr/lib*/security/pam_filter || :

	# shellcheck disable=SC2046
	(
		export USE='-gmp -nls asm cet ssl'
		do_emerge --single-defaults sys-libs/libxcrypt

		# app-arch/zstd is failing here because it can't find dev-build/ninja,
		# which does indeed not appear to be being pulled-in, despite being
		# explicitly required in the inherited eclasses and even when added
		# explicitly in the ebuild...
		#
		do_emerge --single-defaults dev-build/libtool dev-build/ninja \
			sys-libs/pam $(
				# sys-devel/gcc is a special case with a conditional
				# gen_usr_ldscript call...
				#
				# ... and sys-libs/glibc and sys-devel/gcc are now required to
				# have the same 'cet' USE flag, so we do either build both
				# here, add USE='cet' or exclude glibc also.
				#
				# N.B. Using 'grep -lm 1' and so not having to read the whole
				#      file where there is no match is about twice as fast as
				#      finding the 'inherit' line only and then checking for
				#      'usr-ldscript' but having to invoke 'sed', 'grep', and
				#      'cut' (with a cold cache)
				{
					grep -lm 1 '^inherit[^#]\+usr-ldscript' \
							"$( portageq vdb_path )"/*/*/*.ebuild |
						rev |
						cut -d'/' -f 3,4 |
						rev
					if LC_ALL='C' portageq get_repos '/' |
							grep -Fq -- 'srcshelton'
					then
						grep -lm 1 '^inherit[^#]\+usr-ldscript' "$( # <- Syntax
										portageq get_repo_path '/' srcshelton
									)"/*/*/*.ebuild |
							rev |
							cut -d'/' -f 2,3 |
							rev
					fi
				} |
					sort |
					uniq |
					grep -Fxv 'sys-devel/gcc' |
					while read -r ebuild; do
						for file in "$( # <- Syntax
								portageq vdb_path
							)/${ebuild}"-*/CONTENTS
						do
							if [ -f "${file}" ]; then
								grep -Eqm 1 -- '(sym|obj) /lib(x?32|64)' \
										"${file}" ||
									echo "${ebuild}"
							fi
						done
					done
			)
	)

	echo
	echo " * Rebuilding preserved dependencies, if any ..."
	echo
	do_emerge --preserved-defaults '@preserved-rebuild'
)

echo
echo " * Installing stage3 'sys-kernel/gentoo-sources' kernel source" \
	"package ..."
echo

# Some packages require prepared kernel sources...
#
(
	USE="-* symlink $( get_stage3 --values-only USE )"
	export USE
	pkgdir="$( LC_ALL='C' portageq pkgdir )"
	export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
	unset pkgdir

	if echo " ${use_essential}" | grep -q -- ' rpi[0-9-]'; then
			USE="${USE} ${use_essential}" \
		do_emerge --single-defaults sys-kernel/raspberrypi-headers
	fi
		USE="${USE} ${use_essential}" \
	do_emerge --single-defaults virtual/os-headers

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
do
	echo
	echo
	echo " * Building stage3 '${pkg}' package ..."
	echo

	(
		USE="-* $( get_stage3 --values-only USE )"
		USE="$( # <- Syntax
				echo "${USE}" |
					xargs -rn 1 |
					grep -v -e '^python_single_target_' -e 'python_targets_' |
					xargs -r
				echo "python_single_target_${python_default_targets%%" "*}"
				echo "python_targets_${python_default_targets%%" "*}"
			)"
		eval "$( # <- Syntax
				resolve_python_flags \
					"${USE}" \
					"${PYTHON_SINGLE_TARGET:-"${python_default_targets%%" "*}"}" \
					"${PYTHON_TARGETS:-"${python_default_targets}"}"
			)"
		# Add 'xml' to prevent an additional python install/rebuild for
		# sys-process/audit (which pulls-in dev-lang/python without USE='xml')
		# vs. dev-libs/libxml2 (which requires dev-lang/python[xml])
		#
		# shellcheck disable=SC2154
		USE="xml ${USE} ${use_essential_gcc}"
		# Requirement patched out for >=sys-devel/binutils-2.41
		#if [ "${arch}" = 'arm64' ]; then
		#	USE="gold ${USE}"
		#fi
		export USE
		pkgdir="$( LC_ALL='C' portageq pkgdir )"
		export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
		unset pkgdir
		case "${pkg}" in
			'dev-libs/libxml2')
				# Don't install previous versions of python...
				#
				# FIXME: Remove hard-coding of previous python targets
				#
				USE="${USE} -lzma -python_targets_python3_10 -python_targets_python3_11 -python_targets_python3_12"
				;;
			'sys-devel/gcc')
				USE="${USE} -nls"
				# This should be our first time building sys-devel/gcc, so we
				# won't have a backup yet - subsequently, we can only take a
				# fresh backup if libgcc_s may have changed...
				validate_libgcc
				;;
			'sys-libs/libcap')
				USE="${USE} -tools"
				;;
			'sys-process/audit')
				# sys-process/audit is the first package which can pull-in an
				# older python release, which causes preserved libraries...
				#
				# Update for python:3.12 - audit is not compatible, so disable
				# python support entirely
				# (This can't come through package.use as the environment USE
				#  flags set above override it)
				USE="${USE} -berkdb -ensurepip -gdbm -ncurses -python -readline -sqlite"
				;;
		esac
		do_emerge --single-defaults "${pkg}"
		if [ "${pkg}" = 'sys-devel/gcc' ]; then
			validate_libgcc
		fi
	)
	#if LC_ALL='C' eselect --colour=yes news read new |
	#		grep -Fv -- 'No news is good news.'
	#then
	#	printf '\n---\n\n'
	#fi

	# For some reason, after dealing with /usr/sbin being a symlink to
	# /usr/bin, the resultant /usr/sbin/etc-update isn't found when this
	# following line is encountered, despite both elements still appearing in
	# $PATH...
	LC_ALL='C' /usr/sbin/etc-update --quiet --preen
	find /etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete
done  # for pkg in ...
unset pkg

# Replaced by app-alternatives/awk ...
#LC_ALL='C' eselect awk set gawk || :

# Since we've rebuilt sys-devel/gcc, restore user-specified *FLAGS
#
cc_opt=''
for cc_opt in \
		CFLAGS CXXFLAGS \
		CGO_CFLAGS CGO_CXXFLAGS \
		FFLAGS FCFLAGS CGO_FFLAGS \
		LDFLAGS CGO_LDFLAGS FLFLAGS
do
	if [ -n "$( eval "echo \"\$_o_${cc_opt}\"" )" ]; then
		export "$( # <- Syntax
				eval echo "${cc_opt}=\"$( eval "echo \"\$_o_${cc_opt}\"" )\""
			)"
	fi
done
unset _o_CFLAGS _o_CXXFLAGS _o_CGO_CFLAGS _o_CGO_CXXFLAGS \
	_o_FFLAGS _o_FCFLAGS _o_CGO_FFLAGS _o_LDFLAGS _o_CGO_LDFLAGS _o_FLFLAGS

# Now we can build our ROOT environment...
#
echo
echo
echo ' * Creating build root ...'
echo

rm "${stage3_flags_file}"

# (ARCH should now be safe)
export ARCH="${arch}"
unset -v arch

# Since sys-apps/portage-3.0.67, portage commands are much more strict about
# handling of ROOT != '/' ...
#
repo_name='' repo_path=''
if command -v portageq >/dev/null 2>&1; then
	for repo_name in $( portageq get_repos '/' ); do
		if repo_path="$( portageq get_repo_path '/' "${repo_name}" )"; then
			mkdir -p "${service_root}/$( dirname "${repo_path}" )"
			ln -s "${repo_path}" "${service_root}/${repo_path}"
		else
			die "Could not get path for repo '${repo_name}' in root '/': ${?}"
		fi
	done
fi
unset repo_path repo_name

export ROOT="${service_root}"
export SYSROOT="${ROOT}"
export PORTAGE_CONFIGROOT="${SYSROOT}"

# Pre-load keys for new ROOT ...
get_portage_flags

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
# Update: 'nptl' USE flag now seems to have been removed from current ebuilds,
# but this can't do much harm...
#
export USE="nptl ${USE:+"${USE} "}${use_essential}"

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
# app-portage/elt-patches directly depends on app-arch/xz-utils, which
# indirectly depends on app-portage/elt-patches, so let's try to build the
# latter first in order to break this circular dependency.
#
pkg_initial='sys-apps/fakeroot sys-libs/libcap sys-process/audit sys-apps/util-linux app-shells/bash sys-apps/help2man dev-perl/Locale-gettext sys-libs/libxcrypt virtual/libcrypt app-editors/vim'
# See above for 'xml'...
pkg_initial_use='-compress-xz -lzma -nls -pam -perl -python -su -unicode minimal no-xz-utils xml'
if get_portage_flags USE | grep -Eq -- '(^|[^-])graphite'; then
	pkg_initial_use="${pkg_initial_use} graphite"
fi
if get_portage_flags USE | grep -Eq -- '(^|[^-])openmp'; then
	pkg_initial_use="${pkg_initial_use} openmp"
fi

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
		# We need to include sys-devel/gcc flags here, otherwise portage has
		# developed a tendancy to want to reinstall it even if present and not
		# directly depended upon...
		export USE="${pkg_initial_use}${use_essential:+" ${use_essential}"}${use_essential_gcc:+" ${use_essential_gcc}"}"
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
		else # [ "${ROOT:-"/"}" != '/' ]; then
			print "'python_targets' is '${python_targets:-}'," \
				"'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}'," \
				"'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"
			PYTHON_SINGLE_TARGET="${python_targets:+"${python_targets%%" "*}"}"
			PYTHON_TARGETS="${python_targets:-}"
			eval "$( # <- Syntax
					resolve_python_flags \
							"${USE:-}" \
							"${PYTHON_SINGLE_TARGET}" \
							"${PYTHON_TARGETS}"
				)"
			export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS
			print "'python_targets' is '${python_targets:-}'," \
				"'PYTHON_SINGLE_TARGET' is '${PYTHON_SINGLE_TARGET:-}'," \
				"'PYTHON_TARGETS' is '${PYTHON_TARGETS:-}'"
		fi

		if eval "$( # <- Syntax
				filter_toolchain_flags --env-only \
					-fgraphite -fgraphite-identity \
					-floop-nest-optimize -floop-parallelize-all
			)"
		then
			warn "Disabling graphite toolchain flags for stage3 build ..."
		fi
		if eval "$( filter_toolchain_flags --env-only -fopenmp )"; then
			warn "Disabling openmp toolchain flags for stage3 build ..."
		fi

		info="$( LC_ALL='C' emerge --info --verbose=y 2>&1 )"
		echo
		echo 'Resolved build variables for initial packages:'
		echo '---------------------------------------------'
		echo
		echo "${info}" | format 'CFLAGS'
		echo "${info}" | format 'LDFLAGS'
		echo
		echo "ROOT                = $( # <- Syntax
				echo "${info}" |
					grep -- '^ROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "SYSROOT             = $( # <- Syntax
				echo "${info}" |
					grep -- '^SYSROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
				echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo
		echo "${info}" | format 'FEATURES'
		echo "${info}" | format 'ACCEPT_LICENSE'
		echo "${info}" | format 'ACCEPT_KEYWORDS'
		echo "${info}" | format 'USE'
		echo "${info}" | format 'PYTHON_SINGLE_TARGET'
		echo "${info}" | format 'PYTHON_TARGETS'
		echo "MAKEOPTS            = $( # <- Syntax
				echo "${info}" |
					grep -- '^MAKEOPTS=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo
		echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
		echo
		echo "DISTDIR             = $( # <- Syntax
				echo "${info}" |
					grep -- '^DISTDIR=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo "PKGDIR              = $( # <- Syntax
				echo "${info}" |
					grep -- '^PKGDIR=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "PORTAGE_LOGDIR      = $( # <- Syntax
				echo "${info}" |
					grep -- '^PORTAGE_LOGDIR=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo
		unset info

		echo
		echo ' * Building initial packages ...'
		echo

		if ! get_portage_flags USE | grep -Eq -- '(^|[^-])openmp'; then
			warn "'openmp' USE flag is not set: app-crypt/libb2 may" \
				"encounter unresolvable dependency conflicts :("
		fi

		for pkg in ${pkg_initial:-}; do
			for ROOT in $(
						echo "${extra_root:-}" "${ROOT}" |
							xargs -rn 1 |
							sort -u
					)
			do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"

				done_python_deps=0

				# There's no way to set per-package mutually-exclusive USE
				# flags without the use of external files with current versions
				# of portage :(
				#
				if [ -f "${SYSROOT}"/etc/portage/package.use ]; then
					printf >>"${SYSROOT}"/etc/portage/package.use \
						'\n%s hostname\n%s -hostname' \
							'sys-apps/net-tools' 'sys-apps/coreutils'
				else
					mkdir -p "${SYSROOT}"/etc/portage/package.use
					printf >"${SYSROOT}"/etc/portage/package.use/hostname \
						'\n%s hostname\n%s -hostname' \
							'sys-apps/net-tools' 'sys-apps/coreutils'
				fi

				# First package in '${pkg_initial}' to have python deps...
				#
				# TODO: It'd be nice to have a had_deps() function here to
				#       remove this hard-coding...
				#
				#       (There is 'equery depgraph', but it is unreliable with
				#       unlimited depth)
				#
				if [ $(( done_python_deps )) -eq 0 ] && {
						[ "${pkg}" = 'dev-lang/python' ] ||
						[ "${pkg}" = 'sys-apps/help2man' ]
					}
				then
					(
						done_python_deps=1

						ROOT='/'
						SYSROOT="${ROOT}"
						PORTAGE_CONFIGROOT="${SYSROOT}"
						export ROOT SYSROOT PORTAGE_CONFIGROOT

						case "${ROOT:-}" in
							''|'/')
								pkgdir="$( LC_ALL='C' portageq pkgdir )"
								export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/stage3"
								unset pkgdir
								;;
							*)
								die "Unexpected value '${ROOT:-}' for ROOT" \
									"prior to buildling python prerequisites"
								;;
						esac

						eval "$( # <- Syntax
								resolve_python_flags \
										"${USE:-} ${use_essential} ${use_essential_gcc} python" \
										"${PYTHON_SINGLE_TARGET}" \
										"${PYTHON_TARGETS}"
							)"
						PERL_FEATURES=''  # Negation ('-ithreads') not allowed
						USE="$( # <- Syntax
								echo " ${USE} " |
									sed 's/ perl_features_ithreads / /g' |
									sed 's/^ // ; s/ $//'
							)"
						# Requirement patched out for >=sys-devel/binutils-2.41
						#if [ "${ARCH}" = 'arm64' ]; then
						#	USE="gold ${USE:-}"
						#fi
						export USE PERL_FEATURES \
							PYTHON_SINGLE_TARGET PYTHON_TARGETS

						info="$( LC_ALL='C' emerge --info --verbose=y 2>&1 )"
						echo
						echo 'Resolved build variables for python prerequisites:'
						echo '-------------------------------------------------'
						echo
						echo "${info}" | format 'CFLAGS'
						echo "${info}" | format 'LDFLAGS'
						echo
						echo "ROOT                = $( # <- Syntax
								echo "${info}" |
									grep -- '^ROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo "SYSROOT             = $( # <- Syntax
								echo "${info}" |
									grep -- '^SYSROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
								echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo
						echo "${info}" | format 'ACCEPT_LICENSE'
						echo "${info}" | format 'ACCEPT_KEYWORDS'
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_SINGLE_TARGET'
						echo "${info}" | format 'PYTHON_TARGETS'
						echo "MAKEOPTS            = $( # <- Syntax
								echo "${info}" |
									grep -- '^MAKEOPTS=' |
									cut -d'=' -f 2- |
									uniq
							)"
						echo
						echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
						echo
						echo "DISTDIR             = $( # <- Syntax
								echo "${info}" |
									grep -- '^DISTDIR=' |
									cut -d'=' -f 2- |
									uniq
							)"
						echo "PKGDIR              = $( # <- Syntax
								echo "${info}" |
									grep -- '^PKGDIR=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo "PORTAGE_LOGDIR      = $( # <- Syntax
								echo "${info}" |
									grep -- '^PORTAGE_LOGDIR=' |
									cut -d'=' -f 2- |
									uniq
							)"
						echo
						unset info

						# Specifically python-3.12.6 is throwing:
						#
						#   ImportError: cannot import name 'HeaderWriteError'
						#   from 'email.errors'
						#
						# ... when built below, but only if PORTAGE_ELOG_SYSTEM
						# includes 'mail_summary' - without (or even with just
						# 'mail'), the process completes successfully as
						# expected.
						#
						PORTAGE_ELOG_SYSTEM='echo save'
						export PORTAGE_ELOG_SYSTEM

						# ROOT == '/'
						echo
						echo " * Building python prerequisites into ROOT" \
							"'${ROOT:-"/"}' ..."
						echo
						# FIXME:  --emptytree is needed if the upstream stage3
						#         image is built against a different python
						#         version to what we're now trying to build,
						#         but use of this option is fragile when binary
						#         packages don't already exist.
						# TODO:   Perhaps we need to pre-build all dependents
						#         as binary packages in a more controlled
						#         environment first?
						#
						# Include sys-devel/gcc and dev-libs/isl here in case
						# graphite USE flags are enabled...
						#
						# Update: Despite valid binary packages existing,
						#         portage is now insisting on rebuliding
						#         app-crypt/libb2, which then fails because gcc
						#         reports that libisl isn't present and so
						#         graphie flags are invalid.  Except that
						#         portage thinks that it is present in both
						#         roots, and the USE flags match the CFLAGS
						#         requirements.  This makes no sense :(
						#
						# At this point in time (27/11/2024, portage 3.0.66.1,
						# 9388c25) there doesn't seem to be any way this can
						# work - even with fresh binaries for every possible
						# USE flag permutation for app-crypt/libb2, this
						# package building successfully outside of the
						# bootstrap process, every other package compiling
						# correctly (although most *are* from binpkgs),
						# ensuring that sys-devel/gcc and sys-devel/isl are
						# correctly installed, and filtering graphite flags,
						# this process still aborts with portage trying to
						# build a new app-crypt/libb2 (which is weird) and then
						# this failing saying that isl *isn't* available and
						# graphite flags are present... which is weirder.  So
						# all I can think for now is to revert the hack needed
						# for differing dev-lang/python versions and hope that
						# by the time it's needed again, this problem has been
						# resolved :(
						#
						# This process now seems to be pulling-in
						# dev-libs/libxml2[-python] which has flag-conflicts
						# with dev-libs/libxslt which requires
						# dev-libs/libxml2[python] - let's see whether adding
						# both resolves this issue...
						#
						do_emerge --build-defaults --emptytree \
							app-crypt/libb2 \
							app-crypt/libmd \
							dev-libs/isl \
							dev-libs/libbsd \
							dev-libs/libxml2 \
							dev-libs/libxslt \
							dev-python/hatchling \
							dev-python/setuptools \
							sys-devel/gcc # || :

						validate_libgcc
						validate_python_installation "python pre-requisites"
					)

					# Install same dependencies again within our build ROOT...
					#
					(
						SYSROOT="/"
						PORTAGE_CONFIGROOT="${SYSROOT}"
						export SYSROOT PORTAGE_CONFIGROOT

						case "${ROOT:-}" in
							''|'/')
								die "Unexpected value '${ROOT:-}' for ROOT" \
									"prior to buildling python prerequisites"
								;;
							*)
								:
								;;
						esac

						eval "$( # <- Syntax
								resolve_python_flags \
										"${USE:-} ${use_essential} ${use_essential_gcc}" \
										"${PYTHON_SINGLE_TARGET}" \
										"${PYTHON_TARGETS}"
							)"
						PERL_FEATURES=''  # Negation ('-ithreads') not allowed
						USE="$( # <- Syntax
								# Remove certain USE flags to prevent
								# unnecessary rebuilds...
								echo " ${USE} " |
									sed 's/ perl_features_ithreads / /g' |
									sed 's/^ // ; s/ $//'
							)"
						# Requirement patched out for >=sys-devel/binutils-2.41
						#if [ "${ARCH}" = 'arm64' ]; then
						#	USE="gold ${USE:-}"
						#fi
						export USE PERL_FEATURES PYTHON_SINGLE_TARGET \
							PYTHON_TARGETS

						# ROOT == '/build'
						echo
						echo " * Building python prerequisites into ROOT" \
							"'${ROOT}' ..."
						echo

						# Include sys-devel/gcc and dev-libs/isl here in case
						# graphite USE flags are enabled...
						#
						# Additionally, (at least) app-arch/libarchive,
						# app-crypt/libb2, sys-devel/gettext and
						# sys-libs/libxcrypt depend on 'libgomp', but aren't
						# rebuilt when 'openmp' is removed from sys-devel/gcc.
						#
						# With '--emptytree', portage is trying to install
						# sys-devel/gcc to "${ROOT}" with the appropriate
						# flags, but first to re-merge it into '/' with empty
						# flags, which then breaks later builds with graphite
						# CFLAGS :(
						#
						# N.B. Even if sys-devel/gcc is built with
						#      USE='graphite' in a ROOT other than '/', the
						#      compiler used to build further packages will
						#      still be the ROOT='/' one!
						#
						(
							eval "$( # <- Syntax
									filter_toolchain_flags --env-only \
										-fgraphite \
										-fgraphite-identity \
										-floop-nest-optimize \
										-floop-parallelize-all \
										-fopenmp
								)" || :
							do_emerge --build-defaults \
								dev-libs/isl \
								sys-devel/gcc
						)

						validate_libgcc

						do_emerge --build-defaults \
							app-arch/libarchive \
							app-crypt/libb2 \
							app-crypt/libmd \
							dev-libs/libbsd \
							dev-python/hatchling \
							dev-python/setuptools \
							sys-devel/gettext \
							sys-libs/libxcrypt # || :

						validate_python_installation "python pre-requisites"
					)
				elif [ "${pkg}" = 'dev-perl/Locale-gettext' ]; then  # [ "${pkg}" != 'sys-apps/help2man' ]
					(
						case "${ROOT:-}" in
							''|'/')
								die "Unexpected value '${ROOT:-}' for ROOT" \
									"prior to buildling perl prerequisites"
								;;
							*)
								:
								;;
						esac

						echo
						echo " * Building perl (without ithreads) into ROOT" \
							"'${ROOT:-"/"}' for package '${pkg}' ..."
						echo

						# Using --emptytree below causes portage to
						# unnecessarily rebuild existing root-dependencies
						# without any USE flags set, breaking the process if
						# graphite-specific CFLAGS are active.  So far we've
						# been trying to ensure that the correct USE flags are
						# present to suit the user's CFLAGS, but instead if
						# the approach below doesn't work and --emptytree is
						# needed (which is due to portage limitations in the
						# first place), then we'll have to filter the user's
						# CFLAGS simply in order to proceed >:(
						#
						# shellcheck disable=SC2046,SC2086
							PERL_FEATURES='' \
							USE="$( # <- Syntax
									echo " ${USE} ${use_essential}" \
											"${use_essential_gcc}" \
											"-perl_features_ithreads " |
										sed 's/ perl_features_ithreads / /g' |
										xargs -rn 1 |
										sort |
										uniq |
										xargs -r
								)" \
						do_emerge \
								--build-defaults \
							dev-lang/perl $(
									grep -lw 'perl_features_ithreads' \
											"${ROOT:-}"/var/db/pkg/*/*/IUSE |
										rev |
										cut -d'/' -f 2-3 |
										rev |
										sed 's/^/>=/' |
										xargs -r
								) \
							"${pkg}" # || :
								#--emptytree \
					)
				elif [ "${pkg}" = 'sys-apps/util-linux' ]; then  # [ "${pkg}" != 'dev-perl/Locale-gettext' ] && [ "${pkg}" != 'sys-apps/help2man' ]

					# It's unclear whether we hit a one-time problem with a bad
					# package or a new build issue, but we had a circular
					# dependency when building sys-apps/util-linux of
					# libidn2 -> libunistring -> glibc -> libidn2
					echo
					echo " * Building initial package '${pkg:-}' into ROOT" \
						"'${ROOT:-"/"}'" \
						"${pkg_exclude:+"excluding packages with '${pkg_exclude}' "}..."
					echo

					case "${ROOT:-}" in
						''|'/')
							die "Unexpected value '${ROOT:-}' for ROOT" \
								"prior to buildling initial package '${pkg:-}'"
							;;
						*)
							:
							;;
					esac

					# shellcheck disable=SC2086
					if ! do_emerge --initial-defaults "${pkg}" ${pkg_exclude:-}
					then
						pkg_dep=''
						for pkg_dep in sys-libs/glibc dev-libs/libunistring \
								net-dns/libidn2
						do
							echo
							echo " * Building dependencies for initial" \
								"package '${pkg_dep:-}' for ROOT '${ROOT:-"/"}'"
							echo

							# shellcheck disable=SC2086
							do_emerge --initial-defaults --onlydeps \
								--with-bdeps=y "${pkg_dep}"

							echo
							echo " * Rebuilding initial package" \
								"'${pkg_dep:-}' without merging for ROOT" \
								"'${ROOT:-"/"}'"
							echo

							do_emerge --initial-defaults --buildpkgonly \
								"${pkg_dep}"
						done
						unset pkg_dep

						echo
						echo " * Building initial package '${pkg:-}' into" \
							"ROOT '${ROOT:-"/"}'" \
							"${pkg_exclude:+"excluding packages with '${pkg_exclude}' "}..."
						echo
						do_emerge --initial-defaults "${pkg}" ${pkg_exclude:-}
					fi
				else  # [ "${pkg}" != 'sys-libs/glibc' ] && [ "${pkg}" != 'dev-perl/Locale-gettext' ] && [ "${pkg}" != 'sys-apps/help2man' ]

					echo
					echo " * Building initial package '${pkg:-}' into ROOT" \
						"'${ROOT:-"/"}'" \
						"${pkg_exclude:+"excluding packages with '${pkg_exclude}' "}..."
					echo

					case "${ROOT:-}" in
						''|'/')
							die "Unexpected value '${ROOT:-}' for ROOT" \
								"prior to buildling initial package '${pkg:-}'"
							;;
						*)
							:
							;;
					esac

					# shellcheck disable=SC2086
					do_emerge --initial-defaults "${pkg}" ${pkg_exclude:-} # || :
				fi  # [ "${pkg}" = 'sys-apps/help2man' ]

				# For some reason, after dealing with /usr/sbin being a symlink
				# to /usr/bin, the resultant /usr/sbin/etc-update isn't found
				# when this following line is encountered, despite both
				# elements still appearing in $PATH...
				LC_ALL='C' /usr/sbin/etc-update --quiet --preen
				find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

				if echo " ${pkg} " | grep -q -- ' app-shells/bash '; then
					fix_sh_symlink "${ROOT}" 'pre-deploy'
				fi

				if [ -f "${SYSROOT}"/etc/portage/package.use ]; then
					sed -e '/hostname$/ d' \
						-i "${SYSROOT}"/etc/portage/package.use
				else
					[ -e "${SYSROOT}"/etc/portage/package.use/hostname ] &&
						rm "${SYSROOT}"/etc/portage/package.use/hostname
				fi
			done  # for ROOT in $(...)
		done  # for pkg in ${pkg_initial:-}
		unset pkg
	)
fi  # [ -n "${pkg_initial:-}" ]

echo
echo ' * Building @system packages ...'
echo

(
	#set -x

	# sys-apps/shadow is needed for /sbin/nologin;
	#
	# dev-libs/icu is needed for circular dependencies on icu -> python -> ...
	#	sqlite -> icu;
	#
	# libarchive is a frequent dependency, and so quicker to pull-in here
	#
	pkg_system="@system sys-devel/gcc sys-apps/shadow dev-libs/icu app-arch/libarchive ${pkg_initial:-} ${pkg_exclude:-}"

	USE="${USE:+"${USE} "}${use_essential_gcc}"
	# Update: 'nptl' USE flag now seems to have been removed from current
	# ebuilds, but this can't do much harm...
	if
		  echo " ${USE} " | grep -q -- ' -nptl ' ||
		! echo " ${USE} " | grep -q -- ' nptl '
	then
		print "USE flag 'nptl' missing from or disabled in \$USE"
		USE="nptl${USE:+" $( echo "${USE}" | sed 's/ \?-\?nptl \?/ /' ) "}"
		print "USE is now '${USE}'"
	fi
	export USE

	if eval "$( # <- Syntax
			filter_toolchain_flags --env-only \
				-fgraphite -fgraphite-identity \
				-floop-nest-optimize -floop-parallelize-all
		)"
	then
		warn "Disabling graphite toolchain flags for system build ..."
	fi
	if eval "$( filter_toolchain_flags --env-only -fopenmp )"; then
		warn "Disabling openmp toolchain flags for system build ..."
	fi

	for ROOT in $(
				echo '/' "${extra_root:-}" "${ROOT}" |
					xargs -rn 1 |
					sort -u
			)
	do
		export ROOT
		export SYSROOT="${ROOT}"
		export PORTAGE_CONFIGROOT="${SYSROOT}"

		case "${ROOT:-}" in
			''|'/')
				pkgdir="$( LC_ALL='C' portageq pkgdir )"
				export PKGDIR="${PKGDIR:-"${pkgdir:-"/tmp"}"}/stages/system"
				unset pkgdir
				;;
			*)
				:
				;;
		esac

		eval "${format_fn_code}"

		info="$( LC_ALL='C' emerge --info --verbose=y 2>&1 )"
		echo
		echo "Resolved build variables for @system in ROOT '${ROOT}':"
		echo '------------------------------------'
		echo
		echo "${info}" | format 'CFLAGS'
		echo "${info}" | format 'LDFLAGS'
		echo
		echo "ROOT                = $( # <- Syntax
				echo "${info}" |
					grep -- '^ROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "SYSROOT             = $( # <- Syntax
				echo "${info}" |
					grep -- '^SYSROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
				echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo
		echo "${info}" | format 'ACCEPT_LICENSE'
		echo "${info}" | format 'ACCEPT_KEYWORDS'
		echo "${info}" | format 'USE'
		echo "${info}" | format 'PYTHON_SINGLE_TARGET'
		echo "${info}" | format 'PYTHON_TARGETS'
		echo "MAKEOPTS            = $( # <- Syntax
				echo "${info}" |
					grep -- '^MAKEOPTS=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo
		echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
		echo
		echo "DISTDIR             = $( # <- Syntax
				echo "${info}" |
					grep -- '^DISTDIR=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo "PKGDIR              = $( # <- Syntax
				echo "${info}" |
					grep -- '^PKGDIR=' |
					cut -d'=' -f 2- |
					uniq |
					head -n 1
			)"
		echo "PORTAGE_LOGDIR      = $( # <- Syntax
				echo "${info}" |
					grep -- '^PORTAGE_LOGDIR=' |
					cut -d'=' -f 2- |
					uniq
			)"
		echo
		unset info

		echo
		echo " * Ensuring we have sys-apps/baselayout ..."
		echo
		[ ! -f "${ROOT%"/"}/var/lock" ] || rm "${ROOT%"/"}/var/lock"
		#	debug=1 \
		do_emerge --system-defaults sys-apps/baselayout

		# portage is tripping over sys-devel/gcc[openmp] :(
		#
		echo
		echo " * Ensuring we have sys-devel/gcc ..."
		echo
		#	debug=1 \
			USE="openmp${USE:+" ${USE} "}" \
		do_emerge --system-defaults sys-devel/gcc
		validate_libgcc

		#	debug=1 \
			USE="openmp${USE:+" ${USE} "}" \
		do_emerge --system-defaults app-arch/libarchive \
			app-crypt/libb2 sys-devel/gettext sys-libs/libxcrypt

		# ... likewise sys-apps/net-tools[hostname] (for which the recommended
		# fix is sys-apps/coreutils[hostname]?)
		#
		echo
		echo " * Ensuring we have sys-apps/coreutils ..."
		echo
		#	debug=1 \
			USE="${USE:+"${USE} "}-hostname" \
		do_emerge --system-defaults sys-apps/coreutils

		echo
		echo " * Ensuring we have sys-apps/net-tools ..."
		echo
		#	debug=1 \
			USE="hostname${USE:+" ${USE}"}" \
		do_emerge --system-defaults sys-apps/net-tools

		# Try to prevent preserved rebuilds being required...
		#
		# -gmp blocks gnutls...
		#
		echo
		echo " * Trying to avoid preserved libraries ..."
		echo
		# shellcheck disable=SC2046,SC2086
		#	debug=1 \
			USE="asm cxx gmp minimal openssl perl_features_ithreads${USE:+" ${USE}"} -ensurepip -gdbm -ncurses -readline -sqlite -zstd" \
			PERL_FEATURES="ithreads" \
		do_emerge --once-defaults $(
				grep -lw 'perl_features_ithreads' \
						"${ROOT:-}"/var/db/pkg/*/*/IUSE |
					rev |
					cut -d'/' -f 2-3 |
					rev |
					sed 's/^/>=/' |
					xargs -r
			) \
			net-libs/gnutls \
			dev-libs/nettle \
			dev-lang/python \
			dev-lang/perl \
			sys-libs/gdbm \

		validate_python_installation "preserved-library avoidance"

		root_use='' arm64_use=''
		if [ -z "${ROOT:-}" ] || [ "${ROOT}" = '/' ]; then
			root_use='-acl compat -bzip2 -e2fsprogs -expat -iconv -lzma -lzo -nettle -xattr -zstd'
		fi
		# These packages seem to include sys-process/procps, which is breaking
		# due to (forced) USE='unicode' requiring USE='ncurses'...
		#
		[ "${ARCH:-}" = 'arm64' ] && arm64_use='ncurses'

		echo
		echo " * Ensuring we have system packages ..."
		echo
		# For some reason, portage is selecting dropbear to satisfy
		# virtual/ssh?
		#
		# FIXME: Forcing 'openmp'?
		#
		# shellcheck disable=SC2086
		#	debug=1 \
			USE="cxx gmp openmp openssl${arm64_use:+" ${arm64_use}"}${root_use:+" ${root_use}"}${USE:+" ${USE}"} -extra-filters -nettle -nls" \
		do_emerge \
				--exclude='dev-libs/libtomcrypt' \
				--exclude='net-misc/dropbear' \
				--exclude='sys-apps/net-tools' \
				--system-defaults \
			${pkg_system} dev-libs/nettle net-libs/gnutls dev-lang/python \
				dev-libs/libxml2 sys-devel/gettext \
				app-arch/libarchive app-crypt/libb2 sys-devel/gettext \
				sys-libs/libxcrypt
		unset root_use

		validate_libgcc
		validate_python_installation "system packages"

		echo
		echo " * Rebuilding any preserved dependencies ..."
		echo
		# We're hitting errors here that dev-libs/nettle[gmp] is required...
		#	debug=1 \
			USE="asm openssl${USE:+" ${USE}"}-ensurepip -gdbm -ncurses -readline -sqlite -zstd" \
		do_emerge --preserved-defaults '@preserved-rebuild'

		validate_python_installation "preserved dependencies"
	done  # for ROOT in $(...)
)  # @system

# For some reason, after dealing with /usr/sbin being a symlink to /usr/bin,
# the resultant /usr/sbin/etc-update isn't found when this following line is
# encountered, despite both elements still appearing in $PATH...
LC_ALL='C' /usr/sbin/etc-update --quiet --preen
find "${ROOT}"/etc/ -type f -regex '.*\._\(cfg\|mrg\)[0-9]+_.*' -delete

# Ensure we have a valid /bin/sh symlink in our ROOT...
#
fix_sh_symlink "${ROOT}" '@system'

# ... and fix the default bash prompt setup w.r.t. 'screen' window names!
#
# N.B. Compatibility-only: actual configuration is now in /etc/bash/bashrc.d/
#
if [ -s /etc/bash/bashrc.patch ]; then
	if [ -s "${ROOT}"/etc/bash/bashrc ]; then
		if grep -q -- 'PS1=' "${ROOT}"/etc/bash/bashrc; then
			if ! command -v patch >/dev/null 2>&1; then
				warn "@system build has not installed package" \
					"'sys-devel/patch'"
			else
				#pushd >/dev/null "${ROOT}"/etc/bash/  # bash only
				src_cwd="${PWD}"
				cd "${ROOT}"/etc/bash/ ||
					die "chdir() to '${ROOT%"/"}/etc/bash' failed: ${?}"

				echo ' * Patching /etc/bash/bashrc ...'
				patch -p1 -r - -s </etc/bash/bashrc.patch ||
					die "Applying patch to bashrc failed: ${?}"

				#popd >/dev/null  # bash only
				cd "${src_cwd}" ||
					die "chdir() to '${src_cwd}' failed: ${?}"
				unset src_cwd
			fi
		fi
	else
		warn "'${ROOT%"/"}/etc/bash/bashrc' does not exist or is empty"
	fi

	rm /etc/bash/bashrc.patch
fi

echo
echo ' * Cleaning up ...'
echo

# Save failed build logs...
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

# Cleanup any failed bulids/temporary files...
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

# Check for ROOT news...
#if LC_ALL='C' eselect --colour=yes news read new |
#		grep -Fv -- 'No news is good news.'
#then
#	printf '\n---\n\n'
#fi

# At this point, we should have a fully-built @system!

export EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS:+"${EMERGE_DEFAULT_OPTS} "} --with-bdeps=y --with-bdeps-auto=y"

info="$( LC_ALL='C' emerge --info --verbose=y 2>&1 )"
echo
echo 'Resolved build variables after init stage:'
echo '-----------------------------------------'
echo
echo "${info}" | format 'CFLAGS'
echo "${info}" | format 'LDFLAGS'
echo
echo "ROOT                = $( # <- Syntax
		echo "${info}" |
			grep -- '^ROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "SYSROOT             = $( # <- Syntax
		echo "${info}" |
			grep -- '^SYSROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
		echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo
echo "${info}" | format 'ACCEPT_LICENSE'
echo "${info}" | format 'ACCEPT_KEYWORDS'
echo "${info}" | format 'USE'
echo "${info}" | format 'PYTHON_SINGLE_TARGET'
echo "${info}" | format 'PYTHON_TARGETS'
echo "MAKEOPTS            = $( # <- Syntax
		echo "${info}" |
			grep -- '^MAKEOPTS=' |
			cut -d'=' -f 2- |
			uniq
	)"
echo
echo "${info}" | format 'EMERGE_DEFAULT_OPTS'
echo
echo "DISTDIR             = $( # <- Syntax
		echo "${info}" |
			grep -- '^DISTDIR=' |
			cut -d'=' -f 2- |
			uniq
	)"
echo "PKGDIR              = $( # <- Syntax
		echo "${info}" |
			grep -- '^PKGDIR=' |
			cut -d'=' -f 2- |
			uniq |
			head -n 1
	)"
echo "PORTAGE_LOGDIR      = $( # <- Syntax
		echo "${info}" |
			grep -- '^PORTAGE_LOGDIR=' |
			cut -d'=' -f 2- |
			uniq
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
FEATURES="$( # <- Syntax
		filter_features_flags 'clean' 'fail-clean'
	) -clean -fail-clean"
export FEATURES

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
#		cat "${ROOT}${environment_file}"
#	)"

case "${1:-}" in
	'')
		echo
		echo " * Building default '${package}' package ..."
		echo

		(
			for ROOT in $(
						echo "${extra_root:-}" "${ROOT}" |
							xargs -rn 1 |
							sort -u
					)
			do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"
				do_emerge --once-defaults "${package}" || rc=${?}
				if [ $(( rc )) -ne 0 ]; then
					echo "ERROR: Default package build for root '${ROOT}':" \
						"${rc}"
					break
				fi
			done
			exit ${rc}  # from subshell
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
		echo " * Building requested '$( # <- Syntax
				printf '%s' "${*}" |
					sed 's/--[^ ]\+ \?//g'
			)' packages ${post_pkgs:+"(with post-package list) "}..."
		echo

		(
			for ROOT in $(
						echo "${extra_root:-}" "${ROOT}" |
							xargs -rn 1 |
							sort -u
					)
			do
				export ROOT
				export SYSROOT="${ROOT}"
				export PORTAGE_CONFIGROOT="${SYSROOT}"
				# shellcheck disable=SC2086
				do_emerge --multi-defaults "${@}" || rc=${?}
				if [ $(( rc )) -ne 0 ]; then
					echo "ERROR: Package build for root '${ROOT}': ${rc}"
					break
				fi
			done
			exit ${rc}  # from subshell
		) || rc=${?}

		check ${rc} "${@}"

		if [ -z "${post_pkgs:-}" ]; then
			exit ${rc}
		fi


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

		info="$( LC_ALL='C' emerge --info --verbose=y 2>&1 )"

		echo
		echo 'Resolved build variables for post-installation packages:'
		echo '-------------------------------------------------------'
		echo
		echo "${info}" | format 'CFLAGS'
		echo "${info}" | format 'LDFLAGS'
		echo
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
			for arg in ${post_pkgs}; do
				case "${arg}" in
					-*)	continue ;;
					*)
						echo
						echo " * Building single post-package '${arg}'" \
							"from '${post_pkgs}' ..."
						echo
						(
							for ROOT in $(
										echo "${extra_root:-}" "${ROOT}" |
											xargs -rn 1 |
											sort -u
									)
							do
								export ROOT
								export SYSROOT="${ROOT}"
								export PORTAGE_CONFIGROOT="${SYSROOT}"
								# shellcheck disable=SC2086
								do_emerge --defaults ${parallel} \
									--usepkg=y ${flags:-} ${arg} || rc=${?}
								if [ $(( rc )) -ne 0 ]; then
									echo "ERROR: Single post-package build" \
										"for root '${ROOT}': ${rc}"
									break
								fi
							done
							exit ${rc}  # from subshell
						) || rc=${?}
						;;
				esac
			done  # for arg in ${post_pkgs}

		else # ! grep -Eq -- ' --single(-post)? ' <<<" ${EMERGE_OPTS} "
			(
				for ROOT in $(
							echo "${extra_root:-}" "${ROOT}" |
								xargs -rn 1 |
								sort -u
						)
				do
					export ROOT
					export SYSROOT="${ROOT}"
					export PORTAGE_CONFIGROOT="${SYSROOT}"
					echo
					echo " * Building temporary post-packages" \
						"'app-crypt/libb2 sys-apps/coreutils sys-devel/gcc" \
						"sys-devel/gettext sys-libs/glibc' to ROOT" \
						"'${ROOT:-"/"}' ..."
					echo

					# If we don't include 'openmp' in the USE flags here, we
					# hit a hard dependencies failure when performing the
					# ROOT='/build' Stage 1b cleanup below :(
					#
					# shellcheck disable=SC2086
					#	USE="compile-locales minimal multiarch ${use_essential_gcc} -gmp -openmp" \
					# shellcheck disable=SC2086
						USE="compile-locales minimal multiarch openmp ${use_essential_gcc} -gmp" \
					do_emerge --defaults ${parallel} --usepkg=y \
							app-arch/libarchive \
							app-crypt/libb2 \
							sys-apps/coreutils \
							sys-devel/gcc \
							sys-devel/gettext \
							sys-libs/glibc \
							sys-libs/libxcrypt ||
						rc=${?}
					if [ $(( rc )) -ne 0 ]; then
						echo "ERROR: Temporary post-packages build for" \
							"root '${ROOT}': ${rc}"
						break
					fi
					validate_libgcc

					echo
					echo " * Building post-packages '${post_pkgs}' to ROOT '${ROOT:-"/"}' ..."
					echo

					# shellcheck disable=SC2086
						USE='asm compile-locales gmp minimal multiarch native-extensions ssl ssp xattr' \
					do_emerge --defaults ${parallel} --usepkg=y \
						${post_pkgs} || rc=${?}

					if [ $(( rc )) -ne 0 ]; then
						echo "ERROR: Post-packages build for root" \
							"'${ROOT}': ${rc}"
						break
					fi
				done
				exit ${rc}  # from subshell
			) || rc=${?}
		fi

		check ${rc} "${@}"

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
		if [ $(( $(
					echo "${ROOT_USE}" |
						xargs -rn 1 |
						grep -c \
							-e 'python_single_target_' \
							-e 'python_targets_'
				) )) -gt 2 ]
		then
			target='' targetpkg='' targets='' remove=''
			target="$( # <- Syntax
					echo "${ROOT_USE}" |
						xargs -rn 1 |
						grep -- 'python_single_target_python' |
						sed 's/python_single_target_//' |
						sort |
						tail -n 1
				)"
			# python3_13 -> dev-lang/python-3.13
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
					for ROOT in $(
								echo '/' "${ROOT}" |
									xargs -rn 1 |
									sort -u |
									xargs -r
							)
					do
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
									sort |
									uniq |
									xargs -r
							)"
						eval "$( # <- Syntax
								resolve_python_flags \
									"${USE}" \
									"${PYTHON_SINGLE_TARGET}" \
									"${PYTHON_TARGETS}"
							)"
						pkgs="${pkgs:-} $( # <- Syntax
								find "${ROOT%"/"}/var/db/pkg/dev-python/" \
										-mindepth 1 \
										-maxdepth 1 \
										-type d \
										-print |
									sed 's|^.*/var/db/pkg/|>=| ; s|/$||'
							)"

						export USE PYTHON_SINGLE_TARGET PYTHON_TARGETS

						info="$( # <- Syntax
									LC_ALL='C' \
									SYSROOT="${ROOT}" \
									PORTAGE_CONFIGROOT="${ROOT}" \
								emerge --info --verbose=y 2>&1
							)"
						echo
						echo "Resolved build variables for python cleanup stage 1 in ROOT '${ROOT}':"
						echo '---------------------------------------------------'
						echo
						echo "${info}" | format 'CFLAGS'
						echo "${info}" | format 'LDFLAGS'
						echo
						echo "ROOT                = $( # <- Syntax
								echo "${info}" |
									grep -- '^ROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo "SYSROOT             = $( # <- Syntax
								echo "${info}" |
									grep -- '^SYSROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo "PORTAGE_CONFIGROOT  = $( # <- Syntax
								echo "${info}" | grep -- '^PORTAGE_CONFIGROOT=' |
									cut -d'=' -f 2- |
									uniq |
									head -n 1
							)"
						echo
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_SINGLE_TARGET'
						echo "${info}" | format 'PYTHON_TARGETS'
						print "pkgs: '${pkgs}'"

						# shellcheck disable=SC2015,SC2086
							USE="$( # <- Syntax
									echo " ${USE} " |
										sed -r \
											-e 's/ python_targets_[^ ]+ / /g' \
											-e 's/ python_single_target_([^ ]+) / python_single_target_\1 python_targets_\1 /g' \
											-e 's/ \+/ /g ; s/^ \+// ; s/ \+$//'
								) openmp" \
							PYTHON_TARGETS="${PYTHON_SINGLE_TARGET}" \
						do_emerge --rebuild-defaults ${pkgs} ||
							rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							echo "ERROR: Stage 1b cleanup for root" \
								"'${ROOT}': ${rc}"
							break
						fi

						export USE="${USE} -tmpfiles"
						export PYTHON_TARGETS="${BUILD_PYTHON_TARGETS}"

						info="$( # <- Syntax
									LC_ALL='C' \
									SYSROOT="${ROOT}" \
									PORTAGE_CONFIGROOT="${ROOT}" \
								emerge --info --verbose=y 2>&1
							)"
						echo
						echo "Resolved build variables for python cleanup stage 2 in ROOT '${ROOT}':"
						echo '---------------------------------------------------'
						echo
						echo "${info}" | format 'CFLAGS'
						echo "${info}" | format 'LDFLAGS'
						echo
						echo "${info}" | format 'USE'
						echo "${info}" | format 'PYTHON_TARGETS'

						# If we clear 'pkgs' then we hit all manner of
						# dependency problems - even though the roots are
						# independent, and identifying the packages built
						# against old python versions should be
						# exhaustive...
						#
						#pkgs=''
						for arg in ${USE}; do
							print "Checking for '${arg}' in '${remove}' ..."

							if echo "${remove}" | grep -qw -- "${arg}"; then
								pkgs="${pkgs:-} $( # <- Syntax
										find "${ROOT%"/"}/var/db/pkg/" \
												-mindepth 3 \
												-maxdepth 3 \
												-type f \
												-name 'IUSE' \
												-print0 |
											grep -Flw -- "${arg}" |
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
							fi
						done
						pkgs="${pkgs:-} $( # <- Syntax
								find "${ROOT%"/"}/var/db/pkg/dev-python/" \
										-mindepth 1 \
										-maxdepth 1 \
										-type d \
										-print |
									sed 's|^.*/var/db/pkg/|>=| ; s|/$||'
							)"
						if
									ROOT='/' \
									SYSROOT='/' \
									PORTAGE_CONFIGROOT='/' \
								portageq get_repos '/' |
									grep -Fq -- 'srcshelton'
						then
							pkgs="${pkgs:-} virtual/tmpfiles::srcshelton"
						fi
						print "pkgs: '${pkgs}'"

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
								) )) -gt 1 ]
						then
							do_emerge --depclean-defaults "<${targetpkg}" ||
								rc=${?}
							if [ $(( rc )) -ne 0 ]; then
								echo "ERROR: Stage 2 package depclean: ${rc}"
								break
							fi
						fi

						# Running 'do_emerge --depclean-defaults' now complains
						# that app-crypt/libmd is a dependency of
						# net-misc/openssh, for ROOT '/build' - we could ignore
						# this, try to hide the message, or run the above
						# command twice...
						#
						if [ "${ROOT:-"/"}" = "${service_root:-}" ]; then
							do_emerge --depclean-defaults net-misc/openssh \
								app-crypt/libmd
						fi

						do_emerge --depclean-defaults || rc=${?}
						if [ $(( rc )) -ne 0 ]; then
							echo "ERROR: Stage 2 world depclean: ${rc}"
							break
						fi
					done  # for ROOT in $(...)

					exit ${rc}  # from subshell
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
			sed 's/^/>=/' |
			grep -Fv -e 'dev-python/pypy3' -e 'dev-python/gentoo-common'
		)
		if [ -n "${*:-}" ]; then
			do_emerge --depclean-defaults "${@:-}" || :
		fi

		validate_python_installation "final cleanup"

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

		# Try to remove any temporary copy of libgcc_s.so.1 which we might have
		# deployed to prevent breakages...
		#
		libgcc_root=''
		for libgcc_root in $(
					echo "${extra_root:-}" "${ROOT:-"/"}" "${SYSROOT:-}" \
							"${service_root:-}" |
						xargs -rn 1 |
						sort -u
				)
		do
			find "${libgcc_root%"/"}/usr/$(get_libdir)"/ \
				-name 'libgcc_s.so*' \
				-delete
		done
		unset libgcc_dir

		exit ${rc}
	;;
esac

#[ -n "${trace:-}" ] && set +o xtrace

# vi: set colorcolumn=80 foldmarker=()\ {,}\ \ #\  foldmethod=marker syntax=sh sw=4 ts=4:
