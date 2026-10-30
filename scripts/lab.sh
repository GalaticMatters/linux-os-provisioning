#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. Clear it so `on` (`up -d`) does not
# start dnsmasq. `off` resolves container IDs for every other service
# and `docker stop`s those IDs. It does not call `docker compose stop`:
# a long service list still stops vyas. dnsmasq, derek, vyas, kali111,
# and ubuntu111 are never in that ID list. `extra-containers-off`
# stops only those four desktops.
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
    services=$(printf '%s\n' "$services" | grep -vx -e dnsmasq -e derek -e vyas -e kali111 -e ubuntu111 || true)
    if [ -z "$services" ]; then
      exit 0
    fi
    # IDs only. Do not pass the service list to `docker compose stop`.
    # shellcheck disable=SC2086
    ids=$(docker compose $profiles ps -aq $services)
    if [ -z "$ids" ]; then
      exit 0
    fi
    kept=""
    for id in $ids; do
      svc=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id" 2>/dev/null || true)
      case "$svc" in
        ""|dnsmasq|derek|vyas|kali111|ubuntu111) continue ;;
      esac
      kept="${kept} ${id}"
    done
    if [ -z "$kept" ]; then
      exit 0
    fi
    # shellcheck disable=SC2086
    exec docker stop $kept
    ;;
  extra-containers-off)
    exec docker compose stop derek vyas kali111 ubuntu111
    ;;
  dns-on)
    exec docker compose --profile dns up -d dnsmasq
    ;;
  dns-off)
    exec docker compose --profile dns stop dnsmasq
    ;;
  *)
    echo "usage: $0 on|off|extra-containers-off|dns-on|dns-off" >&2
    exit 2
    ;;
esac
