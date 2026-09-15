// GitClub on Railway.
//
//   railway login && railway link
//   railway config plan          # preview, changes nothing
//   railway config apply         # apply after reviewing the plan
//
// Config as Code (railway.json / railway.toml) is deprecated and new services
// cannot opt into it, so this file is the whole project definition. Omitting a
// resource here deletes it, so keep every GitClub service in this one file.
//
// Two settings are enabled through Railway's CLI after initial provisioning:
//   - Point-in-Time Recovery on the Postgres service. Enable it with
//     railway postgres pitr enable --service postgres. Its bucket is retained
//     below so a later apply cannot delete the recovery archive.
//   - The TCP proxy that exposes SSH Git on port 2222. Add it under the
//     service's Settings, Networking, Public Access, or use
//     railway tcp-proxy create --service gitclub --port 2222.
import { bucket, defineRailway, github, postgres, preserve, project, service, volume } from "railway/iac";

export default defineRailway(() => {

  // Pinned to the major tag. Point-in-Time Recovery refuses a minor pin, and
  // converting to high availability later requires a pinned major. PostgreSQL
  // 19 is not an option yet: Railway publishes no 19 image. See DECISION.md.
  const db = postgres("postgres");

  // Bare Git repositories and the SSH host keys. PostgreSQL replication does
  // not cover this volume; the i9 mirror sweep is what protects it.
  const repositories = volume("gitclub-data", { sizeMB: 5_000, region: "us-west2" });
  const archive = bucket("Postgres-PITR", { region: "sjc" });

  const gitclub = service("gitclub", {
    source: github("stevencarpenter/gitclub", { branch: "main" }),
    healthcheck: "/health",
    healthcheckTimeout: 30,
    // One instance only. Repository mutations serialize on a PostgreSQL
    // advisory lock, but the Git objects live on a volume attached to exactly
    // one service, and shared/git-hook.py calls back to 127.0.0.1. A second
    // replica would have no repositories and no route to this one's hooks.
    replicas: 1,
    volumeMounts: { "/data": repositories },
    env: {
      // The image builds both the server and the OpenSSH transport, because
      // Railway attaches a volume to one service and SSH needs the same /data.
      RAILWAY_DOCKERFILE_PATH: "deploy/railway/Dockerfile",
      DATABASE_URL: db.env.DATABASE_URL,
      // Railway generates the hostname. Browser Origin checks use this exact URL.
      PUBLIC_URL: "https://${{RAILWAY_PUBLIC_DOMAIN}}",
      DATA_DIR: "/data",
      PORT: "7701",
      // Set once in the Railway dashboard as a sealed variable, at least 32
      // characters. preserve() keeps it out of this file and out of git.
      GITCLUB_SSH_SECRET: preserve(),
      // Set to an existing account after provisioning it. Its global read
      // access keeps newly created private namespaces in the DR inventory.
      GITCLUB_BACKUP_USERNAME: preserve(),
    },
  });

  return project("gitclub", { resources: [db, repositories, archive, gitclub] });
});
