# GitClub

Three independent implementations of an original self-hosted Git collaboration server: Go, Gleam, and Rust. All serve the same browser interface and API contract. None calls another backend or incorporates another forge's application code.

Go is the chosen implementation. [DECISION.md](DECISION.md) records that choice, the PostgreSQL and Railway deployment target, and the disaster recovery design. Tag `v0.0.0` marks the last commit holding all three implementations and their measurement evidence.

## Run all three

Docker with Compose is the only prerequisite for the packaged installation:

```sh
./scripts/gitclub up
```

| Server | Browser and HTTP Git | SSH Git |
| --- | --- | --- |
| Go | http://localhost:7701 | `ssh://git@localhost:2221/OWNER/REPO.git` |
| Gleam | http://localhost:7702 | `ssh://git@localhost:2222/OWNER/REPO.git` |
| Rust | http://localhost:7703 | `ssh://git@localhost:2223/OWNER/REPO.git` |

Create an account in each server. The installations have separate accounts, SQLite databases, and repository volumes. No demo accounts or sample projects are installed. `./scripts/gitclub down` stops the services and preserves their volumes. Compose restarts crashed services automatically unless explicitly stopped.

The Compose ports bind to localhost. For a remote installation, put HTTP behind a TLS reverse proxy, set each service's `PUBLIC_URL` to its exact external HTTPS origin, and publish the required SSH port. Browser writes validate that origin. Registration is open to visitors who can reach the server.

## Work with repositories

1. Create a personal repository or an organization in **Namespaces**.
2. Push existing history using the commands on the empty repository screen. Import uses your local Git client, including private source credentials held by that client.
3. Find repositories across owners in **Repositories** or with `Cmd/Ctrl+K`. Pin repositories and collect them in shared or personal groups.
4. Open a pull request, review its diff, and merge after another writer approves its current head.

The configured default branch determines freshness. Feature-branch pushes, issue comments, and page visits do not change repository order. Pins appear first, with freshness ordering within each section. Shared groups reveal only repositories the viewer can access.

The MVP includes code, history and diff browsing, issues and comments, pull requests, commit-bound reviews, inline comments, branch protection, repository roles, organization membership, tokens and SSH keys. CI and embedded agent execution are excluded.

## Codex and Claude

Open **Agent access** to create a token and copy the configuration for your installed client. `/mcp` provides 24 tools over authenticated Streamable HTTP. The JSON API uses the same authorization and collaboration logic. Git transfers use native Git.

The official MCP SDK verifies initialization, tool discovery, and repository, issue, and group operations against all three servers. Client setup flags were checked against installed Codex and Claude CLI help. The validation does not invoke a model or modify global client configuration.

## Run from source

Use Python 3.12+, Git 2.38+, and a C compiler. Go requires Go 1.27.1. Gleam requires Gleam 1.18.1 and Erlang/OTP 29. Rust requires Rust 1.98.1. Package versions are locked in each implementation. The launcher builds checksum-verified SQLite 3.53.4 for Gleam and Rust; Go’s driver already embeds that version. See [the dependency audit](DEPENDENCIES.md).

```sh
./scripts/gitclub run go
./scripts/gitclub run gleam
./scripts/gitclub run rust
```

Run these in separate terminals. Native data defaults to `.data/go`, `.data/gleam`, and `.data/rust`. Use `--data-dir`, `--port`, or `--host` to override. `--no-build` reuses an existing build. Native launches provide HTTP Git; the Compose installation also configures OpenSSH.

## Backup and restore

For a native installation, stop its server before backup. The helper refuses a locked data directory or active SSH transfer, verifies SQLite, and includes Git repositories, merge recovery records, and SSH host keys.

```sh
./scripts/gitclub backup go ./backups/go.tar.gz
./scripts/gitclub restore go ./backups/go.tar.gz --data-dir .data/go-restored
./scripts/gitclub run go --data-dir .data/go-restored --port 7711
```

Use `gleam` or `rust` for the corresponding installation. Archives are mode `0600`. Restore requires a new empty destination, checks archive paths, runs SQLite integrity checks and `git fsck`, and refuses to overwrite existing data. Treat backups as credentials because they contain account and token records.

Compose data lives in named volumes, not the native `.data` directories. To make a Go volume backup with the same helper:

```sh
docker compose --env-file .data/compose.env stop go go-ssh
docker compose --env-file .data/compose.env run --name gitclub-go-backup --no-deps --entrypoint python3 go /app/scripts/gitclub backup go /tmp/go.tar.gz --data-dir /data
docker cp gitclub-go-backup:/tmp/go.tar.gz ./go.tar.gz
chmod 600 ./go.tar.gz
docker rm gitclub-go-backup
docker compose --env-file .data/compose.env start go go-ssh
```

The resulting archive can be restored to a native data directory with the helper above. Replace `go` with `gleam` or `rust` for the corresponding volume. Preserve `.data/compose.env` for the existing deployment's SSH service secret.

Read [the Rust implementation guide](implementations/rust/README.md) for the source map and request flow.

## Verification and comparison

[COMPARISON.md](COMPARISON.md) records the measured comparison and its fixture. [The visual comparison](reports/comparison.html) uses the same GitClub design and includes the actual repository screen. Raw results and repeatable tools live in [tests](tests). The complete endpoint and behavior definition is [shared/CONTRACT.md](shared/CONTRACT.md).

```sh
(cd implementations/go && go test -race ./... && go vet ./...)
(cd implementations/gleam && gleam check && gleam run -m collab_check)
(cd implementations/rust && cargo test --locked && cargo clippy --all-targets --locked -- -D warnings)
python3 shared/test_adapters.py
python3 tests/acceptance.py --url http://localhost:7701
```

Acceptance tests create their own accounts and repositories. Use an isolated installation for tests and benchmarks. Successful local checks establish the tested behaviors, not production uptime or Internet-scale capacity.
