#!/bin/sh
# Give each Kali/Ubuntu pair an interface named veth-peer, with no address
# and no default route. Also add a macvlan shim so this server can ping
# 10.0.253.11. The shim is the only way off the parent NIC: frames from
# 10.0.253.1 never reach a macvlan child.
set -u

cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo ./scripts/lab-veth.sh" >&2
  exit 1
fi

parent=""
if [ -f .env ]; then
  parent=$(sed -n 's/^[[:space:]]*PARENT_IFACE=//p' .env | head -1 | tr -d "\"'" | tr -d '[:space:]')
fi
if [ -z "$parent" ]; then
  parent=${PARENT_IFACE:-}
fi

ensure_shim() {
  if [ -z "$parent" ]; then
    echo "PARENT_IFACE is unset; the server still cannot ping 10.0.253.11" >&2
    return 0
  fi
  if ! ip link show "$parent" >/dev/null 2>&1; then
    echo "PARENT_IFACE $parent is not on this host" >&2
    return 0
  fi
  if ! ip link show cybersecurity-shim >/dev/null 2>&1; then
    ip link add cybersecurity-shim link "$parent" type macvlan mode bridge || return 0
  fi
  ip addr show cybersecurity-shim | grep -q '10.0.253.100/' || ip addr add 10.0.253.100/32 dev cybersecurity-shim
  ip link set cybersecurity-shim up
  n=11
  while [ "$n" -le 41 ]; do
    ip route replace "10.0.253.${n}/32" dev cybersecurity-shim
    n=$((n + 1))
  done
  n=50
  while [ "$n" -le 84 ]; do
    ip route replace "10.0.253.${n}/32" dev cybersecurity-shim
    n=$((n + 1))
  done
  echo "shim cybersecurity-shim is up; ping 10.0.253.11 from this server"
}

ensure_bridge() {
  br=$1
  if ! ip link show "$br" >/dev/null 2>&1; then
    ip link add "$br" type bridge
    ip link set "$br" type bridge stp_state 0 forward_delay 0
  fi
  ip link set "$br" up
}

attach_veth() {
  svc=$1
  hostif=$2
  br=$3
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    echo "skip $svc (not running)"
    return 0
  fi
  pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || true)
  if [ -z "$pid" ] || [ "$pid" = "0" ]; then
    echo "skip $svc (not running)"
    return 0
  fi
  if nsenter -t "$pid" -n ip link show veth-peer >/dev/null 2>&1; then
    echo "$svc already has veth-peer"
    return 0
  fi
  ip link del "$hostif" >/dev/null 2>&1 || true
  tmp="p${hostif}"
  ip link add "$hostif" type veth peer name "$tmp"
  ip link set "$tmp" netns "$pid"
  nsenter -t "$pid" -n ip link set "$tmp" name veth-peer
  nsenter -t "$pid" -n ip link set veth-peer up
  ip link set "$hostif" master "$br"
  ip link set "$hostif" up
  echo "$svc veth-peer is up on $br with no address"
}

ensure_shim

n=1
while [ "$n" -le 30 ]; do
  tag=$(printf '%02d' "$n")
  ensure_bridge "brlab${tag}"
  attach_veth "kali${tag}" "vk${tag}" "brlab${tag}"
  attach_veth "ubuntu${tag}" "vu${tag}" "brlab${tag}"
  n=$((n + 1))
done

ensure_bridge brlab111
attach_veth kali111 vk111 brlab111
attach_veth ubuntu111 vu111 brlab111
