#!/bin/sh
# Apply SSH_USER plus a key and/or password from the environment, then run sshd.
# Host keys are created here, on the container's writable layer, so recreate wipes them.
set -eu

# CTFd image: dedicated account from CTFD_USER / CTFD_PASSWORD. Do not use
# DESKTOP_USER (that is vai). Do not default a password here.
if [ -d /opt/CTFd ]; then
  if [ -z "${CTFD_PASSWORD:-}" ]; then
    echo "Set CTFD_PASSWORD in .env. Do not commit it. ctfd will not start without it." >&2
    exit 1
  fi
  SSH_USER=${CTFD_USER:-ctfd}
  SSH_PASSWORD=$CTFD_PASSWORD
fi

if [ -z "${SSH_USER:-}" ]; then
  echo "Set SSH_USER in .env." >&2
  exit 1
fi

case "$SSH_USER" in
  root)
    echo "SSH_USER must not be root." >&2
    exit 1
    ;;
  [a-z_][a-z0-9_-]*)
    ;;
  *)
    echo "SSH_USER must be a lowercase account name, got: $SSH_USER" >&2
    exit 1
    ;;
esac

if [ "${#SSH_USER}" -gt 32 ]; then
  echo "SSH_USER must be 32 characters or fewer." >&2
  exit 1
fi

has_key=0
has_pass=0
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  has_key=1
fi
if [ -n "${SSH_PASSWORD:-}" ]; then
  has_pass=1
fi
if [ "$has_key" -eq 0 ] && [ "$has_pass" -eq 0 ]; then
  echo "Set SSH_PUBLIC_KEY or SSH_PASSWORD in .env. Do not commit either value." >&2
  exit 1
fi

if [ "$has_key" -eq 1 ]; then
  case "$SSH_PUBLIC_KEY" in
    *'
'*)
      echo "SSH_PUBLIC_KEY must be one OpenSSH public key on a single line." >&2
      exit 1
      ;;
    ssh-*|ecdsa-*|sk-*)
      ;;
    *)
      echo "SSH_PUBLIC_KEY must be one OpenSSH public key (ssh-ed25519, ssh-rsa, ecdsa-sha2-*, or sk-)." >&2
      exit 1
      ;;
  esac
fi

if [ "$has_pass" -eq 1 ]; then
  case "$SSH_PASSWORD" in
    *'
'*)
      echo "SSH_PASSWORD must be a single line." >&2
      exit 1
      ;;
  esac
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --user-group "$SSH_USER"
fi
# A named volume may already be mounted on the home directory (vai).
# useradd leaves that mount owned by root, so the account could not write it.
if [ -d "/home/$SSH_USER" ]; then
  chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER"
fi
usermod -aG sudo "$SSH_USER"

if [ "$has_pass" -eq 1 ]; then
  printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd
  pass_flag=yes
else
  pass_flag=no
fi

if [ "$has_key" -eq 1 ]; then
  install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "/home/$SSH_USER/.ssh"
  printf '%s\n' "$SSH_PUBLIC_KEY" > "/home/$SSH_USER/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
fi

if [ -f /etc/pam.d/sshd ]; then
  sed -i 's/^session[[:space:]]\+required[[:space:]]\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd
fi

# Kata guest: Docker DNS 127.0.0.11 is in the shim. Rename the pair extra
# NIC to veth-peer (unnumbered). Failures must not block sshd.
if [ -x /usr/local/bin/kata-net.sh ]; then
  /usr/local/bin/kata-net.sh || true
fi
if [ -x /usr/local/bin/rename-veth-peer.sh ]; then
  /usr/local/bin/rename-veth-peer.sh || true
fi

# CTFd image only (/opt/CTFd). Fleet Ubuntu has no such tree; sshd still starts.
start_ctfd() {
  if [ ! -d /opt/CTFd ] || [ ! -x /opt/CTFd/.venv/bin/gunicorn ]; then
    return 0
  fi
  data=/var/lib/ctfd
  mkdir -p "$data/uploads" "$data/logs"
  secret="${CTFD_SECRET_KEY:-${SECRET_KEY:-}}"
  if [ -z "$secret" ] && [ -f "$data/secret_key" ]; then
    secret=$(cat "$data/secret_key")
  fi
  if [ -z "$secret" ]; then
    echo "ctfd: set CTFD_SECRET_KEY in .env; CTFd not started (sshd still runs)" >&2
    return 0
  fi
  printf '%s\n' "$secret" > "$data/secret_key"
  chmod 600 "$data/secret_key" || true
  export SECRET_KEY="$secret"
  export DATABASE_URL="${DATABASE_URL:-sqlite:////var/lib/ctfd/ctfd.db}"
  export UPLOAD_FOLDER="${UPLOAD_FOLDER:-/var/lib/ctfd/uploads}"
  export FLASK_APP=CTFd
  export SKIP_DB_PING=true
  (
    cd /opt/CTFd
    /opt/CTFd/.venv/bin/flask db upgrade || echo "ctfd: flask db upgrade failed" >&2
    if [ -f /usr/local/bin/ctfd-ensure-admin.py ]; then
      /opt/CTFd/.venv/bin/python /usr/local/bin/ctfd-ensure-admin.py || \
        echo "ctfd: admin seed skipped (use the web setup)" >&2
    fi
    exec /opt/CTFd/.venv/bin/gunicorn 'CTFd:create_app()' \
      --bind 0.0.0.0:8000 \
      --workers 1 \
      --worker-class sync \
      --access-logfile "$data/logs/access.log" \
      --error-logfile "$data/logs/error.log"
  ) &
  echo "ctfd: gunicorn on 0.0.0.0:8000 (data ${data})"
}

start_ctfd

mkdir -p /run/sshd
cat > /etc/ssh/sshd_config.d/cybersecurity.conf << EOF
ListenAddress 0.0.0.0
Port 22
AddressFamily inet
PasswordAuthentication ${pass_flag}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers ${SSH_USER}
UsePAM yes
X11Forwarding no
PrintMotd no
ClientAliveInterval 60
EOF

ssh-keygen -A >/dev/null
/usr/sbin/sshd -t
exec /usr/sbin/sshd -D -e
