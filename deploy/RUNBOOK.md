# GitClub deployment and recovery

Railway serves GitClub at <https://gitclub-production.up.railway.app>.
SSH Git uses `switchyard.proxy.rlwy.net:10681`. The i9 host runs the DR
containers under OrbStack at `~/gitclub-dr`. Its normal configuration publishes
no ports.

**Restore PostgreSQL to the start of the last completed Git mirror sweep.**
The standby normally replays beyond that point. Promoting it directly can
leave database rows referencing Git objects that were never mirrored.

## Verified deployment (2026-09-15 UTC)

1. Production application revision `4b86716` includes default dark mode and
   the Kaneo integration from `cad427f`. Built-in issue routes are retired;
   19 MCP tools remain. The `gitclub-dr` backup account can read repositories
   in new private namespaces. The drill detected a missing private namespace
   before this access-policy fix and refused application startup.
2. i9 runs PostgreSQL 18.6 and pgBackRest 2.59.1 in continuous archive recovery.
   The isolated drill restored to `2026-09-15T07:08:27Z`. Verification found
   seven repositories, 17 metadata commit references and zero missing objects.
   Both Kaneo columns existed before application startup. Two historical
   issues and two comments matched their original fixtures.
3. All 20 HTTP acceptance groups passed on the recovered application, with
   zero skipped. Original login, token, 10 API readbacks, Git refs and clone
   integrity passed. The restored receive hook rejected a protected push to
   an existing repository. Total elapsed time was 1,488.1 seconds, including
   the access-policy repair and deployment wait. Final verification of the
   prepared restore took 13.3 seconds.
4. The normal mirror sweep at `2026-09-15T07:40:15Z` covered eight repositories.
   The hello-world merge commit `8e4b284d7f115b5a8022a006cc44b4ea4e6e9f2f`
   matched mirrored `main`, existed as an object and passed full Git fsck.
   Mirror and standby containers are running without published ports; the
   standby refuses database connections. Drill app and recovery are stopped.
5. Private repository `stevencarpenter/hello-world` is connected to Kaneo
   project `HELLO`. Merging PR #5 automatically moved task `HELLO-1` from
   In Progress to Done through the normal i9 worker. Its completion ledger
   contains one completed repository/PR pair. The `steve` account has repo
   admin access.

Private drill evidence is stored in
`~/.config/gitclub/live-drill.cad427f.passed.json` on the development machine.
The initial drill and failed-attempt reports remain preserved. Demo links and
merge verification are recorded in `~/.config/gitclub/hello-world.json`.

## Railway provisioning

Run these commands from the repository root with Railway CLI 5.57 or later:

```sh
npm ci --prefix .railway --ignore-scripts
railway login
railway link --project 4c952b84-85a6-4fb6-89fa-c4ecb1589b31 --environment production
umask 077
railway config plan --out /tmp/gitclub-plan.json
```

Review the saved plan before applying it. The definition retains the
`Postgres-PITR` bucket: omitting it would propose deleting the live archive.
The repository volume is 5,000 MB, the current workspace limit. Its region is
explicit because omitting that region produces persistent drift.

```sh
railway config apply --plan /tmp/gitclub-plan.json --yes --json > /tmp/gitclub-apply.json
```

Inspect the JSON result and verify its apply status is `applied`. CLI 5.57.0
returned exit status zero when a backend apply failed; a zero shell status alone
does not prove success. Keep plan and result files private and outside git.

For a new environment, complete these operations after provisioning:

1. Generate a public domain for `gitclub`, targeting port 7701. `PUBLIC_URL`
   resolves to `https://${{RAILWAY_PUBLIC_DOMAIN}}`. It must equal the browser's
   external origin or browser writes return 403.
2. Set `GITCLUB_SSH_SECRET` as a sealed variable on `gitclub`, using at least
   32 random characters. The definition preserves the sealed value.
3. Create SSH networking with
   `railway tcp-proxy create --service gitclub --port 2222`.
4. Enable archiving with `railway postgres pitr enable --service postgres`.
   Wait for the initial backup and healthy archiver in
   `railway postgres pitr status --service postgres --json`.
5. Run `railway config plan` again. It must retain both volumes, both services
   and the PITR bucket without proposing a destructive change.

## i9 configuration

The checked-in Compose runtime uses the same PostgreSQL 18 image family as
Railway. Both were verified with PostgreSQL 18.6 and pgBackRest 2.59.1.

Copy `deploy/i9/` to `i9:~/gitclub-dr/`. Store these two files in
`i9:~/.config/gitclub-dr/`, with directory mode 0700 and file mode 0600:

1. `pgbackrest.conf`, based on `pgbackrest.conf.example`. Copy the primary's
   exact `repo1-*` connection values from `/etc/pgbackrest/pgbackrest.conf`.
   The live archive path is `/pgbackrest/cluster-7685622405611208769`;
   `WAL_ARCHIVE_PATH=/pgbackrest` omits the required cluster directory.
   Railway issues read/write bucket credentials only. Direct i9 archive
   access was approved for this deployment. Only the standby and recovery
   containers receive this file.
2. `mirror-sweep.env`, based on `mirror-sweep.env.example`. Use the public
   URL and the `gitclub-dr` account's token. Create this account before setting
   `GITCLUB_BACKUP_USERNAME=gitclub-dr` on the application service.

The application resolves `GITCLUB_BACKUP_USERNAME` to an existing account at
startup and grants that account read access to every repository, including
private repositories in namespaces created later. Existing memberships still
control write and admin access. Keep this account's credentials private. The
application refuses to start if the configured account does not exist.

