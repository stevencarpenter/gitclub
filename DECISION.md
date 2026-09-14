# GitClub technology decision

Go is the chosen implementation. GitClub deploys on Railway as a personal cloud Git host, backed by PostgreSQL 18, with a disaster recovery standby on a self-hosted i9 machine. Decided 2026-09-14. This record states the evidence available at that date and the reasoning applied to it.

Tag `v0.0.0` marks the last commit containing all three implementations and their full measurement evidence. Everything removed after that tag is recoverable from it.

## Implementation choice

Go implements the same contract as Gleam and Rust in 2,072 lines against 3,362 Gleam lines plus 396 Erlang lines, and 3,279 Rust lines. It carries 1 direct dependency and no transitive modules, against 6 direct and 14 resolved for Gleam, and 16 direct and 108 resolved for Rust. All three pass 20 acceptance groups, 24 MCP tools through the official Python SDK 2.2.0, and the OpenSSH and offline recovery checks.

Measured behavior placed Go at or ahead of Rust on every operation except memory. Go's mixed HTTP p95 was 56.51 ms against 58.29 ms for Rust and 438.74 ms for Gleam. Go's throughput at concurrency four was 170.82 requests per second against 163.51 for Rust and 14.43 for Gleam. Rust used the least sampled server RSS at 8.77 MiB against Go's 23.80 MiB. The latency samples do not establish a meaningful Go and Rust speed difference. COMPARISON.md at `v0.0.0` records the fixture, the hardware, and the measurement conditions that bound these numbers.

Gleam was rejected on its subprocess architecture. Every Git command spawns a Python interpreter that then spawns Git, through a script embedded as an Erlang binary literal in `gitclub_ffi.erl`. The Git transport repeats the pattern in `gitclub_transport_ffi.erl`. The measured cost is a 276.39 ms directory median against Go's 2.22 ms at 40 repositories. The BEAM supervision argument does not apply here, because the work runs in operating system processes outside the BEAM and the supervision tree supervises the Python shim rather than the work.

Rust was the runner-up. Its process lifecycle code is the strongest of the three, with an RAII `ProcessGroup` guard over a global registry, `AbortOnDrop`, and 22 unit tests covering injected database failure after the atomic Git merge, conservative ledger recovery, disconnect cleanup, and shutdown of external children. Go has no equivalent lifecycle probe, and that gap is test coverage rather than a language limitation. Rust's cost is a permanent per-feature tax: `rusqlite` is synchronous, so every new endpoint must be placed on one side of the `spawn_blocking` boundary.

Both surviving candidates model SQLite rows and API envelopes as untyped JSON values, so Rust buys no type safety at the persistence boundary. Go's `M = map[string]any` and Rust's `serde_json::Value` carry the same weakness.

### Consequences accepted

Go's routing is a manual conditional chain on path segments at `implementations/go/main.go:385`, errors propagate by `panic` through `fail()`, and request and row data move as `map[string]any`. This is adequate at 2,072 lines and will not hold at GitHub feature parity. Replacing it with `http.ServeMux` patterns and declared struct types is incremental and does not require a rewrite.

Rust's lifecycle test suite should be reproduced against Go rather than discarded with the implementation.

## Deployment

Railway is the primary and only serving site. The scale is a personal cloud Git host, which is a single user or a small number of users, not a multi-tenant forge.

PostgreSQL replaces SQLite. The driver is the requirement: continuous write-ahead log shipping to an offline standby is the disaster recovery mechanism, and SQLite provides no equivalent. At this scale SQLite would carry the load without difficulty, so the port is bought entirely with the recovery requirement.

Pin the image to `postgres-ssl:18`, the major tag only. Point-in-time recovery rejects minor pins, and high availability requires a pinned major. PostgreSQL 18.6 is the current stable release; 19 was at Beta 3 on this date.

Railway PostgreSQL high availability, which is Patroni with etcd and HAProxy, is deferred. It converts one billed service into roughly nine and buys uptime, while the stated requirement is durability. Point-in-time recovery and the standby cover durability. High availability converts in place later if measured uptime justifies it.

