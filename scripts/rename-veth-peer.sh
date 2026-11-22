#!/bin/sh
# Rename the pair extra NIC to veth-peer and leave it bare.
# Ubuntu is Kata: this runs in the QEMU guest (docker exec / entrypoint /
# cont-init), not in the shim netns. The NIC is the virtio endpoint for
# Compose network cybersecurity-vethNN (or veth111). Kali is runc on that
# same bridge. Kata cannot take a host veth.
# Do not apt-get. Do not delete apt locks.
set -eu

hostname_pair() {
  h=$(hostname 2>/dev/null || true)
  case "$h" in
    kali111|ubuntu111)
      printf '%s\n' 111
      return 0
      ;;
    kali[0-9][0-9]|ubuntu[0-9][0-9])
      n=${h#kali}
      n=${n#ubuntu}
      # dash has no 10#; 00 is not a pair.
      case "$n" in
        0[1-9])
          printf '%s\n' "${n#0}"
          return 0
          ;;
        [12][0-9]|30)
          printf '%s\n' "$n"
          return 0
          ;;
      esac
      return 1
      ;;
  esac
  return 1
}

if [ -z "${VETH_PEER_MAC:-}" ] || [ -z "${VETH_PEER_SUBNET:-}" ]; then
  p=$(hostname_pair || true)
  if [ -n "$p" ]; then
    h=$(hostname 2>/dev/null || true)
    if [ "$p" -eq 111 ]; then
      : "${VETH_PEER_SUBNET:=10.255.111.0/24}"
      case "$h" in
        ubuntu*) : "${VETH_PEER_MAC:=02:42:ff:6f:01:01}" ;;
        *) : "${VETH_PEER_MAC:=02:42:ff:6f:02:02}" ;;
      esac
    else
      : "${VETH_PEER_SUBNET:=10.255.${p}.0/24}"
      tag=$(printf '%02d' "$p")
      case "$h" in
        ubuntu*) : "${VETH_PEER_MAC:=02:42:ff:00:${tag}:01}" ;;
        *) : "${VETH_PEER_MAC:=02:42:ff:00:${tag}:02}" ;;
      esac
    fi
  fi
fi

VETH_NAME=veth-peer
VETH_SUBNET="${VETH_PEER_SUBNET:-}"
VETH_MAC=$(printf '%s' "${VETH_PEER_MAC:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

if [ -z "$VETH_MAC" ] && [ -z "$VETH_SUBNET" ]; then
  echo "veth-peer: no pair extra NIC for this hostname; skip"
  exit 0
fi

iface_name() {
  name=$1
  name=${name%%@*}
  name=${name%:}
  printf '%s\n' "$name"
}

mac_of() {
  iface=$1
  ip -o link show dev "$iface" 2>/dev/null | awk '{
    for (i = 1; i <= NF; i++) if ($i == "link/ether") { print tolower($(i+1)); exit }
  }'
}

find_by_mac() {
  want=$1
  [ -n "$want" ] || return 1
  ip -o link show 2>/dev/null | awk -v want="$want" '
    BEGIN { want = tolower(want) }
    {
      raw = $2
      gsub(/:$/, "", raw)
      sub(/@.*$/, "", raw)
      if (raw == "lo") next
      mac = ""
      for (i = 1; i <= NF; i++) if ($i == "link/ether") mac = tolower($(i+1))
      if (mac == want) { print raw; exit }
    }
  '
}

