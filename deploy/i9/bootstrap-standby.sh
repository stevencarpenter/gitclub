#!/usr/bin/env bash
# Bring up the GitClub disaster recovery standby on this machine.
#
# Restores the most recent base backup from the Railway PITR bucket and leaves
# PostgreSQL in continuous recovery with hot_standby off, so it replays the
# archive forever and accepts no connections.
#
# Run once, as root, after installing /etc/pgbackrest/pgbackrest.conf from
# pgbackrest.conf.example. Re-running refuses unless --force is given.
set -euo pipefail

PGDATA="${GITCLUB_STANDBY_PGDATA:-/var/lib/gitclub/standby}"
STANZA="${GITCLUB_STANZA:-main}"
PGUSER_NAME="${GITCLUB_PG_USER:-postgres}"
PGBIN="${GITCLUB_PG_BIN:-/usr/lib/postgresql/18/bin}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

die() { echo "bootstrap-standby: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f /etc/pgbackrest/pgbackrest.conf ] || die "install /etc/pgbackrest/pgbackrest.conf first (see pgbackrest.conf.example)"
command -v pgbackrest >/dev/null || die "pgbackrest is not installed"
[ -x "$PGBIN/postgres" ] || die "PostgreSQL binaries not found at $PGBIN; set GITCLUB_PG_BIN"

# The standby must match the primary's major version or replay will refuse.
PRIMARY_MAJOR="$(pgbackrest --stanza="$STANZA" info --output=json 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["db"][0]["version"] if d and d[0].get("db") else "")' || true)"
LOCAL_MAJOR="$("$PGBIN/postgres" --version | grep -oE '[0-9]+' | head -1)"
if [ -n "$PRIMARY_MAJOR" ] && [ "${PRIMARY_MAJOR%%.*}" != "$LOCAL_MAJOR" ]; then
  die "archive holds PostgreSQL $PRIMARY_MAJOR but this machine has $LOCAL_MAJOR. A standby cannot replay across a major version."
fi

if [ -d "$PGDATA" ] && [ -n "$(ls -A "$PGDATA" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
  die "$PGDATA is not empty. Pass --force to discard it and restore again."
fi

id -u "$PGUSER_NAME" >/dev/null 2>&1 || die "user $PGUSER_NAME does not exist"
install -d -o "$PGUSER_NAME" -g "$PGUSER_NAME" -m 0700 "$PGDATA" /var/log/pgbackrest
install -d -o "$PGUSER_NAME" -g "$PGUSER_NAME" -m 0750 "${GITCLUB_MIRRORS:-/var/lib/gitclub/mirrors}"

echo "restoring the most recent base backup into $PGDATA"
sudo -u "$PGUSER_NAME" pgbackrest --stanza="$STANZA" --pg1-path="$PGDATA" \
  --type=standby --delta restore

# --type=standby writes standby.signal and a restore_command; the include below
# pins hot_standby off and the rest of the standby's settings.
install -o "$PGUSER_NAME" -g "$PGUSER_NAME" -m 0600 \
  "$HERE/postgresql.standby.conf" "$PGDATA/gitclub-standby.conf"
if ! grep -q "gitclub-standby.conf" "$PGDATA/postgresql.conf" 2>/dev/null; then
  echo "include = 'gitclub-standby.conf'" >> "$PGDATA/postgresql.conf"
  chown "$PGUSER_NAME:$PGUSER_NAME" "$PGDATA/postgresql.conf"
fi
[ -f "$PGDATA/standby.signal" ] || sudo -u "$PGUSER_NAME" touch "$PGDATA/standby.signal"

echo
echo "Standby restored. Start it and confirm it stays in recovery:"
echo "  systemctl enable --now gitclub-standby.service"
echo "  journalctl -u gitclub-standby -f"
echo
echo "It will refuse connections by design (hot_standby = off). Check progress with:"
echo "  pg_controldata -D $PGDATA | grep -E 'cluster state|REDO location'"
