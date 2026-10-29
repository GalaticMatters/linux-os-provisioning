#!/bin/bash
# dockerscripts/linuxmint:cinnamon is a real Mint Cinnamon desktop (xrdp).
# Create this container's own account, put it in sudo, and start Cinnamon
# directly. Do not use the shared van account or a display-manager greeter.
set -eu

user=${MINT_USER:-}
home="/home/${user}"

if [ -z "$user" ] || [ "$user" = "root" ] || ! printf '%s' "$user" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "MINT_USER must be a lowercase account name other than root (set DEREK_USER or VYAS_USER)" >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
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

# Cinnamon session for xrdp. Skip LightDM so there is no local greeter.
printf '%s\n' 'export CINNAMON_2D=true' > /etc/X11/Xsession.d/99cinnamon2d
chmod 644 /etc/X11/Xsession.d/99cinnamon2d
if [ -x /usr/bin/cinnamon-session ]; then
  update-alternatives --set x-session-manager /usr/bin/cinnamon-session || true
fi
cat > /etc/xrdp/startwm.sh << 'WM'
#!/bin/sh
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR
export CINNAMON_2D=true
export XDG_CURRENT_DESKTOP=X-Cinnamon
export XDG_SESSION_DESKTOP=cinnamon
export XDG_SESSION_TYPE=x11
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
exec /usr/bin/cinnamon-session
WM
chmod 755 /etc/xrdp/startwm.sh

mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn /dev/null /etc/systemd/system/lightdm.service
rm -f /etc/systemd/system/display-manager.service
ln -sfn /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
for unit in xrdp.service xrdp-sesman.service; do
  for dir in /lib/systemd/system /usr/lib/systemd/system; do
    if [ -f "$dir/$unit" ]; then
      ln -sfn "$dir/$unit" "/etc/systemd/system/multi-user.target.wants/$unit"
    fi
  done
done

exec /lib/systemd/systemd
