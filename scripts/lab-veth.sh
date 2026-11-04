#!/bin/sh
# Pair kali01 with ubuntu01, through kali30 with ubuntu30, and kali111
# with ubuntu111. Each pair gets one cable. Both ends are named veth-peer,
# with no address and no default route. A pair that already has veth-peer
# on both sides is left alone. Also add a macvlan shim so this server can
# ping 10.0.253.11. The shim is the only way off the parent NIC: frames
# from 10.0.253.1 never reach a macvlan child.
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
  if ! ip link show cyber-shim >/dev/null 2>&1; then
    ip link add cyber-shim link "$parent" type macvlan mode bridge || return 0
  fi
  ip addr show cyber-shim | grep -q '10.0.253.100/' || ip addr add 10.0.253.100/32 dev cyber-shim
  ip link set cyber-shim up
  n=11
  while [ "$n" -le 41 ]; do
    ip route replace "10.0.253.${n}/32" dev cyber-shim
    n=$((n + 1))
  done
  n=50
  while [ "$n" -le 84 ]; do
    ip route replace "10.0.253.${n}/32" dev cyber-shim
    n=$((n + 1))
  done
  echo "shim cyber-shim is up; ping 10.0.253.11 from this server"
}

container_pid() {
  svc=$1
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 1
  fi
  pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || true)
  if [ -z "$pid" ] || [ "$pid" = "0" ]; then
    return 1
  fi
  printf '%s\n' "$pid"
}

has_veth() {
  nsenter -t "$1" -n ip link show veth-peer >/dev/null 2>&1
}

# Kali runs NetworkManager. A new ethernet device is claimed, DHCP runs, and
# the address on the desktop bridge can disappear. Caddy reaches kali01 at
# that address. ubuntu01 is macvlan-only, so it keeps working.
# veth-peer stays unmanaged: ip, dhclient, and dhcpd still configure the lab.
keep_kali_net() {
  svc=$1
  pid=$2
  nsenter -t "$pid" -m /bin/sh -c 'mkdir -p /etc/NetworkManager/conf.d
printf "%s\n" "[keyfile]" "unmanaged-devices=interface-name:veth-peer" > /etc/NetworkManager/conf.d/veth-peer-unmanaged.conf
if command -v nmcli >/dev/null 2>&1; then
  nmcli device set veth-peer managed no >/dev/null 2>&1 || true
fi' || true
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 0
  fi
  docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{printf "%s|%s|%s|%s|%s\n" $name $net.IPAddress $net.IPPrefixLen $net.Gateway $net.MacAddress}}{{end}}' "$cid" |
    while IFS='|' read -r name ip prefix gw mac; do
      if [ -z "$ip" ] || [ -z "$prefix" ] || [ -z "$mac" ]; then
        continue
      fi
      iface=$(nsenter -t "$pid" -n ip -o link show | awk -v mac="$mac" 'BEGIN { mac = tolower(mac) } tolower($0) ~ mac { name = $2; sub(/:$/, "", name); print name; exit }')
      if [ -z "$iface" ]; then
        continue
      fi
      nsenter -t "$pid" -n ip link set "$iface" up
      nsenter -t "$pid" -n ip addr replace "$ip/$prefix" dev "$iface"
      case "$name" in
        *desktop*)
          if [ -n "$gw" ]; then
            nsenter -t "$pid" -n ip route replace default via "$gw" dev "$iface"
          fi
          ;;
      esac
    done
}

pair_veth() {
  kali=$1
  ubuntu=$2
  hostk=$3
  hostu=$4
  kpid=$(container_pid "$kali" || true)
  upid=$(container_pid "$ubuntu" || true)
  if [ -z "$kpid" ]; then
    echo "skip $kali (not running)"
  fi
  if [ -z "$upid" ]; then
    echo "skip $ubuntu (not running)"
  fi
  if [ -z "$kpid" ] || [ -z "$upid" ]; then
    return 0
  fi
  if has_veth "$kpid" && has_veth "$upid"; then
    echo "$kali and $ubuntu already have veth-peer"
    keep_kali_net "$kali" "$kpid"
    return 0
  fi
  if has_veth "$kpid"; then
    nsenter -t "$kpid" -n ip link del veth-peer >/dev/null 2>&1 || true
  fi
  if has_veth "$upid"; then
    nsenter -t "$upid" -n ip link del veth-peer >/dev/null 2>&1 || true
  fi
  ip link del "$hostk" >/dev/null 2>&1 || true
  ip link del "$hostu" >/dev/null 2>&1 || true
  if ! ip link add "$hostk" type veth peer name "$hostu"; then
    echo "could not create a cable for $kali and $ubuntu" >&2
    return 0
  fi
  if ! ip link set "$hostk" netns "$kpid"; then
    ip link del "$hostu" >/dev/null 2>&1 || true
    echo "could not move veth-peer into $kali" >&2
    return 0
  fi
  if ! ip link set "$hostu" netns "$upid"; then
    nsenter -t "$kpid" -n ip link del "$hostk" >/dev/null 2>&1 || true
    echo "could not move veth-peer into $ubuntu" >&2
    return 0
  fi
  if ! nsenter -t "$kpid" -n ip link set "$hostk" name veth-peer; then
    echo "could not rename the cable inside $kali" >&2
    return 0
  fi
  if ! nsenter -t "$upid" -n ip link set "$hostu" name veth-peer; then
    echo "could not rename the cable inside $ubuntu" >&2
    return 0
  fi
  nsenter -t "$kpid" -n ip link set veth-peer up || true
  nsenter -t "$upid" -n ip link set veth-peer up || true
  keep_kali_net "$kali" "$kpid"
  echo "$kali and $ubuntu are paired on veth-peer with no address"
}

ensure_shim

n=1
while [ "$n" -le 30 ]; do
  tag=$(printf '%02d' "$n")
  pair_veth "kali${tag}" "ubuntu${tag}" "vk${tag}" "vu${tag}"
  n=$((n + 1))
done

pair_veth kali111 ubuntu111 vk111 vu111
