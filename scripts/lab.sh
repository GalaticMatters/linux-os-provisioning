#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# .env sets COMPOSE_PROFILES=dns. Clear it so `on` does not start dnsmasq.
# `on` and `off` use only kali01–kali30 and ubuntu01–ubuntu30.
# `on` is `docker compose up -d` with those names, not a bare `up -d`,
# so kali111 and the other containers are not recreated.
# `off` docker stops only those container IDs.
# `extra-containers-on` starts only derek, vyas, kali111, ubuntu111, sang, ashraful, and vai.
# `extra-containers-off` stops only those seven.
export COMPOSE_PROFILES=""

# One QEMU per Ubuntu guest. Thirty at once is why compose sits at
# "up 46/62" after creating veth01–30 (30 nets + 32 containers = 62).
KATA_BATCH=${KATA_BATCH:-5}

fleet=""
ubuntu=""
kali=""
n=1
while [ "$n" -le 30 ]; do
  tag=$(printf '%02d' "$n")
  fleet="$fleet kali${tag} ubuntu${tag}"
  ubuntu="$ubuntu ubuntu${tag}"
  kali="$kali kali${tag}"
  n=$((n + 1))
done

# Recreate/start Ubuntu Kata guests a few at a time. Extra args are
# passed to `docker compose up -d` (rebuild uses --force-recreate --no-deps).
up_kata_ubuntu() {
  n=1
  while [ "$n" -le 30 ]; do
    batch=""
    i=0
    while [ "$i" -lt "$KATA_BATCH" ] && [ "$n" -le 30 ]; do
      batch="$batch ubuntu$(printf '%02d' "$n")"
      n=$((n + 1))
      i=$((i + 1))
    done
    echo "Kata Ubuntu batch:$batch"
    # shellcheck disable=SC2086
    docker compose up -d "$@" $batch
  done
}

add_lab_veth() {
  if [ "$(id -u)" -eq 0 ]; then
    ./scripts/lab-veth.sh || echo "veth-peer was not added. Run: sudo ./scripts/lab-veth.sh" >&2
  else
    sudo ./scripts/lab-veth.sh || echo "veth-peer was not added. Run: sudo ./scripts/lab-veth.sh" >&2
  fi
}

case "${1:-}" in
  on)
    # Kali is runc (fast). Ubuntu is Kata (QEMU); do not start all 30 at once.
    # shellcheck disable=SC2086
    docker compose up -d $kali
    up_kata_ubuntu
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
    if ! docker image inspect cybersecurity-ubuntu111:1 >/dev/null 2>&1; then
      docker compose build ubuntu111
    fi
    docker compose up -d derek vyas kali111 ubuntu111 sang ashraful vai
    add_lab_veth
    ;;
  extra-containers-off)
    exec docker compose stop derek vyas kali111 ubuntu111 sang ashraful vai
    ;;
  dns-on)
    exec docker compose --profile dns up -d dnsmasq
    ;;
  dns-off)
    exec docker compose --profile dns stop dnsmasq
    ;;
  rebuild)
    # One build of the shared image, then recreate ubuntu01–ubuntu30,
    # ubuntuserver, and vai (all kata-runtime). lab-veth.sh restores
    # veth-peer on the Kali/Ubuntu pairs (Compose extra NIC, not host veth).
    docker compose build ubuntu01
    up_kata_ubuntu --force-recreate --no-deps
    docker compose up -d --force-recreate --no-deps ubuntuserver vai
    add_lab_veth
    ;;
  *)
    echo "usage: $0 on|off|extra-containers-on|extra-containers-off|dns-on|dns-off|rebuild" >&2
    exit 2
    ;;
esac
