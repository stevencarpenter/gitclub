#!/usr/bin/env bash
# Run inside a disposable image: docker run --rm --entrypoint bash gitclub-dr:local /opt/gitclub/test_runtime.sh
set -euo pipefail

work=$(mktemp -d /tmp/gitclub-runtime.XXXXXX)
chown postgres:postgres "$work"
chmod 0755 "$work"
export PGDATA="$work/standby" GITCLUB_STANDBY_PGDATA="$work/standby"
install -d -o postgres -g postgres -m 0700 "$work/primary" "$work/repo" "$work/socket"
install -d /run/secrets
cat > /run/secrets/pgbackrest <<EOF
[global]
repo1-type=posix
repo1-path=$work/repo
log-level-file=off
log-level-console=warn
[main]
pg1-path=$work/primary
pg1-port=55432
pg1-socket-path=$work/socket
EOF

dr-entrypoint.sh bash -c '[ "$(id -u)" = 999 ] && [ "$(stat -c %a /etc/pgbackrest/pgbackrest.conf)" = 600 ] && [ -r /etc/pgbackrest/pgbackrest.conf ] && [ -w "$PGDATA" ]'
if dr-entrypoint.sh standby > "$work/unbootstrapped.log" 2>&1; then
  echo "unbootstrapped standby unexpectedly started" >&2
  exit 1
fi
grep -q 'bootstrap this volume' "$work/unbootstrapped.log"

cleanup() {
  gosu postgres pg_ctl -D "$PGDATA" -m immediate -w stop >/dev/null 2>&1 || true
  gosu postgres pg_ctl -D "$work/primary" -m immediate -w stop >/dev/null 2>&1 || true
}
trap cleanup EXIT
gosu postgres initdb -D "$work/primary" -A trust >/dev/null
cat >> "$work/primary/postgresql.conf" <<EOF
max_connections = 150
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
EOF
gosu postgres pg_ctl -D "$work/primary" -l "$work/primary.log" \
  -o "-k $work/socket -p 55432 -c listen_addresses=''" -w start >/dev/null
gosu postgres pgbackrest --stanza=main stanza-create
gosu postgres psql -h "$work/socket" -p 55432 -d postgres -c 'CREATE TABLE recovery_probe (value integer); INSERT INTO recovery_probe VALUES (1);' >/dev/null

# Recovery must detect missing objects and recreate server settings that a
# Git mirror does not contain. All fixtures are local to this disposable image.
useradd --uid 10001 git
install -d -o postgres -g postgres "$work/mirrors"
gosu postgres git init --bare --initial-branch=old "$work/mirrors/1.git" >/dev/null
tree=$(gosu postgres git --git-dir="$work/mirrors/1.git" hash-object -t tree --stdin </dev/null)
oid=$(gosu postgres git --git-dir="$work/mirrors/1.git" -c user.name=Test -c user.email=test@example.invalid commit-tree "$tree" -m test)
gosu postgres git --git-dir="$work/mirrors/1.git" update-ref refs/heads/trunk "$oid"
export DATABASE_URL="postgresql://postgres@/postgres?host=$work/socket&port=55432"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 >/dev/null <<SQL
CREATE TABLE repositories (id integer, default_branch text, default_oid text);
CREATE TABLE pull_requests (id integer, repo_id integer, merged_oid text);
CREATE TABLE comments (repo_id integer, commit_oid text);
CREATE TABLE reviews (pull_id integer, commit_oid text);
INSERT INTO repositories VALUES (1, 'trunk', '$oid');
INSERT INTO pull_requests VALUES (2, 1, '$oid');
INSERT INTO comments VALUES (1, '$oid');
INSERT INTO reviews VALUES (2, '$oid');
SQL
gosu postgres gitclub-verify-recovery "$work/mirrors"
psql "$DATABASE_URL" -c "UPDATE reviews SET commit_oid=repeat('0',40)" >/dev/null
if gosu postgres gitclub-verify-recovery "$work/mirrors" > "$work/missing.log" 2>&1; then
  echo "verification accepted a missing review commit" >&2
  exit 1
