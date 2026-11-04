#!/bin/sh
# Recreate every service labeled fleet.reset=true, then restart Caddy.
# Kali homes are tmpfs. Ubuntu keeps SSH host keys and accounts on the
# container writable layer. Recreate throws that layer away, so both fleets
# come back empty. The entrypoint writes the SSH user again from .env.
# Caddy's named volumes stay, so the internal CA does not change. Caddy is
# restarted, not recreated, so it re-resolves Kali container addresses.
set -eu

log() {
  printf '%s reset: %s\n' "$(date -Iseconds)" "$*"
}

if ! docker info >/dev/null 2>&1; then
  log "cannot talk to the Docker daemon. Mount /var/run/docker.sock into the scheduler."
  exit 1
fi

if [ "${RESET_INNER:-}" != "1" ]; then
  self=$(cat /etc/hostname)
  host_src=$(docker inspect "$self" --format '{{ range .Mounts }}{{ if eq .Destination "/workspace" }}{{ .Source }}{{ end }}{{ end }}')
  image=$(docker inspect "$self" --format '{{ .Config.Image }}')
  if [ -z "$host_src" ] || [ -z "$image" ]; then
    log "could not find the host path of /workspace on container $self"
    exit 1
  fi
  log "using project directory $host_src"
  # Host pid and net namespaces so the same script can put veth-peer back
  # after recreate. The cable lives in the container network namespace and
  # dies with it. kali111 and ubuntu111 are not recreated, so theirs stays.
  exec docker run --rm --name cybersecurity-reset \
    -e RESET_INNER=1 \
    -e TZ \
    --pid=host \
    --network=host \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$host_src:$host_src:ro" \
    -w "$host_src" \
    --entrypoint /usr/local/bin/reset-desktops.sh \
    "$image"
fi

compose_file=${COMPOSE_FILE:-compose.yaml}
if [ ! -f "$compose_file" ]; then
  log "compose file not found at $PWD/$compose_file"
  exit 1
fi

services=$(docker compose -f "$compose_file" config --format json | jq -r '
  .services
  | to_entries[]
  | select((.value.labels // {})["fleet.reset"] == "true")
  | .key
')

if [ -z "$services" ]; then
  log "no services labeled fleet.reset=true"
  exit 1
fi

set -f
set --
for svc in $services; do
  [ -n "$svc" ] || continue
  set -- "$@" "$svc"
done
set +f

log "recreating: $*"
docker compose -f "$compose_file" up -d --force-recreate --no-deps --renew-anon-volumes "$@"
log "restarting caddy so it re-resolves desktop addresses"
docker compose -f "$compose_file" restart caddy
if command -v ip >/dev/null 2>&1 && command -v nsenter >/dev/null 2>&1 && [ -x "$PWD/scripts/lab-veth.sh" ]; then
  log "adding veth-peer: kali01 with ubuntu01 through kali30 with ubuntu30"
  "$PWD/scripts/lab-veth.sh" || log "veth-peer was not added. Run: sudo ./scripts/lab-veth.sh"
else
  log "veth-peer was not added. Rebuild the scheduler image, or run: sudo ./scripts/lab-veth.sh"
fi
log "reset complete"
