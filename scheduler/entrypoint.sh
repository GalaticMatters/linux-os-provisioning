#!/bin/sh
# Run the 02:00 desktop reset in the timezone from .env.
set -eu

TZ=${TZ:-UTC}
export TZ

if [ ! -f "/usr/share/zoneinfo/$TZ" ]; then
  echo "TZ=$TZ is not a tz database name. Examples: UTC, America/New_York, Europe/Berlin." >&2
  exit 1
fi

echo "Desktop reset cron is 02:00 $(date +%Z) ($TZ)"
exec supercronic -passthrough-logs /etc/crontab
