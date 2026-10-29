#!/bin/bash
# dockerscripts/linuxmint:cinnamon is a real Mint Cinnamon desktop. The
# published image has no HTTP port, so this entrypoint serves noVNC on 3000.
# The browser shows a login page first. Cinnamon starts only after the
# account password is accepted. xrdp stays masked.
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
  || ! command -v python3 >/dev/null 2>&1 \
  || [ ! -f /usr/share/novnc/vnc.html ]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    sudo \
    python3 \
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

# Password sudo, reset from .env on every start. The login page checks this hash.
printf '%s ALL=(ALL:ALL) ALL\n' "$user" > "/etc/sudoers.d/${user}"
chmod 440 "/etc/sudoers.d/${user}"
if [ -n "${MINT_PASSWORD:-}" ]; then
  printf '%s:%s\n' "$user" "$MINT_PASSWORD" | chpasswd
fi

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

cat > /usr/local/bin/mint-start-session.sh << 'EOF'
#!/bin/bash
# Start Cinnamon after a successful login. Safe to call again.
set -eu
user=${1:-}
home="/home/${user}"
if [ -z "$user" ] || ! printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "mint-start-session: bad account" >&2
  exit 1
fi
if [ ! -x /usr/bin/cinnamon-session ]; then
  echo "cinnamon-session is not installed" >&2
  exit 1
fi
if ! command -v Xtigervnc >/dev/null 2>&1 || ! command -v runuser >/dev/null 2>&1; then
  echo "Xtigervnc or runuser is not installed" >&2
  exit 1
fi

mkdir -p /tmp/.X11-unix "/run/user"
chmod 1777 /tmp/.X11-unix || true
uid=$(id -u "$user")
runtime="/run/user/${uid}"
mkdir -p "$runtime"
chown "$user:$user" "$runtime"
chmod 700 "$runtime"
touch "$home/.Xauthority"
chown "$user:$user" "$home/.Xauthority"
chmod 600 "$home/.Xauthority"
touch /run/mint-vnc.log /run/mint-session.log

vnc_alive() {
  [ -f /run/mint-vnc.pid ] || return 1
  kill -0 "$(cat /run/mint-vnc.pid)" 2>/dev/null
}
session_alive() {
  [ -f /run/mint-session.pid ] || return 1
  kill -0 "$(cat /run/mint-session.pid)" 2>/dev/null
}

# A previous attempt may still be opening the display. Do not kill it.
if ! vnc_alive || [ ! -S /tmp/.X11-unix/X1 ]; then
  if vnc_alive; then
    kill "$(cat /run/mint-vnc.pid)" 2>/dev/null || true
    sleep 0.2
  fi
  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
  runuser -u "$user" -- /usr/bin/Xtigervnc :1 \
    -auth "$home/.Xauthority" \
    -geometry 1920x1080 \
    -depth 24 \
    -rfbport 5901 \
    -localhost=1 \
    -SecurityTypes None \
    -AlwaysShared \
    -DisconnectClients=0 \
    -desktop "Linux Mint" >>/run/mint-vnc.log 2>&1 &
  echo $! > /run/mint-vnc.pid
  echo "Xtigervnc starting for ${user}" >&2
fi

ready=0
for _ in $(seq 1 450); do
  if [ -S /tmp/.X11-unix/X1 ]; then
    ready=1
    break
  fi
  if ! vnc_alive; then
    echo "Xtigervnc exited before opening a display" >&2
    tail -n 30 /run/mint-vnc.log >&2 || true
    exit 1
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  echo "Xtigervnc did not open a display" >&2
  tail -n 30 /run/mint-vnc.log >&2 || true
  exit 1
fi

if ! session_alive; then
  runuser -u "$user" -- env \
    HOME="$home" \
    USER="$user" \
    LOGNAME="$user" \
    DISPLAY=:1 \
    XAUTHORITY="$home/.Xauthority" \
    XDG_RUNTIME_DIR="$runtime" \
    /usr/local/bin/mint-xstartup >>/run/mint-session.log 2>&1 &
  echo $! > /run/mint-session.pid
fi
sleep 1
if ! session_alive; then
  echo "cinnamon-session exited" >&2
  tail -n 30 /run/mint-session.log >&2 || true
  exit 1
fi
if ! bash -c 'echo >/dev/tcp/127.0.0.1/6080' 2>/dev/null; then
  websockify --web /usr/share/novnc --heartbeat 30 127.0.0.1:6080 127.0.0.1:5901 >>/run/mint-websockify.log 2>&1 &
fi
echo "Cinnamon started for ${user}"
EOF
EOF
chmod 755 /usr/local/bin/mint-start-session.sh

