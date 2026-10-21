#!/bin/sh
# Render dnsmasq.conf from the environment and stay in the foreground.
set -eu

require_ipv4() {
  name=$1
  value=$2
  case "$value" in
    ""|*[!0-9.]*)
      echo "$name must be an IPv4 address, got: ${value:-<empty>}" >&2
      exit 1
      ;;
  esac
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $value
  IFS=$old_ifs
  if [ "$#" -ne 4 ]; then
    echo "$name must be an IPv4 address, got: $value" >&2
    exit 1
  fi
  for octet in "$@"; do
    case "$octet" in
      ""|*[!0-9]*)
        echo "$name must be an IPv4 address, got: $value" >&2
        exit 1
        ;;
    esac
    # Reject leading zeros so values like 08 are not parsed as octal.
    if [ "${#octet}" -gt 1 ] && [ "${octet#0}" != "$octet" ]; then
      echo "$name must be an IPv4 address, got: $value" >&2
      exit 1
    fi
    if [ "$octet" -gt 255 ]; then
      echo "$name must be an IPv4 address, got: $value" >&2
      exit 1
    fi
  done
}

require_hostname() {
  name=$1
  value=$2
  case "$value" in
    ""|*[!A-Za-z0-9.-]*|*..*)
      echo "$name must look like desktop.lan, got: ${value:-<empty>}" >&2
      exit 1
      ;;
  esac
  first=${value%"${value#?}"}
  last=${value#"${value%?}"}
  if [ "$first" = "." ] || [ "$first" = "-" ] || [ "$last" = "." ] || [ "$last" = "-" ]; then
    echo "$name must look like desktop.lan, got: $value" >&2
    exit 1
  fi
}

require_ipv4 SERVER_IP "${SERVER_IP:-}"
require_ipv4 UPSTREAM_DNS_1 "${UPSTREAM_DNS_1:-1.1.1.1}"
require_ipv4 UPSTREAM_DNS_2 "${UPSTREAM_DNS_2:-1.0.0.1}"
require_hostname BASE_DOMAIN "${BASE_DOMAIN:-desktop.lan}"

case "$SERVER_IP" in
  0.0.0.0|127.*)
    echo "SERVER_IP must be this server's LAN address, not $SERVER_IP" >&2
    exit 1
    ;;
esac

sed \
  -e "s/__SERVER_IP__/${SERVER_IP}/g" \
  -e "s/__BASE_DOMAIN__/${BASE_DOMAIN}/g" \
  -e "s/__UPSTREAM_DNS_1__/${UPSTREAM_DNS_1}/g" \
  -e "s/__UPSTREAM_DNS_2__/${UPSTREAM_DNS_2}/g" \
  /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

dnsmasq --test -C /etc/dnsmasq.conf
exec dnsmasq -k -C /etc/dnsmasq.conf
