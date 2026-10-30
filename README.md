# Cybersecurity LAN

Thirty Kali desktops in the browser, and thirty Ubuntu servers you reach with SSH. Names sit under `cybersecurity.lan` (`BASE_DOMAIN`). [Caddy](https://caddyserver.com/) terminates HTTPS for the Kali names. Ubuntu is not a desktop and not a Webtop: each one is an Ubuntu Server container with its own LAN address and `sshd` on port 22.

Anyone who can open a Kali URL gets a desktop, and that desktop’s terminal has passwordless sudo inside the container. Keep this on a trusted LAN. Do not publish it on the internet.

Debian and the old single Ubuntu webtop are gone.

## What you set

Copy the example, then edit `.env`. Placeholders in [`.env.example`](.env.example) are not secrets. Put a real key or password only in `.env`, which is gitignored.

| Variable | What it is |
| --- | --- |
| `PARENT_IFACE` | Required. Macvlan parent for Ubuntu. Must be the interface which already has `10.0.253.1` (`br-ex` or `eno1`). It must allow more than one MAC address. |
| `LAN_SUBNET` | `10.0.253.0/24`, the subnet on that interface. |
| `LAN_GATEWAY` | `10.0.253.1`, this server. Same address as `SERVER_IP`. |
| `UBUNTU_IP_START` | `10.0.253.11`, the address of `ubuntu01`. `ubuntu30` is `10.0.253.40`. Must sit inside `LAN_SUBNET`. `10.0.253.2` through `10.0.253.10` are reserved. Do not use `10.0.253.1` for a box. That address is the server. |
| `SERVER_IP` | `10.0.253.1`, this server’s LAN address. Kali names and the bundled DNS use it. |
| `TZ` | Timezone of the 02:00 reset. A tz database name (`UTC`, `America/New_York`), not a UTC offset. The host clock’s timezone is not used. |
| `SSH_USER` | Account on every Ubuntu server. Not `root`. |
| `SSH_PUBLIC_KEY` or `SSH_PASSWORD` | At least one. One single-line OpenSSH public key, and/or a single-line password. |
| `DESKTOP_USER` | Account on kali111, ubuntu100, ubuntu111, and ubuntuserver. Default `van`. Not used by derek or vyas. |
| `DESKTOP_PASSWORD` | Password for that account. Put it only in `.env`. Do not commit it. |
| `DEREK_USER` | Account on derek. Default `derek`. |
| `DEREK_PASSWORD` | Password for derek. No default. Put it only in `.env`. Do not commit it. |
| `VYAS_USER` | Account on vyas. Default `vyas`. |
| `VYAS_PASSWORD` | Password for vyas. No default. Put it only in `.env`. Do not commit it. |

`KALI_COUNT` and `UBUNTU_COUNT` default to 30. The repo already contains that render, so a copied `.env` can start all 60 without running the generator first.

## Hostnames

| Name | Address | What it is |
| --- | --- | --- |
| `https://cybersecurity.lan` | `10.0.253.1` (`SERVER_IP`) | List of Kali desktops, and the SSH names |
| `https://kali01.cybersecurity.lan` … `kali30.cybersecurity.lan` | Browser `10.0.253.1`. Macvlan `10.0.253.55` … `10.0.253.84` | Kali KDE in the browser. Also on the `desktop` bridge so Caddy can reach `kaliNN:3001`. Ping and SSH to Ubuntu from the desktop. |
| `ssh student@ubuntu01.cybersecurity.lan` … `ubuntu30` | `10.0.253.11` … `10.0.253.40` | Ubuntu Server, one macvlan address each, SSH port 22 only |
| `https://derek.research101.stream` | Cloudflare HTTP `http://derek:3000`, macvlan `10.0.253.53` | Persistent Linux Mint Cinnamon. Sign in, then Firefox and sudo. Not wiped at 02:00. |
| `https://vyas.research101.stream` | Cloudflare HTTP `http://vyas:3000`, macvlan `10.0.253.54` | Persistent Linux Mint Cinnamon. Sign in, then Firefox and sudo. Not wiped at 02:00. |
| kali111 | macvlan `10.0.253.50`, still `kali111` on the `desktop` bridge | Persistent Kali. Ping and SSH to the Ubuntu fleet from this desktop. |
| ubuntu111 | macvlan `10.0.253.51`, still `ubuntu111` on the `desktop` bridge | Persistent Ubuntu desktop. Same reachability. |
| ubuntu100 | macvlan `10.0.253.52`, still `ubuntu100` on the `desktop` bridge | Persistent Ubuntu desktop on the 500 GB disk. Same reachability. |

Kali routing is name-based. `kali01.cybersecurity.lan` through `kali30.cybersecurity.lan` resolve to `10.0.253.1`. Browsers stay on Caddy. Caddy listens on that address (ports 80 and 443) and chooses the container from the Host / SNI name. The upstream is `https://kaliNN:3001` on the Compose bridge `cybersecurity-desktop`. Port 3001 is the Selkies HTTPS port. Port 3000 is the Kali container HTTP port and is not used. The container certificate is self-signed, so Caddy does not verify that hop. Browsers only see the Caddy internal CA. The desktop socket is streamed (`flush_interval -1`); do not put another proxy in front that buffers it.

Each of kali01–kali30 stays on that bridge and also has a macvlan address, `10.0.253.55` for kali01 through `10.0.253.84` for kali30. kali111 stays on the same bridge, so Caddy and Cloudflare still use the container name (`kali111:3001`, and port 3000), and it has macvlan `10.0.253.50`. Ping and SSH to `ubuntu01.cybersecurity.lan` work from kali01–kali30 and from kali111, ubuntu111, ubuntu100, derek, or vyas.

All 30 Kali containers share one image, `lscr.io/linuxserver/kali-linux:latest`. There is one copy of that image on disk.

## Run

```sh
cp .env.example .env
# Edit PARENT_IFACE, LAN_SUBNET, LAN_GATEWAY, UBUNTU_IP_START,
# SERVER_IP, TZ, SSH_USER, and a key or password.
./scripts/lab.sh dns-on
./scripts/lab.sh on
```

Start DNS once. `dns-on` starts only dnsmasq. `on` starts the fleet, Caddy, the scheduler, and the persistent desktops (derek, vyas, kali111, ubuntu111, ubuntu100, and ubuntuserver). When `CLOUDFLARE_TUNNEL_TOKEN` is set, `on` also starts the public profile (`cloudflared`). It does not start dnsmasq. Day to day, `off` stops only kali01–kali30 and ubuntu01–ubuntu30. DNS and every other container stay up:

```sh
./scripts/lab.sh off
./scripts/lab.sh on
```

`off` stops only kali01–kali30 and ubuntu01–ubuntu30. It generates those 60 names and `docker stop`s their container IDs. It does not read `docker compose config --services` and it does not call `docker compose stop`. dnsmasq, Caddy, the scheduler, derek, vyas, kali111, ubuntu111, ubuntu100, ubuntuserver, cloudflared, and any other service keep running, so names such as `cybersecurity.lan` still resolve. `./scripts/lab.sh dns-off` stops only dnsmasq.

To stop the four desktops that `off` leaves running:

```sh
./scripts/lab.sh extra-containers-off
```

`extra-containers-off` stops only derek, vyas, kali111, and ubuntu111. It does not stop dnsmasq or the fleet.

When names are down, use the console or `10.0.253.1`, then:

```sh
./scripts/lab.sh dns-on
./scripts/lab.sh on
```

`.env.example` sets `COMPOSE_PROFILES=dns`. `lab.sh` clears that for `on`, so `up -d` does not start dnsmasq. `off` keeps dnsmasq running by stopping only the kali01–kali30 and ubuntu01–ubuntu30 container IDs. `extra-containers-off` names only those four desktops. Ubuntu containers exit until `SSH_PUBLIC_KEY` or `SSH_PASSWORD` is set. That is intentional: the repo has no default password.

The first start pulls the Kali image (about 4.8 GB). Watch `docker compose ps` and `docker compose logs -f caddy`. Then install the CA and open <https://cybersecurity.lan>.

If a host firewall is on, allow 80/tcp and 443/tcp to `SERVER_IP`, DNS if you use the bundled resolver, and TCP 22 from workstations to the Ubuntu address range (not to the server).

To pull a newer Kali image later (the reset job does not pull):

```sh
docker compose pull kali01
./scripts/reset-now.sh
```

Every Kali service uses the same image, so pulling one updates the image for the fleet. The reset recreates the containers onto it.

## Mint desktops

`derek` and `vyas` are persistent Linux Mint Cinnamon desktops. They sit on the Compose network `desktop` (`cybersecurity-desktop`), so the existing `cloudflared` container can reach them by service name (`http://derek:3000`, `http://vyas:3000`). They also have macvlan addresses `10.0.253.53` (derek) and `10.0.253.54` (vyas). The bridge keeps the default route. The macvlan address is how the desktop reaches the Ubuntu servers.

`lscr.io/linuxserver/webtop` has no Mint tag. Checked again on 29 October 2026: Docker Hub tag queries for `mint`, `cinnamon`, `linuxmint`, and `lmde` each returned zero tags. `linuxserver/rdesktop` has no Mint tag either. These two desktops use the published image `dockerscripts/linuxmint:cinnamon` (linux/amd64 manifest `sha256:02f4a0cb1561907d22865e2ed075c9c198443557d5884d316d3bfe0d3c268825`). The image build installs `mint-meta-cinnamon` and `firefox` (also Epiphany, Falkon, and Konqueror). That image does not serve HTTP. [`mint/entrypoint.sh`](mint/entrypoint.sh) serves a login page at HTTP port **3000** before it installs noVNC and TigerVNC. If apt, VNC, or Cinnamon fails, the error is printed and port 3000 stays open. The username is `DEREK_USER` or `VYAS_USER`. The password is `DEREK_PASSWORD` or `VYAS_PASSWORD`. Cinnamon starts after that password is accepted. xrdp stays masked, so the browser does not use RDP. The entrypoint puts the account in the `sudo` group. `sudo` asks for the same password.

derek and vyas do not share `DESKTOP_USER` or `DESKTOP_PASSWORD`. The login page asks for `DEREK_USER` (default `derek`) and `DEREK_PASSWORD`, or `VYAS_USER` (default `vyas`) and `VYAS_PASSWORD`. Neither password has a default. The entrypoint writes that password again on every start. An empty password cannot sign in. Homes are the named volumes `cybersecurity-derek-config` and `cybersecurity-vyas-config`, mounted at `/home/$DEREK_USER` and `/home/$VYAS_USER`. Neither service has `fleet.reset: "true"`, so the 02:00 job does not recreate them.

Do not add a second tunnel token. `cloudflared` (profile `public`) is the tunnel already in this Compose file. In the Cloudflare Zero Trust dashboard, on that same tunnel, replace the RDP routes. A browser cannot render RDP, and HTTP pointed at `rdp://` is a blank page. The service type is **HTTP**:

| Public hostname | Service |
| --- | --- |
| `derek.research101.stream` | `http://derek:3000` |
| `vyas.research101.stream` | `http://vyas:3000` |

`/` is the login page. After sign-in, Firefox is in the Cinnamon menu. `sudo` in a terminal asks for the same password.

On the ProLiant, from this repo:

```sh
git pull
# Set DEREK_PASSWORD and VYAS_PASSWORD in .env. Leave them empty in .env.example.
# Do not commit the real passwords.
docker compose up -d --force-recreate --no-deps derek vyas
```

`docker compose up -d --force-recreate --no-deps derek vyas` recreates only those two containers so they pick up the account and the home mount. The named volumes stay. This is not the 02:00 fleet reset. `lab.sh on` also starts them with the rest of the lab. `lab.sh off` leaves derek and vyas running (and kali111 and ubuntu111). `lab.sh extra-containers-off` stops only derek, vyas, kali111, and ubuntu111. It does not stop dnsmasq or the fleet. If `CLOUDFLARE_TUNNEL_TOKEN` is set, `lab.sh on` starts the existing `cloudflared`. It does not start or stop dnsmasq. Adding the hostnames is a Cloudflare dashboard change. Compose does not create them.

The containers run systemd so Cinnamon and the HTTP desktop can start. They stay privileged because systemd needs that to bring the session up. They do not set `cgroup: host` and they do not mount the host `/sys/fs/cgroup`. A host cgroup namespace makes the container exit when another container stops. They stay on the `desktop` network and on the macvlan LAN. The first start installs noVNC, so it takes longer than a later start. The next `./scripts/lab.sh on` recreates derek and vyas once so the running containers drop the host cgroup namespace. After that, `off` leaves them running.

## SSH

```sh
ssh student@ubuntu01.cybersecurity.lan
```

Port 22 on that container’s LAN address. Nothing is published on the Docker host’s port 22. The same `SSH_USER` is created on every Ubuntu container at start, from `.env`.

- Set `SSH_PUBLIC_KEY` to one line (`ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*`, or `sk-*`). `PubkeyAuthentication` is on.
- Set `SSH_PASSWORD` if you want password login. `PasswordAuthentication` is on only when a password is set.
- Leave both empty in `.env.example`. Do not commit `.env`.
- A `$` in `SSH_PASSWORD` must be written `$$`. Compose treats `$` as interpolation.
- Root login and empty passwords are off. The account is not given sudo.

Host keys are created when the container starts (`ssh-keygen -A`). They are not stored in the image. The 02:00 reset deletes them. Clients will see a changed host key and must update `known_hosts`.

## Macvlan

Ubuntu is attached to the `cybersecurity-macvlan` network (`driver: macvlan`, parent `PARENT_IFACE`). Each service has a fixed `ipv4_address`, and dnsmasq (and `dns/hosts.example`) has a matching A record.

kali01–kali30 and five persistent desktops are on that macvlan as well as the `desktop` bridge. [`scripts/render.py`](scripts/render.py) pins both blocks, so a re-render keeps them.

kali01 is `10.0.253.55` and kali30 is `10.0.253.84`. That block is not `10.0.253.1`, not `10.0.253.2`–`10.0.253.10`, not `10.0.253.11`–`10.0.253.41`, and not `10.0.253.50`–`10.0.253.54`. Each Kali service keeps `extra_hosts`, so `ubuntu01` and `ubuntu01.cybersecurity.lan` resolve to `10.0.253.11`, through `ubuntu30` at `10.0.253.40`. Caddy still opens `https://kaliNN:3001` on the bridge. The bridge keeps the default route (`gw_priority`).

After `git pull` on the ProLiant, recreate the thirty Kali desktops so they join the macvlan, then restart Caddy so it drops cached bridge addresses. This is not `lab.sh off`. `./scripts/lab.sh off` still stops only kali01–kali30 and ubuntu01–ubuntu30:

```sh
git pull
docker compose up -d --force-recreate --no-deps $(for n in $(seq 1 30); do printf 'kali%02d ' "$n"; done)
docker compose restart caddy
```

From a terminal on kali01 (or any kaliNN):

```sh
ping -c 2 10.0.253.11
ping -c 2 ubuntu01.cybersecurity.lan
ssh student@ubuntu01.cybersecurity.lan
```

Persistent desktops, same idea, different addresses:

| Desktop | Macvlan address | Still reachable on `desktop` as |
| --- | --- | --- |
| kali111 | `10.0.253.50` | `kali111` (ports 3000 and 3001) |
| ubuntu111 | `10.0.253.51` | `ubuntu111` |
| ubuntu100 | `10.0.253.52` | `ubuntu100` |
| derek | `10.0.253.53` | `http://derek:3000` |
| vyas | `10.0.253.54` | `http://vyas:3000` |

Those addresses are not `10.0.253.1`, not the gateway `10.0.253.254`, not `10.0.253.2`–`10.0.253.10`, and not `10.0.253.11`–`10.0.253.41`. The bridge keeps the default route (`gw_priority`), so Cloudflare still opens `http://derek:3000` and `http://vyas:3000`, and Caddy still opens `https://kali111:3001`.

A macvlan interface does not deliver packets to the parent address `10.0.253.1`, so these desktops do not send DNS to dnsmasq there. Compose writes the Ubuntu records into each desktop’s hosts file (`extra_hosts`). `ubuntu01` and `ubuntu01.cybersecurity.lan` both resolve to `10.0.253.11`, through `ubuntu30` at `10.0.253.40` and `ubuntuserver` at `10.0.253.41`. The same addresses are in `dns/records.conf`.

From a terminal on kali111, ubuntu111, ubuntu100, derek, or vyas:

```sh
ping -c 2 10.0.253.11
ping -c 2 ubuntu01
ping -c 2 ubuntu01.cybersecurity.lan
ssh student@ubuntu01.cybersecurity.lan
```

`./scripts/lab.sh off` still stops only kali01–kali30 and ubuntu01–ubuntu30. It does not stop these five.

After `git pull` on the ProLiant, recreate only those desktops so they join the macvlan. This is not `lab.sh off` and it is not the 02:00 reset:

```sh
git pull
docker compose up -d --force-recreate --no-deps kali111 ubuntu111 ubuntu100 derek vyas
```

Named volumes stay. Then open one of those desktops and run the ping and SSH commands above.

The ProLiant cannot ping macvlan addresses such as `10.0.253.11` (`ubuntu01`). Lab PCs can. The kernel does not deliver packets from the parent NIC to a macvlan child on that same NIC, so `ssh student@ubuntu01...` from this server fails even when DNS is right. A lab PC can open that SSH session. From the host, use the container directly:

```sh
docker exec -it ubuntu01 bash
```

Optional shim, if you need to SSH from the host. Pick an address that is not the gateway, not `SERVER_IP`, not `10.0.253.2`–`10.0.253.10`, not `10.0.253.11`–`10.0.253.41`, not the persistent desktop block `10.0.253.50`–`10.0.253.54`, and not the Kali fleet block `10.0.253.55`–`10.0.253.84`. This is not created for you:

```sh
# PARENT_IFACE is the interface which already has 10.0.253.1 (br-ex or eno1).
sudo ip link add cybersecurity-shim link "$PARENT_IFACE" type macvlan mode bridge
sudo ip addr add 10.0.253.100/32 dev cybersecurity-shim
sudo ip link set cybersecurity-shim up
for i in $(seq 11 40); do
  sudo ip route add "10.0.253.${i}/32" dev cybersecurity-shim
done
```

`10.0.253.100` is only an example shim address: not the gateway `10.0.253.254`, not `10.0.253.1`, not in the reserved range `10.0.253.2`–`10.0.253.10`, not in the Ubuntu range `10.0.253.11`–`10.0.253.41`, not in the persistent desktop block `10.0.253.50`–`10.0.253.54`, and not in the Kali fleet block `10.0.253.55`–`10.0.253.84`. The parent has to accept the extra MACs (promiscuous mode, no port security, not typical Wi-Fi). Cloud interfaces often drop them, and then the containers stay unreachable from the LAN.

`PARENT_IFACE`, `LAN_SUBNET`, and `LAN_GATEWAY` are read when Compose starts. Changing only the NIC does not require a re-render. The Ubuntu addresses are written into `compose.yaml` and `dns/records.conf`, so they still have to fall inside the subnet you set.

## Change the count

Counts are 1 through 99 so the names stay two digits (`kali01`, `ubuntu07`). Edit `.env`, render, then recreate:

```sh
# .env
KALI_COUNT=10
UBUNTU_COUNT=10
python3 scripts/render.py
docker compose up -d --build --remove-orphans
```

[`scripts/render.py`](scripts/render.py) rewrites `compose.yaml`, `caddy/Caddyfile`, `caddy/site/index.html`, `dns/records.conf`, and `dns/hosts.example`. Re-run it after changing `KALI_COUNT`, `UBUNTU_COUNT`, `UBUNTU_IP_START`, `BASE_DOMAIN`, `SERVER_IP`, or `SSH_USER`. A smaller count leaves the old containers until `--remove-orphans`. The 02:00 job does not remove orphans.

`docker compose up` with the committed files starts all 60. If `.env` still has `COMPOSE_PROFILES=dns`, that command also starts dnsmasq. Day to day, `./scripts/lab.sh off` and `./scripts/lab.sh on` leave DNS up. The generator is how you change that number; you do not copy services by hand.

## Resources

There is one Kali image on disk. RAM is per running desktop: about 1–2 GB for the session, plus a tmpfs home up to `DESKTOP_TMPFS_SIZE` (default 2 GB, only written files count) and a 1 GB shared-memory ceiling. Thirty desktops at once is tens of GB of RAM. Lower `KALI_COUNT` on a small host. The Ubuntu image is built once (`ubuntu:24.04` plus OpenSSH) and each server is only `sshd`.

Every container Compose defines has `mem_limit: 4g`: the Kali fleet, the Ubuntu fleet, the persistent desktops (kali111, ubuntu100, ubuntu111, derek, vyas), ubuntuserver, Caddy, dnsmasq, the scheduler, and cloudflared. That is a ceiling. Docker does not reserve 4 GB for an idle container. Desktops still have `shm_size: "1gb"`: the Kali fleet, kali111, ubuntu100, ubuntu111, derek, and vyas.

## DNS

Pick one. You do not need all three.

### Bundled dnsmasq

Start it once with `./scripts/lab.sh dns-on`. `on`, `off`, and `extra-containers-off` leave it running. `dns-off` stops only dnsmasq. The `dnsmasq` service listens on `SERVER_IP:53`. It answers the apex and each `kaliNN` name with `SERVER_IP`, and each `ubuntuNN` name with that container’s macvlan address. Other names go to `UPSTREAM_DNS_1` and `UPSTREAM_DNS_2` (1.1.1.1 and 1.0.0.1 unless you change them).

There is no wildcard for the zone. A wildcard would send the Ubuntu names to `SERVER_IP`.

Point workstations at `SERVER_IP`, then:

```sh
dig @10.0.253.1 kali01.cybersecurity.lan +short
dig @10.0.253.1 ubuntu01.cybersecurity.lan +short
```

The first should print `10.0.253.1`. The second should print `10.0.253.11` (`ubuntu01`). `ubuntu30` is `10.0.253.40`.

`SERVER_IP` is substituted when dnsmasq starts. Ubuntu addresses are already written in [`dns/records.conf`](dns/records.conf).

If port 53 on `SERVER_IP` is taken, do not run `./scripts/lab.sh dns-on`. Clear the profile so a plain `docker compose up` does not bind it:

```sh
# .env
COMPOSE_PROFILES=
```

`ss -ulpn | grep ':53'` shows what owns the port. systemd-resolved on `127.0.0.53` does not block `SERVER_IP:53`.

### You already run dnsmasq

Leave `COMPOSE_PROFILES` empty, and do not run `./scripts/lab.sh dns-on`. Install the generated records on that resolver. Replace the placeholders, then restart dnsmasq:

```sh
sed -e "s/__SERVER_IP__/10.0.253.1/g" -e "s/__BASE_DOMAIN__/cybersecurity.lan/g" \
  dns/records.conf > /etc/dnsmasq.d/cybersecurity.lan.conf
```

Also set `local=/cybersecurity.lan/` on that daemon so it does not forward the zone. Do not add `address=/cybersecurity.lan/<ip>`.

### Hosts file

Append [`dns/hosts.example`](dns/hosts.example) to `/etc/hosts` on each workstation. Re-render after `SERVER_IP`, the domain, the counts, or `UBUNTU_IP_START` change. A hosts file cannot express a wildcard, and this zone must not use one.

## Trust the Caddy CA

Caddy issues certificates from a CA it creates on first start and stores in the `cybersecurity-caddy-data` volume. Browsers warn until that root is installed.

```sh
./scripts/export-ca.sh
# writes ./cybersecurity-lan-root.crt
```

Install that file on each workstation:

- **Linux system store** (Chrome and Chromium on Linux use this):

  ```sh
  sudo cp cybersecurity-lan-root.crt /usr/local/share/ca-certificates/cybersecurity-lan-caddy.crt
  sudo update-ca-certificates
  ```

- **Firefox** keeps its own store. Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import, and trust it for websites. Or, with NSS tools: `certutil -d sql:$HOME/.mozilla/firefox/<profile> -A -t "C,," -n "Cybersecurity LAN" -i cybersecurity-lan-root.crt`.

- **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cybersecurity-lan-root.crt`

- **Windows** (Administrator): `certutil -addstore -f "ROOT" cybersecurity-lan-root.crt`

Deleting the `cybersecurity-caddy-data` volume creates a new CA. Workstations must import the new root. The 02:00 reset does not delete that volume.

## The 02:00 reset

[`scheduler/crontab`](scheduler/crontab) is `0 2 * * *`, run by [supercronic](https://github.com/aptible/supercronic) in the `scheduler` service. Supercronic uses the container timezone, which is `TZ` from `.env`. `TZ=America/New_York` means 02:00 in New York, including daylight-saving changes. An unknown `TZ` makes the scheduler exit instead of silently using UTC.

The job runs [`scheduler/reset-desktops.sh`](scheduler/reset-desktops.sh), which:

1. Finds the project directory on the host (Compose’s relative paths have to be the host’s paths).
2. Selects every service labeled `fleet.reset: "true"` (the fleet Kali desktops and the fleet Ubuntu SSH servers).
3. Runs `docker compose up -d --force-recreate --no-deps --renew-anon-volumes` for those services only.
4. Restarts Caddy so it drops cached Kali addresses. Caddy is not recreated, and its CA volume is not removed.

Recreate replaces the container.

- Kali home is a tmpfs on `/config`. The new container has an empty home. Packages written into the image layer rather than the home are discarded too.
- Ubuntu has no volume. The writable layer goes away, including the account, `authorized_keys`, and the SSH host keys. The entrypoint creates the account again from `.env` and generates new host keys.
- derek and vyas are not labeled `fleet.reset`. The job does not recreate them, and `cybersecurity-derek-config` and `cybersecurity-vyas-config` stay.

Caddy, dnsmasq, and the scheduler keep running. The scheduler is not recreated (that would kill the job). It mounts the Docker socket and runs as root, so it can control the daemon.

Run it yourself:

```sh
./scripts/reset-now.sh
```

Logs: `docker compose logs scheduler`. A reboot of the Docker host also clears the Kali tmpfs. The cron job is what recreates both fleets when the host stays up. The cron job does not pull images.

## Layout

| Path | Role |
| --- | --- |
| `compose.yaml` | Generated. 30 Kali, 30 Ubuntu, persistent desktops, Caddy, dnsmasq, scheduler, cloudflared. `mem_limit: 4g` on every service. Desktops keep `shm_size: "1gb"`. |
| `scripts/render.py` | Rebuilds the fleet files from `.env`, including derek and vyas |
| `mint/entrypoint.sh` | Creates the derek or vyas account, grants sudo, requires that password on HTTP port 3000, then starts Cinnamon |
| `.env.example` | Domain, timezone, NIC, subnet, counts, SSH placeholders |
| `caddy/Caddyfile` | Generated. Internal CA and one site per Kali desktop |
| `caddy/site/index.html` | Generated page on the apex name |
| `ubuntu/` | Ubuntu Server image: OpenSSH only, host keys at start |
| `dns/` | Bundled dnsmasq, generated records, hosts-file example |
| `scheduler/` | supercronic and the recreate script |
| `scripts/lab.sh` | `on` starts the lab and does not start dnsmasq. `off` stops only kali01–kali30 and ubuntu01–ubuntu30. `extra-containers-off` stops only derek, vyas, kali111, and ubuntu111. `dns-on` / `dns-off` start and stop only dnsmasq |
| `scripts/export-ca.sh` | Copy the Caddy root out of the volume |
| `scripts/reset-now.sh` | Recreate both fleets now |

## Images

`linuxserver/kali-linux:latest` is a Selkies web desktop (KDE, HTTPS on 3001). Checked on Docker Hub on 21 October 2026: digest `sha256:bc00b18887b5b263c03a52282867ac747d5e2a039f93969bb7e3d31b618833a6`, about 4.8 GB. `linuxserver/webtop` has no Kali tag and no Mint tag (checked 29 October 2026).

`derek` and `vyas` use `dockerscripts/linuxmint:cinnamon` (Linux Mint Cinnamon, Firefox). The image has no HTTP port, so the entrypoint adds noVNC on port 3000. Registry index digest `sha256:094170fed2aaa379cd8c85f48fbf395dd7bfc2b19511b73f037cc340fe414342`. The linux/amd64 manifest is `sha256:02f4a0cb1561907d22865e2ed075c9c198443557d5884d316d3bfe0d3c268825`, pushed 26 October 2026.

Ubuntu is a local image, `cybersecurity-ubuntu-ssh:1`, built from `ubuntu:24.04` with `openssh-server`. It is not a browser desktop.

Other pinned pieces: Caddy `2.11.7-alpine`, scheduler base `docker:28.5.2-cli`, Compose plugin `v5.6.0`, supercronic `v0.2.50`, dnsmasq image `alpine:3.22`.

## Troubleshooting

- **Ubuntu container exits immediately.** Neither `SSH_PUBLIC_KEY` nor `SSH_PASSWORD` is set, or `SSH_USER` is `root` or not a lowercase account name. `docker compose logs ubuntu01`.
- **The ProLiant cannot ping `10.0.253.11` (`ubuntu01`). A lab PC can.** SSH from the ProLiant to that address times out the same way. Macvlan on the same NIC. Use `docker exec`, the shim above, or a terminal on kali111, ubuntu111, ubuntu100, derek, or vyas.
- **kali111 cannot ping `10.0.253.11` or `ubuntu01.cybersecurity.lan`.** That desktop was not recreated after the macvlan addresses landed. From the repo, `docker compose up -d --force-recreate --no-deps kali111 ubuntu111 ubuntu100 derek vyas`.
- **kali01 cannot ping `ubuntu01.cybersecurity.lan`.** Recreate the fleet so it picks up `10.0.253.55`–`10.0.253.84`: `docker compose up -d --force-recreate --no-deps $(for n in $(seq 1 30); do printf 'kali%02d ' "$n"; done)`, then `docker compose restart caddy`.
- **Names do not resolve.** dnsmasq is stopped. From the console, or from `10.0.253.1`, run `./scripts/lab.sh dns-on`, then `./scripts/lab.sh on`.
- **SSH from the LAN times out.** `PARENT_IFACE` is wrong, the address is outside the real subnet, or the switch is dropping the extra MAC.
- **`known_hosts` mismatch.** The 02:00 reset replaced the host keys. Remove the old line and connect again.
- **Certificate warning.** The CA is not installed on that workstation, or the data volume was recreated. Export it again.
- **`kali01` does not resolve, or it points at the Ubuntu address.** DNS was not re-rendered, or a wildcard `address=/cybersecurity.lan/` is still installed. `dig @SERVER_IP kali01.cybersecurity.lan` and `dig @SERVER_IP ubuntu01.cybersecurity.lan` should differ.
- **502 from Caddy.** That Kali container is still starting, or the image is still downloading. `docker compose logs kali01`.
- **Page loads, black screen.** The browser is not on HTTPS, or something is stripping WebSocket upgrades. Caddy forwards them.
- **Reset did not run.** `docker compose logs scheduler` should show the timezone at start and a `reset:` line after 02:00. `docker compose exec scheduler date` should match `TZ`.
- **502 Bad gateway on derek or vyas.** Cloudflare reached the tunnel and nothing accepted HTTP on port 3000. `docker compose logs derek` should include `Mint login on http://0.0.0.0:3000` before apt finishes. `ERROR: apt-get update failed` or `ERROR: apt-get install failed` means packages did not install; the login page stays up. Origins stay `http://derek:3000` and `http://vyas:3000`.
- **derek or vyas is a blank page.** The public hostname must be service type HTTP, origin `http://derek:3000` or `http://vyas:3000`. RDP does not render in a browser. Replace an RDP route.
- **The Mint login is rejected.** `DEREK_PASSWORD` or `VYAS_PASSWORD` is empty, or the container was not recreated after the password changed. The entrypoint resets the password from `.env` on start. The same password is used for `sudo` after Cinnamon starts.
- **Sign-in says the desktop did not start.** A correct password installs `tigervnc-standalone-server` (Xtigervnc) and `util-linux` (runuser) if apt has not finished. Port 3000 stays open during that install. `docker compose logs derek` should then contain `Xtigervnc and runuser are ready` and `Cinnamon started for derek` (`Cinnamon started for vyas` on that desktop).
- **502 on `/vnc.html` after sign-in.** The login page waits until websockify answers `GET /vnc.html` before it redirects. That path is not answered with 502. The log line is `noVNC proxy is serving /vnc.html`, then `Cinnamon started for derek`. Port 3000 stays open while the proxy starts.
