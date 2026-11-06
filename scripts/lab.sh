#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. Clear it so `on` does not start dnsmasq.
# `on` and `off` use only kali01–kali30 and ubuntu01–ubuntu30.
# `on` is `docker compose up -d` with those names, not a bare `up -d`,
# so kali111 and the other containers are not recreated.
# `off` docker stops only those container IDs.
# `extra-containers-on` starts only derek, vyas, kali111, ubuntu111, and sang.
# `extra-containers-off` stops only those five.
export COMPOSE_PROFILES=""

fleet=""
ubuntu=""
n=1
while [ "$n" -le 30 ]; do
  fleet="$fleet kali$(printf '%02d' "$n") ubuntu$(printf '%02d' "$n")"
  ubuntu="$ubuntu ubuntu$(printf '%02d' "$n")"
  n=$((n + 1))
done

add_lab_veth() {
  if [ "$(id -u)" -eq 0 ]; then
    ./scripts/lab-veth.sh || echo "veth-peer was not added. Run: sudo ./scripts/lab-veth.sh" >&2
  else
    sudo ./scripts/lab-veth.sh || echo "veth-peer was not added. Run: sudo ./scripts/lab-veth.sh" >&2
  fi
}

case "${1:-}" in
  on)
    # shellcheck disable=SC2086
    docker compose up -d $fleet
    add_lab_veth
    ;;
  off)
    # shellcheck disable=SC2086
    ids=$(docker compose ps -aq $fleet)
    if [ -z "$ids" ]; then
      exit 0
    fi
    # shellcheck disable=SC2086
    exec docker stop $ids
    ;;
  extra-containers-on)
    docker compose up -d derek vyas kali111 ubuntu111 sang
    add_lab_veth
    ;;
  extra-containers-off)
    exec docker compose stop derek vyas kali111 ubuntu111 sang
    ;;
  dns-on)
    exec docker compose --profile dns up -d dnsmasq
    ;;
  dns-off)
    exec docker compose --profile dns stop dnsmasq
    ;;
  rebuild)
    # One build of the shared image, then recreate ubuntu01–ubuntu30 and ubuntuserver.
    docker compose build ubuntu01
    # shellcheck disable=SC2086
    docker compose up -d --force-recreate --no-deps $ubuntu ubuntuserver
    add_lab_veth
    ;;
  *)
    echo "usage: $0 on|off|extra-containers-on|extra-containers-off|dns-on|dns-off|rebuild" >&2
    exit 2
    ;;
esac
