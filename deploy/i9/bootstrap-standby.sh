#!/usr/bin/env bash
# Bring up the GitClub disaster recovery standby on this machine.
#
# Restores the most recent base backup from the Railway PITR bucket and leaves
# PostgreSQL in continuous recovery with hot_standby off, so it replays the
# archive forever and accepts no connections.
#
# Run as postgres (or root on Linux) after installing the pgBackRest config.
# Re-running refuses unless --force is given.
set -euo pipefail

PGDATA="${GITCLUB_STANDBY_PGDATA:-/var/lib/gitclub/standby}"
STANZA="${GITCLUB_STANZA:-main}"
PGUSER_NAME="${GITCLUB_PG_USER:-postgres}"
PGBIN="${GITCLUB_PG_BIN:-/usr/lib/postgresql/18/bin}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0

die() { echo "bootstrap-standby: $*" >&2; exit 1; }
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) die "usage: bootstrap-standby.sh [--force]" ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  install -d -o "$PGUSER_NAME" -g "$PGUSER_NAME" -m 0700 "$PGDATA" /var/log/pgbackrest
  exec runuser -u "$PGUSER_NAME" -- "$0" "$@"
fi
[ "$(id -un)" = "$PGUSER_NAME" ] || die "run as $PGUSER_NAME or root"
[ -r /etc/pgbackrest/pgbackrest.conf ] || die "install readable /etc/pgbackrest/pgbackrest.conf first (see pgbackrest.conf.example)"
command -v pgbackrest >/dev/null || die "pgbackrest is not installed"
[ -x "$PGBIN/postgres" ] || die "PostgreSQL binaries not found at $PGBIN; set GITCLUB_PG_BIN"

if [ -d "$PGDATA" ] && [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
  die "$PGDATA is not empty. Pass --force to discard it and restore again."
fi
[ ! -f "$PGDATA/postmaster.pid" ] || die "stop PostgreSQL before restoring this directory"

# The standby must match the primary's major version or replay will refuse.
PRIMARY_MAJOR="$(pgbackrest --stanza="$STANZA" info --output=json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["db"][-1]["version"] if d and d[0].get("db") else "")')"
[[ "$("$PGBIN/postgres" --version)" =~ ([0-9]+) ]]
LOCAL_MAJOR="${BASH_REMATCH[1]}"
if [ -n "$PRIMARY_MAJOR" ] && [ "${PRIMARY_MAJOR%%.*}" != "$LOCAL_MAJOR" ]; then
  die "archive holds PostgreSQL $PRIMARY_MAJOR but this machine has $LOCAL_MAJOR. A standby cannot replay across a major version."
fi

install -d -m 0700 "$PGDATA"

echo "restoring the most recent base backup into $PGDATA"
pgbackrest --stanza="$STANZA" --pg1-path="$PGDATA" \
  --type=standby --delta restore

# --type=standby writes standby.signal and a restore_command; the include below
# pins hot_standby off and the rest of the standby's settings.
install -m 0600 \
  "$HERE/postgresql.standby.conf" "$PGDATA/gitclub-standby.conf"
if ! grep -q "gitclub-standby.conf" "$PGDATA/postgresql.conf" 2>/dev/null; then
  echo "include = 'gitclub-standby.conf'" >> "$PGDATA/postgresql.conf"
fi
[ -f "$PGDATA/standby.signal" ] || touch "$PGDATA/standby.signal"

echo
echo "Standby restored. Start it and confirm it stays in recovery:"
echo "  docker compose up -d standby"
echo "  docker compose logs --tail=50 standby"
echo
echo "It will refuse connections by design (hot_standby = off). Check progress with:"
echo "  pg_controldata -D $PGDATA"
