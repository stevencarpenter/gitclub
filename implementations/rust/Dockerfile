FROM rust:1.98.1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/build-sqlite.py /tmp/build-sqlite.py
RUN python3 /tmp/build-sqlite.py /opt/sqlite
ENV LIBSQLITE3_SYS_USE_PKG_CONFIG=1 SQLITE3_NO_PKG_CONFIG=1 \
    SQLITE3_LIB_DIR=/opt/sqlite/lib SQLITE3_INCLUDE_DIR=/opt/sqlite/include SQLITE3_STATIC=1
WORKDIR /src/implementations/rust
COPY implementations/rust/Cargo.toml implementations/rust/Cargo.lock ./
COPY implementations/rust/src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git python3 ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/sh git \
    && mkdir /data && chown git:git /data
WORKDIR /app
COPY --from=build /src/implementations/rust/target/release/gitclub /app/.build/gitclub-rust
COPY web /app/web
COPY shared /app/shared
COPY scripts/gitclub /app/scripts/gitclub
USER git
ENV DATA_DIR=/data HOST=0.0.0.0 PORT=7703 WEB_DIR=/app/web SHARED_DIR=/app/shared
EXPOSE 7703
ENTRYPOINT ["python3", "/app/scripts/gitclub", "run", "rust", "--no-build", "--host", "0.0.0.0", "--data-dir", "/data"]
