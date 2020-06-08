
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

# Define essential USE flags
#
# dev-libs/openssl: asm tls-heartbeat zlib
# sys-apps/busybox: mdev
use_essential="asm mdev tls-heartbeat zlib"

# Colour options!
#
bold=$'\e[1m'
red=$'\e[31m'
green=$'\e[32m'
blue=$'\e[34m'
# Place 'reset' last to prevent coloured xtrace output!
reset=$'\e[0m'

# Export portage job-control variables...
#
export JOBS='4'
export MAXLOAD='4.0'

# Are we using docker or podman?
docker='docker'
#extra_build_args=''
docker_readonly='readonly'
