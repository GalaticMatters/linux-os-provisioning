#!/bin/sh
# Fleet Ubuntu (ubuntu01–30, ubuntuserver, vai) uses the same Docker runtime
# as ubuntu111: kata-runtime. This name is the fleet installer; it runs the
# same ProLiant host install.
echo "Ubuntu fleet uses Kata Containers (kata-runtime). Running install-ubuntu111-kata.sh" >&2
exec "$(dirname "$0")/install-ubuntu111-kata.sh" "$@"
