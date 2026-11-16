#!/bin/sh
# Student NFS lab on one Kali/Ubuntu pair. Ubuntu exports /sharedfolder;
# Kali mounts it at /mnt/sharedfolder. Nothing here starts NFS on the
# whole fleet. lab.sh on/off, extra-containers, lab-veth.sh, and the
# 02:00 reset are unchanged.
#
# Prefer veth-peer so the share stays off the macvlan LAN. Each pair can
# reuse 192.168.101.1 (Ubuntu) and 192.168.101.2 (Kali): the cable is
# private. Pass macvlan as the last argument to export/mount on
# 10.0.253.(10+N) / 10.0.253.(54+N) instead.
#
# From the ProLiant, in this repo:
#   ./scripts/nfs-lab.sh addr [NN]
#   ./scripts/nfs-lab.sh server [NN]
#   ./scripts/nfs-lab.sh client [NN]
# Inside Ubuntu (after copying this script):  nfs-lab.sh server
# Inside Kali:                                nfs-lab.sh client
set -eu

VETH_UBUNTU=192.168.101.1
VETH_KALI=192.168.101.2
VETH_PREFIX=24
SHARE=/sharedfolder
MNT=/mnt/sharedfolder

# sh -s (docker compose exec stdin) leaves $0 as sh. Only cd when this
# file is invoked by name from the ProLiant checkout.
if [ -f "$0" ]; then
  case "$0" in
    */nfs-lab.sh|nfs-lab.sh)
      cd "$(dirname "$0")/.."
      ;;
  esac
fi

usage() {
  echo "usage: $0 addr|server|client [NN] [macvlan]" >&2
  echo "  NN is 01 through 30 (default 01). ubuntu07 and 7 are the same pair." >&2
  exit 2
}

in_guest() {
  [ -f /.dockerenv ]
}

pair_from_hostname() {
  h=$(hostname 2>/dev/null || true)
  case "$h" in
    ubuntu[0-9][0-9]) printf '%s\n' "${h#ubuntu}" ;;
    kali[0-9][0-9]) printf '%s\n' "${h#kali}" ;;
    *) printf '%s\n' "01" ;;
  esac
}

normalize_pair() {
  raw=$1
  raw=${raw#ubuntu}
  raw=${raw#kali}
  case "$raw" in
    [1-9]) raw="0$raw" ;;
  esac
  n=$(printf '%s' "$raw" | sed 's/^0*//')
  [ -n "$n" ] || n=0
  if [ "$n" -lt 1 ] || [ "$n" -gt 30 ]; then
    echo "pair must be 01 through 30, got $1" >&2
    exit 2
  fi
  printf '%02d\n' "$n"
}

pair_num() {
  n=$(printf '%s' "$1" | sed 's/^0*//')
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

ubuntu_macvlan() {
  printf '10.0.253.%s\n' $((10 + $1))
}

kali_macvlan() {
  printf '10.0.253.%s\n' $((54 + $1))
}

veth_present() {
  ip link show veth-peer >/dev/null 2>&1
}

veth_has_ipv4() {
  ip -4 -o addr show dev veth-peer 2>/dev/null | grep -q ' inet '
}

as_ubuntu() {
  docker compose exec -T --privileged --user root "ubuntu${pair}" "$@"
}

as_kali() {
  docker compose exec -T --privileged --user root "kali${pair}" "$@"
}

need_running() {
  role=$1
  svc="${role}${pair}"
  if [ -z "$(docker compose ps -q "$svc" 2>/dev/null || true)" ]; then
    echo "$svc is not running. Start the fleet: ./scripts/lab.sh on" >&2
    exit 1
  fi
}

load_nfsd() {
  if [ -f /.dockerenv ]; then
    return 0
  fi
  if [ "$(id -u)" -eq 0 ]; then
    modprobe nfsd 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n modprobe nfsd 2>/dev/null || true
  fi
  if ! grep -q '^nfsd ' /proc/modules 2>/dev/null; then
    echo "nfsd is not loaded on this host. On the ProLiant run: sudo modprobe nfsd" >&2
  fi
}

start_nfs_server() {
  mkdir -p /run /var/lib/nfs/sm /var/lib/nfs/v4recovery /proc/fs/nfsd
  if ! grep -q ' /proc/fs/nfsd ' /proc/mounts; then
    mount -t nfsd nfsd /proc/fs/nfsd
  fi
  if ! rpcinfo >/dev/null 2>&1; then
    rpcbind -w
  fi
  exportfs -ra
  # Restart nfsd in this netns so a second run is idempotent.
  rpc.nfsd 0 2>/dev/null || true
  rpc.nfsd 8
  rpc.mountd 2>/dev/null || true
  if ! rpcinfo >/dev/null 2>&1; then
    echo "rpcbind is not answering; nfsd may still be up on UDP/TCP 2049" >&2
  fi
}

do_addr() {
  if ! veth_present; then
    echo "veth-peer is missing. On the ProLiant: sudo ./scripts/lab-veth.sh" >&2
    exit 1
  fi
  ip link set veth-peer up
  h=$(hostname 2>/dev/null || true)
  case "$h" in
    ubuntu*) ip addr replace "${VETH_UBUNTU}/${VETH_PREFIX}" dev veth-peer ;;
    kali*) ip addr replace "${VETH_KALI}/${VETH_PREFIX}" dev veth-peer ;;
    *)
      echo "hostname $h is not ubuntuNN or kaliNN; not addressing veth-peer" >&2
      exit 1
      ;;
  esac
  ip -4 addr show dev veth-peer
}

