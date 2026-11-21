#!/bin/sh
# ubuntu111 is Kata now, not Sysbox. This name remains so an old command still
# installs the current host runtime.
echo "ubuntu111 uses Kata Containers (kata-runtime), not Sysbox. Running install-ubuntu111-kata.sh" >&2
exec "$(dirname "$0")/install-ubuntu111-kata.sh" "$@"
