# GitClub for Railway: the application and the OpenSSH transport in one image.
#
# Compose runs these as two services sharing the go-data volume. Railway
# attaches a volume to exactly one service, and the SSH transport needs the
# same /data (host keys, and the bare repositories its forced commands run
# git against), so on Railway they share a container instead.
FROM golang:1.27.1-bookworm AS build
WORKDIR /src/implementations/go
COPY implementations/go/go.mod implementations/go/go.sum ./
RUN go mod download
COPY implementations/go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /gitclub .

FROM debian:trixie-slim
# Debian ships pg_dump 15, which refuses to dump a PostgreSQL 18 server, so the
# client tools that backup and restore shell out to come from PGDG instead.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends git python3 openssh-server openssh-client postgresql-client-18 \
    && apt-get purge -y curl gnupg && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/sh git \
    && passwd -d git \
    && mkdir /data && chown git:git /data
WORKDIR /app
COPY --from=build /gitclub /app/.build/gitclub-go
COPY web /app/web
COPY shared /app/shared
COPY scripts/gitclub /app/scripts/gitclub
COPY deploy/railway/entrypoint.py /app/deploy/railway/entrypoint.py
ENV DATA_DIR=/data HOST=0.0.0.0 PORT=7701 WEB_DIR=/app/web SHARED_DIR=/app/shared
EXPOSE 7701 2222
# Starts as root so sshd can own its host keys and privilege separation; the
# application process drops to the git account.
ENTRYPOINT ["python3", "/app/deploy/railway/entrypoint.py"]
