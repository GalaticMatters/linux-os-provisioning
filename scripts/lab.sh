#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. Clear it so `on` (`up -d`) does not
# start dnsmasq. `off` still names services and drops dnsmasq: a bare
# `docker compose stop` stops every running container in the project.
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
    services=$(docker compose $profiles config --services)
    services=$(printf '%s\n' "$services" | grep -vx dnsmasq || true)
    if [ -z "$services" ]; then
      exit 0
    fi
    # shellcheck disable=SC2086
    exec docker compose $profiles stop $services
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