fi
grep -q 'MISSING review_oid' "$work/missing.log"
psql "$DATABASE_URL" -c "UPDATE reviews SET commit_oid='$oid'" >/dev/null
export DATA_DIR="$work/serving" SHARED_DIR="$work/shared" GITCLUB_MIRRORS="$work/mirrors"
mkdir "$SHARED_DIR"
printf '#!/bin/sh\nexit 1\n' > "$SHARED_DIR/git-hook.py"
python3 /opt/gitclub/prepare-repositories.py
for hook in pre-receive post-receive; do
  cmp "$SHARED_DIR/git-hook.py" "$DATA_DIR/repos/1.git/hooks/$hook"
  [ "$(stat -c %a "$DATA_DIR/repos/1.git/hooks/$hook")" = 700 ]
  [ "$(stat -c %u "$DATA_DIR/repos/1.git/hooks/$hook")" = 10001 ]
  [ ! -f "$GITCLUB_MIRRORS/1.git/hooks/$hook" ]
done
[ "$(gosu git git --git-dir="$DATA_DIR/repos/1.git" symbolic-ref HEAD)" = refs/heads/trunk ]
[ "$(gosu git git --git-dir="$DATA_DIR/repos/1.git" config http.receivepack)" = true ]
[ "$(gosu git git --git-dir="$DATA_DIR/repos/1.git" config transfer.hideRefs)" = refs/gitclub/ ]
if python3 /opt/gitclub/prepare-repositories.py > "$work/overwrite.log" 2>&1; then
  echo "repository preparation overwrote a populated directory" >&2
  exit 1
fi
grep -q 'Refusing to overwrite' "$work/overwrite.log"

# The shell-quoted preview must match the actual default restore invocation.
python3 - "$work" <<'PY'
import json, os, shlex, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'mirrors/sweep-state.json').write_text(json.dumps({
    'format': 1, 'repository_count': 1, 'recovery_target_utc': '2026-09-15T00:00:00Z'}))
fake = root / 'fake-bin'
fake.mkdir()
(fake / 'pgbackrest').write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\n')
(fake / 'pgbackrest').chmod(0o755)
common = ['gitclub-recover', '--mirrors', str(root / 'mirrors'), '--target-dir', str(root / 'quoted target')]
preview = subprocess.check_output(common + ['plan'], text=True).splitlines()[-1]
env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'], CAPTURE=str(root / 'restore-args'))
subprocess.run(common + ['promote', '--yes'], env=env, check=True, stdout=subprocess.DEVNULL)
actual = ['pgbackrest'] + (root / 'restore-args').read_text().splitlines()
assert shlex.split(preview) == actual
assert '--delta' not in actual
subprocess.run(common + ['promote', '--yes', '--delta'], env=env, check=True, stdout=subprocess.DEVNULL)
assert '--delta' in (root / 'restore-args').read_text().splitlines()
PY

gosu postgres pgbackrest --stanza=main --type=full --start-fast backup
dr-entrypoint.sh bootstrap
[ "$(gosu postgres postgres -D "$PGDATA" -C max_connections)" = 150 ]
[ -f "$PGDATA/standby.signal" ]
if dr-entrypoint.sh bootstrap > "$work/repeat.log" 2>&1; then
  echo "bootstrap unexpectedly overwrote an existing standby" >&2
  exit 1
fi
grep -q 'is not empty' "$work/repeat.log"

dr-entrypoint.sh standby > "$work/standby.log" 2>&1 &
for attempt in {1..60}; do
  if grep -q 'consistent recovery state reached' "$work/standby.log"; then break; fi
  sleep 1
done
grep -q 'consistent recovery state reached' "$work/standby.log" || { cat "$work/standby.log"; exit 1; }
gosu postgres pg_controldata -D "$PGDATA" | grep -q 'in archive recovery'
ready=0
pg_isready -h /var/run/postgresql -p 5433 >/dev/null || ready=$?
[ "$ready" = 1 ]

# A failed sweep must still wait for the next interval, without a busy retry.
mkdir "$work/bin"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/gitclub-mirror-sweep"
printf '#!/bin/sh\necho 100\n' > "$work/bin/date"
printf '#!/bin/sh\n[ "$1" = 300 ] || exit 2\nexit 99\n' > "$work/bin/sleep"
chmod 0755 "$work/bin/"*
result=0
PATH="$work/bin:$PATH" mirror-loop.sh || result=$?
[ "$result" = 99 ]
echo 'runtime checks passed: private config, object verification, repository preparation, empty-volume guards, real pgBackRest restore, archive recovery, connection refusal, sweep retry interval'
