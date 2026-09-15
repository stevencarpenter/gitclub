#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = mirror ]; then
  # Compose bind-mounted secrets retain the host UID, so root reads the file
  # before dropping privileges. The token never enters Compose's environment.
  source /run/secrets/mirror-sweep
  export GITCLUB_URL GITCLUB_TOKEN GITCLUB_MIRRORS
  install -d -o postgres -g postgres -m 0700 "$GITCLUB_MIRRORS"
  exec gosu postgres /usr/local/bin/mirror-loop.sh
fi

install -d -m 0755 /etc/pgbackrest
install -o postgres -g postgres -m 0600 /run/secrets/pgbackrest /etc/pgbackrest/pgbackrest.conf
install -d -o postgres -g postgres -m 0700 "$PGDATA" /var/log/pgbackrest

case "${1:-}" in
  bootstrap)
    shift
    exec gosu postgres /usr/local/bin/bootstrap-standby.sh "$@"
    ;;
  standby)
    if [ ! -f "$PGDATA/standby.signal" ]; then
      echo "standby: bootstrap this volume before starting continuous replay" >&2
      exit 1
    fi
    exec gosu postgres postgres -D "$PGDATA" -c hot_standby=off \
      -c listen_addresses= -c port=5433 -c ssl=off \
      -c archive_mode=off -c logging_collector=off
    ;;
  *) exec gosu postgres "$@" ;;
esac
