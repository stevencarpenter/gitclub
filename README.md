# GitClub

An original self-hosted Git collaboration server written in Go. It does not incorporate another forge's application code.

[DECISION.md](DECISION.md) records why Go was chosen over the Gleam and Rust implementations that preceded it, the PostgreSQL and Railway deployment target, and the disaster recovery design. Tag `v0.0.0` holds all three implementations and their measurement evidence.

[deploy/](deploy) holds the Railway and disaster recovery infrastructure, and [deploy/RUNBOOK.md](deploy/RUNBOOK.md) the bring-up order, recovery procedure, and drill.

## Run

Docker with Compose is the only prerequisite for the packaged installation:

```sh
./scripts/gitclub up
```

The browser and HTTP Git endpoint is http://localhost:7701. SSH Git is `ssh://git@localhost:2221/OWNER/REPO.git`.

Create an account. No demo accounts or sample projects are installed. `./scripts/gitclub down` stops the services and preserves their volumes. Compose restarts crashed services automatically unless explicitly stopped.

The Compose ports bind to localhost. For a remote installation, put HTTP behind a TLS reverse proxy, set `PUBLIC_URL` to the exact external HTTPS origin, and publish the SSH port. Browser writes validate that origin. Registration is open to visitors who can reach the server.

## Work with repositories

1. Create a personal repository or an organization in **Namespaces**.
2. Push existing history using the commands on the empty repository screen. Import uses your local Git client, including private source credentials held by that client.
3. Find repositories across owners in **Repositories** or with `Cmd/Ctrl+K`. Pin repositories and collect them in shared or personal groups.
4. Open a pull request, review its diff, and merge after another writer approves its current head.

The configured default branch determines freshness. Feature-branch pushes, issue comments, and page visits do not change repository order. Pins appear first, with freshness ordering within each section. Shared groups reveal only repositories the viewer can access.

The MVP includes code, history and diff browsing, issues and comments, pull requests, commit-bound reviews, inline comments, branch protection, repository roles, organization membership, tokens and SSH keys. CI and embedded agent execution are excluded.

## Codex and Claude

Open **Agent access** to create a token and copy the configuration for your installed client. `/mcp` provides 24 tools over authenticated Streamable HTTP. The JSON API uses the same authorization and collaboration logic. Git transfers use native Git.

The official MCP SDK verifies initialization, tool discovery, and repository, issue, and group operations. Client setup flags were checked against installed Codex and Claude CLI help. The validation does not invoke a model or modify global client configuration.

## Run from source

Use Go 1.27.1, Python 3.12+, Git 2.38+, and PostgreSQL 18 client tools (`psql`, `pg_dump`, `pg_restore`) for backup and restore. The single direct dependency is `pgx` v5, a pure-Go driver, so the build needs no C compiler. Versions are locked in `implementations/go/go.mod` and `go.sum`.

The server requires `DATABASE_URL` and applies `shared/migrations/*.sql` at startup.

```sh
export DATABASE_URL=postgres://gitclub:password@localhost:5432/gitclub?sslmode=disable
./scripts/gitclub run
```

Git repositories still live on disk; native data defaults to `.data/go`. Use `--data-dir`, `--port`, or `--host` to override. `--no-build` reuses an existing build. Native launches provide HTTP Git; the Compose installation also configures OpenSSH.

## Backup and restore

Stop the server before backup. The helper refuses a locked data directory or an active SSH transfer, then captures a `pg_dump` custom-format archive and the Git repositories in one pass, along with merge recovery records and SSH host keys.

```sh
./scripts/gitclub backup ./backups/gitclub.tar.gz
./scripts/gitclub restore ./backups/gitclub.tar.gz --data-dir .data/go-restored --database-url postgres://gitclub:password@localhost:5432/gitclub_restored
./scripts/gitclub run --data-dir .data/go-restored --port 7711
```

Both commands take `--database-url`, defaulting to `DATABASE_URL`. Archives are mode `0600`. Restore requires both a new empty data directory and an empty target database, checks archive paths, verifies the dump parses, runs `git fsck`, and refuses to overwrite existing data. Treat backups as credentials because they contain account and token records.

The database and the Git repositories are one consistency unit. Back them up together and restore them together; see the recovery ordering section of [DECISION.md](DECISION.md).

Compose data lives in a named volume, not the native `.data` directory. To make a volume backup with the same helper:

```sh
docker compose --env-file .data/compose.env stop go go-ssh
docker compose --env-file .data/compose.env run --name gitclub-backup --entrypoint python3 go /app/scripts/gitclub backup /tmp/gitclub.tar.gz --data-dir /data
docker cp gitclub-backup:/tmp/gitclub.tar.gz ./gitclub.tar.gz
chmod 600 ./gitclub.tar.gz
docker rm gitclub-backup
docker compose --env-file .data/compose.env start go go-ssh
```

The resulting archive restores to a native data directory with the helper above. Preserve `.data/compose.env`; it holds the deployment's SSH service secret and database password.

## Verification

The complete endpoint and behavior definition is [shared/CONTRACT.md](shared/CONTRACT.md). Repeatable tools live in [tests](tests).

```sh
(cd implementations/go && go test -race ./... && go vet ./...)
python3 shared/test_adapters.py
python3 tests/acceptance.py --url http://localhost:7701
```

Database-backed Go tests need a PostgreSQL instance and are skipped without one. They create and drop a disposable schema per test:

```sh
export GITCLUB_TEST_DATABASE_URL=postgres://gitclub:password@localhost:5432/gitclub?sslmode=disable
(cd implementations/go && go test -race ./...)
```

Acceptance tests create their own accounts and repositories. Use an isolated installation for tests and benchmarks. Successful local checks establish the tested behaviors, not production uptime or Internet-scale capacity.
