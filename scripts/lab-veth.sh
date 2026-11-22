#!/bin/sh
# Pair kali01 with ubuntu01, through kali30 with ubuntu30, and kali111
# with ubuntu111. Ubuntu is Kata: the Docker pid is the shim, so a host
# veth never appears in the guest. Each pair uses Compose network
# cybersecurity-vethNN (Kata extra virtio NIC / hotplug), renamed to
# veth-peer inside the Ubuntu guest and on kaliNN. Kali stays runc.
# Kata cannot take a host veth. Both ends are named veth-peer, with no
# address and no default route. A Kata pair that already has veth-peer
# is left quiet. Also add a macvlan shim so this server can ping
# 10.0.253.11, and the persistent Ubuntu boxes through vai at
# 10.0.253.42. The shim is the only way off the parent NIC: frames from
# 10.0.253.1 never reach a macvlan child. ubuntuserver and vai have no
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

# Kata extra NIC: one internal bridge per pair. Placeholder IPs are flushed
# so the guest name is veth-peer with no address. Kata cannot take a host veth.
RENAME_VETH="$PWD/scripts/rename-veth-peer.sh"

# dash has no bash 10#; $((10#01)) is "expecting EOF" and then n is empty,
# so this script used to invent cybersecurity-veth00 / 10.255..254 and
# retry docker network create for every pair. Only kali01–30 / ubuntu01–30
# and 111. Never pair 00.
pair_num() {
  n=${1#kali}
  n=${n#ubuntu}
  case "$n" in
    111)
      echo 111
      return 0
      ;;
    0[1-9])
      echo "${n#0}"
      return 0
      ;;
    [1-9]|[12][0-9]|30)
      echo "$n"
      return 0
      ;;
  esac
  echo "lab-veth.sh: skip unknown pair '$1' (only kali01–30 / ubuntu01–30 / 111)" >&2
  return 1
}

veth_net_name() {
  n=$1
  case "$n" in
    111)
      echo cybersecurity-veth111
      ;;
    [1-9]|[12][0-9]|30)
      printf 'cybersecurity-veth%02d' "$n"
      ;;
    *)
      echo "lab-veth.sh: refusing cybersecurity-veth00 (pair '$n')" >&2
      return 1
      ;;
  esac
}

veth_subnet() { echo "10.255.${1}.0/24"; }
veth_gw() { echo "10.255.${1}.254"; }
veth_ubuntu_ip() { echo "10.255.${1}.1"; }
veth_kali_ip() { echo "10.255.${1}.2"; }

veth_ubuntu_mac() {
  n=$1
  case "$n" in
    111) echo 02:42:ff:6f:01:01 ;;
    [1-9]|[12][0-9]|30) printf '02:42:ff:00:%02d:01' "$n" ;;
    *) return 1 ;;
  esac
}

veth_kali_mac() {
  n=$1
  case "$n" in
    111) echo 02:42:ff:6f:02:02 ;;
    [1-9]|[12][0-9]|30) printf '02:42:ff:00:%02d:02' "$n" ;;
    *) return 1 ;;
  esac
}

# Kata's docker pid is the host-side shim netns, not the guest. A host-injected
# veth-peer never appears inside the Ubuntu VM. Every Ubuntu box uses a Kata
# extra virtio NIC instead. Kali stays runc on that same Compose bridge.
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

# iproute2 dumps every link, including veth-peer. The other end lives in the
# Ubuntu container netns. `ip link set netns $pid` does not install a netnsid,
# so a later `ip -o link show` prints "Error: Peer netns reference is invalid."
# That is not a failed move and must not hit stdout/stderr on a rerun.
link_by_mac() {
  pid=$1
  mac=$2
  nsenter -t "$pid" -n ip -o link show 2>/dev/null |
    awk -v mac="$mac" 'BEGIN { mac = tolower(mac) } tolower($0) ~ mac { print $2; exit }'
}

