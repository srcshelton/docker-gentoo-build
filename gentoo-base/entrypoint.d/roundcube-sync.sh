#! /bin/sh

rcdir='/var/www/localhost/htdocs/roundcube'

# sync'ing reminders from CalDAV takes about 15 seconds to complete...
if test -e "$rcdir"/plugins/calendar/cron/sync_caldav_reminders.php; then
	php "$rcdir"/plugins/calendar/cron/sync_caldav_reminders.php
fi
if test -e "$rcdir"/plugins/calendar/cron/reminders.php; then
	php "$rcdir"/plugins/calendar/cron/reminders.php
fi

# Pull updates from CardDAV
if test -e "$rcdir"/plugins/carddav/cronjob/synchronize.php; then
	php "$rcdir"/plugins/carddav/cronjob/synchronize.php
fi

exit 0

# vi: set syntax=sh:
