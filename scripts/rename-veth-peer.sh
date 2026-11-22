#!/bin/sh
# Rename the ubuntu111/kali111 extra NIC to veth-peer and leave it bare.
# ubuntu111 is Kata: this runs in the QEMU guest (docker exec / cont-init),
# not in the shim netns. The NIC is the virtio endpoint for Compose network
# cybersecurity-veth111. kali111 is runc on that same bridge.
# Fleet kali01–30 / ubuntu01–30 do not mount this file.
# Do not apt-get. Do not delete apt locks.
set -eu

VETH_NAME=veth-peer
VETH_SUBNET="${VETH_PEER_SUBNET:-10.255.111.0/24}"
VETH_MAC=$(printf '%s' "${VETH_PEER_MAC:-}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

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
  echo "veth-peer: ${iface} is up with no address (ubuntu111 Kata extra NIC / kali111 pair)"
  ip -br link show "$VETH_NAME" 2>/dev/null || ip link show "$VETH_NAME" || true
}

if ! command -v ip >/dev/null 2>&1; then
  echo "veth-peer: ip is missing; skip" >&2
  exit 0
fi

iface=$(wait_for_peer || true)
if [ -z "$iface" ]; then
  echo "veth-peer: extra NIC not in this namespace yet (Compose network veth111 / hotplug)" >&2
  exit 0
fi

mac=$(mac_of "$iface")
write_udev "${VETH_MAC:-$mac}"
bare_peer "$iface" || true
