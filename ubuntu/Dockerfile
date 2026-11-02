FROM ubuntu:24.04

# openssh-server's postinst writes host keys into the image. Delete them so
# the entrypoint creates a fresh set on every container start. Recreate then
# wipes those keys with the rest of the writable layer.
# Ubuntu server, not a desktop. SSH stays. apt, ping, ip, and dhcpd are on the image.
# policy-rc.d stops the dhcpd postinst from starting during the build. The
# entrypoint starts dhcpd later, only when veth-peer is attached.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apt \
        openssh-server \
        ca-certificates \
        curl \
        iputils-ping \
        iproute2 \
        sudo \
        isc-dhcp-server \
    && rm -f /usr/sbin/policy-rc.d \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/sshd_config.d

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
