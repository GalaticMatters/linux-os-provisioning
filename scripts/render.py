#!/usr/bin/env python3
"""Render the fleet from .env.

Writes compose.yaml, caddy/Caddyfile, caddy/site/index.html, dns/records.conf,
and dns/hosts.example. Defaults are 30 Kali desktops and 30 Ubuntu SSH servers.
The example LAN is 10.0.253.0/24. The server is 10.0.253.1. The upstream
gateway 10.0.253.254 is not assigned to a container. 10.0.253.2 through
10.0.253.10 are reserved and are not assigned to Ubuntu. ubuntu01 is
10.0.253.11 and ubuntu30 is 10.0.253.40. ubuntuserver is 10.0.253.41.
ctfd is 10.0.253.43 (desktop + macvlan). vai is 10.0.253.42.
kali01–kali30 resolve to 10.0.253.1 for browsers and also take
10.0.253.55–84 on the macvlan, so a re-render keeps that block. They stay
on the desktop bridge for Caddy. kali111 and ubuntu111 are on that bridge
and on the macvlan at 10.0.253.50 and 10.0.253.51. ubuntu100, derek, and
vyas stay on the desktop bridge and macvlan at 10.0.253.52–54. derek,
sang, and ashraful are persistent Kali extra-containers (derek
10.0.253.53, sang 10.0.253.85, ashraful 10.0.253.86). vyas stays Linux Mint.
scripts/lab-veth.sh restores an address-less veth-peer for each Kali/Ubuntu
pair. Ubuntu (ubuntu01–30, ubuntu111, ubuntuserver, vai, ctfd) is Kata:
Compose network cybersecurity-vethNN is a Kata extra virtio NIC renamed
to veth-peer, paired with kaliNN. Kali stays runc. Kata cannot take a
host veth. veth-peer is not the path to 10.0.253.11.
Hosts entries on every Kali desktop and those persistent desktops map
ubuntuNN names to the Ubuntu macvlan addresses.
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
    fleet_kali: list[str] | None = None,
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
    # 10.0.253.50–54 belong to the persistent desktops. A re-render must not
    # hand those addresses to ubuntu01–ubuntu30.
    for _name, raw in PERSISTENT_DESKTOPS:
        reserved.add(ipv4(raw, _name))
    # 10.0.253.55 upward belongs to kali01–kali30. Do not hand it to Ubuntu.
    for raw in fleet_kali or []:
        reserved.add(ipv4(raw, "FLEET_KALI_IP_START"))
    # vai is a persistent SSH box at 10.0.253.42, next to ubuntuserver.
    reserved.add(ipv4(VAI_IP, "VAI_IP"))
    reserved.add(ipv4(CTFD_IP, "CTFD_IP"))
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
                "SERVER_IP, 10.0.253.2 through 10.0.253.10, the persistent "
                "desktop block 10.0.253.50 through 10.0.253.54, or the Kali "
                "fleet block that starts at 10.0.253.55."
            )
        chosen.append(str(addr))
    return chosen


def fleet_names(prefix: str, count: int) -> list[str]:
    return [f"{prefix}{index:02d}" for index in range(1, count + 1)]


# vai is a persistent Ubuntu SSH box, not a desktop. 10.0.253.42 sits beside
# ubuntuserver (.41) and outside ubuntu01–30 (.11–.40), the persistent
# desktops (.50–.54), the Kali fleet (.55–.84), sang (.85), and ashraful (.86).
VAI_IP = "10.0.253.42"
# ctfd is Kata Ubuntu (SSH + CTFd :8000) on desktop + macvlan. Next free
# after vai. Not a desktop. Flags live on the ubuntu100 disk.
CTFD_IP = "10.0.253.43"


# Persistent desktops that stay up across lab off. Each is on the Compose
# bridge `desktop` (Cloudflare and Caddy use the container name) and on the
# macvlan LAN at a fixed address. 10.0.253.50 upward: not .1, not the
# gateway .254, not .2–.10, and not .11–.41 (ubuntu01–ubuntu30 and ubuntuserver).
# kali01–kali30 use FLEET_KALI_IP_START and are not in this list.
PERSISTENT_DESKTOPS: list[tuple[str, str]] = [
    ("kali111", "10.0.253.50"),
    ("ubuntu111", "10.0.253.51"),
    ("ubuntu100", "10.0.253.52"),
    ("derek", "10.0.253.53"),
    ("vyas", "10.0.253.54"),
    ("sang", "10.0.253.85"),
    ("ashraful", "10.0.253.86"),
]

# Browser names Caddy serves on SERVER_IP, besides the kali01–kali30 fleet.
CADDY_LAN_DESKTOPS = ["kali111", "derek", "sang", "ashraful", "ubuntu100", "ubuntu111"]

# Pair extra NIC: one internal Docker bridge per kaliNN/ubuntuNN pair, plus
# kali111/ubuntu111. Docker assigns a placeholder IP; rename-veth-peer.sh
# strips it so the guest name is veth-peer with no address. Ubuntu is Kata
# (virtio hotplug). Kali is runc on the same bridge. Kata cannot take a
# host veth. ubuntuserver and vai have no pair network.
VETH111_NET = "cybersecurity-veth111"
VETH111_SUBNET = "10.255.111.0/24"
VETH111_GW = "10.255.111.254"
VETH111_UBUNTU_IP = "10.255.111.1"
VETH111_KALI_IP = "10.255.111.2"
VETH111_UBUNTU_MAC = "02:42:ff:6f:01:01"
VETH111_KALI_MAC = "02:42:ff:6f:02:02"


def veth_pair(n: int) -> dict[str, str]:
    """Compose extra-NIC parameters for kaliN/ubuntuN (N is 1–30 or 111)."""
    if n == 111:
        return {
            "n": "111",
            "key": "veth111",
            "name": VETH111_NET,
            "subnet": VETH111_SUBNET,
            "gw": VETH111_GW,
            "ubuntu_ip": VETH111_UBUNTU_IP,
            "kali_ip": VETH111_KALI_IP,
            "ubuntu_mac": VETH111_UBUNTU_MAC,
            "kali_mac": VETH111_KALI_MAC,
        }
    tag = f"{n:02d}"
    return {
        "n": str(n),
        "key": f"veth{tag}",
        "name": f"cybersecurity-veth{tag}",
        "subnet": f"10.255.{n}.0/24",
        "gw": f"10.255.{n}.254",
        "ubuntu_ip": f"10.255.{n}.1",
        "kali_ip": f"10.255.{n}.2",
        "ubuntu_mac": f"02:42:ff:00:{tag}:01",
        "kali_mac": f"02:42:ff:00:{tag}:02",
    }


def render_veth_network(pair: dict[str, str]) -> list[str]:
    return [
        f"  {pair['key']}:",
        f"    name: {pair['name']}",
        "    driver: bridge",
        "    internal: true",
        "    enable_ipv6: false",
        "    driver_opts:",
        '      com.docker.network.bridge.enable_ip_masquerade: "false"',
        "    ipam:",
        "      config:",
        f"        - subnet: {pair['subnet']}",
        f"          gateway: {pair['gw']}",
        "",
    ]


def fleet_pair_nums(kali: list[str], ubuntu: list[tuple[str, str]]) -> list[int]:
    nums: set[int] = set()
    for name in kali:
        if name.startswith("kali"):
            nums.add(int(name[4:], 10))
    for name, _addr in ubuntu:
        if name.startswith("ubuntu"):
            nums.add(int(name[6:], 10))
    return sorted(n for n in nums if n != 111)


def persistent_addr(name: str) -> str:
    for desktop, addr in PERSISTENT_DESKTOPS:
        if desktop == name:
            return addr
    raise SystemExit(f"{name} has no macvlan address in PERSISTENT_DESKTOPS")


def check_persistent_desktops(
    subnet: ipaddress.IPv4Network,
    gateway: ipaddress.IPv4Address,
    server: ipaddress.IPv4Address,
    ubuntu_addrs: list[str],
    server_box: str,
) -> None:
    forbidden: set[ipaddress.IPv4Address] = {
        subnet.network_address,
        subnet.broadcast_address,
        gateway,
        server,
        ipaddress.IPv4Address("10.0.253.1"),
        ipaddress.IPv4Address("10.0.253.254"),
    }
    for octet in range(2, 42):
        forbidden.add(ipaddress.IPv4Address(f"10.0.253.{octet}"))
    for raw in ubuntu_addrs:
        forbidden.add(ipv4(raw, "UBUNTU_IP_START"))
    forbidden.add(ipv4(server_box, "UBUNTU_SERVER_IP"))
    forbidden.add(ipv4(VAI_IP, "VAI_IP"))
    forbidden.add(ipv4(CTFD_IP, "CTFD_IP"))
    seen: set[ipaddress.IPv4Address] = set()
    for name, raw in PERSISTENT_DESKTOPS:
        addr = ipv4(raw, name)
        if addr not in subnet or addr in forbidden or addr in seen:
            raise SystemExit(
                f"{name} address {addr} is not a free macvlan address. "
                "Persistent desktops use 10.0.253.50 upward, outside "
                "10.0.253.1, the gateway 10.0.253.254, 10.0.253.2-10, "
                "and 10.0.253.11-41."
            )
        seen.add(addr)


# kali01–kali30. One address each, starting at 10.0.253.55 (kali30 is
# 10.0.253.84). Outside 10.0.253.1, .2–.10, .11–.41, .50–.54, and the
# gateway 10.0.253.254. A re-render keeps this start address.
FLEET_KALI_IP_START = "10.0.253.55"


def fleet_kali_addresses(count: int) -> list[str]:
    start = ipv4(FLEET_KALI_IP_START, "FLEET_KALI_IP_START")
    chosen: list[str] = []
    for offset in range(count):
        try:
            addr = start + offset
        except ipaddress.AddressValueError:
            addr = None
        if not isinstance(addr, ipaddress.IPv4Address):
            raise SystemExit(
                f"Kali fleet address {FLEET_KALI_IP_START}+{offset} does not fit. "
                "kali01 starts at 10.0.253.55."
            )
        chosen.append(str(addr))
    return chosen


def check_fleet_kali(
    addrs: list[str],
    subnet: ipaddress.IPv4Network,
    gateway: ipaddress.IPv4Address,
    server: ipaddress.IPv4Address,
    ubuntu_addrs: list[str],
    server_box: str,
) -> None:
    forbidden: set[ipaddress.IPv4Address] = {
        subnet.network_address,
        subnet.broadcast_address,
        gateway,
        server,
        ipaddress.IPv4Address("10.0.253.1"),
        ipaddress.IPv4Address("10.0.253.254"),
    }
    for octet in range(2, 42):
        forbidden.add(ipaddress.IPv4Address(f"10.0.253.{octet}"))
    for name, raw in PERSISTENT_DESKTOPS:
        forbidden.add(ipv4(raw, name))
    for raw in ubuntu_addrs:
        forbidden.add(ipv4(raw, "UBUNTU_IP_START"))
    forbidden.add(ipv4(server_box, "UBUNTU_SERVER_IP"))
    forbidden.add(ipv4(VAI_IP, "VAI_IP"))
    forbidden.add(ipv4(CTFD_IP, "CTFD_IP"))
    seen: set[ipaddress.IPv4Address] = set()
    for index, raw in enumerate(addrs, 1):
        addr = ipv4(raw, f"kali{index:02d}")
        if addr not in subnet or addr in forbidden or addr in seen:
            raise SystemExit(
                f"kali{index:02d} address {addr} is not a free macvlan address. "
                "The Kali fleet starts at 10.0.253.55 "
                "(kali01–kali30 are 10.0.253.55–84), outside 10.0.253.1, "
                "10.0.253.2-10, 10.0.253.11-41, and 10.0.253.50-54."
            )
        seen.add(addr)


def dual_lan(
    addr: str,
    extra_hosts: str = "*lab-hosts",
    veth111_ip: str | None = None,
    veth111_mac: str | None = None,
) -> list[str]:
    """Bridge plus macvlan. The bridge keeps the default route.

    Cloudflare and Caddy resolve the container name on `desktop`.
    gw_priority on that network keeps internet and container-name traffic
    there. The macvlan connected route covers 10.0.253.0/24, so ping and
    SSH to the Ubuntu fleet leave on the LAN interface.
    veth111 is the ubuntu111 Kata extra NIC (kali111 peer).
    """
    lines = [
        f"    extra_hosts: {extra_hosts}",
        "    networks:",
        "      desktop:",
        "        gw_priority: 100",
        "      lan:",
        f"        ipv4_address: {addr}",
    ]
    if veth111_ip:
        lines += [
            "      veth111:",
            f"        ipv4_address: {veth111_ip}",
            f'        mac_address: "{veth111_mac}"',
        ]
    return lines


def lab_host_entries(
    domain: str,
    server: str,
    kali: list[str],
    ubuntu: list[tuple[str, str]],
    extra: list[tuple[str, str]],
) -> list[str]:
    """Hosts entries so a desktop resolves names without dnsmasq on 10.0.253.1.

    A macvlan endpoint does not reach the parent address, so these
    containers do not use dnsmasq there. Kali FQDNs point at SERVER_IP
    (Caddy). Short kali01 stays off this list so Docker DNS still finds
    the container for Caddy's https://kali01:3001 hop. Ubuntu short names
    and FQDNs both point at the macvlan address.
    """
    entries = [f"{domain}:{server}"]
    for name in kali + CADDY_LAN_DESKTOPS:
        entries.append(f"{name}.{domain}:{server}")
    for name, addr in list(ubuntu) + list(extra):
        entries.append(f"{name}.{domain}:{addr}")
        entries.append(f"{name}:{addr}")
    return entries


def lab_host_lines(
    domain: str,
    server: str,
    kali: list[str],
    ubuntu: list[tuple[str, str]],
    extra: list[tuple[str, str]],
) -> list[str]:
    entries = lab_host_entries(domain, server, kali, ubuntu, extra)
    lines = ["x-lab-hosts: &lab-hosts"]
    for item in entries:
        lines.append(f'  - "{item}"')
    # Kata guest cannot use Docker 127.0.0.11. Short names of the other
    # persistent desktops go to their macvlan addresses. kali111 still
    # uses *lab-hosts, so Docker DNS keeps http://ubuntu111:3000 on the
    # desktop bridge for Cloudflare and kali111.
    lines.append("x-ubuntu111-hosts: &ubuntu111-hosts")
    for name, addr in PERSISTENT_DESKTOPS:
        if name == "ubuntu111":
            continue
        lines.append(f'  - "{name}:{addr}"')
    for item in entries:
        lines.append(f'  - "{item}"')
    lines.append("")
    return lines


def render_persistent_kali(
    name: str,
    title: str,
    user_var: str = "DESKTOP_USER",
    password_var: str = "DESKTOP_PASSWORD",
    default_user: str = "van",
    require_password: bool = False,
    veth111: bool = False,
) -> list[str]:
    """Persistent Kali desktop on desktop + macvlan. No fleet.reset label.

    linuxserver Selkies only shows the browser login when PASSWORD is
    non-empty. CUSTOM_USER alone does nothing. An empty interpolates to
    PASSWORD= and the desktop opens with no prompt.
    veth111 is kali111 only (peer of Kata ubuntu111). derek/sang/ashraful
    stay off that network. Fleet kali01–30 attach in the fleet loop.
    """
    if require_password:
        password_line = (
            f'      PASSWORD: "${{{password_var}:?Set {password_var} in .env}}"'
        )
    else:
        password_line = f"      PASSWORD: ${{{password_var}:-}}"
    env_extra: list[str] = []
    vol_extra: list[str] = []
    veth_ip = None
    veth_mac = None
    if veth111:
        env_extra = [
            f"      VETH_PEER_MAC: {VETH111_KALI_MAC}",
            f"      VETH_PEER_SUBNET: {VETH111_SUBNET}",
        ]
        vol_extra = [
            "      - ./scripts/rename-veth-peer.sh:/custom-cont-init.d/97-veth-peer:ro",
        ]
        veth_ip = VETH111_KALI_IP
        veth_mac = VETH111_KALI_MAC
    return [
        f"  {name}:",
        f"    hostname: {name}",
        "    image: lscr.io/linuxserver/kali-linux:latest",
        "    mem_limit: 4g",
        '    shm_size: "1gb"',
        "    restart: unless-stopped",
        "    stop_grace_period: 20s",
        "    cap_add:",
        "      - NET_ADMIN",
        "    environment:",
        "      PUID: ${PUID:-1000}",
        "      PGID: ${PGID:-1000}",
        "      TZ: ${TZ:-UTC}",
        "      SERVER_IP: ${SERVER_IP:-10.0.253.1}",
        f"      CUSTOM_USER: ${{{user_var}:-{default_user}}}",
        password_line,
        f"      TITLE: {title}",
        *env_extra,
        "    volumes:",
        f"      - {name}-config:/config",
        "      - ./kali/cont-init.d/99-ping:/custom-cont-init.d/99-ping:ro",
        "      - ./kali/cont-init.d/99-route-host:/custom-cont-init.d/99-route-host:ro",
        *vol_extra,
        *dual_lan(persistent_addr(name), veth111_ip=veth_ip, veth111_mac=veth_mac),
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3000\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 180s",
        "",
    ]


def render_mint(name: str) -> list[str]:
    """Persistent Linux Mint Cinnamon desktop served over HTTP. No fleet.reset label.

    vyas uses VYAS_USER / VYAS_PASSWORD. derek is Kali, not Mint.
    The browser origin is http://<name>:3000. RDP is not the public path.
    privileged stays so systemd can start the session. No cgroup: host
    and no host /sys/fs/cgroup mount: that namespace exits this container
    when another container stops. The container stays on `desktop` and
    also takes its fixed macvlan address.
    """
    key = name.upper()
    return [
        f"  {name}:",
        "    image: dockerscripts/linuxmint:cinnamon",
        "    mem_limit: 4g",
        '    shm_size: "1gb"',
        "    privileged: true",
        "    restart: unless-stopped",
        "    stop_grace_period: 30s",
        "    environment:",
        "      TZ: ${TZ:-UTC}",
        f"      MINT_USER: ${{{key}_USER:-{name}}}",
        f"      MINT_PASSWORD: ${{{key}_PASSWORD:-}}",
        '    entrypoint: ["/bin/bash", "/mint-entrypoint.sh"]',
        "    volumes:",
        f"      - {name}-config:/home/${{{key}_USER:-{name}}}",
        "      - ./mint/entrypoint.sh:/mint-entrypoint.sh:ro",
        "    tmpfs:",
        "      - /run",
        "      - /run/lock",
        "      - /tmp",
        *dual_lan(persistent_addr(name)),
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3000\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 300s",
        "",
    ]


def render_compose(
    kali: list[str],
    ubuntu: list[tuple[str, str]],
    domain: str,
    extra: list[tuple[str, str]],
    server: str,
) -> str:
    desktop_note = ", ".join(f"{name} {addr}" for name, addr in PERSISTENT_DESKTOPS)
    kali_addrs = fleet_kali_addresses(len(kali))
    lines = [
        "# Generated by scripts/render.py. Do not edit by hand.",
        f"# Kali desktops: {len(kali)}. Ubuntu SSH servers: {len(ubuntu)}.",
        "# Persistent Mint desktop vyas is not part of the fleet reset.",
        "# Every service has mem_limit 4g. That is a ceiling, not a reservation.",
        f"# {kali[0]} is {kali_addrs[0]} and {kali[-1]} is {kali_addrs[-1]} on desktop and macvlan.",
        "# Caddy still reaches each kaliNN by container name on the desktop bridge.",
        f"# Persistent desktops on desktop and macvlan: {desktop_note}.",
        "# kali111, derek, sang, ashraful, and ubuntu111 are on the desktop bridge with cloudflared and on macvlan.",
        "# Ubuntu (ubuntu01–30, ubuntu111, ubuntuserver, vai, ctfd) is Kata: runtime kata-runtime.",
        "# Kali stays runc. Do not set Docker default-runtime to kata-runtime.",
        "# Pair veth-peer is Compose network vethNN (extra virtio NIC on Ubuntu, extra",
        "# Docker NIC on Kali). Kata cannot take a host veth. ubuntuserver, vai, and ctfd have none.",
        "# Kata guest DNS cannot use Docker 127.0.0.11. ubuntu111 extra_hosts maps kali111",
        "# (and the other persistent desktops) to macvlan. Cloudflare still uses Docker DNS",
        "# on the desktop bridge for http://ubuntu111:3000.",
        "# extra_hosts maps kali FQDNs to SERVER_IP (Caddy) and ubuntuNN to the macvlan address.",
        "# The desktop bridge keeps the default route so Caddy still reaches kaliNN:3001.",
        "# scripts/lab-veth.sh restores veth-peer (rename/flush) after recreate; no host veth.",
        "# Cloudflare still opens",
        "# http://kali111:3000, http://derek:3000, http://sang:3000, http://ashraful:3000, and http://ubuntu111:3000.",
        "# vyas stays http://vyas:3000. ctfd is http://ctfd:8000 on desktop (Cloudflare), SSH on 10.0.253.43.",
        "# cloudflared reaches the ProLiant sshd as host.docker.internal:22.",
        "# Public SSH into ctfd is ssh-ctfd.research101.stream -> ssh://ctfd:22 (dashboard, not Compose).",
        "# Re-run the script after changing counts, UBUNTU_IP_START, or BASE_DOMAIN.",
        "# PARENT_IFACE, LAN_SUBNET, and LAN_GATEWAY are still read from .env when Compose starts.",
        "",
        "name: cybersecurity-lan",
        "",
        *lab_host_lines(domain, server, kali, ubuntu, extra),
        "x-logging: &json-logs",
        "  driver: json-file",
        "  options:",
        '    max-size: "10m"',
        '    max-file: "3"',
        "",
        "x-kali: &kali",
        "  image: lscr.io/linuxserver/kali-linux:latest",
        "  mem_limit: 4g",
        '  shm_size: "1gb"',
        "  restart: unless-stopped",
        "  stop_grace_period: 20s",
        "  cap_add:",
        "    - NET_ADMIN",
        "  environment:",
        "    PUID: ${PUID:-1000}",
        "    PGID: ${PGID:-1000}",
        "    TZ: ${TZ:-UTC}",
        "  tmpfs:",
        "    - /config:rw,nosuid,nodev,size=${DESKTOP_TMPFS_SIZE:-2g},mode=1777",
        "  volumes:",
        "    - ./kali/cont-init.d/99-ping:/custom-cont-init.d/99-ping:ro",
        "    - ./scripts/rename-veth-peer.sh:/custom-cont-init.d/97-veth-peer:ro",
        "  labels:",
        '    fleet.reset: "true"',
        "  extra_hosts: *lab-hosts",
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
        "  mem_limit: 4g",
        "  runtime: kata-runtime",
        "  build:",
        "    context: .",
        "    dockerfile: ubuntu/Dockerfile",
        "  restart: unless-stopped",
        "  stop_grace_period: 10s",
        "  cap_add:",
        "    - NET_ADMIN",
        "  environment:",
        '    SSH_USER: "${SSH_USER:?Set SSH_USER in .env}"',
        '    SSH_PUBLIC_KEY: "${SSH_PUBLIC_KEY:-}"',
        '    SSH_PASSWORD: "${SSH_PASSWORD:-}"',
        "    TZ: ${TZ:-UTC}",
        "    LAN_GATEWAY: ${LAN_GATEWAY:-10.0.253.1}",
        "    UPSTREAM_DNS_1: ${UPSTREAM_DNS_1:-1.1.1.1}",
        "    UPSTREAM_DNS_2: ${UPSTREAM_DNS_2:-8.8.8.8}",
        "  labels:",
        '    fleet.reset: "true"',
        "  logging: *json-logs",
        "  healthcheck:",
        '    test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/22\'"]',
        "    interval: 30s",
        "    timeout: 5s",
        "    retries: 5",
        "    start_period: 60s",
        "",
        "services:",
    ]
    for name, addr in zip(kali, kali_addrs):
        pair = veth_pair(int(name[4:], 10))
        lines += [
            f"  {name}:",
            "    hostname: " + name,
            "    <<: *kali",
            "    networks:",
            "      desktop:",
            "        gw_priority: 100",
            "      lan:",
            f"        ipv4_address: {addr}",
            f"      {pair['key']}:",
            f"        ipv4_address: {pair['kali_ip']}",
            f'        mac_address: "{pair["kali_mac"]}"',
        ]
    for name, addr in ubuntu:
        pair = veth_pair(int(name[6:], 10))
        lines += [
            f"  {name}:",
            "    hostname: " + name,
            "    <<: *ubuntu",
            "    networks:",
            "      lan:",
            f"        ipv4_address: {addr}",
            f"      {pair['key']}:",
            f"        ipv4_address: {pair['ubuntu_ip']}",
            f'        mac_address: "{pair["ubuntu_mac"]}"',
        ]
    lines += render_persistent_kali("kali111", "Kali111", veth111=True)
    lines += render_persistent_kali(
        "derek",
        "Derek",
        user_var="DEREK_USER",
        password_var="DEREK_PASSWORD",
        default_user="derek",
        require_password=True,
    )
    lines += render_persistent_kali(
        "sang",
        "Sang",
        user_var="SANG_USER",
        password_var="SANG_PASSWORD",
        default_user="sang",
        require_password=True,
    )
    lines += render_persistent_kali(
        "ashraful",
        "Ashraful",
        user_var="ASHRAFUL_USER",
        password_var="ASHRAFUL_PASSWORD",
        default_user="ashraful",
        require_password=True,
    )
    lines += [
        "  ubuntu100:",
        "    image: lscr.io/linuxserver/webtop:ubuntu-xfce",
        "    mem_limit: 4g",
        '    shm_size: "1gb"',
        "    restart: unless-stopped",
        "    stop_grace_period: 20s",
        "    environment:",
        "      PUID: ${PUID:-1000}",
        "      PGID: ${PGID:-1000}",
        "      TZ: ${TZ:-UTC}",
        "      CUSTOM_USER: ${DESKTOP_USER:-van}",
        "      PASSWORD: ${DESKTOP_PASSWORD:-}",
        "      TITLE: Ubuntu100 desktop",
        "    volumes:",
        "      - /var/lib/cybersecurity/ubuntu100:/config",
        *dual_lan(persistent_addr("ubuntu100")),
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3001\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 180s",
        "",
        "  ubuntu111:",
        "    hostname: ubuntu111",
        "    image: cybersecurity-ubuntu111:1",
        "    build:",
        "      context: .",
        "      dockerfile: ubuntu111/Dockerfile",
        "    runtime: kata-runtime",
        "    mem_limit: 4g",
        '    shm_size: "1gb"',
        "    restart: unless-stopped",
        "    stop_grace_period: 20s",
        "    cap_add:",
        "      - NET_ADMIN",
        "    environment:",
        "      PUID: ${PUID:-1000}",
        "      PGID: ${PGID:-1000}",
        "      TZ: ${TZ:-UTC}",
        "      SERVER_IP: ${SERVER_IP:-10.0.253.1}",
        "      CUSTOM_USER: ${DESKTOP_USER:-van}",
        "      PASSWORD: ${DESKTOP_PASSWORD:-}",
        "      TITLE: Ubuntu111 desktop",
        '      S6_CMD_WAIT_FOR_SERVICES_MAXTIME: "0"',
        f"      VETH_PEER_MAC: {VETH111_UBUNTU_MAC}",
        f"      VETH_PEER_SUBNET: {VETH111_SUBNET}",
        "    volumes:",
        "      - ubuntu111-config:/config",
        "      - ./ubuntu/custom-services.d:/custom-services.d:ro",
        *dual_lan(
            persistent_addr("ubuntu111"),
            extra_hosts="*ubuntu111-hosts",
            veth111_ip=VETH111_UBUNTU_IP,
            veth111_mac=VETH111_UBUNTU_MAC,
        ),
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/3000\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 180s",
        "",
    ]
    lines += render_mint("vyas")
    lines += [
        "  ubuntuserver:",
        "    image: cybersecurity-ubuntu-ssh:1",
        "    mem_limit: 4g",
        "    runtime: kata-runtime",
        "    build:",
        "      context: .",
        "      dockerfile: ubuntu/Dockerfile",
        "    restart: unless-stopped",
        "    stop_grace_period: 10s",
        "    cap_add:",
        "      - NET_ADMIN",
        "    environment:",
        "      SSH_USER: ${DESKTOP_USER:-van}",
        "      SSH_PASSWORD: ${DESKTOP_PASSWORD:-}",
        "      TZ: ${TZ:-UTC}",
        "      LAN_GATEWAY: ${LAN_GATEWAY:-10.0.253.1}",
        "      UPSTREAM_DNS_1: ${UPSTREAM_DNS_1:-1.1.1.1}",
        "      UPSTREAM_DNS_2: ${UPSTREAM_DNS_2:-8.8.8.8}",
        "    networks:",
        "      lan:",
        "        ipv4_address: ${UBUNTU_SERVER_IP:-10.0.253.41}",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/22\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 60s",
        "",
        "  vai:",
        "    image: cybersecurity-ubuntu-ssh:1",
        "    mem_limit: 4g",
        "    runtime: kata-runtime",
        "    build:",
        "      context: .",
        "      dockerfile: ubuntu/Dockerfile",
        "    restart: unless-stopped",
        "    stop_grace_period: 10s",
        "    privileged: true",
        "    cap_add:",
        "      - NET_ADMIN",
        "    environment:",
        "      SSH_USER: ${DESKTOP_USER:-van}",
        "      SSH_PASSWORD: ${DESKTOP_PASSWORD:-}",
        "      TZ: ${TZ:-UTC}",
        "      LAN_GATEWAY: ${LAN_GATEWAY:-10.0.253.1}",
        "      UPSTREAM_DNS_1: ${UPSTREAM_DNS_1:-1.1.1.1}",
        "      UPSTREAM_DNS_2: ${UPSTREAM_DNS_2:-8.8.8.8}",
        "    volumes:",
        "      - vai-config:/home/${DESKTOP_USER:-van}",
        "    networks:",
        "      lan:",
        f"        ipv4_address: {VAI_IP}",
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/22\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 60s",
        "",
        "  ctfd:",
        "    hostname: ctfd",
        "    image: cybersecurity-ctfd:1",
        "    mem_limit: 4g",
        "    runtime: kata-runtime",
        "    build:",
        "      context: .",
        "      dockerfile: ubuntu/ctfd.Dockerfile",
        "    restart: unless-stopped",
        "    stop_grace_period: 10s",
        "    cap_add:",
        "      - NET_ADMIN",
        "    environment:",
        "      SSH_USER: ${CTFD_USER:-ctfd}",
        "      SSH_PASSWORD: ${CTFD_PASSWORD:-}",
        "      CTFD_USER: ${CTFD_USER:-ctfd}",
        "      CTFD_PASSWORD: ${CTFD_PASSWORD:-}",
        "      TZ: ${TZ:-UTC}",
        f"      LAN_ADDR: {CTFD_IP}",
        "      LAN_GATEWAY: ${LAN_GATEWAY:-10.0.253.1}",
        "      UPSTREAM_DNS_1: ${UPSTREAM_DNS_1:-1.1.1.1}",
        "      UPSTREAM_DNS_2: ${UPSTREAM_DNS_2:-8.8.8.8}",
        "      CTFD_SECRET_KEY: ${CTFD_SECRET_KEY:-}",
        "      CTFD_ADMIN_EMAIL: ${CTFD_ADMIN_EMAIL:-ctfd@cybersecurity.lan}",
        "      SECRET_KEY: ${CTFD_SECRET_KEY:-}",
        "      DATABASE_URL: sqlite:////home/${CTFD_USER:-ctfd}/ctfd.db",
        "      UPLOAD_FOLDER: /home/${CTFD_USER:-ctfd}/uploads",
        "    volumes:",
        # Same 500 GB loop disk as ubuntu100. Subdir only — do not bind
        # ubuntu100 /config and do not create another .img or named volume.
        # create_host_path: false so Compose does not mkdir a decoy on the
        # root fs before the loop is mounted (that hid the disk once).
        "      - type: bind",
        "        source: /var/lib/cybersecurity/ubuntu100/ctfd",
        "        target: /home/${CTFD_USER:-ctfd}",
        "        bind:",
        "          create_host_path: false",
        *dual_lan(CTFD_IP),
        "    logging: *json-logs",
        "    healthcheck:",
        '      test: ["CMD-SHELL", "bash -c \'echo >/dev/tcp/127.0.0.1/22\'"]',
        "      interval: 30s",
        "      timeout: 5s",
        "      retries: 5",
        "      start_period: 60s",
        "",
        "  caddy:",
        "    image: caddy:2.11.7-alpine",
        "    mem_limit: 4g",
        "    restart: unless-stopped",
        "    depends_on:",
    ]
    for name in kali + CADDY_LAN_DESKTOPS:
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
        "    mem_limit: 4g",
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
        "    mem_limit: 4g",
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
        "    mem_limit: 4g",
        "    restart: unless-stopped",
        "    command: tunnel --no-autoupdate run",
        "    environment:",
        '      TUNNEL_TOKEN: ${CLOUDFLARE_TUNNEL_TOKEN:-}',
        "    extra_hosts:",
        '      - "host.docker.internal:host-gateway"',
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
    ]
    for n in fleet_pair_nums(kali, ubuntu):
        lines += render_veth_network(veth_pair(n))
    lines += render_veth_network(veth_pair(111))
    lines += [
        "",
        "volumes:",
        "  caddy-data:",
        "    name: cybersecurity-caddy-data",
        "  caddy-config:",
        "    name: cybersecurity-caddy-config",
        "  kali111-config:",
        "    name: cybersecurity-kali111-config",
        "  sang-config:",
        "    name: cybersecurity-sang-config",
        "  ashraful-config:",
        "    name: cybersecurity-ashraful-config",
        "  ubuntu111-config:",
        "    name: cybersecurity-ubuntu111-config",
        "  derek-config:",
        "    name: cybersecurity-derek-config",
        "  vyas-config:",
        "    name: cybersecurity-vyas-config",
        "  vai-config:",
        "    name: cybersecurity-vai-config",
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


def render_records(kali: list[str], ubuntu: list[tuple[str, str]], extra: list[tuple[str, str]]) -> str:
    lines = [
        "# Generated by scripts/render.py. Do not edit by hand.",
        "# Kali names and the apex use __SERVER_IP__, filled in when dnsmasq starts.",
        "# Ubuntu addresses are fixed here so they match the macvlan addresses in compose.yaml.",
        "# host-record is exact. address=/name/ is not used on the zone apex, because that",
        "# would also answer every subdomain and hide the Ubuntu records.",
        "host-record=__BASE_DOMAIN__,__SERVER_IP__",
    ]
    for name in kali + CADDY_LAN_DESKTOPS:
        lines.append(f"address=/{name}.__BASE_DOMAIN__/__SERVER_IP__")
    for name, addr in ubuntu + extra:
        lines.append(f"address=/{name}.__BASE_DOMAIN__/{addr}")
    lines.append("")
    return "\n".join(lines)


def render_hosts(
    domain: str,
    server_ip: str,
    kali: list[str],
    ubuntu: list[tuple[str, str]],
    extra: list[tuple[str, str]],
) -> str:
    lines = [
        "# Generated by scripts/render.py. Workstation fallback when you cannot change DNS.",
        "# Append to /etc/hosts on each workstation. Re-run the script after changing",
        "# SERVER_IP, the domain, the counts, or UBUNTU_IP_START.",
        f"{server_ip} {domain}",
    ]
    for name in kali + CADDY_LAN_DESKTOPS:
        lines.append(f"{server_ip} {name}.{domain}")
    for name, addr in ubuntu + extra:
        lines.append(f"{addr} {name}.{domain}")
    lines.append("")
    return "\n".join(lines)


def render_index(root: Path, domain: str, user: str, kali: list[str], ubuntu_count: int) -> str:
    template = (root / "caddy" / "index.template.html").read_text()
    items = []
    for name in kali + CADDY_LAN_DESKTOPS:
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
        f"Shell access is <code>ssh {user}@{first}</code> through <code>{last}</code>, "
        f"and <code>ssh van@ubuntuserver.{domain}</code> / "
        f"<code>ssh ctfd@ctfd.{domain}</code>, port 22."
    )
    if "%%KALI_LINKS%%" not in template or "%%SSH_BLURB%%" not in template or "%%DESKTOP_BLURB%%" not in template:
        raise SystemExit("caddy/index.template.html is missing a render marker")
    html = template.replace("%%KALI_LINKS%%", "\n".join(items))
    html = html.replace("%%SSH_BLURB%%", blurb)
    html = html.replace(
        "%%DESKTOP_BLURB%%",
        "kali111, derek, sang, ashraful, ubuntu100, and ubuntu111 keep their files and are not wiped at 02:00. "
        f"The account on kali111 and ubuntu111 is van. The account on derek is derek. "
        f"The account on sang is sang. The account on ashraful is ashraful. "
        f"ubuntu100 keeps its files on a 500 GB disk. Open them at "
        f"https://kali111.{domain}/, https://derek.{domain}/, https://sang.{domain}/, "
        f"https://ashraful.{domain}/, "
        f"https://ubuntu100.{domain}/, and https://ubuntu111.{domain}/. "
        "vyas is a persistent Linux Mint Cinnamon desktop with Firefox. "
        "It is not on this page. Open it in a browser at vyas.research101.stream. "
        "Sign in as VYAS_USER (default vyas). Cinnamon starts after that password. sudo uses it too.",
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
    kali_addrs = fleet_kali_addresses(kali_count)
    addresses = ubuntu_ips(start, ubuntu_count, subnet, gateway, server, kali_addrs)
    ubuntu = list(zip(fleet_names("ubuntu", ubuntu_count), addresses))
    server_box = str(ipv4(env.get("UBUNTU_SERVER_IP", "10.0.253.41").strip() or "10.0.253.41", "UBUNTU_SERVER_IP"))
    if server_box in addresses or server_box in {str(server), str(gateway)}:
        raise SystemExit(f"UBUNTU_SERVER_IP {server_box} is already used")
    extra = [("ubuntuserver", server_box), ("vai", VAI_IP), ("ctfd", CTFD_IP)]
    if VAI_IP in addresses or VAI_IP in {str(server), str(gateway), server_box} or VAI_IP in {addr for _name, addr in PERSISTENT_DESKTOPS}:
        raise SystemExit(f"vai address {VAI_IP} is already used")
    if CTFD_IP in addresses or CTFD_IP in {str(server), str(gateway), server_box, VAI_IP} or CTFD_IP in {addr for _name, addr in PERSISTENT_DESKTOPS}:
        raise SystemExit(f"ctfd address {CTFD_IP} is already used")

    check_persistent_desktops(subnet, gateway, server, addresses, server_box)
    desktop_ips = {addr for _name, addr in PERSISTENT_DESKTOPS}
    if server_box in desktop_ips:
        raise SystemExit(f"UBUNTU_SERVER_IP {server_box} is a persistent desktop address")
    check_fleet_kali(kali_addrs, subnet, gateway, server, addresses, server_box)
    if set(kali_addrs) & desktop_ips:
        raise SystemExit("Kali fleet addresses overlap the persistent desktop block")

    write(root / "compose.yaml", render_compose(kali, ubuntu, domain, extra, str(server)))
    write(root / "caddy" / "Caddyfile", render_caddy(kali, CADDY_LAN_DESKTOPS))
    write(root / "caddy" / "site" / "index.html", render_index(root, domain, user, kali, ubuntu_count))
    write(root / "dns" / "records.conf", render_records(kali, ubuntu, extra))
    write(root / "dns" / "hosts.example", render_hosts(domain, str(server), kali, ubuntu, extra))
    print(
        f"Rendered {kali_count} Kali and {ubuntu_count} Ubuntu from {env_path}. "
        f"Ubuntu addresses {addresses[0]}-{addresses[-1]}. "
        f"Kali fleet macvlan {kali_addrs[0]}-{kali_addrs[-1]}. "
        "Persistent desktops "
        + ", ".join(f"{name} {addr}" for name, addr in PERSISTENT_DESKTOPS)
        + "."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
