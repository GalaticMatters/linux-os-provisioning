#!/bin/sh
# veth-peer is only the lab NIC. Docker may install the default route via
# 10.201.N.1 when that NIC is attached. Replies to ping and SSH then go into
# the lab bridge and never reach 10.0.253.11. Drop that default route.
# Do not add ip rules.
set +e

if ! command -v ip >/dev/null 2>&1; then
  exit 0
fi

ip -4 route show default | while read -r line; do
  gw=$(printf '%s\n' "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}')
  case "$gw" in
    10.201.*)
      # shellcheck disable=SC2086
      ip route del $line
      ;;
  esac
done

if ip -4 route show default | grep -q '^default '; then
  echo "default route: $(ip -4 route show default)"
  exit 0
fi

# Ubuntu servers have macvlan plus veth-peer. The LAN gateway is not .1.
if [ -n "${LAN_GATEWAY:-}" ]; then
  dev=$(ip -4 -o addr show scope global | awk '$4 ~ /^10\.0\.253\./ {print $2; exit}')
  if [ -n "$dev" ]; then
    ip route add default via "$LAN_GATEWAY" dev "$dev"
    echo "default route: $(ip -4 route show default)"
    exit 0
  fi
fi

# Desktops keep the compose bridge as the default route.
pair=$(ip -4 -o addr show scope global | awk '$2 != "veth-peer" && $4 !~ /^10\.0\.253\./ && $4 !~ /^10\.201\./ {print $2, $4; exit}')
if [ -z "$pair" ]; then
  echo "no default route to restore" >&2
  exit 0
fi
dev=$(printf '%s\n' "$pair" | awk '{print $1}')
cidr=$(printf '%s\n' "$pair" | awk '{print $2}')
ipaddr=${cidr%/*}
prefix=${cidr#*/}
case "$prefix" in
  8) gw=$(printf '%s\n' "$ipaddr" | awk -F. '{print $1".0.0.1"}') ;;
  16) gw=$(printf '%s\n' "$ipaddr" | awk -F. '{print $1"."$2".0.1"}') ;;
  24) gw=$(printf '%s\n' "$ipaddr" | awk -F. '{print $1"."$2"."$3".1"}') ;;
  *)
    echo "no default route to restore" >&2
    exit 0
    ;;
esac
ip route add default via "$gw" dev "$dev"
echo "default route: $(ip -4 route show default)"
exit 0
