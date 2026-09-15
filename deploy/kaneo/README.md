# GitClub to Kaneo status sync

The i9 bridge polls allowlisted GitClub repositories and marks a linked Kaneo task done after its pull request merges. Kaneo stays on the tailnet. The container makes outbound requests and publishes no ports.

## Configure on i9

1. Copy this directory to `~/gitclub-kaneo` on i9. From that directory, create the private config:

   ```sh
   mkdir -p ~/.config/gitclub-kaneo
   chmod 700 ~/.config/gitclub-kaneo
   install -m 600 config.example.json ~/.config/gitclub-kaneo/config.json
   ```

2. Set the two credentials in `~/.config/gitclub-kaneo/config.json`. The GitClub account needs read access to each configured repository. The Kaneo API key needs access to its tasks, project columns and task status updates. An empty `repositories` object performs no requests or updates.

   A repository mapping looks like this, with real IDs substituted:

   ```json
   {
     "gitclub_url": "https://gitclub-production.up.railway.app",
     "gitclub_token": "GITCLUB_TOKEN",
     "kaneo_url": "https://kaneo.snugmarina.org",
     "kaneo_api_key": "KANEO_API_KEY",
     "repositories": {
       "42": {
         "project_url": "https://kaneo.snugmarina.org/dashboard/workspace/WORKSPACE_ID/project/PROJECT_ID/board",
         "done_status": "done"
       }
     }
   }
   ```

   The mapping key is the GitClub repository ID. `project_url` must exactly match that repository's Kaneo board URL. `done_status` is the destination column's slug, checked against `GET /api/column/PROJECT_ID`. Both server URLs must be HTTPS origins without a trailing slash. Config permissions must remain `0600` or `0400`.

3. Run one sweep, then start the service:

   ```sh
   docker compose run --rm sync python -B -u /app/sync.py --config /run/secrets/config --state /state/completed.sqlite3 --once
   docker compose up -d
   docker compose logs --tail 20 sync
   ```

   `--once` performs status updates and returns a nonzero exit code on failure. After changing the config, run `docker compose up -d --force-recreate` to remount it.

## Synchronization contract

The bridge waits 60 seconds between sweeps. Only explicitly configured repository IDs are fetched. It reads `GET /api/repos/ID/kaneo/merges?after_id=0` in pages of 100 linked merges, without PR bodies. IDs must increase across pages, and responses remain limited to 4 MiB. Each sweep starts at ID zero so failed task updates remain eligible for retry.

Each merged pull request must carry a canonical task URL under its allowlisted project. The bridge also checks the task's actual `projectId` before sending `PUT /api/task/status/TASK_ID` with only `{"status":"done"}` (or the configured column slug).

The bridge creates no tasks, comments or backlinks and does not change task titles or descriptions. Failed requests retry on the next sweep. GitClub merges do not wait for Kaneo. Newly configured repositories include existing merged pull requests with task links.

Successful PR/task pairs are recorded in `/state/completed.sqlite3`, including tasks already in the destination status. The ledger prevents replay after restarts and preserves later manual task reopens. Keep the `gitclub-kaneo_state` Docker volume when restarting or upgrading; an empty ledger reprocesses existing merges. Credentials live only in the private config mounted read-only into this container. The bridge does not share the disaster recovery network, volumes or secrets.

## Offline verification

From the GitClub repository root:

```sh
python3 tests/test_kaneo_sync.py
docker compose -f deploy/kaneo/compose.yaml config --quiet
```