cat > /usr/local/bin/mint-login.py << 'EOF'
#!/usr/bin/env python3
"""Login page on port 3000. Cinnamon starts only after the account password matches."""

import hmac
import os
import re
import secrets
import socket
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

import ctypes
import ctypes.util

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
ACCOUNT = sys_account = None  # set from argv in main
SECRET = secrets.token_bytes(32)
COOKIE = "mint_session"
NOVNC = "/vnc.html?autoconnect=1&resize=scale&reconnect=1"
# Loaded on the first sign-in, not at import. find_library() is often None
# in a container, and CDLL(None) raises before the socket would bind.
_CRYPT = None
_CRYPT_TRIED = False


def shadow_hash(password: str, salt: str) -> str:
    global _CRYPT, _CRYPT_TRIED
    if not _CRYPT_TRIED:
        _CRYPT_TRIED = True
        names = []
        found = ctypes.util.find_library("crypt")
        if found:
            names.append(found)
        names.extend(["libcrypt.so.1", "libcrypt.so.2"])
        for name in names:
            try:
                lib = ctypes.CDLL(name)
                fn = lib.crypt
                fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
                fn.restype = ctypes.c_char_p
                _CRYPT = fn
                break
            except (OSError, AttributeError):
                continue
    if _CRYPT is None:
        raise OSError("libcrypt is not available")
    hashed = _CRYPT(password.encode(), salt.encode())
    if not hashed:
        return ""
    return hashed.decode()


def account_ok(username: str, password: str) -> bool:
    if not ACCOUNT or username != ACCOUNT or not password:
        return False
    try:
        with open("/etc/shadow", encoding="utf-8") as handle:
            row = next(line for line in handle if line.startswith(ACCOUNT + ":"))
        hashed = row.split(":", 2)[1]
        if not hashed or hashed[0] in "!*":
            return False
        return hmac.compare_digest(shadow_hash(password, hashed), hashed)
    except (OSError, StopIteration, ValueError):
        return False


def session_cookie() -> str:
    return hmac.new(SECRET, b"mint-ok", "sha256").hexdigest()


def authed(header: str | None) -> bool:
    if not header:
        return False
    token = ""
    for part in header.split(";"):
        name, _, value = part.strip().partition("=")
        if name == COOKIE:
            token = value
            break
    if not token:
        return False
    return hmac.compare_digest(token, session_cookie())


