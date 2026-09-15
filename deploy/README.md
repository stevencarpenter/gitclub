# Deployment

GitClub runs at <https://gitclub-production.up.railway.app>, with SSH Git at
`switchyard.proxy.rlwy.net:10681`. Railway hosts PostgreSQL 18, the application
and SSH transport, the repository volume, and the PITR archive bucket.

i9 runs the DR containers under OrbStack. The mirror fetches repositories every
five minutes. The standby replays the PITR archive with `hot_standby=off`.
Normal operation publishes no ports. [RUNBOOK.md](RUNBOOK.md) contains the
deployment, health and recovery commands.

The [Kaneo status worker](kaneo/README.md) runs separately on i9 under
`~/gitclub-kaneo`. It polls explicitly configured repositories every 60 seconds
and completes linked tasks after pull requests merge. Its private credentials
and completion ledger are separate from the DR stack.

## Recovery invariant

Restore PostgreSQL to the start of the last completed mirror sweep. The
continuously replaying standby is usually ahead of that target. Promoting it
directly can leave metadata referencing missing Git objects.

Git mirrors keep deleted and force-pushed history using disabled pruning and
unexpired reflogs. Recovery verifies every repository and every commit ID
stored in the database before starting the application. Copies receive their
server hooks and ownership before serving writes.

## Runtime files

| Path | Purpose |
| --- | --- |
| `../.railway/railway.ts` | Railway services, volumes and retained PITR bucket |
| `railway/Dockerfile`, `railway/entrypoint.py` | App and OpenSSH on one shared volume; either process exiting stops the container |
| `i9/compose.yaml`, `i9/compose.drill.yaml` | Normal DR containers and isolated application drill |
| `i9/gitclub-mirror-sweep`, `i9/gitclub-recover` | Mirror coverage, recovery target and PITR restore |
| `i9/gitclub-verify-recovery`, `i9/prepare-repositories.py` | Object verification and repository preparation |

Railway attaches the repository volume to one service, so the application and
SSH transport share one container with one replica. The DR stack mounts archive
credentials only into standby/recovery containers and the GitClub token only
into the mirror container. Railway bucket credentials have read/write access;
the standby's read-only operations do not restrict the credentials themselves.

## Runnable checks

```sh
python3 deploy/i9/test_mirror_sweep.py
cd deploy/i9
docker compose build standby
docker run --rm --entrypoint bash gitclub-dr:local /opt/gitclub/test_runtime.sh
```

The runtime check uses disposable PostgreSQL and local pgBackRest fixtures. It
checks recovery, private configuration, primary-compatible connection limits,
connection refusal, object verification, restored hooks, overwrite refusal and
retry timing. It needs no production credentials.

The application acceptance suites run against a live deployment:

```sh
python3 tests/acceptance.py --url "$PUBLIC_URL"
python3 tests/ssh_acceptance.py --url "$PUBLIC_URL" --ssh-host switchyard.proxy.rlwy.net --ssh-port 10681 --report /tmp/gitclub-ssh.json
```

`i9/install.sh` and `i9/systemd/` support Linux hosts. The deployed macOS i9 uses
Compose instead.
