#!/bin/sh
# Apply SSH_USER plus a key and/or password from the environment, then run sshd.
# Host keys are created here, on the container's writable layer, so recreate wipes them.
set -eu

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

mkdir -p /run/sshd
cat > /etc/ssh/sshd_config.d/cybersecurity.conf << EOF
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
