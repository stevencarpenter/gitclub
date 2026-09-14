# GitClub Gleam server

From the repository root:

```sh
scripts/gitclub run gleam
```

The server listens on `127.0.0.1:7702` by default. `scripts/gitclub run --help` lists configuration options. The launcher builds an Erlang shipment, holds the data-directory process lock, and starts the application. Git, Python 3, Erlang, and Gleam are runtime/build prerequisites. The container packages runtime dependencies.

The implementation uses Gleam for HTTP routing, input validation, authorization, repository discovery, Git hook policies, groups, issues, pull requests, review eligibility, merge ref transactions, recovery, and MCP dispatch. Mist serves HTTP. Sqlight uses SQLite through its native driver. No other GitClub implementation is called.

Erlang FFI provides filesystem access, cryptography, synchronization, timers, and subprocess I/O. Embedded Python uses only the standard library to provide portable subprocess pipe handling, process groups, and cancellation. It does not implement application routes, permissions, or persistence rules. The SQL schema, browser assets, SSH adapters, and MCP declarations are shared with the Go implementation.

Repository freshness reconciliation reads Git loose refs and packed refs directly. Directory requests do not start a Git or Python process for each repository. Symbolic refs have a four-hop limit; ref metadata reads are bounded at 8 MiB. Failed ref reads retain the previously observed freshness timestamp.

Metadata requests use individual database connections and a process-local FIFO serialization lock. Admission allows 128 queued callers per lock and waits at most five seconds before returning HTTP 503 with Retry-After. Process monitors release locks and remove waiters when their request process exits. Git transfer callbacks run outside that lock. The server allows eight simultaneous HTTP Git transfers and eight ordinary Git subprocess operations. The separate budgets allow active transfers to complete their authorization hooks. JSON input is limited to 1 MiB with a ten-second body-read deadline. Git request input is limited to 256 MiB and transfers have a 120-second deadline. Gleam decodes HTTP chunk framing with bounded reads, including chunked JSON bodies; it does not buffer a complete declared chunk.

Merges use native Git merge-tree and commit-tree, followed by an atomic update-ref transaction that verifies the reviewed head and compare-and-swaps the base. The same transaction creates a hidden per-pull merge ref, preserving success evidence when the base branch later moves. Durable recovery markers live beside the bare repository refs and are reconciled at startup and before retrying a merge. Review submissions must supply the head OID the reviewer actually inspected.

Validation:

```sh
cd implementations/gleam
gleam check
gleam run -m collab_check
mkdir -p /tmp/gitclub-mutex-check
erlc -o /tmp/gitclub-mutex-check src/gitclub_mutex.erl test/mutex_check.erl
erl -noshell -pa /tmp/gitclub-mutex-check -eval 'mutex_check:run(), halt().'
```

From the root, run `python3 tests/acceptance.py --url http://127.0.0.1:7702` against an isolated instance for the common black-box contract. `tests/network_limits.py` checks incomplete JSON uploads and concurrent reads. Build and measurement records belong in the shared comparison report.

Verified development toolchain: Gleam 1.18.1, Erlang/OTP 29 (ERTS 17.0.6), SQLite 3.53.4 through sqlight 1.2.0/esqlite 0.9.0. Hex dependencies are pinned in `manifest.toml`.

The launcher and container build a local SQLite 3.53.4 static library with `scripts/build-sqlite.py`. The helper verifies the official archive and source SHA3-256 hashes and checks the linked library version. It retains SQLite's default initialization, parser limits, and durability settings while enabling the bindings' extensions. Its cache records the version, architecture, compiler, build recipe, and artifact hashes. Esqlite's supported `ESQLITE_USE_SYSTEM=1` option links that library into the NIF, replacing esqlite's bundled SQLite 3.50.4 without a package fork or a runtime SQLite installation.

For direct Gleam builds, first run `python3 scripts/gitclub build gleam` from the repository root. Use `ESQLITE_USE_SYSTEM=1`, `CFLAGS=-I<repository>/.build/sqlite-3.53.4/include`, and `LDFLAGS=-L<repository>/.build/sqlite-3.53.4/lib` for subsequent Gleam build commands. On macOS, append `-Wl,-undefined,dynamic_lookup` to `LDFLAGS` so the NIF resolves Erlang's host symbols. The launcher supplies these flags. The container verifies `select sqlite_version()` through esqlite in both build and runtime images.

The lock regression also exposes `mutex_check:global_reproduction()` to reproduce the former randomized `global:trans` contention delays. It runs independently of the HTTP server.
