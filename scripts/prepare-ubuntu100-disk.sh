#!/bin/sh
# Create a 500 GB sparse disk for the ubuntu100 desktop and mount it.
# The file uses almost no space until the desktop writes data.
# It cannot grow past 500 GB.
set -eu

img=/var/lib/cybersecurity/ubuntu100.img
mnt=/var/lib/cybersecurity/ubuntu100

mkdir -p /var/lib/cybersecurity
if [ ! -f "$img" ]; then
  truncate -s 500G "$img"
  mkfs.ext4 -F -L ubuntu100 "$img"
fi
mkdir -p "$mnt"
if ! findmnt -n "$mnt" >/dev/null 2>&1; then
  mount -o loop "$img" "$mnt"
fi
grep -q 'ubuntu100.img' /etc/fstab || printf '%s %s ext4 loop,nofail 0 2\n' "$img" "$mnt" >> /etc/fstab
