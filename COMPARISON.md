# GitClub: Go, Gleam, and Rust comparison

Rust passes the same GitClub MVP contract. Rust's mixed HTTP p95 was 58.29 ms, versus 56.51 ms for Go and 438.74 ms for Gleam. Rust had the lowest sampled server RSS at 8.77 MiB. These are single runs of this fixture, not language-wide performance claims.

All three implementations serve byte-identical browser assets, use the same schema and API contract, and independently implement authorization and collaboration. No backend calls another backend. No existing forge application code was used.

The performance and image-size measurements precede the 2026-09-14 dependency refresh. Current builds use Go 1.27.1 and SQLite 3.53.4; Rust cryptography and other crates were also updated. Those measurements have not been rerun. See [the dependency audit](DEPENDENCIES.md) for current versions and validation.

## Measured behavior

| Operation | Go | Gleam | Rust |
| --- | ---: | ---: | ---: |
| Directory within mixed load, 40 repos, median | 2.22 ms | 276.39 ms | 3.99 ms |
| Repository directory, 1,000 repos, p95 | 49.53 ms | 594.05 ms | 84.24 ms |
| Mixed HTTP workload, p95 | 56.51 ms | 438.74 ms | 58.29 ms |
| Git clone, median | 147.58 ms | 230.95 ms | 145.92 ms |
| Git push, median | 240.22 ms | 310.85 ms | 251.13 ms |
| Sampled server RSS peak | 23.80 MiB | 73.86 MiB | 8.77 MiB |
| Sampled process-tree RSS peak | 71.36 MiB | 135.50 MiB | 55.75 MiB |

All 400 measured HTTP requests succeeded in each primary run. Throughput at concurrency four was 170.82 requests/second for Go, 14.43 for Gleam, and 163.51 for Rust. This measures the specified workload, not maximum server capacity.

## Equal functionality

| Check | Go | Gleam | Rust |
| --- | --- | --- | --- |
| Shared API, permissions, Git, issues, PRs, reviews and groups | 20 groups pass | 20 groups pass | 20 groups pass |
| MCP operations | 24 tools pass | 24 tools pass | 24 tools pass |
| Official MCP Python SDK 2.2.0 | Pass | Pass | Pass |
| Real OpenSSH Git and key revocation | 6 checks pass | 6 checks pass | 6 checks pass |
| Offline backup, restore and authenticated readback | Pass | Pass | Pass |
| Incomplete JSON body deadline, concurrent reads still work | About 10 seconds | About 10 seconds | About 10 seconds |

The browser checks cover account and repository creation, pins, shared groups across owners, inline comments, protected merge state, keyboard switching and mobile navigation. All three backends serve the same assets. Rust additionally passed browser integration checks for sign-in, personal and organization navigation, pins, keyboard switching, and mobile navigation. Codex and Claude setup flags were verified with the installed clients. No model was invoked and no global client configuration was changed.

## Implementation cost

| Component | Go | Gleam | Rust |
| --- | --- | --- | --- |
| Application source | 2,072 Go lines | 3,362 Gleam lines | 3,279 Rust lines |
| Application-specific OS integration | Go standard library | 396 Erlang lines, including embedded Python | Tokio, standard library, safe nix process APIs |
| Locked application packages | 1 direct | 6 direct, 14 resolved | 16 direct, 108 resolved |
| Runtime shape | Go executable with SQLite CGO, Git, Python | BEAM application with SQLite NIF, Git, Python | Rust executable with bundled SQLite, Git, Python |
| Packaged image size, uncompressed | 234.8 MiB | 480.4 MiB | 231.0 MiB |

All three use the shared OpenSSH sidecar, Python transport adapters, SQLite schema, MCP declarations and plain JavaScript interface. Image sizes exclude the shared SSH image. Physical line counts include comments and blanks, exclude tests and dependencies, and depend on formatting. They describe implementation size, not maintainability or developer productivity.

Gleam serializes metadata requests through a bounded FIFO mutex. Slow Git-backed operations therefore delay unrelated metadata reads under concurrent load. Go avoids that application-wide serialization and uses repository locks for mutations. The directory row from the mixed workload includes this queueing; the separate 1,000-repository probe isolates directory and search operations.

Gleam expresses application rules in typed, immutable functions. Erlang and embedded Python provide filesystem, process, pipe and cancellation primitives. Go provides those primitives directly through its standard library. All three use native Git for repository operations. None replaces Git's object storage or wire protocol.

Rust uses Axum on Tokio with an explicit HTTP/1 connection boundary for header deadlines and connection admission. Metadata requests use separate SQLite connections and bounded blocking workers. Per-repository locks serialize mutations; directory reads return persisted metadata for a busy repository. Typed input structures and enums cover mutation fields, while SQLite rows and API envelopes use JSON values. Rust's additional dependencies provide HTTP, asynchronous I/O, SQLite, and cryptography that Go supplies largely through its standard library.

