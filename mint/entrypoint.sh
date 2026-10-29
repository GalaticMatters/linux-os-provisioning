#!/bin/bash
# dockerscripts/linuxmint:cinnamon is a real Mint Cinnamon desktop, but the
# published image only exposes xrdp. A browser cannot render RDP. This
# entrypoint creates the account, grants password sudo, starts Cinnamon on
# a local VNC display, and serves that display over HTTP on port 3000.
set -eu

user=${MINT_USER:-}
home="/home/${user}"

if [ -z "$user" ] || [ "$user" = "root" ] || ! printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "MINT_USER must be a lowercase account name other than root (set DEREK_USER or VYAS_USER)" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1 \
  || ! command -v Xtigervnc >/dev/null 2>&1 \
  || ! command -v websockify >/dev/null 2>&1 \
  || ! command -v dbus-launch >/dev/null 2>&1 \
  || [ ! -f /usr/share/novnc/vnc.html ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    sudo \
    tigervnc-standalone-server \
    novnc \
    websockify \
    dbus-x11 \
    xfonts-base \
    libgl1-mesa-dri
fi

if ! id "$user" >/dev/null 2>&1; then
  if ! useradd --shell /bin/bash --home-dir "$home" --create-home "$user"; then
    useradd --shell /bin/bash --home-dir "$home" "$user"
  fi
fi

mkdir -p "$home"
if [ -z "$(ls -A "$home" 2>/dev/null || true)" ] && [ -d /etc/skel ]; then
  cp -a /etc/skel/. "$home/"
fi
usermod -d "$home" "$user"
usermod -aG sudo "$user"
chown -R "$user:$user" "$home"

# Password sudo, reset from .env on every start.
printf '%s ALL=(ALL:ALL) ALL\n' "$user" > "/etc/sudoers.d/${user}"
chmod 440 "/etc/sudoers.d/${user}"
if [ -n "${MINT_PASSWORD:-}" ]; then
  printf '%s:%s\n' "$user" "$MINT_PASSWORD" | chpasswd
fi

# Browser opens this page and is sent straight into the desktop.
cat > /usr/share/novnc/index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linux Mint</title>
<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&amp;resize=scale&amp;reconnect=1">
<script>location.replace("vnc.html?autoconnect=1&resize=scale&reconnect=1");</script>
</head>
<body>
<p><a href="vnc.html?autoconnect=1&amp;resize=scale&amp;reconnect=1">Open the Linux Mint desktop</a></p>
</body>
</html>
HTML

cat > /usr/local/bin/mint-xstartup << 'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export CINNAMON_2D=true
export XDG_CURRENT_DESKTOP=X-Cinnamon
export XDG_SESSION_DESKTOP=cinnamon
export XDG_SESSION_TYPE=x11
export GDK_BACKEND=x11
export CLUTTER_BACKEND=x11
export LIBGL_ALWAYS_SOFTWARE=1
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
exec dbus-launch --exit-with-session /usr/bin/cinnamon-session
EOF
chmod 755 /usr/local/bin/mint-xstartup

# Username is substituted below. systemd does not pass the container environment.
cat > /usr/local/bin/mint-desktop.sh << 'EOF'
#!/bin/bash
set -eu
user='@MINT_USER@'
home="/home/${user}"
uid=$(id -u "$user")
runtime="/run/user/${uid}"
mkdir -p "$runtime" /tmp/.X11-unix
chown "$user:$user" "$runtime"
chmod 700 "$runtime"
chmod 1777 /tmp/.X11-unix
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
touch "$home/.Xauthority"
chown "$user:$user" "$home/.Xauthority"
chmod 600 "$home/.Xauthority"

if [ ! -x /usr/bin/cinnamon-session ]; then
  echo "cinnamon-session is not installed" >&2
  exit 1
fi

runuser -u "$user" -- /usr/bin/Xtigervnc :1 \
  -auth "$home/.Xauthority" \
  -geometry 1920x1080 \
  -depth 24 \
  -rfbport 5901 \
  -localhost=1 \
  -SecurityTypes None \
  -AlwaysShared \
  -DisconnectClients=0 \
  -desktop "Linux Mint" &
vnc_pid=$!

ready=0
for _ in $(seq 1 100); do
  if [ -S /tmp/.X11-unix/X1 ]; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "Xtigervnc did not open a display" >&2
  kill "$vnc_pid" 2>/dev/null || true
  exit 1
fi

runuser -u "$user" -- env \
  HOME="$home" \
  USER="$user" \
  LOGNAME="$user" \
  DISPLAY=:1 \
  XAUTHORITY="$home/.Xauthority" \
  XDG_RUNTIME_DIR="$runtime" \
  /usr/local/bin/mint-xstartup &
sess_pid=$!

websockify --web /usr/share/novnc --heartbeat 30 3000 127.0.0.1:5901 &
ws_pid=$!

echo "Mint desktop HTTP on port 3000 for $user"
wait -n "$vnc_pid" "$sess_pid" "$ws_pid"
kill "$vnc_pid" "$sess_pid" "$ws_pid" 2>/dev/null || true
exit 1
EOF
sed -i "s/@MINT_USER@/${user}/" /usr/local/bin/mint-desktop.sh
chmod 755 /usr/local/bin/mint-desktop.sh

cat > /etc/systemd/system/mint-desktop.service << 'EOF'
[Unit]
Description=Cinnamon desktop over HTTP
After=systemd-logind.service dbus.service
Wants=systemd-logind.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mint-desktop.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/journald.conf.d /etc/systemd/system/multi-user.target.wants
printf '%s\n' '[Journal]' 'ForwardToConsole=yes' 'MaxLevelConsole=info' \
  > /etc/systemd/journald.conf.d/console.conf
ln -sfn ../mint-desktop.service /etc/systemd/system/multi-user.target.wants/mint-desktop.service

# No greeter and no RDP listener. The browser session is the desktop.
ln -sfn /dev/null /etc/systemd/system/lightdm.service
ln -sfn /dev/null /etc/systemd/system/xrdp.service
ln -sfn /dev/null /etc/systemd/system/xrdp-sesman.service
rm -f /etc/systemd/system/display-manager.service
ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

exec /lib/systemd/systemd