## Disaster recovery

The i9 machine is a disaster recovery target and serves nothing. It runs PostgreSQL 18 in continuous recovery with `hot_standby = off`, so it accepts no connections at all, and replays write-ahead log segments pulled from the Railway point-in-time recovery bucket using `restore_command = 'pgbackrest --stanza=main archive-get %f %p'` with read-only credentials.

Log shipping was chosen over streaming replication because it requires no replication slot, no `pg_hba.conf` access, no `wal_level` change, no inbound connection to the house, and no public TCP proxy on PostgreSQL. The standby dials out to object storage only. Streaming replication to an external standby is not available on Railway's managed image, and logical replication is unsuitable for recovery because it replicates neither DDL nor sequences, so a promoted logical subscriber fails on duplicate keys.

The Railway bucket is transport, not the recovery store. The standby replays into a local data directory, and the Git mirrors sit on local disk, so a Railway outage that also removes the bucket does not cost the standby its contents.

### Recovery ordering

GitClub state spans two systems with independent replication lag. PostgreSQL holds metadata including four columns of Git object identifiers: `repositories.default_oid`, `pull_requests.merged_oid`, `comments.commit_oid`, and `reviews.commit_oid`. The repositories are bare Git directories on local disk at `implementations/go/git.go:47`.

Recover PostgreSQL to a timestamp at or before the start of the last completed Git mirror sweep. Metadata behind code is safe. Code behind metadata is corrupt, because those four columns then reference objects the surviving node cannot produce. Use the sweep start timestamp rather than its completion, because a push landing during a sweep may have missed a repository already scanned.

Two consequences follow. The Git mirror interval sets the real recovery point objective, so reducing PostgreSQL replication lag below it produces currency that cannot be used. Write-ahead log shipping is async with `archive_timeout=60`, placing the PostgreSQL lag floor near 60 seconds regardless.

Do not run `--prune` against the disaster recovery mirrors. An upstream force push would otherwise delete objects that older metadata still references.

The existing backup helper already treats the database and the repositories as one consistency unit. `scripts/gitclub` acquires `exclusive_data` and `quiescent_transfers` together before snapshotting, and `tests/recovery.py` fingerprints both.

## Required before deployment

The PostgreSQL port is unconditional and precedes the deployment work. The Go implementation contains no `json_object`, `json_extract`, or `PRAGMA` calls in application code, so the port is confined to these changes.

1. Rewrite `?` placeholders to `$n` inside `rows` and `exec` rather than editing the 68 call sites.
2. Replace `LastInsertId()` at `main.go:165` and `main.go:347` with `INSERT ... RETURNING id` and `QueryRow`. The driver does not support `LastInsertId`.
3. Convert `INSERT OR IGNORE` at `repositories.go:257` and `repositories.go:386` to `ON CONFLICT DO NOTHING`. The `ON CONFLICT ... DO UPDATE` statements at `repositories.go:110` and `repositories.go:271` are already valid PostgreSQL.
4. Replace `repoLocks sync.Map` at `main.go:111` with `pg_advisory_xact_lock(repo_id)`. An in-process mutex serializes nothing once a second instance exists.
5. Convert `shared/schema.sql`: drop the `PRAGMA` statements and change `INTEGER PRIMARY KEY` to `BIGINT GENERATED ALWAYS AS IDENTITY`. The epoch millisecond `BIGINT` timestamps stay as they are.
6. Add a schema migration mechanism. `shared/schema.sql` is `CREATE TABLE IF NOT EXISTS` only and carries no version.

`main.go:448` hardcodes `internalURL` to `http://127.0.0.1:PORT` for the `shared/git-hook.py` callback. This is correct while the Git store and the application are colocated, and it is a hard constraint against splitting them: a push must be served by the node holding that repository's disk. `rates` at `main.go:112` is per-instance and would permit a multiple of the intended limit across instances.
