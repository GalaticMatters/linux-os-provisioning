#!/usr/bin/env python3
"""Render the fleet from .env.

Writes compose.yaml, caddy/Caddyfile, caddy/site/index.html, dns/records.conf,
and dns/hosts.example. Defaults are 30 Kali desktops and 30 Ubuntu SSH servers.
The example LAN is 10.0.253.0/24. The server and gateway are 10.0.253.1.
10.0.253.2 through 10.0.253.10 are reserved and are not assigned to Ubuntu.
ubuntu01 is 10.0.253.11 and ubuntu30 is 10.0.253.40. Kali names resolve to
10.0.253.1 and stay behind Caddy; they are not placed on the macvlan.
Re-run after changing KALI_COUNT, UBUNTU_COUNT, UBUNTU_IP_START, SERVER_IP, or BASE_DOMAIN.
"""

from __future__ import annotations

import argparse
import ipaddress
import sys
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise SystemExit(f"Missing env file: {path}")
    values: dict[str, str] = {}
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise SystemExit(f"{path}:{lineno}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
            value = value[1:-1]
        if not key:
            raise SystemExit(f"{path}:{lineno}: empty key")
        values[key] = value
    return values


def need(env: dict[str, str], key: str) -> str:
    value = env.get(key, "").strip()
    if not value:
        raise SystemExit(f"{key} is empty. Set it in the env file before rendering.")
    return value


def parse_count(env: dict[str, str], key: str, default: int) -> int:
    raw = env.get(key, str(default)).strip()
    try:
        count = int(raw, 10)
    except ValueError:
        raise SystemExit(f"{key} must be an integer from 1 to 99, got {raw!r}") from None
    if count < 1 or count > 99:
        raise SystemExit(f"{key} must be from 1 to 99 so names stay two digits, got {count}")
    return count


def ipv4(raw: str, key: str) -> ipaddress.IPv4Address:
    try:
        addr = ipaddress.ip_address(raw)
    except ValueError:
        raise SystemExit(f"{key} must be an IPv4 address, got {raw!r}") from None
    if not isinstance(addr, ipaddress.IPv4Address):
        raise SystemExit(f"{key} must be an IPv4 address, got {raw!r}")
    return addr


def hostname(raw: str, key: str) -> str:
    if not raw or len(raw) > 253:
        raise SystemExit(f"{key} must look like cybersecurity.lan, got {raw!r}")
    labels = raw.split(".")
    for label in labels:
        if not label or len(label) > 63:
            raise SystemExit(f"{key} must look like cybersecurity.lan, got {raw!r}")
        if label.startswith("-") or label.endswith("-"):
            raise SystemExit(f"{key} must look like cybersecurity.lan, got {raw!r}")
        for char in label:
            if char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-":
                raise SystemExit(f"{key} must look like cybersecurity.lan, got {raw!r}")
    return raw


def username(raw: str) -> str:
    if raw == "root" or len(raw) > 32:
        raise SystemExit("SSH_USER must be a lowercase account name other than root")
    if not raw[0].islower() and raw[0] != "_":
        raise SystemExit(f"SSH_USER must be a lowercase account name, got {raw!r}")
    for char in raw:
        if char not in "abcdefghijklmnopqrstuvwxyz0123456789_-":
            raise SystemExit(f"SSH_USER must be a lowercase account name, got {raw!r}")
    return raw


def iface(raw: str) -> str:
    message = (
        "PARENT_IFACE must be the NIC name of the interface which already has "
        f"10.0.253.1, got {raw!r}"
    )
    if not raw or len(raw) > 15:
        raise SystemExit(message)
    for char in raw:
        if char not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-":
            raise SystemExit(message)
    return raw


def ubuntu_ips(
    start: ipaddress.IPv4Address,
    count: int,
    subnet: ipaddress.IPv4Network,
    gateway: ipaddress.IPv4Address,
    server: ipaddress.IPv4Address,
) -> list[str]:
    reserved = {
        subnet.network_address,
        subnet.broadcast_address,
        gateway,
        server,
    }
    # 10.0.253.2 through 10.0.253.10 are reserved. Do not assign them to Ubuntu.
    for octet in range(2, 11):
        reserved.add(ipaddress.IPv4Address(f"10.0.253.{octet}"))
    chosen: list[str] = []
    for offset in range(count):
        try:
            addr = start + offset
        except ipaddress.AddressValueError:
            addr = None
        if not isinstance(addr, ipaddress.IPv4Address) or addr not in subnet or addr in reserved:
            raise SystemExit(
                "Ubuntu addresses do not fit. "
                f"Start {start}, count {count}, subnet {subnet}, "
                f"gateway {gateway}, SERVER_IP {server}. "
                "Pick a free UBUNTU_IP_START inside LAN_SUBNET that is not the gateway, "
                "SERVER_IP, or 10.0.253.2 through 10.0.253.10."
            )
        chosen.append(str(addr))
    return chosen


def fleet_names(prefix: str, count: int) -> list[str]:
    return [f"{prefix}{index:02d}" for index in range(1, count + 1)]


def render_compose(kali: list[str], ubuntu: list[tuple[str, str]]) -> str:
    lines = [
        "# Generated by scripts/render.py. Do not edit by hand.",
        f"# Kali desktops: {len(kali)}. Ubuntu SSH servers: {len(ubuntu)}.",
        "# Re-run the script after changing counts, UBUNTU_IP_START, or BASE_DOMAIN.",
        "# PARENT_IFACE, LAN_SUBNET, and LAN_GATEWAY are still read from .env when Compose starts.",
        "",
        "name: cybersecurity-lan",
        "",
        "x-logging: &json-logs",
        "  driver: json-file",
        "  options:",
        '    max-size: "10m"',
        '    max-file: "3"',
        "",
        "x-kali: &kali",
        "  image: lscr.io/linuxserver/kali-linux:latest",
        '  shm_size: "1gb"',
        "  restart: unless-stopped",
        "  stop_grace_period: 20s",
        "  environment:",
        "    PUID: ${PUID:-1000}",
        "    PGID: ${PGID:-1000}",
        "    TZ: ${TZ:-UTC}",
        "  tmpfs:",
        "    - /config:rw,nosuid,nodev,size=${DESKTOP_TMPFS_SIZE:-2g},mode=1777",
        "  labels:",
        '    fleet.reset: "true"',
        "  logging: *json-logs",
        "  healthcheck:",
        '    test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3001\'"]',
        "    interval: 30s",
        "    timeout: 5s",
        "    retries: 5",
        "    start_period: 180s",
        "",
        "x-ubuntu: &ubuntu",
        "  image: cybersecurity-ubuntu-ssh:1",
        "  build: ./ubuntu",
        "  restart: unless-stopped",
        "  stop_grace_period: 10s",
        "  environment:",
        '    SSH_USER: "${SSH_USER:?Set SSH_USER in .env}"',
        '    SSH_PUBLIC_KEY: "${SSH_PUBLIC_KEY:-}"',
        '    SSH_PASSWORD: "${SSH_PASSWORD:-}"',
        "    TZ: ${TZ:-UTC}",
        "  labels:",
        '    fleet.reset: "true"',
        "  logging: *json-logs",
        "  healthcheck:",
        '    test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/22\'"]',
        "    interval: 30s",
        "    timeout: 5s",
        "    retries: 5",
        "    start_period: 20s",
        "",
        "services:",
    ]
    for name in kali:
        lines += [
            f"  {name}:",
            "    <<: *kali",
            "    networks: [desktop]",
        ]
    for name, addr in ubuntu:
        lines += [
            f"  {name}:",
            "    <<: *ubuntu",
            "    networks:",
            "      lan:",
            f"        ipv4_address: {addr}",
        ]
    lines += [
        "  ubuntu100:",
        "    image: lscr.io/linuxserver/webtop:ubuntu-xfce",
        '    shm_size: "1gb"',
        "    restart: unless-stopped",
        "    stop_grace_period: 20s",
        "    environment:",
        "      PUID: ${PUID:-1000}",
        "      PGID: ${PGID:-1000}",
        "      TZ: ${TZ:-UTC}",
        "      TITLE: Ubuntu100",
        "    volumes:",
        "      - /var/lib/cybersecurity/ubuntu100:/config",
        "    networks: [desktop]",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3001\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 180s",
        "",
        "  ubuntu111:",
        "    image: lscr.io/linuxserver/webtop:ubuntu-xfce",
        '    shm_size: "1gb"',
        "    restart: unless-stopped",
        "    stop_grace_period: 20s",
        "    environment:",
        "      PUID: ${PUID:-1000}",
        "      PGID: ${PGID:-1000}",
        "      TZ: ${TZ:-UTC}",
        "      TITLE: Ubuntu111",
        "    volumes:",
        "      - ubuntu111-config:/config",
        "    networks: [desktop]",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3001\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 180s",
        "",
        "  caddy:",
        "    image: caddy:2.11.7-alpine",
        "    restart: unless-stopped",
        "    depends_on:",
    ]
    for name in kali + ["ubuntu100", "ubuntu111"]:
        lines.append(f"      - {name}")
    lines += [
        "    environment:",
        "      BASE_DOMAIN: ${BASE_DOMAIN:-cybersecurity.lan}",
        "      TZ: ${TZ:-UTC}",
        "    ports:",
        '      - "${HTTP_PORT:-80}:80"',
        '      - "${HTTPS_PORT:-443}:443"',
        "    volumes:",
        "      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro",
        "      - ./caddy/site:/srv:ro",
        "      - caddy-data:/data",
        "      - caddy-config:/config",
        "    networks: [desktop]",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "wget -S -O /dev/null http://127.0.0.1/ 2>&1 | grep -q 308"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 3",
        "      start_period: 10s",
        "",
        "  dnsmasq:",
        '    profiles: ["dns"]',
        "    build: ./dns",
        "    image: cybersecurity-dnsmasq:1",
        "    restart: unless-stopped",
        "    environment:",
        "      SERVER_IP: ${SERVER_IP:?Set SERVER_IP in .env to this server's LAN address}",
        "      BASE_DOMAIN: ${BASE_DOMAIN:-cybersecurity.lan}",
        "      UPSTREAM_DNS_1: ${UPSTREAM_DNS_1:-1.1.1.1}",
        "      UPSTREAM_DNS_2: ${UPSTREAM_DNS_2:-1.0.0.1}",
        "    ports:",
        '      - "${SERVER_IP}:${DNS_PORT:-53}:53/udp"',
        '      - "${SERVER_IP}:${DNS_PORT:-53}:53/tcp"',
        "    volumes:",
        "      - ./dns/records.conf:/records.conf:ro",
        "    networks: [desktop]",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "dig +short +time=2 +tries=1 kali01.$${BASE_DOMAIN} @127.0.0.1 | grep -qx \\"$$SERVER_IP\\""]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 3",
        "      start_period: 5s",
        "",
        "  scheduler:",
        "    build: ./scheduler",
        "    image: cybersecurity-scheduler:1",
        "    restart: unless-stopped",
        "    environment:",
        "      TZ: ${TZ:-UTC}",
        "    volumes:",
        "      - /var/run/docker.sock:/var/run/docker.sock",
        "      - ./:/workspace:ro",
        "    networks: [desktop]",
        "    logging: *json-logs",
        "",
        "  cloudflared:",
        '    profiles: ["public"]',
        "    image: cloudflare/cloudflared:latest",
        "    restart: unless-stopped",
        "    command: tunnel --no-autoupdate run",
        "    environment:",
        '      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:-}',
        "    networks: [desktop]",
        "    logging: *json-logs",
        "",
        "networks:",
        "  desktop:",
        "    name: cybersecurity-desktop",
        "  lan:",
        "    name: cybersecurity-macvlan",
        "    driver: macvlan",
        "    driver_opts:",
        "      parent: ${PARENT_IFACE:?Set PARENT_IFACE to the interface that already has 10.0.253.1}",
        "    ipam:",
        "      config:",
        "        - subnet: ${LAN_SUBNET:?Set LAN_SUBNET}",
        "          gateway: ${LAN_GATEWAY:?Set LAN_GATEWAY}",
        "",
        "volumes:",
        "  caddy-data:",
        "    name: cybersecurity-caddy-data",
        "  caddy-config:",
        "    name: cybersecurity-caddy-config",
        "  ubuntu111-config:",
        "    name: cybersecurity-ubuntu111-config",
        "",
    ]
    return "\n".join(lines)


