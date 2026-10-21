#!/bin/sh
# Run the same reset the 02:00 cron runs. Desktops drop immediately.
set -eu

cd "$(dirname "$0")/.."
exec docker compose exec -T scheduler /usr/local/bin/reset-desktops.sh
