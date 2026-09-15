# Deployment

GitClub runs on Railway. The i9 machine holds a PostgreSQL standby and Git
mirrors and serves nothing. [RUNBOOK.md](RUNBOOK.md) has the bring-up order,
the health checks, the recovery procedure, and the drill.

```
Railway                                   i9 (serves nothing)
  gitclub service  ── WAL ──▶ PITR bucket ──▶ pgBackRest ──▶ standby (hot_standby off)
    app + sshd                                                  replays continuously
    /data volume ◀──────── HTTPS fetch ──────  mirror sweep ──▶ Git mirrors
  postgres 18                                  every 5 minutes   + recovery target
```

The two arrows into the i9 are independent and lag differently, which is the
whole reason for the ordering rule: recovery restores PostgreSQL to the mirror
sweep's target, never past it. [DECISION.md](../DECISION.md) explains why.

## What is here

| Path | Purpose |
| --- | --- |
| `../.railway/railway.ts` | The Railway project: Postgres, the volume, the service |
| `railway/Dockerfile` | Combined app and OpenSSH image for Railway |
| `railway/entrypoint.py` | Supervises both processes in that container |
| `i9/install.sh` | Places the commands, units, and config templates |
| `i9/gitclub-mirror-sweep` | Mirrors repositories and publishes the recovery target |
| `i9/gitclub-recover` | `status`, `plan`, `promote` |
| `i9/bootstrap-standby.sh` | First restore and standby configuration |
| `i9/test_mirror_sweep.py` | Checks the properties the invariant depends on |

## Two constraints worth knowing before you read the files

**Railway attaches a volume to one service.** Compose runs the app and the
OpenSSH transport as two services sharing `go-data`. That is not expressible on
Railway, and the transport needs the same `/data` for host keys and for the
bare repositories its forced commands run `git` against. `railway/Dockerfile`
therefore builds both into one image and `railway/entrypoint.py` supervises
them, exiting the container if either dies so Railway restarts a whole one.

**The sweep interval is the recovery point objective.** Not the WAL shipping
lag, which is roughly 60 seconds. A push that lands between sweeps cannot be
recovered, because the database can only be restored to the last completed
sweep. The timer ships at 5 minutes; shortening it costs one API call plus an
incremental fetch per repository.

## Verification

```sh
python3 deploy/i9/test_mirror_sweep.py
```

Covers the behaviors the recovery ordering depends on: the target derives from
the server's clock rather than this machine's, an upstream ref deletion does not
prune the mirror, a failed repository holds the target where it was, and a
shrinking repository count is refused.

For the Railway image, build it and run both acceptance suites against it:

```sh
docker build -f deploy/railway/Dockerfile -t gitclub-railway:local .
# start it with DATABASE_URL, PUBLIC_URL and GITCLUB_SSH_SECRET, then
python3 tests/acceptance.py --url "$PUBLIC_URL"
python3 tests/ssh_acceptance.py --url "$PUBLIC_URL" --ssh-port 2222 --report /tmp/ssh.json
```
