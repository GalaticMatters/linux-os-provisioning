#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

profiles="--profile dns"
token=""
if [ -f .env ]; then
  token=$(sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' .env | tail -n 1)
fi
case "$token" in
  ""|unused) ;;
  *) profiles="$profiles --profile public" ;;
esac

case "${1:-}" in
  on)
    # shellcheck disable=SC2086
    exec docker compose $profiles up -d
    ;;
  off)
    # shellcheck disable=SC2086
    exec docker compose $profiles stop
    ;;
  *)
    echo "usage: $0 on|off" >&2
    exit 2
    ;;
esac
