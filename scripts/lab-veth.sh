#!/bin/sh
# Pair kali01 with ubuntu01, through kali30 with ubuntu30, and kali111
# with ubuntu111. Fleet pairs (runc) get a host veth moved into each
# netns. Both ends are named veth-peer, with no address and no default
# route. A runc pair that already has veth-peer on both sides is left
# alone. ubuntu111 is Kata: the Docker pid is the shim, so a host veth
# never appears in the guest. That pair uses Compose network
# cybersecurity-veth111 (Kata extra virtio NIC / hotplug), renamed to
# veth-peer inside the guest and on kali111. kali01–kali30 /
# ubuntu01–ubuntu30 stay runc host-veth pairs. Also add a macvlan shim
# so this server can ping 10.0.253.11, and the persistent Ubuntu boxes
# through vai at 10.0.253.42. The shim is the only way off the parent
# NIC: frames from 10.0.253.1 never reach a macvlan child. vai has no
# veth-peer.
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
  # ubuntu01 (.11) through ubuntu30 (.40), ubuntuserver (.41), vai (.42).
  n=11
  while [ "$n" -le 42 ]; do
    ip route replace "10.0.253.${n}/32" dev cyber-shim
    n=$((n + 1))
  done
  # Persistent desktops .50–.54, Kali fleet .55–.84, sang .85, ashraful .86.
  n=50
  while [ "$n" -le 86 ]; do
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

# Kata extra NIC for ubuntu111 (test only). Not attached to the fleet.
VETH111_NET=cybersecurity-veth111
VETH111_SUBNET=10.255.111.0/24
VETH111_GW=10.255.111.254
VETH111_UBUNTU_IP=10.255.111.1
VETH111_KALI_IP=10.255.111.2
VETH111_UBUNTU_MAC=02:42:ff:6f:01:01
VETH111_KALI_MAC=02:42:ff:6f:02:02
RENAME_VETH="$PWD/scripts/rename-veth-peer.sh"

# Kata's docker pid is the host-side shim netns, not the guest. A host-injected
# veth-peer never appears inside ubuntu111. Fleet pairs stay runc and still
# get the cable. ubuntu111 uses a Kata extra virtio NIC instead.
is_kata_runtime() {
  svc=$1
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 1
  fi
  rt=$(docker inspect -f '{{.HostConfig.Runtime}}' "$cid" 2>/dev/null || true)
  case "$rt" in
    kata|kata-runtime|io.containerd.kata*)
      return 0
      ;;
  esac
  return 1
}

has_veth() {
  nsenter -t "$1" -n ip link show veth-peer >/dev/null 2>&1
}

# A bare veth does not break the desktop. NetworkManager does: it claims the
# new cable, and the bridge address Caddy uses can end up missing or sitting
# on veth-peer. ubuntu01 has no NetworkManager, so its macvlan address stays.
# veth-peer stays unmanaged. ip, dhclient, and dhcpd still configure the lab.
iface_name() {
  name=$1
  name=${name%%@*}
  name=${name%:}
  printf '%s\n' "$name"
}

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
  # IPPrefixLen is an int. %s prints %!s(int=16) and ip rejects the prefix.
  docker inspect -f '{{range $name, $net := .NetworkSettings.Networks}}{{printf "%s|%s|%d|%s|%s\n" $name $net.IPAddress $net.IPPrefixLen $net.Gateway $net.MacAddress}}{{end}}' "$cid" |
    while IFS='|' read -r name ip prefix gw mac; do
      if [ -z "$ip" ] || [ -z "$prefix" ] || [ -z "$mac" ]; then
        continue
      fi
      case "$name" in
        *veth111*) continue ;;
      esac
      case "$ip" in
        10.255.111.*) continue ;;
      esac
      # ip -o link prints eth0@if3320: — the kernel device is eth0.
      raw=$(nsenter -t "$pid" -n ip -o link show | awk -v mac="$mac" 'BEGIN { mac = tolower(mac) } tolower($0) ~ mac { print $2; exit }')
      iface=$(iface_name "$raw")
      if [ -z "$iface" ]; then
        echo "$svc has no interface for $ip" >&2
        continue
      fi
      # Leave a correct Docker address alone. Telling NetworkManager to drop
      # eth0 while Selkies is still starting keeps port 3001 closed.
      misplaced=""
      others=$(nsenter -t "$pid" -n ip -o -4 addr show | awk -v ip="$ip/" '$3 == "inet" && index($4, ip) == 1 { print $2 }')
      for other in $others; do
        other=$(iface_name "$other")
        if [ -n "$other" ] && [ "$other" != "$iface" ]; then
          misplaced=1
          nsenter -t "$pid" -n ip addr del "$ip/$prefix" dev "$other" || true
        fi
      done
      if ! nsenter -t "$pid" -n ip -o -4 addr show dev "$iface" | awk -v ip="$ip/" '$3 == "inet" && index($4, ip) == 1 { found = 1 } END { exit !found }'; then
        nsenter -t "$pid" -n ip link set "$iface" up
        nsenter -t "$pid" -n ip addr replace "$ip/$prefix" dev "$iface"
        echo "$svc $ip/$prefix restored on $iface"
      elif [ -n "$misplaced" ]; then
        echo "$svc $ip/$prefix moved back to $iface"
      else
        echo "$svc $ip/$prefix is on $iface"
      fi
      case "$name" in
        *desktop*)
          if [ -n "$gw" ]; then
            current=$(nsenter -t "$pid" -n ip -4 route show default | awk 'NR==1 { print $3; exit }')
            if [ "$current" != "$gw" ]; then
              nsenter -t "$pid" -n ip route replace default via "$gw" dev "$iface"
            fi
          fi
          server_ip=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" | sed -n 's/^SERVER_IP=//p' | head -1)
          if [ -n "$server_ip" ] && [ -n "$gw" ]; then
            if ! nsenter -t "$pid" -n ip route show "$server_ip/32" | grep -q .; then
              nsenter -t "$pid" -n ip route replace "$server_ip/32" via "$gw" dev "$iface"
            fi
          fi
          ;;
      esac
    done
}