def render_caddy(kali: list[str], desktops: list[str]) -> str:
    blocks = []
    for name in kali + desktops:
        blocks.append(
            "\n".join(
                [
                    f"{name}.{{$BASE_DOMAIN}} {{",
                    f"\timport desktop https://{name}:3001",
                    "}",
                ]
            )
        )
    header = """# Generated by scripts/render.py. Do not edit by hand.
# Browsers talk to Caddy on the server IP. Caddy routes by name to each Kali
# container over HTTPS on port 3001 (the Selkies HTTPS port). Port 3000 is the
# container HTTP port and is not used. The container certificate is self-signed,
# so this hop does not verify it. Browsers only see the Caddy internal CA.
# Ubuntu servers are not listed here; they are SSH on their own LAN addresses.
{
	local_certs
	admin off
	servers {
		protocols h1 h2
	}
}

(desktop) {
	reverse_proxy {args[0]} {
		header_up Host {host}
		header_up X-Real-IP {remote_host}
		transport http {
			tls_insecure_skip_verify
			resolvers 127.0.0.11
			dial_timeout 10s
			response_header_timeout 2m
		}
		# Stream the desktop socket; do not buffer it.
		flush_interval -1
	}
}

{$BASE_DOMAIN} {
	encode gzip
	header Cache-Control "no-store"
	@favicon path /favicon.ico
	handle @favicon {
		respond "" 204
	}
	handle {
		root * /srv
		file_server
	}
}

"""
    return header + "\n\n".join(blocks) + "\n"


