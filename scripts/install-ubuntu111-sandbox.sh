#!/bin/sh
# One-time ProLiant install of Sysbox CE so ubuntu111 can use runtime: sysbox-runc.
# Does not docker rm the fleet. Does not change Docker's default runtime.
# Does not start or recreate ubuntu111. After this, from the repo:
#   docker compose up -d --force-recreate --no-deps ubuntu111
set -eu

SYSBOX_VER=0.7.1
SYSBOX_DEB="sysbox-ce_${SYSBOX_VER}.linux_amd64.deb"
SYSBOX_SHA256=9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5
SYSBOX_URL="https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VER}/${SYSBOX_DEB}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

docker_bin=$(command -v docker || true)
if [ -z "$docker_bin" ]; then
  echo "docker is not installed. Install Docker CE from Docker's apt repo first." >&2
  exit 1
fi
case "$docker_bin" in
  /snap/*)
    echo "Docker is the Ubuntu snap ($docker_bin). Sysbox needs Docker CE at /usr/bin/docker." >&2
    exit 1
    ;;
esac

if docker info 2>/dev/null | grep -E 'Runtimes:.*sysbox-runc' >/dev/null \
  && command -v sysbox-runc >/dev/null 2>&1; then
  echo "sysbox-runc is already registered. Default runtime stays whatever docker info reports."
  docker info | grep -i runtime || true
  exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cd "$tmpdir"

download() {
  url=$1
  dest=$2
  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  else
    echo "Need wget or curl to download Sysbox" >&2
    return 1
  fi
}

if ! download "$SYSBOX_URL" "$SYSBOX_DEB"; then
  echo "GitHub download failed; trying downloads.nestybox.com" >&2
  download \
    "https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VER}/sysbox-ce_${SYSBOX_VER}-0.linux_amd64.deb" \
    "$SYSBOX_DEB"
fi
echo "${SYSBOX_SHA256}  ${SYSBOX_DEB}" | sha256sum -c

apt-get update
apt-get install -y jq
# Do not docker rm the lab. The installer SIGHUPs dockerd to add sysbox-runc.
# If daemon.json lacks bip and default-address-pools, dockerd may restart;
# restart: unless-stopped brings those containers back.
DEBIAN_FRONTEND=noninteractive apt-get install -y "./${SYSBOX_DEB}"

if ! systemctl is-active --quiet sysbox; then
  echo "sysbox.service is not active" >&2
  systemctl status sysbox -n20 >&2 || true
  exit 1
fi

if ! docker info 2>/dev/null | grep -E 'Runtimes:.*sysbox-runc' >/dev/null; then
  echo "dockerd does not list sysbox-runc. Check /etc/docker/daemon.json, then: systemctl reload docker" >&2
  docker info | grep -i runtime >&2 || true
  exit 1
fi

echo "Sysbox CE ${SYSBOX_VER} is installed. Default runtime is unchanged."
docker info | grep -i runtime || true
echo "Recreate only ubuntu111 (do not restart dnsmasq):"
echo "  docker compose up -d --force-recreate --no-deps ubuntu111"