The Railway IaC preserves this setting. Enable it only after creating the
backup account. Per-namespace grants are insufficient for DR: a new private
namespace can otherwise be absent from both the inventory and its count.

After both private files are configured, run on i9:

```sh
cd ~/gitclub-dr
docker compose build standby
docker compose run --rm standby bootstrap
docker compose up -d standby mirror
docker compose run --rm recovery gitclub-recover status
```

Bootstrap refuses a populated standby directory. The standby has
`hot_standby=off` and refuses database connections while replaying the archive.
The mirror runs every five minutes. Its token is mounted only into the mirror
container and is excluded from Git configuration and URLs.

`install.sh` and `systemd/` remain available for a Linux host. They are not the
runtime used by this macOS i9.

## Health checks

```sh
curl -fsS https://gitclub-production.up.railway.app/health
railway postgres pitr status --service postgres --json
ssh i9 'cd ~/gitclub-dr && docker compose ps'
ssh i9 'cd ~/gitclub-dr && docker compose logs --tail=30 standby mirror'
ssh i9 'cd ~/gitclub-dr && docker compose run --rm recovery gitclub-recover status'
```

Require a recent completed mirror sweep, a healthy Railway archiver and a
standby in archive recovery. The recovery point is the mirror sweep's start
time, so a stalled sweep increases potential data loss even if WAL replay is
current. `gitclub-recover status` returns nonzero when that target is over
60 minutes old.

For detailed local checks on i9:

```sh
cd ~/gitclub-dr
docker compose exec -u postgres standby pg_controldata -D /var/lib/gitclub/standby
docker compose exec -u postgres standby pgbackrest --stanza=main info
```

The control file should report `in archive recovery`. The primary's
`max_connections` and other replay-sensitive settings must not be reduced on
the standby.

## Restore and drill

Run this quarterly and after changes to the recovery tools or schema. The
`recovered` and `serving` volumes are separate from the standby and mirrors.
The application is reachable only through i9's loopback port 17701.

1. **Prepare the application image.** On i9, build the application revision
   being recovered from a complete repository checkout:

   ```sh
   docker build -f deploy/railway/Dockerfile -t gitclub-railway:drill .
   cd ~/gitclub-dr
   docker compose stop mirror
   docker compose run --rm recovery gitclub-recover status
   docker compose run --rm recovery gitclub-recover plan
   ```

   Record the target and elapsed-time start. Stop the mirror only to freeze
   its state during the drill. The standby continues replaying.

2. **Restore and complete database recovery.** Use empty scratch volumes:

   ```sh
   docker compose run --rm recovery gitclub-recover promote --yes
   docker compose -f compose.yaml -f compose.drill.yaml --profile drill up -d --wait recovery
   docker compose exec -u postgres recovery psql -p 5433 -d railway -tAc 'SELECT pg_is_in_recovery()'
   docker compose exec -u postgres recovery gitclub-verify-recovery
   ```

   `promote` restores the base backup and writes a time recovery target.
   Starting PostgreSQL performs replay and promotion. Require
   `pg_is_in_recovery()` to return `f`. Require zero missing repositories and
   commits. Verification covers `default_oid`, `merged_oid`, comment commits
   and review commits. A failure blocks application startup.

3. **Prepare repositories and start the application.**

   ```sh
   docker compose -f compose.yaml -f compose.drill.yaml --profile drill run --rm --no-deps prepare
   docker compose -f compose.yaml -f compose.drill.yaml --profile drill up -d app
   curl -fsS http://127.0.0.1:17701/health
   ```

   Preparation copies mirrors into the separate serving volume, installs both
   receive hooks, sets the database's default branch and applies the app's
   Git settings and file ownership. It refuses to overwrite existing repos.
   A plain `cp` would omit the hooks required for push authorization.

4. **Verify recovered data and writes.** From the development machine, open
   `ssh -N -L 17701:127.0.0.1:17701 i9`. In a second terminal at the repository:

   ```sh
   python3 tests/readback.py --url http://127.0.0.1:17701 --state-file "$HOME/.config/gitclub/production-readback.json" --report /tmp/gitclub-drill-readback.json
   python3 tests/acceptance.py --url http://127.0.0.1:17701 --report /tmp/gitclub-drill-acceptance.json
   ```

   `readback.py` checks the original login, token, metadata, Git refs and a
   cloned repository. Its private state file is produced by a previous
   production acceptance run with `--state-file`; keep it outside git. The
   deployed fixture and drill reports are stored in `~/.config/gitclub/` on
   the development machine.
   Also attempt a prohibited push against an existing recovered protected
   repository, since acceptance creates new repositories. Record the elapsed
   time to passing verification as measured recovery time.

5. **Stop the drill and resume mirroring.** On i9:

   ```sh
   docker compose -f compose.yaml -f compose.drill.yaml --profile drill stop app recovery
   docker compose up -d mirror
   ```

   The scratch volumes remain available for inspection. Before repeating the
   drill, explicitly remove only the stopped drill containers and the
   `gitclub-dr_recovered` and `gitclub-dr_serving` volumes. Never use
   `docker compose down -v`: it would also delete the standby and mirrors.

For an actual outage, leave mirroring stopped until the source of truth is
settled. Complete the same restore and verification, then configure the new
external origin, TLS and SSH endpoint before routing users to i9. Repository
mirrors do not preserve SSH host keys; a newly served SSH endpoint has a new
host-key identity.