def render_records(kali: list[str], ubuntu: list[tuple[str, str]]) -> str:
    lines = [
        "# Generated by scripts/render.py. Do not edit by hand.",
        "# Kali names and the apex use __SERVER_IP__, filled in when dnsmasq starts.",
        "# Ubuntu addresses are fixed here so they match the macvlan addresses in compose.yaml.",
        "# host-record is exact. address=/name/ is not used on the zone apex, because that",
        "# would also answer every subdomain and hide the Ubuntu records.",
        "host-record=__BASE_DOMAIN__,__SERVER_IP__",
    ]
    for name in kali + ["ubuntu100", "ubuntu111"]:
        lines.append(f"address=/{name}.__BASE_DOMAIN__/__SERVER_IP__")
    for name, addr in ubuntu:
        lines.append(f"address=/{name}.__BASE_DOMAIN__/{addr}")
    lines.append("")
    return "\n".join(lines)


def render_hosts(
    domain: str,
    server_ip: str,
    kali: list[str],
    ubuntu: list[tuple[str, str]],
) -> str:
    lines = [
        "# Generated by scripts/render.py. Workstation fallback when you cannot change DNS.",
        "# Append to /etc/hosts on each workstation. Re-run the script after changing",
        "# SERVER_IP, the domain, the counts, or UBUNTU_IP_START.",
        f"{server_ip} {domain}",
    ]
    for name in kali + ["ubuntu100", "ubuntu111"]:
        lines.append(f"{server_ip} {name}.{domain}")
    for name, addr in ubuntu:
        lines.append(f"{addr} {name}.{domain}")
    lines.append("")
    return "\n".join(lines)


