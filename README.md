# Desktop LAN

Kali, Ubuntu, and Debian desktops in the browser, one hostname each, on a Linux server you control. [Caddy](https://caddyserver.com/) serves HTTPS from its internal CA and reverse-proxies to the [linuxserver](https://www.linuxserver.io/) web desktop on each container. Nothing in a desktop is kept: `/config` (the home directory) is a tmpfs, and a scheduler recreates the desktop containers at 02:00.

Anyone who can open the URL gets a desktop, and the desktop’s terminal has passwordless sudo inside the container. Keep this on a trusted LAN.

## Confirm before you start

- Docker Engine and the Compose plugin are installed, and your user can run `docker`. Install docs: <https://docs.docker.com/engine/install/>.
- `SERVER_IP` in `.env` is the address workstations use to reach this server.
- `TZ` is the timezone in which **02:00** should wipe the desktops. The default is `UTC`. The host clock’s timezone is not used.
- Ports **80** and **443** on the server are free, or you change `HTTP_PORT` and `HTTPS_PORT`.
- If you use the bundled DNS service, UDP and TCP **53** on `SERVER_IP` are free. A resolver that only listens on `127.0.0.53` (systemd-resolved’s stub) does not block that.
- The Docker socket is at `/var/run/docker.sock`. The scheduler mounts it so the 02:00 job can recreate containers. That container can control Docker.

Plan for roughly 10 GB of image disk (Kali is the large one) and about 1 GB of RAM per desktop you actually open, plus up to `DESKTOP_TMPFS_SIZE` (default 2 GB) of RAM for files written in that desktop’s home.

## Subdomains

| Hostname | Image | Desktop | Caddy upstream |
| --- | --- | --- | --- |
| `https://kali.desktop.lan` | `lscr.io/linuxserver/kali-linux:latest` | KDE (the only published tag; the image installs `kali-desktop-kde`) | `https://kali:3001` |
| `https://ubuntu.desktop.lan` | `lscr.io/linuxserver/webtop:ubuntu-kde` | KDE | `https://ubuntu:3001` |
| `https://debian.desktop.lan` | `lscr.io/linuxserver/webtop:debian-kde` | KDE | `https://debian:3001` |
| `https://desktop.lan` | Caddy static page | Links to the three desktops | — |

`desktop.lan` is `BASE_DOMAIN`. Change it in `.env` and every hostname follows. Port **3001** is the container’s HTTPS web desktop. Port 3000 is the HTTP port and is not published.

Smaller images, if you want them: `lscr.io/linuxserver/webtop:ubuntu-xfce` and `lscr.io/linuxserver/webtop:debian-xfce`. Both exist. Swap the image line and recreate that service.

## Run

```sh
cp .env.example .env
# Set SERVER_IP to this server's LAN address, and TZ if 02:00 UTC is wrong.
docker compose up -d --build
```

`.env.example` sets `COMPOSE_PROFILES=dns`, so that command also starts dnsmasq. The first start downloads the desktop images. Kali’s registry size is about 4.8 GB, Ubuntu KDE about 1.8 GB, Debian KDE about 1.5 GB.

Watch startup with `docker compose ps` and `docker compose logs -f caddy kali`. Then install the CA (next section) and open <https://desktop.lan>.

If a host firewall is on, allow 80/tcp, 443/tcp, and DNS from the LAN to `SERVER_IP`.

To pull newer desktop images later (the reset job does not pull):

```sh
docker compose pull kali ubuntu debian
./scripts/reset-now.sh
```

## Point workstations at the names

Pick one of these. You do not need all three.

### Bundled dnsmasq

The `dnsmasq` service listens on `SERVER_IP:53` and answers `desktop.lan` and every subdomain with `SERVER_IP`. Other names are forwarded to `UPSTREAM_DNS_1` and `UPSTREAM_DNS_2` (1.1.1.1 and 1.0.0.1 unless you change them).

Point workstations, or the desktop zone on your existing resolver, at `SERVER_IP`. Check from a workstation:

```sh
dig @192.168.1.10 kali.desktop.lan +short
```

That should print `SERVER_IP`. Use the address you set, not necessarily 192.168.1.10.

If port 53 on `SERVER_IP` is already taken, `docker compose up` fails on this service. See the next two options, and remove `dns` from `COMPOSE_PROFILES` in `.env` so Compose stops trying to bind it:

```sh
# .env
COMPOSE_PROFILES=
docker compose up -d --build
```

Check what owns the port with `ss -ulpn | grep ':53'`.

### You already run dnsmasq

Do not start this stack’s dnsmasq (clear `COMPOSE_PROFILES` as above). Copy [`dns/desktop.lan.conf`](dns/desktop.lan.conf) to `/etc/dnsmasq.d/desktop.lan.conf` on the machine that already runs dnsmasq, replace `SERVER_IP` with the server’s LAN address, and restart that dnsmasq. `address=/desktop.lan/<ip>` covers the apex and every subdomain, including ones you add later.

### Hosts file

If you cannot change DNS, append [`dns/hosts.example`](dns/hosts.example) to `/etc/hosts` on **each workstation** after replacing `SERVER_IP`. A hosts file cannot say `*.desktop.lan`, so each name is listed. Add a line when you add an OS.

## Trust the Caddy CA

Caddy issues certificates from a CA it creates on first start and stores in the `desktop-lan-caddy-data` volume. Browsers will warn until that root is installed. Export it after Caddy is up:

```sh
./scripts/export-ca.sh
# writes ./desktop-lan-root.crt
```

Install `desktop-lan-root.crt` on each workstation:

- **Linux system store** (Chrome and Chromium on Linux use this):

  ```sh
  sudo cp desktop-lan-root.crt /usr/local/share/ca-certificates/desktop-lan-caddy.crt
  sudo update-ca-certificates
  ```

- **Firefox** keeps its own store. Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import, and trust it for websites. Or, with NSS tools: `certutil -d sql:$HOME/.mozilla/firefox/<profile> -A -t "C,," -n "Desktop LAN" -i desktop-lan-root.crt`.

- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain desktop-lan-root.crt`

- **Windows** (Administrator): `certutil -addstore -f "ROOT" desktop-lan-root.crt`

Deleting the `desktop-lan-caddy-data` volume creates a new CA. Workstations must import the new root. The 02:00 reset does not delete that volume.

The certificate browsers see is Caddy’s. The hop from Caddy to the desktop is a second HTTPS connection, to port 3001, and Caddy does not verify the container’s self-signed certificate. LinuxServer’s own reverse-proxy notes prefer the container’s HTTP port (3000) to avoid that inner TLS. This stack uses 3001 because the web desktop’s HTTPS port is what should sit behind the proxy here.

## Add another OS

Wildcard DNS already answers the new name. A hosts-file setup does not.

1. Confirm the tag exists. `lscr.io/linuxserver/webtop` publishes tags such as `fedora-xfce`, `ubuntu-xfce`, and `arch-kde`. Do not invent one.
2. Add a service. The label is what puts it on the 02:00 reset; you do not edit the cron script.

   ```yaml
   fedora:
     <<: *desktop
     image: lscr.io/linuxserver/webtop:fedora-xfce
     networks: [desktop]
   ```

3. Add a site to `caddy/Caddyfile`:

   ```
   fedora.{$BASE_DOMAIN} {
       import desktop https://fedora:3001
   }
   ```

4. If workstations use a hosts file, add `fedora.desktop.lan` (or `fedora.<your domain>`) next to the other names.
5. `docker compose up -d fedora caddy`.

`fedora-xfce` was present on Docker Hub on 21 October 2026 (`sha256:2e103dd2a83e1b978ffb1dc488cf83db18fb260f0c81f94f012414a1a81e819a`).

## The 02:00 reset

[`scheduler/crontab`](scheduler/crontab) is a single line, `0 2 * * *`, run by [supercronic](https://github.com/aptible/supercronic) in the `scheduler` service. Supercronic evaluates that in the container timezone, which is `TZ` from `.env`. `TZ=America/New_York` means 02:00 in New York, including daylight-saving changes. An unknown `TZ` makes the scheduler exit instead of silently using UTC.

The job runs [`scheduler/reset-desktops.sh`](scheduler/reset-desktops.sh), which:

1. Finds its project directory on the host (the Compose file’s relative paths have to be the host’s paths).
2. Selects every service whose label is `desktop.lan.reset: "true"` (Kali, Ubuntu, and Debian).
3. Runs `docker compose up -d --force-recreate --no-deps --renew-anon-volumes` for those services only.
4. Restarts Caddy so it drops cached upstream addresses. Caddy is not recreated, and its CA volume is not removed.

Recreate replaces the container. The tmpfs mounted at `/config` is the linuxserver home directory, so the new container starts with an empty home. The container’s own writable layer is discarded too, which removes packages installed into the image rather than into the home directory. Caddy, dnsmasq, and the scheduler keep running.

Run it yourself, without waiting for 02:00:

```sh
./scripts/reset-now.sh
```

Logs: `docker compose logs scheduler`. A reboot of the Docker host also clears the tmpfs homes; the cron job is what recreates the containers so the writable layer is cleared even when the host stays up.

Image updates are separate. The cron job does not pull.

## Images verified 21 October 2026

Checked on Docker Hub. `lscr.io` is linuxserver’s registry and publishes these same tags. Tags move when linuxserver rebuilds; the digests are what the tags pointed at that day.

| Tag | Last updated | Digest | Registry size |
| --- | --- | --- | --- |
| `linuxserver/kali-linux:latest` | 2026-10-19 | `sha256:bc00b18887b5b263c03a52282867ac747d5e2a039f93969bb7e3d31b618833a6` | 4.8 GB |
| `linuxserver/webtop:ubuntu-kde` | 2026-10-20 | `sha256:7a859491e0d06e05025558d78f5bd212ccd329e4db0ca7a39a24d80ae25c1a48` | 1.8 GB |
| `linuxserver/webtop:debian-kde` | 2026-10-20 | `sha256:551fd08152afc4735b68e66fe496c4e4cfdd1362d1d5c4e3b3e0d6a3cbcc907e` | 1.5 GB |
| `linuxserver/webtop:ubuntu-xfce` (not selected) | 2026-10-20 | `sha256:278797c03b62454aaf05cd1fdeb35dbdc822846855020f9e5233f508a89980d9` | 1.3 GB |
| `linuxserver/webtop:debian-xfce` (not selected) | 2026-10-20 | `sha256:dd8218828958988f88b3e0d9ddd97a6337189662eeca57bfa49d78688f5a3695` | 1.3 GB |

`linuxserver/webtop` has no Kali tag. `linuxserver/kali-linux:latest` is a Selkies web desktop (KDE, HTTPS on port 3001), so the stack stays on these images.

Other pinned pieces: Caddy `2.11.7-alpine`, scheduler base `docker:28.5.2-cli`, Compose plugin `v5.6.0`, supercronic `v0.2.50`, dnsmasq image `alpine:3.22`.

## Layout

| Path | Role |
| --- | --- |
| `compose.yaml` | Caddy, three desktops, dnsmasq, scheduler |
| `.env.example` | Domain, timezone, ports, DNS profile |
| `caddy/Caddyfile` | Internal CA and HTTPS upstreams |
| `caddy/site/index.html` | Page on the apex name |
| `dns/` | Bundled dnsmasq, plus a host dnsmasq drop-in and a hosts-file example |
| `scheduler/` | supercronic and the recreate script |
| `scripts/export-ca.sh` | Copy the Caddy root out of the volume |
| `scripts/reset-now.sh` | Recreate the desktops now |

## Troubleshooting

- **Certificate warning.** The CA is not installed on that workstation, or the data volume was recreated and the root changed. Export it again.
- **Name does not resolve.** `dig @SERVER_IP kali.desktop.lan +short`. If that works but the workstation does not, the workstation is not using this DNS and does not have a hosts entry.
- **502 from Caddy.** The desktop is still starting, or the image is still downloading. `docker compose logs kali`.
- **Page loads, black screen.** The browser is not on HTTPS, or something is stripping WebSocket upgrades. Caddy forwards them. Selkies’ optional WebRTC mode is left off; its media would bypass the proxy over UDP, which this stack does not publish.
- **Reset did not run.** `docker compose logs scheduler` should show the timezone at start and a `reset:` line after 02:00. `docker compose exec scheduler date` should match `TZ`.
