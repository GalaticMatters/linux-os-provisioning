#!/bin/sh
# Recreate every desktop labeled desktop.lan.reset=true and restart Caddy.
# Homes are tmpfs, so recreate wipes them. Recreate also drops the container
# writable layer (packages installed outside /config). Caddy's named volumes
# stay, so the internal CA does not change. Caddy is restarted, not recreated,
# so it re-resolves desktop DNS without remounting its config.
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
  exec docker run --rm --name desktop-lan-reset \
    -e RESET_INNER=1 \
    -e TZ \
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
  | select((.value.labels // {})["desktop.lan.reset"] == "true")
  | .key
')

if [ -z "$services" ]; then
  log "no services labeled desktop.lan.reset=true"
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
log "reset complete"
