FROM ubuntu:24.04

# openssh-server's postinst writes host keys into the image. Delete them so
# the entrypoint creates a fresh set on every container start. Recreate then
# wipes those keys with the rest of the writable layer.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /etc/ssh/sshd_config.d

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
