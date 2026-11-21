#!/bin/sh
# ProLiant install of Kata Containers so ubuntu111 can use runtime:
# kata-runtime. Also patches host Kata networking (tcfilter, /etc copy of
# the QEMU runtime-rs config). Re-run after git pull; it does not download
# again when the shim is already there. Docker CE on Ubuntu, KVM/QEMU.
# Does not docker rm the fleet. Does not change Docker's default runtime
# (fleet stays runc). Does not start or recreate ubuntu111. Does not
# uninstall Sysbox. After this, from the repo:
#   docker compose up -d --force-recreate --no-deps ubuntu111
set -eu

KATA_VER=4.4.0
KATA_ARCH=amd64
KATA_TAR="kata-static-${KATA_VER}-${KATA_ARCH}.tar.zst"
KATA_SHA256=ccbc0cbc591089d0c57012b78da64b23ef43e0bac0f869dc7bfebe8588c33986
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VER}/${KATA_TAR}"
KATA_SHIM=/opt/kata/runtime-rs/bin/containerd-shim-kata-v2
KATA_PACKAGED_CONFIG=/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml
KATA_CONFIG=/etc/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml
DOCKER_RUNTIME=kata-runtime
# tcfilter is Kata's Docker model (veth in the shim netns → TAP in QEMU).
# macvtap is KATA_INTERNETWORKING=macvtap. Do not set none/disable_new_netns:
# that puts the TAP on the host and drops ubuntu111 off cybersecurity-desktop.

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
    echo "Docker is the Ubuntu snap ($docker_bin). Kata needs Docker CE at /usr/bin/docker." >&2
    exit 1
    ;;
esac

uname_m=$(uname -m)
if [ "$uname_m" != "x86_64" ]; then
  echo "This script pins the amd64 Kata tarball. Host arch is $uname_m." >&2
  exit 1
fi

docker_ver=$(docker info --format '{{.ServerVersion}}' 2>/dev/null || true)
docker_major=${docker_ver%%.*}
if [ -z "$docker_ver" ]; then
  echo "dockerd is not answering. Start Docker CE first." >&2
  exit 1
fi
if [ "$docker_major" -lt 26 ]; then
  echo "Docker $docker_ver is too old. Kata with runtimeType needs Docker 26+." >&2
  exit 1
fi

virt=$(systemd-detect-virt 2>/dev/null || true)
echo "systemd-detect-virt: ${virt:-unknown}"
if [ "$virt" != "none" ] && [ -n "$virt" ]; then
  echo "This host looks like a VM ($virt). Kata needs nested virtualization and /dev/kvm."
  echo "On the hypervisor: expose vmx/svm (host-passthrough or host-model) and enable nested KVM."
fi

if [ ! -e /dev/kvm ]; then
  if grep -q vmx /proc/cpuinfo; then
    modprobe kvm_intel || true
  elif grep -q svm /proc/cpuinfo; then
    modprobe kvm_amd || true
  fi
fi
if [ ! -e /dev/kvm ]; then
  echo "No /dev/kvm. Enable VT-x (vmx) or AMD-V (svm) in BIOS, or nested virt if this is a VM." >&2
  grep -E -o '(vmx|svm)' /proc/cpuinfo | sort -u >&2 || true
  ls -l /dev/kvm >&2 || true
  exit 1
fi
if ! grep -Eq 'vmx|svm' /proc/cpuinfo; then
  echo "CPU does not advertise vmx or svm. Kata will not start a QEMU guest." >&2
  exit 1
fi
echo "KVM: $(ls -l /dev/kvm)"
grep -E -o '(vmx|svm)' /proc/cpuinfo | sort -u | sed 's/^/CPU virt: /'

modprobe vhost_vsock || true
modprobe vhost_net || true
mkdir -p /etc/modules-load.d
if [ ! -f /etc/modules-load.d/kata-containers.conf ]; then
  printf '%s\n' vhost_vsock vhost_net > /etc/modules-load.d/kata-containers.conf
fi

default_rt=$(docker info --format '{{.DefaultRuntime}}' 2>/dev/null || true)
if [ -n "$default_rt" ] && [ "$default_rt" != "runc" ]; then
  echo "WARNING: Default Runtime is $default_rt, not runc. This script will not change it."
  echo "The fleet should stay on runc. Do not set default-runtime to kata-runtime."
fi

runtime_registered() {
  docker info --format '{{range $k, $_ := .Runtimes}}{{println $k}}{{end}}' 2>/dev/null \
    | grep -Fx "$DOCKER_RUNTIME" >/dev/null
}

