
# Set docker image names...
#
env_name="gentoo-env"
stage3_name="gentoo-stage3"
init_name="gentoo-init"
base_name="gentoo-base"
build_name="gentoo-build"

# Default environment-variable filter
#
environment_filter='^(declare -x|export) (EDITOR|GENTOO_PROFILE|HOME|HOSTNAME|LESS(OPEN)?LS_COLORS|(MAN)?PAGER|(OLD)?PWD|PATH|(|SYS|PORTAGE_CONFIG)ROOT|SHLVL|TERM)='

# Colour options!
#
reset=$'\e[0m'
bold=$'\e[1m'
red=$'\e[31m'
green=$'\e[32m'
blue=$'\e[34m'

# Export portage job-control variables...
#
export JOBS='4'
export MAXLOAD='4.0'
