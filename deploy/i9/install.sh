#!/usr/bin/env bash
# Install the GitClub disaster recovery tooling on the i9 machine.
#
# Places the sweep and recovery commands, the systemd units, and the config
# templates. Does not start anything and does not overwrite an existing
# /etc/gitclub/mirror-sweep.env or /etc/pgbackrest/pgbackrest.conf, so it is
# safe to re-run after pulling a new revision.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local/bin}"
MIRRORS="${GITCLUB_MIRRORS:-/var/lib/gitclub/mirrors}"

die() { echo "install: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root"

# A dedicated account: the sweep holds a token that can read every repository,
# so it should not run as the postgres user or as root.
if ! id -u gitclub >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/gitclub --create-home --shell /usr/sbin/nologin gitclub
  echo "created the gitclub system account"
fi

install -m 0755 "$HERE/gitclub-mirror-sweep" "$PREFIX/gitclub-mirror-sweep"
install -m 0755 "$HERE/gitclub-recover" "$PREFIX/gitclub-recover"
install -d -o gitclub -g gitclub -m 0750 "$MIRRORS"
install -d -m 0755 /etc/gitclub /etc/pgbackrest

for template in mirror-sweep.env:/etc/gitclub/mirror-sweep.env \
                pgbackrest.conf:/etc/pgbackrest/pgbackrest.conf; do
  source_name="${template%%:*}"
  target="${template##*:}"
  if [ -e "$target" ]; then
    echo "keeping existing $target"
  else
    install -m 0600 "$HERE/${source_name}.example" "$target"
    echo "installed $target from the example; fill in the CHANGEME values"
  fi
done
chown gitclub:gitclub /etc/gitclub/mirror-sweep.env

install -m 0644 "$HERE/systemd/gitclub-mirror-sweep.service" /etc/systemd/system/
install -m 0644 "$HERE/systemd/gitclub-mirror-sweep.timer" /etc/systemd/system/
install -m 0644 "$HERE/systemd/gitclub-standby.service" /etc/systemd/system/
systemctl daemon-reload

cat <<'NEXT'

Installed. Remaining steps, in order:

  1. Fill in /etc/pgbackrest/pgbackrest.conf from the Railway Postgres
     service's WAL_ARCHIVE_* variables (read-only key).
  2. sudo ./bootstrap-standby.sh
  3. systemctl enable --now gitclub-standby.service
  4. Fill in /etc/gitclub/mirror-sweep.env with the server URL and a token
     that can read every repository.
  5. sudo -u gitclub gitclub-mirror-sweep          # run once by hand first
  6. systemctl enable --now gitclub-mirror-sweep.timer
  7. gitclub-recover status
  8. Run the drill in deploy/RUNBOOK.md.
NEXT
