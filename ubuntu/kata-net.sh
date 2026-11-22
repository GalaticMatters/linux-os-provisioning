#!/bin/sh
# Kata guest networking for ubuntu01–30, ubuntuserver, vai, and any other
# box on this image. Docker's embedded DNS (127.0.0.11) lives in the shim
# netns, not in this VM. Compose gw_priority is not applied inside the VM.
# The pair extra NIC (10.255.N.0/24, later named veth-peer) is internal
# and must not be the default route.
# Do not apt-get. Do not delete apt locks. Always exit 0 so sshd still starts.
set -u

LAN_PREFIX="10.0.253."
VETH_PREFIX="10.255."
PUBLIC_DNS_1="${UPSTREAM_DNS_1:-1.1.1.1}"
PUBLIC_DNS_2="${UPSTREAM_DNS_2:-8.8.8.8}"
LAN_GW="${LAN_GATEWAY:-${SERVER_IP:-10.0.253.1}}"

iface_name() {
  name=$1
  name=${name%%@*}
  name=${name%:}
  printf '%s\n' "$name"
}

wait_for_nics() {
  n=0
  while [ "$n" -lt 50 ]; do
    if ip -4 -o addr show 2>/dev/null | awk '$2 != "lo" { found = 1 } END { exit !found }'; then
      return 0
    fi
    n=$((n + 1))
    sleep 0.2
  done
  echo "kata-net: no non-loopback IPv4 after wait (Docker may still be attaching)" >&2
  return 1
}

desktop_iface() {
  ip -4 -o addr show 2>/dev/null | while read -r _ name _ cidr _; do
    name=$(iface_name "$name")
    [ "$name" = "lo" ] && continue
    [ "$name" = "veth-peer" ] && continue
    case "$cidr" in
      ${LAN_PREFIX}*) continue ;;
      ${VETH_PREFIX}*) continue ;;
    esac
    printf '%s\n' "$name"
    return 0
  done
}

macvlan_iface() {
  ip -4 -o addr show 2>/dev/null | while read -r _ name _ cidr _; do
    name=$(iface_name "$name")
    [ "$name" = "lo" ] && continue
    case "$cidr" in
      ${LAN_PREFIX}*)
        printf '%s\n' "$name"
        return 0
        ;;
    esac
  done
}

gateway_on() {
  dev=$1
  via=$(ip -4 route show default dev "$dev" 2>/dev/null | awk '{ print $3; exit }')
  if [ -n "$via" ]; then
    printf '%s\n' "$via"
    return 0
  fi
  via=$(ip -4 route show dev "$dev" 2>/dev/null | awk '/^default/ { print $3; exit }')
  if [ -n "$via" ]; then
    printf '%s\n' "$via"
    return 0
  fi
  net=$(ip -4 route show dev "$dev" 2>/dev/null | awk '/proto kernel/ { print $1; exit }')
  [ -n "$net" ] || return 1
  network=${net%/*}
  IFS=. read -r a b c d <<EOF
$network
EOF
  printf '%s.%s.%s.%s\n' "$a" "$b" "$c" "$((d + 1))"
}

replace_resolv() {
  if [ ! -e /etc/resolv.conf ]; then
    return 0
  fi
  if ! grep -qE 'nameserver[[:space:]]+127\.0\.0\.11' /etc/resolv.conf 2>/dev/null; then
    echo "kata-net: resolv.conf is not Docker 127.0.0.11; leaving it"
    return 0
  fi
  tmp=/run/kata-resolv.conf
  {
    printf '%s\n' "nameserver ${PUBLIC_DNS_1}"
    if [ -n "$PUBLIC_DNS_2" ] && [ "$PUBLIC_DNS_2" != "$PUBLIC_DNS_1" ]; then
      printf '%s\n' "nameserver ${PUBLIC_DNS_2}"
    fi
    printf '%s\n' "options ndots:0"
  } > "$tmp"
  if printf '' >> /etc/resolv.conf 2>/dev/null; then
    cp "$tmp" /etc/resolv.conf
  else
    mount --bind "$tmp" /etc/resolv.conf || {
      echo "kata-net: could not replace 127.0.0.11 in resolv.conf" >&2
      return 0
    }
  fi
  echo "kata-net: DNS ${PUBLIC_DNS_1} ${PUBLIC_DNS_2} (127.0.0.11 is not in this VM)"
}

drop_veth_default() {
  ip -4 route show default 2>/dev/null | while read -r _ _ via _ dev rest; do
    [ "$dev" = "veth-peer" ] && ip route del default dev "$dev" 2>/dev/null || true
    case "$via" in
      10.255.*) ip route del default via "$via" 2>/dev/null || true ;;
    esac
  done
}

prefer_desktop_default() {
  desk=$(desktop_iface || true)
  mac=$(macvlan_iface || true)
  if [ -z "$desk" ]; then
    return 1
  fi
  ip link set "$desk" up || true
  gw=$(gateway_on "$desk" || true)
  if [ -z "$gw" ]; then
    echo "kata-net: desktop iface ${desk} has no gateway" >&2
    return 1
  fi
  current=$(ip -4 route show default 2>/dev/null | awk 'NR==1 { print $3; exit }')
  current_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }
  }')
  if [ "$current_dev" = "$desk" ] && [ "$current" = "$gw" ]; then
    echo "kata-net: default route already via ${gw} dev ${desk}"
    return 0
  fi
  ip route replace default via "$gw" dev "$desk" || true
  echo "kata-net: default route via ${gw} dev ${desk} (desktop bridge, Docker NAT)"
  if [ -n "$mac" ]; then
    ip link set "$mac" up || true
    ip route replace "${LAN_PREFIX}0/24" dev "$mac" || true
  fi
  return 0
}

ensure_macvlan_default() {
  mac=$(macvlan_iface || true)
  if [ -z "$mac" ]; then
    echo "kata-net: no macvlan IPv4 (10.0.253.0/24)" >&2
    return 0
  fi
  ip link set "$mac" up || true
  current_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }
  }')
  if [ "$current_dev" = "$mac" ]; then
    echo "kata-net: default route already on macvlan ${mac}"
    return 0
  fi
  gw=$(gateway_on "$mac" || true)
  if [ -z "$gw" ]; then
    gw=$LAN_GW
  fi
  ip route replace default via "$gw" dev "$mac" || true
  echo "kata-net: default route via ${gw} dev ${mac} (macvlan LAN)"
}

if ! command -v ip >/dev/null 2>&1; then
  echo "kata-net: ip is missing; skip" >&2
  exit 0
fi

wait_for_nics || true
drop_veth_default
if ! prefer_desktop_default; then
  ensure_macvlan_default
fi
replace_resolv
echo "kata-net: interfaces (veth-peer is unnumbered; LAN is 10.0.253.0/24)"
ip -br addr show || ip -br link show || true
ip -4 route show || true
cat /etc/resolv.conf || true
exit 0