patch_kata_network_config() {
  model=${KATA_INTERNETWORKING:-tcfilter}
  case "$model" in
    tcfilter|macvtap) ;;
    bridge)
      echo "Kata deprecated internetworking_model=bridge. Using tcfilter so ubuntu111 stays on the Docker desktop bridge."
      model=tcfilter
      ;;
    none)
      echo "internetworking_model=none needs disable_new_netns and a host TAP. ubuntu111 would leave cybersecurity-desktop." >&2
      exit 1
      ;;
    *)
      echo "KATA_INTERNETWORKING must be tcfilter or macvtap, got $model" >&2
      exit 1
      ;;
  esac
  mkdir -p /etc/kata-containers/runtime-rs
  if [ ! -f "$KATA_PACKAGED_CONFIG" ]; then
    echo "Packaged Kata config missing: $KATA_PACKAGED_CONFIG" >&2
    exit 1
  fi
  if [ ! -f "$KATA_CONFIG" ]; then
    cp -a "$KATA_PACKAGED_CONFIG" "$KATA_CONFIG"
  fi
  # Keep the /etc copy even if it already existed; only rewrite the two keys.
  if grep -qE '^[[:space:]]*#?[[:space:]]*internetworking_model[[:space:]]*=' "$KATA_CONFIG"; then
    sed -i -E "s/^[[:space:]]*#?[[:space:]]*internetworking_model[[:space:]]*=.*/internetworking_model = \"${model}\"/" "$KATA_CONFIG"
  else
    printf '\ninternetworking_model = "%s"\n' "$model" >> "$KATA_CONFIG"
  fi
  if grep -qE '^[[:space:]]*#?[[:space:]]*disable_new_netns[[:space:]]*=' "$KATA_CONFIG"; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*disable_new_netns[[:space:]]*=.*/disable_new_netns = false/' "$KATA_CONFIG"
  else
    printf '\ndisable_new_netns = false\n' >> "$KATA_CONFIG"
  fi
  echo "Kata networking: internetworking_model=${model} disable_new_netns=false"
  echo "Config: $KATA_CONFIG"
  grep -E '^(internetworking_model|disable_new_netns) ' "$KATA_CONFIG" || true
}

need_packages=0
command -v jq >/dev/null 2>&1 || need_packages=1
command -v zstd >/dev/null 2>&1 || need_packages=1
if [ "$need_packages" -eq 1 ] || [ ! -x "$KATA_SHIM" ] || [ ! -f "$KATA_PACKAGED_CONFIG" ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq zstd ca-certificates
fi

download() {
  url=$1
  dest=$2
  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$dest" "$url"
  else
    echo "Need wget or curl to download Kata" >&2
    return 1
  fi
}

if [ ! -x "$KATA_SHIM" ] || [ ! -f "$KATA_PACKAGED_CONFIG" ]; then
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT
  cd "$tmpdir"
  download "$KATA_URL" "$KATA_TAR"
  echo "${KATA_SHA256}  ${KATA_TAR}" | sha256sum -c
  # Official install: archive is rooted at /opt/kata/. Do not docker rm anything.
  tar --zstd -xf "$KATA_TAR" -C /
  cd /
  trap - EXIT
  rm -rf "$tmpdir"
fi

if [ ! -x "$KATA_SHIM" ]; then
  echo "Kata shim missing after install: $KATA_SHIM" >&2
  exit 1
fi
if [ ! -f "$KATA_PACKAGED_CONFIG" ]; then
  echo "Kata QEMU runtime-rs config missing: $KATA_PACKAGED_CONFIG" >&2
  exit 1
fi

patch_kata_network_config

daemon=/etc/docker/daemon.json
mkdir -p /etc/docker
if [ ! -s "$daemon" ]; then
  printf '%s\n' '{}' > "$daemon"
fi
merged=$(mktemp)
if ! jq --arg shim "$KATA_SHIM" --arg cfg "$KATA_CONFIG" --arg name "$DOCKER_RUNTIME" '
  if type != "object" then {} else . end
  | .runtimes = (.runtimes // {})
  | .runtimes[$name] = {
      runtimeType: $shim,
      options: { ConfigPath: $cfg }
    }
' "$daemon" > "$merged"; then
  echo "Could not merge $daemon." >&2
  rm -f "$merged"
  exit 1
fi
# Never write default-runtime. jq above only adds runtimes.kata-runtime.
daemon_changed=0
if ! cmp -s "$daemon" "$merged"; then
  cp -a "$daemon" "$daemon.bak-ubuntu111-kata"
  mv "$merged" "$daemon"
  daemon_changed=1
else
  rm -f "$merged"
fi

# Prefer reload so the fleet is not bounced. Kata docs restart dockerd if needed.
if [ "$daemon_changed" -eq 1 ] || ! runtime_registered; then
  if systemctl reload docker; then
    sleep 1
  fi
fi
if ! runtime_registered; then
  echo "Reload did not list ${DOCKER_RUNTIME}; restarting dockerd."
  echo "restart: unless-stopped brings other containers back. Do not compose-restart dnsmasq."
  systemctl restart docker
  n=0
  while [ "$n" -lt 30 ]; do
    if docker info >/dev/null 2>&1; then
      break
    fi
    n=$((n + 1))
    sleep 1
  done
fi

if ! runtime_registered; then
  echo "dockerd does not list ${DOCKER_RUNTIME}. Check $daemon, then: systemctl reload docker" >&2
  docker info | grep -i runtime >&2 || true
  exit 1
fi

echo "Kata Containers ${KATA_VER} is installed as Docker runtime ${DOCKER_RUNTIME}."
echo "Default runtime is unchanged (${default_rt:-runc}). Fleet stays runc."
docker info | grep -i runtime || true
echo "Recreate only ubuntu111 (do not restart dnsmasq; fleet Ubuntu stays runc):"
echo "  docker compose build ubuntu111"
echo "  docker compose up -d --force-recreate --no-deps ubuntu111"
echo "  sudo ./scripts/lab-veth.sh"
echo "Internet is expected after that recreate (guest DNS 1.1.1.1, default route on the desktop bridge)."
echo "Guest ip -br should list veth-peer (Kata extra virtio NIC on cybersecurity-veth111, peer kali111)."
echo "Sysbox is unused after that recreate. Uninstall is optional; this script does not remove it."
