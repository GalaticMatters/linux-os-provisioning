#!/bin/sh
# Each Kali/Ubuntu pair shares one private bridge. Inside every container the
# interface is named veth-peer. Ubuntu keeps 10.201.N.2 and answers DHCP.
# Kali flushes Docker's address and takes a lease, without touching DNS or
# the default route (those belong to the desktop and the macvlan LAN).
set +e

if ! command -v ip >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iproute2
fi
if ! command -v ip >/dev/null 2>&1; then
  echo "veth-peer: ip is missing" >&2
  exit 0
fi

name=$(hostname)
# dash treats 08 and 09 as invalid octal, so strip leading zeros without $((10#)).
num=$(printf '%s' "$name" | tr -cd '0-9')
while [ -n "$num" ] && [ "${num#0}" != "$num" ]; do
  num=${num#0}
done
if [ -z "$num" ]; then
  echo "veth-peer: hostname $name has no number" >&2
  exit 0
fi
prefix="10.201.${num}"

if ! ip link show veth-peer >/dev/null 2>&1; then
  dev=$(ip -4 -o addr show | awk -v pfx="$prefix." '$4 ~ "^" pfx {print $2; exit}')
  if [ -n "$dev" ]; then
    ip link set "$dev" down
    ip link set "$dev" name veth-peer
  fi
fi
if ! ip link show veth-peer >/dev/null 2>&1; then
  echo "veth-peer: interface is not attached" >&2
  exit 0
fi

ip addr flush dev veth-peer
ip link set veth-peer up

case "$name" in
  ubuntu*)
    if ! command -v dhcpd >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends isc-dhcp-server
    fi
    if ! command -v dhcpd >/dev/null 2>&1; then
      echo "veth-peer: dhcpd is not installed" >&2
      exit 0
    fi
    ip addr add "${prefix}.2/24" dev veth-peer
    mkdir -p /var/lib/dhcp /etc/dhcp /run
    touch /var/lib/dhcp/dhcpd.leases
    if id dhcpd >/dev/null 2>&1; then
      chown dhcpd:dhcpd /var/lib/dhcp /var/lib/dhcp/dhcpd.leases
    fi
    cat > /etc/dhcp/dhcpd.conf << EOF
default-lease-time 600;
max-lease-time 7200;
authoritative;
subnet ${prefix}.0 netmask 255.255.255.0 {
  range ${prefix}.50 ${prefix}.150;
}
EOF
    printf '%s\n' 'INTERFACESv4="veth-peer"' 'INTERFACESv6=""' > /etc/default/isc-dhcp-server
    if dhcpd -4 -q -cf /etc/dhcp/dhcpd.conf -lf /var/lib/dhcp/dhcpd.leases veth-peer; then
      echo "veth-peer: dhcpd on ${prefix}.2 for ${prefix}.50-${prefix}.150"
    else
      echo "veth-peer: dhcpd failed" >&2
    fi
    ;;
  kali*)
    if ! command -v dhclient >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends isc-dhcp-client
    fi
    if ! command -v dhclient >/dev/null 2>&1; then
      echo "veth-peer: dhclient is not installed" >&2
      exit 0
    fi
    cat > /run/lab-dhclient.conf << EOF
interface "veth-peer" {
  request subnet-mask, broadcast-address;
}
EOF
    dhclient -nw -cf /run/lab-dhclient.conf -lf /run/lab-dhclient.leases veth-peer
    echo "veth-peer: dhclient on veth-peer for ${prefix}.0/24"
    ;;
esac
exit 0