guest_has_veth() {
  svc=$1
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 1
  fi
  docker exec "$cid" ip link show veth-peer >/dev/null 2>&1
}

ensure_veth111_network() {
  if docker network inspect "$VETH111_NET" >/dev/null 2>&1; then
    return 0
  fi
  if docker network create \
    --driver bridge \
    --internal \
    --subnet "$VETH111_SUBNET" \
    --gateway "$VETH111_GW" \
    -o com.docker.network.bridge.enable_ip_masquerade=false \
    "$VETH111_NET" >/dev/null; then
    echo "created $VETH111_NET for ubuntu111 Kata veth-peer"
    return 0
  fi
  echo "could not create $VETH111_NET" >&2
  return 1
}

on_veth111() {
  cid=$1
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$cid" 2>/dev/null |
    grep -q veth111
}

connect_veth111() {
  svc=$1
  ipaddr=$2
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    echo "skip $svc (not running)" >&2
    return 1
  fi
  if on_veth111 "$cid"; then
    return 0
  fi
  if docker network connect --ip "$ipaddr" "$VETH111_NET" "$cid"; then
    echo "connected $svc to $VETH111_NET ($ipaddr) (Kata extra NIC / hotplug)"
    return 0
  fi
  echo "could not connect $svc to $VETH111_NET" >&2
  return 1
}

rename_guest_veth() {
  svc=$1
  mac=$2
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 1
  fi
  if [ ! -f "$RENAME_VETH" ]; then
    echo "missing $RENAME_VETH" >&2
    return 1
  fi
  # docker exec on Kata runs in the guest, not the shim. stdin so this
  # works before the container is recreated onto the new bind mounts.
  docker exec -i \
    -e "VETH_PEER_MAC=$mac" \
    -e "VETH_PEER_SUBNET=$VETH111_SUBNET" \
    "$cid" /bin/sh < "$RENAME_VETH"
}

pair_kata_veth() {
  kali=$1
  ubuntu=$2
  kpid=$3
  if ! ensure_veth111_network; then
    keep_kali_net "$kali" "$kpid"
    return 0
  fi
  connect_veth111 "$ubuntu" "$VETH111_UBUNTU_IP" || true
  connect_veth111 "$kali" "$VETH111_KALI_IP" || true
  rename_guest_veth "$ubuntu" "$VETH111_UBUNTU_MAC" || true
  rename_guest_veth "$kali" "$VETH111_KALI_MAC" || true
  keep_kali_net "$kali" "$kpid"
  if guest_has_veth "$ubuntu" && guest_has_veth "$kali"; then
    echo "$kali and $ubuntu are paired on veth-peer (Kata extra virtio NIC on $VETH111_NET)"
  else
    echo "$ubuntu Kata veth-peer is not in the guest yet; recreate ubuntu111, then re-run this script" >&2
  fi
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
  if is_kata_runtime "$ubuntu"; then
    pair_kata_veth "$kali" "$ubuntu" "$kpid"
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
