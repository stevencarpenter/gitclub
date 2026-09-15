FROM ghcr.io/railwayapp-templates/postgres-ssl:18

RUN apt-get update \
    && apt-get install -y --no-install-recommends git python3 \
    && rm -rf /var/lib/apt/lists/*

COPY gitclub-mirror-sweep gitclub-recover gitclub-verify-recovery bootstrap-standby.sh dr-entrypoint.sh mirror-loop.sh /usr/local/bin/
COPY postgresql.standby.conf /usr/local/bin/postgresql.standby.conf
COPY test_runtime.sh prepare-repositories.py /opt/gitclub/
RUN chmod 0755 /usr/local/bin/gitclub-* /usr/local/bin/*.sh /opt/gitclub/test_runtime.sh

ENV PGDATA=/var/lib/gitclub/standby \
    GITCLUB_STANDBY_PGDATA=/var/lib/gitclub/standby \
    GITCLUB_RECOVERY_PGDATA=/var/lib/gitclub/recovered \
    GITCLUB_MIRRORS=/var/lib/gitclub/mirrors

# Bypass Railway's primary wrapper, which configures archiving and backups.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/dr-entrypoint.sh"]
CMD ["standby"]
STOPSIGNAL SIGTERM