Rust's 22 unit tests include an injected database failure after the atomic Git merge, conservative recovery of corrupt or mismatched ledger state, default-branch rollback, and permission changes. Separate transport checks verify 8 MiB chunked payload identity, eight-transfer admission, hook availability at capacity, disconnect cleanup, five-second header deadlines, and cleanup of external children during active and startup shutdown. No equivalent new lifecycle probe was run against Go or Gleam in this Rust addition.

Go retains the smallest dependency surface. Rust adds a larger crate graph and explicit lifecycle code while using less sampled memory in this fixture. The latency samples do not establish a meaningful Go/Rust speed winner or developer productivity difference.

## Findings fixed before final measurement

The initial Go directory benchmark took 229 ms median for 40 repositories. Missing or packed default refs caused a Git subprocess per repository. Bounded loose/packed ref reads removed those process launches while preserving missed-hook reconciliation.

The initial Gleam run had three requests delayed roughly 27 to 31 seconds. OTP's distributed lock retried with randomized backoff while newer requests repeatedly acquired the lock. A bounded local FIFO mutex replaced it. An isolated contention check reduced the first completed lock-protected calls from as much as 9,037 ms to 11, 22, 33 and 44 ms, including ten milliseconds of simulated work per call.

These changes show why runtime claims must follow measurement. The final comparison includes both fixes. Earlier measurements are retained as `go-benchmark-before-ref-read.json` and `gleam-benchmark-before-fifo-lock.json` under `tests/results`.

## Measurement conditions

- Apple M5 Max, 128 GiB RAM, macOS 27, arm64. Go 1.26.8; Gleam 1.18.1; Erlang/OTP 29, ERTS 17.0.6; Rust 1.98.1 with release optimization and thin LTO, Axum 0.8.9, Tokio 1.53.1, and rusqlite 0.40.2.
- Native servers with fresh, separate data directories. The Rust measurements were added later on the same machine with the same harness and fixture. Earlier Go/Gleam measurements are retained, not rerun. No builds ran during the measured Rust phases. Docker packaging was checked separately.
- Primary fixture: 40 repositories, one populated and 39 empty. The populated repository has 20 default-branch commits, 100 source files and a seeded 1 MiB binary. HTTP measurement uses 40 warmup requests, 400 measured requests across ten operations and concurrency four. Git clone and push have five samples each.
- Directory probe: 1,000 repositories, one populated and 999 empty; four warmup requests and 20 measured requests divided between directory listing and search, at concurrency four. Each directory percentile has ten samples. This measures directory metadata scaling, not 1,000 large active repositories.
- Percentiles use nearest rank. HTTP latency includes client scheduling and fresh urllib requests. RSS is sampled every 50 ms plus process-table collection time after setup and warmup. It is not an OS high-water mark; summed process-tree RSS can double-count shared pages.

Local tests do not establish production uptime, Internet-scale capacity or a developer-experience advantage over GitHub/GitLab. No competing forge was benchmarked. The results compare these implementations and their dependency paths, not the languages in isolation.

## Reproduce

Use the commands in [README.md](README.md) to start isolated source builds. Tests create disposable accounts and repositories.

```sh
python3 tests/benchmark.py --url http://localhost:7701 --server-pid ACTUAL_GO_PID --report go.json
python3 tests/benchmark.py --url http://localhost:7702 --server-pid ACTUAL_BEAM_PID --report gleam.json
python3 tests/benchmark.py --url http://localhost:7703 --server-pid ACTUAL_RUST_PID --report rust.json
```

The benchmark servers must start with empty data directories. Use `--repositories 1000 --directory-only --requests 20 --warmup 4 --git-rounds 1` for the directory probe. Keep workload flags identical and do not run measurements concurrently.

Raw primary results: [Go](tests/results/go-benchmark.json), [Gleam](tests/results/gleam-benchmark.json). Directory probe: [Go](tests/results/go-directory-1000.json), [Gleam](tests/results/gleam-directory-1000.json). Supporting evidence: [browser](reports/browser.json), [MCP SDK](reports/mcp-client.json), [review fixes](reports/review.json), [source size](reports/source-size.json), [packaging](reports/packaging.json). The remaining acceptance, recovery and SSH reports are under [tests/results](tests/results).

Rust evidence: [primary benchmark](tests/results/rust-benchmark.json), [1,000-repository directory](tests/results/rust-directory-1000.json), [review](reports/rust-review.json), [lifecycle](tests/results/rust-lifecycle.json), [packaging](reports/rust-packaging.json), [browser](reports/rust-browser.json), and [MCP SDK](reports/rust-mcp-client.json). Start reading the implementation at [the Rust guide](implementations/rust/README.md).
