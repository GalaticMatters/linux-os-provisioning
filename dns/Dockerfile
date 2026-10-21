FROM alpine:3.22

RUN apk add --no-cache dnsmasq bind-tools

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY entrypoint.sh /usr/local/bin/dnsmasq-entrypoint.sh
RUN chmod 755 /usr/local/bin/dnsmasq-entrypoint.sh

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/usr/local/bin/dnsmasq-entrypoint.sh"]