keep_kali_net() {
  svc=$1
  pid=$2
  quiet=${3:-}
  # -m -n: resolv.conf and NM live in the container mount; nmcli sees veth-peer
  # in the container netns. -m alone used to run nmcli against the host.
  nsenter -t "$pid" -m -n /bin/sh -s <<'EOS' || true
mkdir -p /etc/NetworkManager/conf.d
printf "%s\n" "[keyfile]" "unmanaged-devices=interface-name:veth-peer" > /etc/NetworkManager/conf.d/veth-peer-unmanaged.conf
printf "%s\n" "[main]" "dns=none" "rc-manager=unmanaged" > /etc/NetworkManager/conf.d/90-docker-dns.conf
if command -v nmcli >/dev/null 2>&1; then
  nmcli device set veth-peer managed no >/dev/null 2>&1 || true
  for uuid in $(nmcli -t -f UUID,DEVICE connection show 2>/dev/null | awk -F: '$2 == "veth-peer" { print $1 }'); do
    [ -n "$uuid" ] || continue
    nmcli connection modify "$uuid" ipv4.ignore-auto-dns yes ipv4.never-default yes ipv4.dns "" ipv6.ignore-auto-dns yes ipv6.never-default yes ipv6.dns "" >/dev/null 2>&1 || true
  done
  nmcli general reload >/dev/null 2>&1 || true
fi
if command -v resolvectl >/dev/null 2>&1; then
  resolvectl revert veth-peer >/dev/null 2>&1 || true
fi
if ! grep -qE "nameserver[[:space:]]+127\.0\.0\.11" /etc/resolv.conf 2>/dev/null; then
  printf "%s\n" "nameserver 127.0.0.11" "options ndots:0" > /etc/resolv.conf 2>/dev/null || true
fi
EOS
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
        *veth*) continue ;;
      esac
      case "$ip" in
        10.255.*) continue ;;
      esac
      # ip -o link prints eth0@if3320: — the kernel device is eth0.
      raw=$(link_by_mac "$pid" "$mac")
      iface=$(iface_name "$raw")
      # veth-peer is the lab cable (no address). Never treat it as eth0/eth1.
      if [ -z "$iface" ] || [ "$iface" = "veth-peer" ]; then
        echo "$svc has no interface for $ip" >&2
        continue
      fi
      # Leave a correct Docker address alone. Telling NetworkManager to drop
      # eth0 while Selkies is still starting keeps port 3001 closed.
      misplaced=""
      others=$(nsenter -t "$pid" -n ip -o -4 addr show 2>/dev/null | awk -v ip="$ip/" '$3 == "inet" && index($4, ip) == 1 { print $2 }')
      for other in $others; do
        other=$(iface_name "$other")
        if [ -n "$other" ] && [ "$other" != "$iface" ]; then
          misplaced=1
          nsenter -t "$pid" -n ip addr del "$ip/$prefix" dev "$other" || true
        fi
      done
      if ! nsenter -t "$pid" -n ip -o -4 addr show dev "$iface" 2>/dev/null | awk -v ip="$ip/" '$3 == "inet" && index($4, ip) == 1 { found = 1 } END { exit !found }'; then
        nsenter -t "$pid" -n ip link set "$iface" up 2>/dev/null
        nsenter -t "$pid" -n ip addr replace "$ip/$prefix" dev "$iface"
        echo "$svc $ip/$prefix restored on $iface"
      elif [ -n "$misplaced" ]; then
        echo "$svc $ip/$prefix moved back to $iface"
      elif [ -z "$quiet" ]; then
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

ensure_veth_network() {
  net=$1
  subnet=$2
  gw=$3
  case "$net" in
    cybersecurity-veth111|cybersecurity-veth0[1-9]|cybersecurity-veth[12][0-9]|cybersecurity-veth30)
      ;;
    *)
      echo "lab-veth.sh: refusing $net (only veth01–30 and veth111)" >&2
      return 1
      ;;
  esac
  case "$gw" in
    10.255.111.254|10.255.[1-9].254|10.255.[12][0-9].254|10.255.30.254)
      ;;
    *)
      echo "lab-veth.sh: refusing gateway $gw" >&2
      return 1
      ;;
  esac
  if docker network inspect "$net" >/dev/null 2>&1; then
    return 0
  fi
  # One attempt. Do not retry a failed create (veth00 used to loop 31 times).
  if docker network create \
    --driver bridge \
    --internal \
    --subnet "$subnet" \
    --gateway "$gw" \
    -o com.docker.network.bridge.enable_ip_masquerade=false \
    "$net" >/dev/null; then
    echo "created $net for Kata veth-peer"
    return 0
  fi
  echo "could not create $net; skip this pair" >&2
  return 1
}

on_veth_net() {
  cid=$1
  net=$2
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$cid" 2>/dev/null |
    grep -Fx "$net" >/dev/null
}

