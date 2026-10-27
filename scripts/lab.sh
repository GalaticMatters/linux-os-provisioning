#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
case "${1:-}" in
  on)
    exec docker compose --profile dns up -d
    ;;
  off)
    exec docker compose --profile dns stop
    ;;
  *)
    echo "usage: $0 on|off" >&2
    exit 2
    ;;
esac
