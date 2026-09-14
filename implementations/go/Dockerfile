FROM golang:1.27.1-bookworm AS build
WORKDIR /src/implementations/go
COPY implementations/go/go.mod implementations/go/go.sum ./
RUN go mod download
COPY implementations/go .
RUN CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o /gitclub .

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends git python3 ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/sh git \
    && mkdir /data && chown git:git /data
WORKDIR /app
COPY --from=build /gitclub /app/.build/gitclub-go
COPY web /app/web
COPY shared /app/shared
COPY scripts/gitclub /app/scripts/gitclub
USER git
ENV DATA_DIR=/data HOST=0.0.0.0 PORT=7701 WEB_DIR=/app/web SHARED_DIR=/app/shared
EXPOSE 7701
ENTRYPOINT ["python3", "/app/scripts/gitclub", "run", "go", "--no-build", "--host", "0.0.0.0", "--data-dir", "/data"]