connect_veth_net() {
  svc=$1
  net=$2
  ipaddr=$3
  mac=$4
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    echo "skip $svc (not running)" >&2
    return 1
  fi
  if on_veth_net "$cid" "$net"; then
    return 0
  fi
  if docker network connect --ip "$ipaddr" --mac-address "$mac" "$net" "$cid" 2>/dev/null ||
     docker network connect --ip "$ipaddr" "$net" "$cid"; then
    echo "connected $svc to $net ($ipaddr) (Kata extra NIC / hotplug)"
    return 0
  fi
  echo "could not connect $svc to $net" >&2
  return 1
}

rename_guest_veth() {
  svc=$1
  mac=$2
  subnet=$3
  cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
  if [ -z "$cid" ]; then
    return 1
  fi
  if [ ! -f "$RENAME_VETH" ]; then
    echo "missing $RENAME_VETH" >&2
    return 1
  fi
  # docker exec on Kata runs in the guest, not the shim. stdin so this
  # works before the container is recreated onto the baked-in script.
  docker exec -i \
    -e "VETH_PEER_MAC=$mac" \
    -e "VETH_PEER_SUBNET=$subnet" \
    -e "VETH_PEER_WAIT=30" \
    "$cid" /bin/sh < "$RENAME_VETH"
}

pair_kata_veth() {
  kali=$1
  ubuntu=$2
  kpid=$3
  n=$(pair_num "$ubuntu") || return 0
  net=$(veth_net_name "$n") || return 0
  subnet=$(veth_subnet "$n")
  gw=$(veth_gw "$n")
  uip=$(veth_ubuntu_ip "$n")
  kip=$(veth_kali_ip "$n")
  umac=$(veth_ubuntu_mac "$n") || return 0
  kmac=$(veth_kali_mac "$n") || return 0
  kcid=$(docker compose ps -q "$kali" 2>/dev/null || true)
  if ! ensure_veth_network "$net" "$subnet" "$gw"; then
    return 0
  fi
  # Leftover runc host veth on Kali (peer netns died with the old Ubuntu).
  # Drop it so the Compose extra NIC can take the name veth-peer.
  if [ -n "$kpid" ] && has_veth "$kpid"; then
    if [ -z "$kcid" ] || ! on_veth_net "$kcid" "$net"; then
      nsenter -t "$kpid" -n ip link del veth-peer >/dev/null 2>&1 || true
    fi
  fi
  connect_veth_net "$ubuntu" "$net" "$uip" "$umac" || true
  connect_veth_net "$kali" "$net" "$kip" "$kmac" || true
  # Compose attach plus leftover host veth-peer: drop leftover so the extra NIC can take the name.
  if [ -n "$kpid" ] && has_veth "$kpid"; then
    extra=$(nsenter -t "$kpid" -n ip -4 -o addr show 2>/dev/null | awk -v pfx="10.255.${n}." '
      $2 == "lo" { next }
      index($4, pfx) == 1 {
        raw = $2
        gsub(/:$/, "", raw)
        sub(/@.*$/, "", raw)
        if (raw != "veth-peer") { print raw; exit }
      }
    ')
    if [ -n "$extra" ]; then
      nsenter -t "$kpid" -n ip link del veth-peer >/dev/null 2>&1 || true
    fi
  fi
  rename_guest_veth "$ubuntu" "$umac" "$subnet" || true
  rename_guest_veth "$kali" "$kmac" "$subnet" || true
  keep_kali_net "$kali" "$kpid" quiet
  if guest_has_veth "$ubuntu" && guest_has_veth "$kali"; then
    echo "$kali and $ubuntu are paired on veth-peer (Kata extra virtio NIC on $net)"
  else
    echo "$ubuntu Kata veth-peer is not in the guest yet; recreate $ubuntu, then re-run this script" >&2
  fi
}

restore_kali_peer_dns() {
  kali=$1
  n=$(pair_num "$kali") || return 0
  kmac=$(veth_kali_mac "$n") || kmac=""
  subnet=$(veth_subnet "$n")
  rename_guest_veth "$kali" "$kmac" "$subnet" || true
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
  else
    # Docker DNS 127.0.0.11 even if the Ubuntu peer is down (kali111 had
    # nameserver 192.168.200.1 with no route after ubuntu111 closed).
    keep_kali_net "$kali" "$kpid" quiet
    restore_kali_peer_dns "$kali"
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
    keep_kali_net "$kali" "$kpid" quiet
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
