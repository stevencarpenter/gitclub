FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY scripts/build-sqlite.py /tmp/build-sqlite.py
RUN python3 /tmp/build-sqlite.py /opt/sqlite
ENV ESQLITE_USE_SYSTEM=1 CFLAGS=-I/opt/sqlite/include LDFLAGS=-L/opt/sqlite/lib
WORKDIR /src/implementations/gleam
COPY implementations/gleam/gleam.toml implementations/gleam/manifest.toml ./
RUN gleam deps download
COPY implementations/gleam .
RUN gleam export erlang-shipment \
    && erl -noshell -pa build/erlang-shipment/*/ebin \
       -eval '{ok,D}=esqlite3:open(":memory:"), [[<<"3.53.4">>]]=esqlite3:q(D,"select sqlite_version()"), ok=esqlite3:close(D), halt().'

FROM erlang:29.0.6-slim
RUN apt-get update && apt-get install -y --no-install-recommends git python3 ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/sh git \
    && mkdir /data && chown git:git /data
WORKDIR /app
COPY --from=build /src/implementations/gleam/build/erlang-shipment /app/implementations/gleam/build/erlang-shipment
COPY web /app/web
COPY shared /app/shared
COPY scripts/gitclub /app/scripts/gitclub
RUN erl -noshell -pa /app/implementations/gleam/build/erlang-shipment/*/ebin \
    -eval '{ok,D}=esqlite3:open(":memory:"), [[<<"3.53.4">>]]=esqlite3:q(D,"select sqlite_version()"), ok=esqlite3:close(D), halt().'
USER git
ENV DATA_DIR=/data HOST=0.0.0.0 PORT=7702 WEB_DIR=/app/web SHARED_DIR=/app/shared
EXPOSE 7702
ENTRYPOINT ["python3", "/app/scripts/gitclub", "run", "gleam", "--no-build", "--host", "0.0.0.0", "--data-dir", "/data"]
