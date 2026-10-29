#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. on/off must not inherit that, or a lab
# reset starts and stops dnsmasq with the desktops.
export COMPOSE_PROFILES=""

profiles=""
token=""
if [ -f .env ]; then
  token=$(sed -n 's/^CLOUDFLARE_TUNNEL_TOKEN=//p' .env | tail -n 1)
fi
case "$token" in
  ""|unused) ;;
  *) profiles="--profile public" ;;
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
  dns-on)
    exec docker compose --profile dns up -d dnsmasq
    ;;
  dns-off)
    exec docker compose --profile dns stop dnsmasq
    ;;
  *)
    echo "usage: $0 on|off|dns-on|dns-off" >&2
    exit 2
    ;;
esac