def render_index(root: Path, domain: str, user: str, kali: list[str], ubuntu_count: int) -> str:
    template = (root / "caddy" / "index.template.html").read_text()
    items = []
    for name in kali + ["ubuntu100", "ubuntu111"]:
        items.append(
            "      "
            f'<li><a class="desk" data-name="{name}" href="https://{name}.{domain}/">'
            f'<span class="os">{name}</span>'
            f'<span class="host">{name}.{domain}</span></a></li>'
        )
    first = f"ubuntu01.{domain}"
    last = f"ubuntu{ubuntu_count:02d}.{domain}"
    blurb = (
        f"Ubuntu servers are not browser desktops. "
        f"Shell access is <code>ssh {user}@{first}</code> through <code>{last}</code>, port 22."
    )
    if "%%KALI_LINKS%%" not in template or "%%SSH_BLURB%%" not in template or "%%DESKTOP_BLURB%%" not in template:
        raise SystemExit("caddy/index.template.html is missing a render marker")
    html = template.replace("%%KALI_LINKS%%", "\n".join(items))
    html = html.replace("%%SSH_BLURB%%", blurb)
    html = html.replace(
        "%%DESKTOP_BLURB%%",
        "ubuntu100 and ubuntu111 are persistent Ubuntu desktops and are not wiped at 02:00. "
        f"ubuntu100 keeps its files on a 500 GB disk. Open them at "
        f"https://ubuntu100.{domain}/ and https://ubuntu111.{domain}/.",
    )
    return html


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def main() -> int:
    parser = argparse.ArgumentParser(description="Render the cybersecurity.lan fleet.")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--env-file", type=Path, default=None)
    args = parser.parse_args()
    root = args.root.resolve()
    env_path = args.env_file
    if env_path is None:
        env_path = root / ".env" if (root / ".env").is_file() else root / ".env.example"
    env = load_env(env_path)

    domain = hostname(need(env, "BASE_DOMAIN"), "BASE_DOMAIN")
    server = ipv4(need(env, "SERVER_IP"), "SERVER_IP")
    if str(server).startswith("127.") or str(server) == "0.0.0.0":
        raise SystemExit("SERVER_IP must be this server's LAN address")
    subnet_raw = need(env, "LAN_SUBNET")
    try:
        subnet = ipaddress.ip_network(subnet_raw, strict=True)
    except ValueError as exc:
        raise SystemExit(f"LAN_SUBNET must be a network like 10.0.253.0/24 ({exc})") from None
    if subnet.version != 4:
        raise SystemExit("LAN_SUBNET must be IPv4")
    gateway = ipv4(need(env, "LAN_GATEWAY"), "LAN_GATEWAY")
    if gateway not in subnet:
        raise SystemExit(f"LAN_GATEWAY {gateway} is outside {subnet}")
    start = ipv4(need(env, "UBUNTU_IP_START"), "UBUNTU_IP_START")
    iface(need(env, "PARENT_IFACE"))
    user = username(need(env, "SSH_USER"))
    kali_count = parse_count(env, "KALI_COUNT", 30)
    ubuntu_count = parse_count(env, "UBUNTU_COUNT", 30)
    kali = fleet_names("kali", kali_count)
    addresses = ubuntu_ips(start, ubuntu_count, subnet, gateway, server)
    ubuntu = list(zip(fleet_names("ubuntu", ubuntu_count), addresses))

    write(root / "compose.yaml", render_compose(kali, ubuntu))
    write(root / "caddy" / "Caddyfile", render_caddy(kali, ["ubuntu100", "ubuntu111"]))
    write(root / "caddy" / "site" / "index.html", render_index(root, domain, user, kali, ubuntu_count))
    write(root / "dns" / "records.conf", render_records(kali, ubuntu))
    write(root / "dns" / "hosts.example", render_hosts(domain, str(server), kali, ubuntu))
    print(
        f"Rendered {kali_count} Kali and {ubuntu_count} Ubuntu from {env_path}. "
        f"Ubuntu addresses {addresses[0]}-{addresses[-1]}."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
