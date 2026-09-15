# GitClub disaster recovery runbook

Railway serves GitClub. The i9 machine holds a PostgreSQL standby and a set of
Git mirrors and serves nothing. Recovery restores the database to the mirror
sweep's recovery target, not to the standby's current position.

The rule everything else follows: **restore PostgreSQL to a point at or before
the start of the last completed Git mirror sweep.** Metadata behind code is
safe. Code behind metadata is not, because `repositories.default_oid`,
`pull_requests.merged_oid`, `comments.commit_oid` and `reviews.commit_oid` would
name Git objects this machine does not hold.

## Bring-up order

Each step depends on the one before it.

1. **Railway project and service.** From the repository root, `railway login`,
   `railway link`, then `railway config plan` and `railway config apply`. The
   definition is `.railway/railway.ts`.
2. **Sealed SSH secret.** Set `GITCLUB_SSH_SECRET` on the `gitclub` service to
   at least 32 random characters (`python3 -c "import secrets;
   print(secrets.token_hex(32))"`). The IaC file keeps it with `preserve()` so
   it never enters git. Without it the container serves HTTP Git only.
3. **SSH TCP proxy.** Service Settings, Networking, Public Access, port 2222.
   Railway allows one TCP proxy per service; HTTP goes through the domain.
4. **Point-in-Time Recovery.** Postgres service, Backups tab, Enable PITR.
   This creates the `Postgres-PITR` bucket and starts archiving every WAL
   segment. **Nothing downstream works until this is on**, because the bucket
   is how write-ahead log reaches the i9.
5. **Read-only bucket credentials** for the i9, from the Postgres service's
   `WAL_ARCHIVE_*` variables.
6. **i9 standby.** Install `pgbackrest.conf` from `deploy/i9/pgbackrest.conf.example`,
   then `sudo deploy/i9/bootstrap-standby.sh`, then
   `systemctl enable --now gitclub-standby.service`.
7. **i9 mirror sweep.** Create a GitClub account with read access to every
   repository, mint a token, fill `/etc/gitclub/mirror-sweep.env` from
   `deploy/i9/mirror-sweep.env.example`, install the unit and timer, then
   `systemctl enable --now gitclub-mirror-sweep.timer`.
8. **Run the drill below.** An untested recovery path is not a recovery path.

## Health

```sh
gitclub-recover status
```

Reports what the mirror covers, what the standby has replayed, and warns when
the recovery target is stale. A stale target is the common real failure: the
sweep timer stopped and nobody noticed, so the recoverable point silently aged.

Check these when something looks wrong:

- `systemctl status gitclub-mirror-sweep.timer` and `journalctl -u gitclub-mirror-sweep`
- `systemctl status gitclub-standby` and `pg_controldata -D /var/lib/gitclub/standby`
- `pgbackrest --stanza=main info` for archive freshness
- Railway, Postgres service, Backups tab for archiver health

## Recovery

Do this when Railway is lost and GitClub must come back on the i9.

1. **Stop the sweep.** `systemctl stop gitclub-mirror-sweep.timer`. A sweep
   against a dead or half-dead primary can fail midway and is noise you do not
   need during recovery.
2. **Read the target.** `gitclub-recover status`. Note the recovery target and
   how old it is. Everything pushed after it is not recoverable. If that
   window is unacceptable, stop and decide whether to wait for Railway instead.
3. **Review the plan.** `gitclub-recover plan`. It prints the exact
   `pgbackrest restore` and changes nothing.
4. **Restore.** `gitclub-recover promote --yes`. This restores into
   `/var/lib/gitclub/recovered` and promotes. The standby at
   `/var/lib/gitclub/standby` is left untouched, so a failed restore costs
   nothing and can be retried.
5. **Place the repositories.** Copy the mirrors into the new server's data
   directory as `repos/<id>.git`. The mirror directories are already named by
   repository id:
   ```sh
   install -d -m 0700 /var/lib/gitclub/serving/repos
   cp -a /var/lib/gitclub/mirrors/*.git /var/lib/gitclub/serving/repos/
   ```
6. **Start GitClub** against the recovered database and that data directory,
   with `PUBLIC_URL` set to the new external origin. Browser writes validate
   Origin against it, so a wrong value rejects every mutation with 403.
7. **Verify before announcing.** See below.
8. **Repoint DNS** once verification passes.

### Verify a recovery

```sh
curl -fsS "$PUBLIC_URL/health"
python3 tests/acceptance.py --url "$PUBLIC_URL"
```

Then confirm the invariant actually held, which the acceptance suite does not
check because it creates its own fixtures:

```sh
# Every Git object id the database names must exist in the restored repository.
psql "$DATABASE_URL" -tAc "SELECT id, default_oid FROM repositories WHERE default_oid <> ''" |
while IFS='|' read -r id oid; do
  git --git-dir="/var/lib/gitclub/serving/repos/$id.git" cat-file -e "$oid^{commit}" \
    || echo "MISSING default_oid $oid in repository $id"
done
```

Repeat for `pull_requests.merged_oid`. Output means the ordering invariant was
violated and the database is ahead of the mirrors: restore again to an earlier
target.

### When the mirror is too far behind

If the recovery target is hours old and the standby is current, the choice is
between losing recent pushes and having metadata reference missing objects.
Restoring the standby's current position is possible but leaves specific broken
references, not general corruption: repositories and pull requests whose head
commits were never mirrored return errors on those resources while the rest of
the instance works. Prefer the sweep target. Take the newer position only
deliberately, and re-run the verification above to learn exactly which
repositories are affected.

## Drill

Run this quarterly and after any change to the sweep, the standby, or the
schema. It exercises the real path without touching production.

1. `gitclub-recover status` and record the target.
2. `gitclub-recover promote --yes --target-dir /var/lib/gitclub/drill`.
3. Start PostgreSQL against `/var/lib/gitclub/drill` on a spare port.
4. Copy mirrors to a scratch data directory and start GitClub against both.
5. Run `python3 tests/acceptance.py` and the object-existence check above.
6. Record the wall-clock time from step 2 to a passing step 5. That number is
   your real recovery time objective; the estimate is not.
7. Destroy the drill directories. Leave the standby and the timer running.

A drill that has never been run is the most likely reason a recovery fails.