def page(error: str, username: str) -> bytes:
    def esc(value: str) -> str:
        return (
            value.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
        )

    message = f'<p class="err">{esc(error)}</p>' if error else ""
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in to Linux Mint</title>
<style>
  body {{ margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: #1a3a2a; color: #f4f1ea; font-family: "Segoe UI", sans-serif; }}
  form {{ width: min(22rem, calc(100% - 2rem)); background: #24382c; padding: 1.5rem;
    border-radius: 12px; box-shadow: 0 12px 40px rgba(0,0,0,.35); }}
  h1 {{ font-size: 1.25rem; margin: 0 0 .25rem; }}
  p {{ margin: 0 0 1rem; color: #d5e0d8; }}
  label {{ display: block; font-size: .85rem; margin: .75rem 0 .25rem; }}
  input {{ width: 100%; box-sizing: border-box; padding: .6rem .7rem; border-radius: 8px;
    border: 1px solid #3d5c49; background: #12241b; color: inherit; }}
  button {{ margin-top: 1rem; width: 100%; padding: .7rem; border: 0; border-radius: 8px;
    background: #8db87a; color: #142016; font-weight: 700; cursor: pointer; }}
  .err {{ color: #ffb4a8; }}
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>Linux Mint</h1>
  <p>Sign in to this desktop. Cinnamon starts after the password is accepted.</p>
  {message}
  <label for="username">Username</label>
  <input id="username" name="username" autocomplete="username" autocapitalize="none" required value="{esc(username)}">
  <label for="password">Password</label>
  <input id="password" name="password" type="password" autocomplete="current-password" required>
  <button type="submit">Sign in</button>
</form>
</body>
</html>
"""
    return html.encode()


def start_desktop() -> None:
    result = subprocess.run(
        ["/usr/local/bin/mint-start-session.sh", ACCOUNT or ""],
        check=False,
        timeout=90,
        capture_output=True,
        text=True,
    )
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n", flush=True)
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", flush=True)
    if result.returncode != 0:
        lines = (result.stderr or result.stdout or "desktop did not start").strip().splitlines()
        raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, lines[-1] if lines else "")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        if self.path.startswith("/login"):
            print("login request", flush=True)
            return
        super().log_message(fmt, *args)

    def do_POST(self) -> None:
        if self.path.split("?", 1)[0] != "/login":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0 or length > 4096:
            self._form("Sign-in failed.", "")
            return
        fields = parse_qs(self.rfile.read(length).decode("utf-8", "replace"), keep_blank_values=True)
        username = fields.get("username", [""])[0]
        password = fields.get("password", [""])[0]
        if not account_ok(username, password):
            self._form("That username or password is wrong.", username if USER_RE.fullmatch(username) else "")
            return
        try:
            start_desktop()
        except subprocess.CalledProcessError as exc:
            self._form("The desktop did not start. " + str(exc.stderr or ""), username)
            return
        except (OSError, subprocess.SubprocessError):
            self._form("The desktop did not start.", username)
            return
        body = b""
        self.send_response(303)
        self.send_header("Location", NOVNC)
        self.send_header("Set-Cookie", f"{COOKIE}={session_cookie()}; HttpOnly; SameSite=Lax; Path=/")
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        del body

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        signed_in = authed(self.headers.get("Cookie"))
        if path in ("/", "/login") and not signed_in:
            self._form("", "")
            return
        if path in ("/", "/login") and signed_in:
            self.send_response(303)
            self.send_header("Location", NOVNC)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not signed_in:
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            start_desktop()
        except subprocess.CalledProcessError as exc:
            self._form("The desktop did not start. " + str(exc.stderr or ""), ACCOUNT or "")
            return
        except (OSError, subprocess.SubprocessError):
            self._form("The desktop did not start.", ACCOUNT or "")
            return
        self._proxy()

    def _form(self, error: str, username: str) -> None:
        body = page(error, username)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _proxy(self) -> None:
        try:
            backend = socket.create_connection(("127.0.0.1", 6080), timeout=10)
        except OSError:
            self.send_error(502, "desktop proxy is not ready")
            return
        request = f"{self.command} {self.path} HTTP/1.1\r\n"
        for key, value in self.headers.items():
            if key.lower() == "host":
                value = "127.0.0.1:6080"
            request += f"{key}: {value}\r\n"
        request += "\r\n"
        try:
            backend.sendall(request.encode())
            self._splice(backend)
        except OSError:
            pass
        finally:
            backend.close()
        self.close_connection = True

    def _splice(self, backend: socket.socket) -> None:
        client = self.connection
        def pump(src: socket.socket, dst: socket.socket) -> None:
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        break
                    dst.sendall(data)
            except OSError:
                pass
            try:
                dst.shutdown(socket.SHUT_WR)
            except OSError:
                pass

        left = threading.Thread(target=pump, args=(client, backend), daemon=True)
        right = threading.Thread(target=pump, args=(backend, client), daemon=True)
        left.start()
        right.start()
        left.join()
        right.join()


def main() -> None:
    global ACCOUNT
    import sys
    account = sys.argv[1] if len(sys.argv) == 2 else ""
    if not USER_RE.fullmatch(account):
        print("mint-login: account name missing; the login page stays up and sign-in fails", flush=True)
        account = ""
    ACCOUNT = account
    # Bind before any desktop or libcrypt work. Cloudflare 502 means this socket is down.
    server = ThreadingHTTPServer(("0.0.0.0", 3000), Handler)
    print(f"Mint login on http://0.0.0.0:3000 for {ACCOUNT or 'unset'}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
EOF
chmod 755 /usr/local/bin/mint-login.py

cat > /usr/local/bin/mint-desktop.sh << 'EOF'
#!/bin/bash
set -eu
user='@MINT_USER@'
mkdir -p /var/log
# Local noVNC backend only. A failure here must not stop port 3000.
websockify --web /usr/share/novnc --heartbeat 30 127.0.0.1:6080 127.0.0.1:5901 >>/var/log/mint-websockify.log 2>&1 &
echo "starting Mint login on port 3000 for ${user}"
exec python3 -u /usr/local/bin/mint-login.py "$user"
EOF
sed -i "s/@MINT_USER@/${user}/" /usr/local/bin/mint-desktop.sh
chmod 755 /usr/local/bin/mint-desktop.sh

cat > /etc/systemd/system/mint-desktop.service << 'EOF'
[Unit]
Description=Mint login and Cinnamon over HTTP
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

# xrdp stays off. The browser login page is the sign-in, then Cinnamon.
ln -sfn /dev/null /etc/systemd/system/lightdm.service
ln -sfn /dev/null /etc/systemd/system/xrdp.service
ln -sfn /dev/null /etc/systemd/system/xrdp-sesman.service
rm -f /etc/systemd/system/display-manager.service
ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target

exec /lib/systemd/systemd
