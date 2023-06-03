#! /bin/sh

# PLEASE NOTE:
#
# This file is *NOT* a perl source file - it is a shell-script which must have
# the same name as the container service-command to be executed (which is, in
# this case, a perl script...)

rc=0

sa-update --checkonly || rc=${?}

if [ $(( rc )) -ge 4 ]; then
	echo >&2 " * sa-update flagged error - aborting"
	exit ${rc}

elif [ $(( rc )) -ge 2 ]; then
	echo >&2 " * sa-update flagged partial success - updates available"
	echo >&2 "WARN: Please run '/etc/init.d/spamd update'"
	#exit ${rc}

elif [ $(( rc )) -eq 1 ]; then
	echo >&2 " * sa-update flagged no updates available"

else # [ $(( rc )) -eq 0 ]; then
	echo >&2 "WARN: Definitions out of date - please run '/etc/init.d/spamd update'"
	#exit ${rc}
fi

if command -v cdcc >/dev/null 2>&1; then
	cdcc info || :
else
	echo >&2 "WARN: Not running 'cdcc info'"
fi

echo >&2 "Remote data refreshed, writing PID file ..."
echo '0' > /var/run/spampd.pid

# vi: set syntax=sh:
