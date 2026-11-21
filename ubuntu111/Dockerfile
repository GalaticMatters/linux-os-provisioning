FROM lscr.io/linuxserver/webtop:ubuntu-xfce

# ubuntu111 only. ping is not in the webtop image. Bake it so a recreate
# still has `ping` even if apt is locked or Kata DNS is not ready yet.
# scripts/rename-veth-peer.sh and 99-packages also install it at start if missing.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iputils-ping \
  && rm -rf /var/lib/apt/lists/*