find_by_subnet() {
  [ -n "$VETH_SUBNET" ] || return 1
  prefix=${VETH_SUBNET%/*}
  pfx=$(printf '%s' "$prefix" | awk -F. '{ print $1 "." $2 "." $3 "." }')
  ip -4 -o addr show 2>/dev/null | awk -v pfx="$pfx" '
    $2 == "lo" { next }
    index($4, pfx) == 1 {
      raw = $2
      gsub(/:$/, "", raw)
      sub(/@.*$/, "", raw)
      print raw
      exit
    }
  '
}

wait_for_peer() {
  # Cont-init runs before sshd. A long wait here delays port 22. lab-veth.sh
  # sets VETH_PEER_WAIT=30 after the guest is up.
  max=${VETH_PEER_WAIT:-8}
  n=0
  while [ "$n" -lt "$max" ]; do
    if ip link show "$VETH_NAME" >/dev/null 2>&1; then
      printf '%s\n' "$VETH_NAME"
      return 0
    fi
    found=""
    if [ -n "$VETH_MAC" ]; then
      found=$(find_by_mac "$VETH_MAC" || true)
    fi
    if [ -z "$found" ]; then
      found=$(find_by_subnet || true)
    fi
    if [ -n "$found" ]; then
      printf '%s\n' "$found"
      return 0
    fi
    n=$((n + 1))
    sleep 1
  done
  return 1
}

write_udev() {
  mac=$1
  [ -n "$mac" ] || return 0
  mkdir -p /etc/udev/rules.d
  printf '%s\n' \
    "SUBSYSTEM==\"net\", ACTION==\"add\", ATTR{address}==\"${mac}\", NAME=\"${VETH_NAME}\"" \
    >/etc/udev/rules.d/70-veth-peer.rules 2>/dev/null || true
}

is_kali_guest() {
  h=$(hostname 2>/dev/null || true)
  case "$h" in
    kali*) return 0 ;;
  esac
  return 1
}

# veth-peer is unnumbered. NM must not DHCP it, must not take its default
# route, and must not copy a nameserver off it (kali111 had stale
# 192.168.200.1, which is not a lab address; pair net is 10.255.111.0/24).
nm_peer_no_dns() {
  iface=$1
  mkdir -p /etc/NetworkManager/conf.d
  printf '%s\n' "[keyfile]" "unmanaged-devices=interface-name:${VETH_NAME}" \
    >/etc/NetworkManager/conf.d/veth-peer-unmanaged.conf 2>/dev/null || true
  if ! command -v nmcli >/dev/null 2>&1; then
    return 0
  fi
  nmcli device set "$iface" managed no >/dev/null 2>&1 || true
  nmcli device set "$VETH_NAME" managed no >/dev/null 2>&1 || true
  uuids=$(nmcli -t -f UUID,DEVICE connection show 2>/dev/null |
    awk -F: -v d="$iface" -v v="$VETH_NAME" '$2 == d || $2 == v { print $1 }') || true
  for uuid in $uuids; do
    [ -n "$uuid" ] || continue
    nmcli connection modify "$uuid" \
      ipv4.ignore-auto-dns yes \
      ipv4.never-default yes \
      ipv4.dns "" \
      ipv6.ignore-auto-dns yes \
      ipv6.never-default yes \
      ipv6.dns "" >/dev/null 2>&1 || true
  done
}

# Kali is runc: Docker DNS is 127.0.0.11. Do not run this in an Ubuntu
# Kata guest (127.0.0.11 is the shim, not the VM).
restore_kali_docker_dns() {
  is_kali_guest || return 0
  mkdir -p /etc/NetworkManager/conf.d
  printf '%s\n' "[main]" "dns=none" "rc-manager=unmanaged" \
    >/etc/NetworkManager/conf.d/90-docker-dns.conf 2>/dev/null || true
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload >/dev/null 2>&1 || true
  fi
  if command -v resolvectl >/dev/null 2>&1; then
    resolvectl revert "$VETH_NAME" >/dev/null 2>&1 || true
  fi
  if grep -qE 'nameserver[[:space:]]+127\.0\.0\.11' /etc/resolv.conf 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "nameserver 127.0.0.11" "options ndots:0" > /etc/resolv.conf 2>/dev/null || true
  echo "veth-peer: Kali DNS restored to Docker 127.0.0.11"
}

bare_peer() {
  iface=$1
  ip link set "$iface" down >/dev/null 2>&1 || true
  if [ "$iface" != "$VETH_NAME" ]; then
    if ip link show "$VETH_NAME" >/dev/null 2>&1; then
      echo "veth-peer: ${VETH_NAME} already exists; not renaming ${iface}" >&2
      iface=$VETH_NAME
    elif ! ip link set "$iface" name "$VETH_NAME"; then
      echo "veth-peer: could not rename ${iface} to ${VETH_NAME}" >&2
      return 1
    else
      iface=$VETH_NAME
    fi
  fi
  ip addr flush dev "$iface" 2>/dev/null || true
  ip -4 route del default dev "$iface" 2>/dev/null || true
  ip link set "$iface" up || true
  nm_peer_no_dns "$iface"
  echo "veth-peer: ${iface} is up with no address (Kata extra virtio NIC / pair peer)"
  ip -br link show "$VETH_NAME" 2>/dev/null || ip link show "$VETH_NAME" || true
}

if ! command -v ip >/dev/null 2>&1; then
  echo "veth-peer: ip is missing; skip" >&2
  restore_kali_docker_dns
  exit 0
fi

iface=$(wait_for_peer || true)
if [ -z "$iface" ]; then
  echo "veth-peer: extra NIC not in this namespace yet (Compose network vethNN / hotplug)" >&2
  restore_kali_docker_dns
  exit 0
fi

mac=$(mac_of "$iface")
write_udev "${VETH_MAC:-$mac}"
bare_peer "$iface" || true
restore_kali_docker_dns
