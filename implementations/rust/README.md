# GitClub Rust

Run the Rust server from the repository root:

```sh
./scripts/gitclub run rust
```

Open http://localhost:7703. The native launcher stores data in `.data/rust`. `./scripts/gitclub up` builds the Go, Gleam, and Rust installations with separate volumes and OpenSSH services. Rust SSH uses port 2223.

## Read the implementation

| File | Responsibility |
| --- | --- |
| [src/main.rs](src/main.rs) | Process startup and server entry point |
| [src/core.rs](src/core.rs) | HTTP dispatch, request limits, authentication, SQLite access, MCP, and static assets |
| [src/repos.rs](src/repos.rs) | Repository directory, pins, namespaces, roles, groups, and repository settings |
| [src/git.rs](src/git.rs) | Native Git processes, HTTP streaming, SSH authorization, hooks, refs, and code browsing |
| [src/collab.rs](src/collab.rs) | Issues, comments, current-head reviews, atomic merges, and merge recovery |

Start with the HTTP dispatch in `core.rs`, follow repository routing into `repos.rs`, and read the merge operation in `collab.rs` with its recovery routine. [The shared contract](../../shared/CONTRACT.md) defines the observable behavior for all three backends.

## Runtime boundaries

[Axum](https://docs.rs/axum/0.8.9/axum/) handles HTTP on Tokio. Metadata operations use blocking workers and a SQLite connection per request. Repository mutations use repository-specific locks. HTTP connections have a five-second header deadline, metadata bodies have a ten-second deadline, and startup and active requests share signal-driven subprocess cleanup. [Rusqlite](https://docs.rs/rusqlite/0.40.2/rusqlite/) provides SQLite access; the launcher and container builds statically link checksum-verified SQLite 3.53.4. Prepared SQL parameters carry user values. API operations return `Result` errors instead of panicking for expected failures.

Git object storage, merge calculation, and network protocols use the installed Git executable. Commands receive argument arrays and a sanitized environment. Automatic Git maintenance runs in the foreground so it remains inside the process group and its deadline. Git HTTP has a separate admission budget from ordinary Git commands so receive hooks can reach their authorization API during active transfers. Transfer input and output stream through bounded buffers. Process groups provide descendant cleanup.

Default-branch freshness reads loose and packed refs directly. Changing a feature branch or discussion does not advance directory order. A merge records a durable intent before an atomic Git ref transaction verifies the reviewed head, compares the base tip, and writes the resulting commit plus a hidden transaction reference. Recovery uses that reference to finish metadata recording without resetting Git history.

The application logic is Rust. The shared browser assets, SQLite schema, MCP declarations, Python Git hooks, and OpenSSH adapters are the same artifacts used by the other implementations. This server does not call the Go or Gleam backend.

## Build and check

The release build uses Rust 1.98.1, a C compiler, Python 3.12+, and the checked-in Cargo lockfile. `./scripts/gitclub build rust` builds SQLite 3.53.4 through the shared checksum-verifying helper and selects it using the supported libsqlite3-sys environment variables. The container build uses the same SQLite source. Direct Cargo commands without those environment variables retain the crate’s bundled SQLite 3.53.2 fallback. Runtime prerequisites are Git 2.38+, Python 3.12+, and `ssh-keygen`.

```sh
./scripts/gitclub build rust
cd implementations/rust
cargo test --locked
cargo clippy --all-targets --locked -- -D warnings
```

Run shared acceptance against an isolated native server:

```sh
./scripts/gitclub run rust --data-dir .data/rust-check --port 7795
```

In another terminal, from the repository root:

```sh
python3 tests/acceptance.py --url http://localhost:7795 --data-dir .data/rust-check
python3 tests/network_limits.py --url http://localhost:7795 --report artifacts/rust-network.json
python3 tests/http_git_limits.py --url http://localhost:7795 --report artifacts/rust-streams.json
```

The tests create accounts and repositories. [COMPARISON.md](../../COMPARISON.md) records measured results and the exact benchmark fixture.
