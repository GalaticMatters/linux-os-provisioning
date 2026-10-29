#!/bin/bash
# infrastlabs/docker-headless:cinna signs in as "headless".
# Rename that account to DESKTOP_USER (van) and keep the home on the named volume.
set -eu

user=${DESKTOP_USER:-van}
home=/home/van

if [ "$user" = "root" ] || ! printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "DESKTOP_USER must be a lowercase account name other than root" >&2
  exit 1
fi

if id headless >/dev/null 2>&1 && [ "$user" != "headless" ]; then
  usermod -l "$user" headless
  if getent group headless >/dev/null 2>&1 && ! getent group "$user" >/dev/null 2>&1; then
    groupmod -n "$user" headless
  fi
fi

if ! id "$user" >/dev/null 2>&1; then
  echo "account $user does not exist in this image" >&2
  exit 1
fi

mkdir -p "$home"
if [ -d /home/headless ] && [ -z "$(ls -A "$home" 2>/dev/null || true)" ]; then
  cp -a /home/headless/. "$home/"
fi
usermod -d "$home" "$user"
if getent group "$user" >/dev/null 2>&1; then
  chown -R "$user:$user" "$home"
else
  chown -R "$user" "$home"
fi

# Point the image entrypoint at this account. Leave the name1==headless
# branch (it selects the real session) and the default VNC password check.
if [ -f /entry.sh ] && ! grep -q "user1=${user}" /entry.sh; then
  sed -i \
    -e "s|user1=headless|user1=${user}|" \
    -e "s|/home/headless|${home}|g" \
    -e "s/USER=headless/USER=${user}/g" \
    -e "s/user=headless/user=${user}/g" \
    -e "s/chown headless:headless/chown ${user}:${user}/g" \
    -e "s/echo \"headless:/echo \"${user}:/" \
    /entry.sh
fi

if [ -f /etc/systemd/system/de-start.service ]; then
  sed -i \
    -e "s|/home/headless|${home}|g" \
    -e "s/User=headless/User=${user}/g" \
    /etc/systemd/system/de-start.service
fi

if [ -n "${SSH_PASS:-}" ]; then
  printf '%s:%s\n' "$user" "$SSH_PASS" | chpasswd
fi

if [ -n "${VNC_PASS:-}" ] && command -v vncpasswd >/dev/null 2>&1; then
  ro=${VNC_PASS_RO:-$VNC_PASS}
  printf '%s\n%s\ny\n%s\n%s\n' "$VNC_PASS" "$VNC_PASS" "$ro" "$ro" | vncpasswd /etc/xrdp/vnc_pass || true
  chmod 644 /etc/xrdp/vnc_pass 2>/dev/null || true
fi

exec /entry.sh
