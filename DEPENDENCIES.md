# GitClub dependency audit

All 23 direct application packages resolve to their latest stable registry releases as checked on 2026-09-14. Six Rust transitive packages remain on older versions required by their upstream consumers. The native launcher and Docker builds select SQLite 3.53.4 for all three implementations.

| Implementation | Current dependency state | Inventory |
| --- | --- | --- |
| Go | Go 1.27.1; go-sqlite3 1.14.52 with SQLite 3.53.4; no transitive modules | [Go](reports/go-dependencies.json) |
| Gleam | Gleam 1.18.1, OTP 29.0.6, Rebar 3.27.0; all 14 resolved Hex packages and the pc build plugin are latest stable | [Gleam](reports/gleam-dependencies.json) |
| Rust | Rust 1.98.1; all 16 direct crates are latest stable; 108 resolved packages across all targets | [Rust](reports/rust-dependencies.json) |

Go moved from 1.26.8 to [1.27.1](https://go.dev/dl/). Rust upgraded [pbkdf2 to 0.13.0](https://crates.io/crates/pbkdf2), [sha2 to 0.11.0](https://crates.io/crates/sha2), [rand to 0.10.2](https://crates.io/crates/rand), [base64 to 0.23.1](https://crates.io/crates/base64), and [nix to 0.31.3](https://crates.io/crates/nix). The random-byte API now uses SysRng/TryRng. A known Python-generated PBKDF2-SHA256 value verifies compatibility with existing password hashes. Gleam's direct minimum constraints now name the current releases; its locked package versions were already current.

The shared MCP compatibility test uses the current [Python SDK 2.2.0](https://pypi.org/project/mcp/). The browser has no third-party package dependencies. Container Git, Python, OpenSSH and certificate packages remain managed by their base distribution; their version numbers do not represent latest upstream releases.

## SQLite linkage

The latest esqlite release embeds SQLite 3.50.4, and libsqlite3-sys embeds 3.53.2. GitClub's supported builds override those bundled copies with [SQLite 3.53.4](https://sqlite.org/changes.html), using each driver's external-library build interface. No dependency source is patched.

[scripts/build-sqlite.py](scripts/build-sqlite.py) verifies the official archive and amalgamation SHA3-256 hashes, compiles a project-local PIC static library, and checks its header, runtime version and database initialization. The cache validates compiler, platform, recipe and artifact hashes. SQLite retains automatic initialization and its default durability and parser limits. The shared library enables thread safety, URI filenames, column metadata and the drivers' supported extensions. The esqlite NIF previously used SQLite's NORMAL WAL synchronization default; the shared library retains SQLite's FULL default.

Use `python3 scripts/gitclub build gleam` or `python3 scripts/gitclub build rust` to select this library. The Dockerfiles use the same helper. Direct Cargo or Gleam commands without the documented environment can still use their driver's older bundled SQLite; the implementation guides describe the required flags. Go's current driver already embeds 3.53.4.

[tests/sqlite_version.py](tests/sqlite_version.py) installs a scoped trigger in a disposable test database. The trigger evaluates `sqlite_version()` during a server API write, proving the server's linked version independently of Python's SQLite installation.

## Upstream version constraints

These latest upstream packages do not accept the newest transitive releases. Cargo.lock records the newest compatible versions; incompatible overrides would require changing upstream code.

| Package | Resolved | Latest stable | Upstream requirement |
| --- | --- | --- | --- |
| [hashbrown](https://crates.io/crates/hashbrown) | 0.16.1 | 0.17.1 | rsqlite-vfs requires ^0.16.1 |
| [matchit](https://crates.io/crates/matchit) | 0.8.4 | 0.9.2 | Axum requires =0.8.4 |
| [r-efi](https://crates.io/crates/r-efi) | 6.0.0 | 7.1.0 | getrandom requires ^6 |
| [redox_syscall](https://crates.io/crates/redox_syscall) | 0.5.18 | 0.9.4 | parking_lot_core requires ^0.5 |
| [wasi](https://crates.io/crates/wasi) | 0.11.1+wasi-snapshot-preview1 | 0.14.7+wasi-0.2.4 | mio requires ^0.11.0 |
| [windows-link](https://crates.io/crates/windows-link) | 0.2.1 | 0.100.0 | parking_lot_core and windows-sys require ^0.2 |

The [validation report](reports/dependencies.json) records all three implementations passing 20 acceptance groups, all 24 MCP tools through the current SDK, and SQLite 3.53.4 checks from both native servers and fresh containers. Rust also passes 22 unit tests, Clippy, Git stream limits and subprocess lifecycle checks. Go passes race-enabled tests and vet; Gleam passes type checking, collaboration and mutex checks.

The JSON inventories record registry URLs, resolved versions, upstream requirements and validation. Performance and image-size measurements in [the comparison](COMPARISON.md) precede this dependency refresh and have not been rerun.
