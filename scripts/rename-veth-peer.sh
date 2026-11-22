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
      printf '%s\n' "$((10#$n))"
      return 0
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
  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "$iface" managed no >/dev/null 2>&1 || true
  fi
  mkdir -p /etc/NetworkManager/conf.d
  printf '%s\n' "[keyfile]" "unmanaged-devices=interface-name:${VETH_NAME}" \
    >/etc/NetworkManager/conf.d/veth-peer-unmanaged.conf 2>/dev/null || true
  echo "veth-peer: ${iface} is up with no address (Kata extra virtio NIC / pair peer)"
  ip -br link show "$VETH_NAME" 2>/dev/null || ip link show "$VETH_NAME" || true
}

if ! command -v ip >/dev/null 2>&1; then
  echo "veth-peer: ip is missing; skip" >&2
  exit 0
fi

iface=$(wait_for_peer || true)
if [ -z "$iface" ]; then
  echo "veth-peer: extra NIC not in this namespace yet (Compose network vethNN / hotplug)" >&2
  exit 0
fi

mac=$(mac_of "$iface")
write_udev "${VETH_MAC:-$mac}"
bare_peer "$iface" || true