do_server() {
  n=$(pair_num "$pair")
  use_macvlan=0
  if [ "$path" = "macvlan" ]; then
    use_macvlan=1
  elif ! veth_present || ! veth_has_ipv4; then
    use_macvlan=1
    echo "veth-peer has no address; exporting to the macvlan peer. On the ProLiant: ./scripts/nfs-lab.sh addr $pair" >&2
  fi
  if [ "$use_macvlan" -eq 1 ]; then
    peer=$(kali_macvlan "$n")
  else
    peer=$VETH_KALI
  fi
  mkdir -p "$SHARE"
  chmod 1777 "$SHARE"
  printf '%s\n' "${SHARE} ${peer}(rw,sync,no_subtree_check)" > /etc/exports
  start_nfs_server
  echo "exported ${SHARE} to ${peer} (root_squash, rw,sync,no_subtree_check)"
  exportfs -v
}

do_client() {
  n=$(pair_num "$pair")
  use_macvlan=0
  if [ "$path" = "macvlan" ]; then
    use_macvlan=1
  elif ! veth_present || ! veth_has_ipv4; then
    use_macvlan=1
    echo "veth-peer has no address; mounting the macvlan Ubuntu address. On the ProLiant: ./scripts/nfs-lab.sh addr $pair" >&2
  fi
  if [ "$use_macvlan" -eq 1 ]; then
    server=$(ubuntu_macvlan "$n")
  else
    server=$VETH_UBUNTU
  fi
  if ! command -v mount.nfs >/dev/null 2>&1 && ! command -v mount.nfs4 >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nfs-common
  fi
  mkdir -p "$MNT"
  if grep -q " ${MNT} " /proc/mounts; then
    umount "$MNT"
  fi
  if ! mount -t nfs -o vers=4 "${server}:${SHARE}" "$MNT"; then
    echo "NFSv4 failed; trying NFSv3" >&2
    mount -t nfs -o vers=3,nolock "${server}:${SHARE}" "$MNT"
  fi
  echo "mounted ${server}:${SHARE} on ${MNT}"
  df -h "$MNT"
  showmount -e "$server" 2>/dev/null || true
}

cmd=${1:-}
[ -n "$cmd" ] || usage
case "$cmd" in
  addr|server|client) ;;
  *) usage ;;
esac

if in_guest; then
  pair=$(normalize_pair "${2:-$(pair_from_hostname)}")
  path=${3:-}
  case "$cmd" in
    addr) do_addr ;;
    server) do_server ;;
    client) do_client ;;
  esac
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Run this from the ProLiant repo, or copy it into ubuntuNN / kaliNN." >&2
  exit 1
fi

pair=$(normalize_pair "${2:-01}")
path=${3:-}
case "$path" in
  ""|macvlan|veth) ;;
  *) usage ;;
esac

need_running ubuntu
need_running kali

case "$cmd" in
  addr)
    echo "addressing veth-peer on ubuntu${pair} (${VETH_UBUNTU}/${VETH_PREFIX}) and kali${pair} (${VETH_KALI}/${VETH_PREFIX})"
    as_ubuntu /bin/sh -s -- addr "$pair" < "$0"
    as_kali /bin/sh -s -- addr "$pair" < "$0"
    echo "ping the Ubuntu end from Kali:"
    as_kali ping -c 2 "$VETH_UBUNTU"
    ;;
  server)
    load_nfsd
    as_ubuntu /bin/sh -s -- server "$pair" "$path" < "$0"
    ;;
  client)
    as_kali /bin/sh -s -- client "$pair" "$path" < "$0"
    ;;
esac
