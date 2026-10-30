#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. Clear it so `on` (`up -d`) does not
# start dnsmasq. `off` stops only kali01–kali30 and ubuntu01–ubuntu30,
# by container ID. It does not ask Compose for the service list.
# `extra-containers-off` stops only derek, vyas, kali111, and ubuntu111.
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
    fleet=""
    n=1
    while [ "$n" -le 30 ]; do
      fleet="$fleet kali$(printf '%02d' "$n") ubuntu$(printf '%02d' "$n")"
      n=$((n + 1))
    done
    # shellcheck disable=SC2086
    ids=$(docker compose ps -aq $fleet)
    if [ -z "$ids" ]; then
      exit 0
    fi
    # shellcheck disable=SC2086
    exec docker stop $ids
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
