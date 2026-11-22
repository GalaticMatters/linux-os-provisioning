FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# ubuntu111 only (Kata). ping and sshd must be in the image so they survive
# recreate when apt is locked or Kata virtiofs skips bind-mounted scripts.
# Build context is the repo root (compose dockerfile: ubuntu111/Dockerfile).
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iputils-ping \
    openssh-server \
    iproute2 \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /run/sshd /custom-services.d /custom-cont-init.d /etc/udev/rules.d \
  && chmod 755 /run/sshd

COPY ubuntu/custom-services.d/sshd /custom-services.d/sshd
COPY scripts/rename-veth-peer.sh /custom-cont-init.d/97-veth-peer
COPY ubuntu/cont-init.d/98-kata-net /custom-cont-init.d/98-kata-net
COPY ubuntu/cont-init.d/99-packages /custom-cont-init.d/99-packages
COPY kali/cont-init.d/99-route-host /custom-cont-init.d/99-route-host
COPY ubuntu/udev/70-veth-peer.rules /etc/udev/rules.d/70-veth-peer.rules

RUN chmod 755 /custom-services.d/sshd /custom-cont-init.d/97-veth-peer \
      /custom-cont-init.d/98-kata-net /custom-cont-init.d/99-packages \
      /custom-cont-init.d/99-route-host
