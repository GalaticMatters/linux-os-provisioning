#!/bin/sh
# Copy Caddy's local CA root to a file you can install on workstations.
set -eu

cd "$(dirname "$0")/.."
out=${1:-./desktop-lan-root.crt}

docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt "$out"
chmod 644 "$out"
echo "Wrote $out"
echo "Install this file on each workstation before opening the desktops. See the README."
