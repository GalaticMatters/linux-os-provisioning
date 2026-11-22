FROM ubuntu:24.04

# openssh-server's postinst writes host keys into the image. Delete them so
# the entrypoint creates a fresh set on every container start. Recreate then
# wipes those keys with the rest of the writable layer.
# Ubuntu server, not a desktop. SSH stays. apt, ping, and ip are on the image.
# nfs-kernel-server is installed for the student NFS lab. Do not start it
# here and do not export /sharedfolder: scripts/nfs-lab.sh (or the README)
# does that on one pair. policy-rc.d stops the postinst from trying to
# start nfsd during the build.
RUN printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        apt \
        openssh-server \
        ca-certificates \
        curl \
        iputils-ping \
        iproute2 \
        sudo \
        nfs-kernel-server \
        nfs-common \
        rpcbind \
    && rm -f /usr/sbin/policy-rc.d \
    && printf '%s\n' \
        '# Student NFS lab writes the export for one peer. Do not use *.' \
        '# /sharedfolder is created by scripts/nfs-lab.sh or by hand.' \
        > /etc/exports \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/sshd_config.d

# Build context is the repo root (compose: dockerfile ubuntu/Dockerfile).
COPY ubuntu/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY ubuntu/kata-net.sh /usr/local/bin/kata-net.sh
COPY scripts/rename-veth-peer.sh /usr/local/bin/rename-veth-peer.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/kata-net.sh /usr/local/bin/rename-veth-peer.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
