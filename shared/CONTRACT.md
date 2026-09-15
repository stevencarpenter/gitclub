# GitClub implementation contract

The Go server implements this contract. Schema, browser assets, Git hook and SSH transport glue, test fixtures, and MCP tool declarations live under `shared/` and `web/`. All authorization, business rules, persistence operations, HTTP routing, and MCP dispatch live in Go.

## Runtime

Start from repository root. Environment: PORT (default 7701), HOST (default 127.0.0.1), DATA_DIR (required configurable, default .data/go), WEB_DIR (default web), SHARED_DIR (default shared), PUBLIC_URL (default http://localhost:PORT). DATABASE_URL (required, postgres://user:password@host:port/database). Data: PostgreSQL, migrated from shared/migrations/*.sql at startup; bare Git repositories DATA_DIR/repos/ID.git. All paths must become absolute at startup. Python 3 and Git are runtime dependencies for hook and SSH transport adapters. Package a Linux container.

GET /health returns {"status":"ok","implementation":"go"}. Listen only after migrations complete. Shutdown stops accepting requests and completes/cancels work within a bounded timeout. Use independent bounded budgets of 8 Git HTTP transfers and 8 ordinary Git commands; return 503 when saturated. Reserve hook-control capacity so transfers cannot deadlock their own authorization callbacks. SSH separately enforces 8 simultaneous transfers across all forced-command processes; this is a distinct transport budget. JSON request bodies have a 10-second read deadline and must be read before repository locks are acquired. JSON bodies max 1 MiB; Git HTTP requests max 256 MiB, output streamed. Read Git subprocesses timeout 30s; transfers 120s. No arbitrary user-supplied shell commands or server-side clone URLs.

## Common data and auth

Timestamps are integer Unix milliseconds. IDs are PostgreSQL BIGINT identity values. JSON snake_case fields. Collections are enveloped in the plural resource name; errors {"error":"actionable message"}. Validation 400, missing authentication 401, forbidden mutation 403, inaccessible resource 404, state conflict 409. No stack traces, secrets, or subprocess stderr exposing private paths in API errors. GET responses never mutate user choices.

User: {id,username}. Repository: {id,owner,name,full_name,description,visibility,default_branch,require_review,created_at,updated_at,pinned,role}; full_name=owner/name, booleans real JSON bools; role admin/write/read (public nonmembers read). Never expose password/token hashes. Namespace: {name,kind,role}. Group: {id,name,creator_id,shared,repo_ids}, with repo_ids filtered by requester access.

Password storage: PBKDF2-HMAC-SHA256, 600000 iterations, random 16-byte salt, 32-byte hash, format pbkdf2_sha256$600000$SALT_HEX$HASH_HEX. Password 12..256 UTF-8 bytes, username/namespace/repository lowercase ASCII [a-z0-9][a-z0-9._-]{0,62}, reject . and .. and .git suffix for repo names. Tokens random 32-byte hex, store SHA256(token) only. Authorization: Bearer TOKEN or HttpOnly SameSite=Strict gc_session cookie (Secure under HTTPS), Git HTTPS additionally supports Basic username:TOKEN. Check cookie-authenticated mutations have same-origin Origin or explicit X-GitClub-Request: 1 header and application/json; never allow cross-origin CORS. Registration open for this self-hosted MVP. Basic rate limit login/registration failures per peer with bounded state. Logging excludes request auth and passwords.

Roles inherit namespace membership or repository membership, take highest. Organization creation gives creator admin. Personal namespace belongs to user. Read sees code and discussions; write may push branches/create and review PRs/issues; admin manages repository settings and membership. Only creator can edit group contents/sharing; any authenticated user can read shared group filtered by existing repository access. Sharing grants no repo access. All group membership inserts require creator already has repo read access. Pins per user.

## Authentication and ownership routes

POST /api/auth/register {username,password} -> 201 {user,token}, creates personal namespace, signs in with cookie.
POST /api/auth/login {username,password} -> 200 {user,token}, sets cookie.
POST /api/auth/logout -> {ok:true}, revokes current token and clears cookie.
GET /api/session -> {user:User|null}.
GET /api/users -> {users:[User]} authenticated, search optional ?q=, max 100.
GET /api/namespaces -> {namespaces:[Namespace]} requester memberships only.
POST /api/namespaces {name} -> 201 {namespace:Namespace} organization.
POST /api/namespaces/NAME/members {username,role} -> {ok:true}, admin only.
GET /api/ssh-keys -> {ssh_keys:[{id,title,public_key,created_at}]} own keys.
POST /api/ssh-keys {title,public_key} -> 201 {ssh_key:{id,title,public_key,created_at}}. Validate actual OpenSSH key using ssh-keygen, reject options/newlines.
DELETE /api/ssh-keys/ID -> {ok:true}, owner only.

## Repositories

GET /api/repos?q=&owner=&group=ID -> {repositories:[Repository]}. Accessible repositories across ALL owners, pins first, then updated_at DESC, id ASC. Search case-insensitive owner/name/description. Group filter must enforce group visibility. Anonymous sees public repos only.
POST /api/repos {owner,name,description?,visibility?,default_branch?} -> 201 {repository:Repository}. Namespace write/admin only. Initialize empty bare repo, HEAD to default branch, install shared hooks. created_at and updated_at=now, default_oid empty. No embedded demo data.
GET /api/repos/ID -> {repository:Repository}.
PATCH /api/repos/ID {description?,visibility?,default_branch?,require_review?} -> {repository:Repository}, admin only. Validate branch with git check-ref-format --branch; changing default updates symbolic HEAD and sets observed freshness to now.
POST /api/repos/ID/members {username,role} -> {ok:true}, admin only.
POST /api/repos/ID/pin {pinned:bool} -> {ok:true}, authenticated read access.
GET /api/repos/ID/branches -> {branches:[{name,oid}],default_branch}.
GET /api/repos/ID/tree?ref=BRANCH&path= -> {entries:[{name,path,type:"file"|"directory",size}],ref}. Empty repo -> entries [].
GET /api/repos/ID/blob?ref=BRANCH&path=PATH -> {path,content,binary,truncated,size}. Max 512 KiB returned, no HTML rendering of source/Markdown; binary content empty with binary true.
GET /api/repos/ID/commits?ref=BRANCH -> {commits:[{oid,short_oid,subject,author,date}]}, max 50, date ISO8601.
GET /api/repos/ID/diff?base=REF&head=REF -> {diff,base_oid,head_oid,truncated}. Max 1 MiB output; truncated flag. Resolve and validate refs before command construction. Git arguments passed as argv, never shell interpolation. Invalid paths/refs rejected; output rendered as text.

## Groups

GET /api/groups -> {groups:[Group]}, own + shared, ordered name/id.
POST /api/groups {name,shared?} -> 201 {group:Group}, name 1..80 chars.
PATCH /api/groups/ID {name?,shared?,repo_ids?:[ID]} -> {group:Group}, creator only, replace membership atomically.
DELETE /api/groups/ID -> {ok:true}, creator only.

## Issues and pull requests

Issue: {id,repo_id,author_id,author,title,body,state,created_at,updated_at}. Pull: {id,repo_id,author_id,author,title,body,base_branch,head_branch,state,created_at,updated_at,merged_oid}. Comment: {id,author_id,author,body,path,line,commit_oid,created_at}. Review: {id,author_id,author,decision,body,commit_oid,created_at}.

GET /api/repos/ID/issues -> {issues:[Issue]} newest first.
POST /api/repos/ID/issues {title,body?} -> 201 {issue:Issue}, write access.
GET /api/repos/ID/issues/ISSUE -> {issue:Issue,comments:[Comment]}.
PATCH /api/repos/ID/issues/ISSUE {title?,body?,state?} -> {issue:Issue}, author or repo admin.
POST /api/repos/ID/issues/ISSUE/comments {body} -> 201 {comment:Comment}, write access.
GET /api/repos/ID/pulls -> {pulls:[Pull]} newest first.
POST /api/repos/ID/pulls {title,body?,base_branch?,head_branch} -> 201 {pull:Pull}, write access, existing distinct branch tips with actual changes. default base configured default branch.
GET /api/repos/ID/pulls/PULL -> {pull:Pull,comments:[Comment],reviews:[Review],diff,base_oid,head_oid,truncated,mergeable:bool,merge_blockers:[string]}. Read latest heads for open PR; expose actionable blockers. No CI state.
PATCH /api/repos/ID/pulls/PULL {title?,body?,state?} -> {pull:Pull}, author/admin, open/closed only, merged immutable.
POST /api/repos/ID/pulls/PULL/comments {body,path?,line?,commit_oid?} -> 201 {comment:Comment}, write access. Optional inline location anchored to provided current head OID; reject stale/invalid OID, unsafe paths, negative lines.
POST /api/repos/ID/pulls/PULL/reviews {expected_head_oid:OID,decision:"approve"|"request_changes"|"comment",body?} -> 201 {review:Review}, write access. Compare expected_head_oid against the current head under repository lock; reject stale reviews with 409. Record that exact reviewed head OID; author cannot approve own PR.
POST /api/repos/ID/pulls/PULL/merge {expected_head_oid:OID} -> {pull:Pull,commit_oid:OID}, write access. Reject changed heads. Require open PR, no merge conflict, no current request_changes (latest decisive review per reviewer for current head), and when require_review true at least one approval of CURRENT head by another still-authorized writer. Serialize mutations per repo. Native git merge-tree --write-tree + commit-tree + update-ref compare-and-swap old base OID. Never reset or discard refs on failure. Mark merged and refresh default freshness after success. Handle a successful ref update with DB failure through explicit reconciliation/state marker. Use actual user's username as commit identity, no tool signatures.

## Git transport, hooks, SSH

GET/POST /OWNER/NAME.git/{info/refs,git-upload-pack,git-receive-pack} delegates native git http-backend CGI with streamed stdin/stdout and correct CGI headers. Git read requires repo read, receive requires write. Use sanitized env: GIT_PROJECT_ROOT=DATA_DIR/repos, PATH_INFO=/ID.git/..., GIT_HTTP_EXPORT_ALL=1, REMOTE_USER=username, GIT_PROTOCOL from Git-Protocol. Deny unsupported CGI paths. Set GITCLUB_URL=internal loopback URL, GITCLUB_TOKEN=authenticated raw token, GITCLUB_REPO_ID=ID for hooks; no inherited arbitrary Git config, external diff, hooks path, proxy environment. Disable receive.denyNonFastForwards? Hook enforces default policy.

Each bare repo gets executable pre-receive and post-receive adapters from shared/git-hook.py. Adapter forwards refs as {updates:[{old,new,ref}]} to POST /api/repos/ID/git/pre-receive or post-receive with Bearer token. Pre optionally includes quarantine_path from GIT_QUARANTINE_PATH; validate its resolved path is inside this exact repository objects/tmp_objdir-incoming-* and use it plus the normal objects directory for ancestry checks. Pre requires write; protects initialized default branch against direct push when require_review true; always forbids non-fast-forward/deletion of initialized default branch. Initial empty-branch population allowed for Git-history-only import. Post requires write; refreshes default_oid and updated_at only if current default OID differs. Reconcile missed notifications on repository read/list by comparing actual default OID; feature branches must not change freshness.

SSH transport will use system OpenSSH and a shared Python adapter. POST /api/ssh/authorize {key_id,command} with X-GitClub-SSH-Secret header matching server-side GITCLUB_SSH_SECRET -> {repo_id,user_id,token,repository_path,operation,internal_url}; parse only git-upload-pack or git-receive-pack with quoted OWNER/NAME.git, validate key and permissions. Short-lived/revoked adapter token cleanup required. GET /api/ssh/authorized-keys with X-GitClub-SSH-Secret header -> {keys:[{id,public_key}]}. Adapter implementation owned by root; backend implement endpoints. Default disable SSH secret endpoints unless configured. No network-supplied command executed through shell.

## MCP

POST /mcp authenticated Bearer, stateless JSON-RPC 2.0 over HTTP. Support initialize (negotiate 2025-06-18 for unknown versions, otherwise requested supported 2024-11-05/2025-03-26/2025-06-18), notifications/initialized (202), ping, tools/list, tools/call. Proper request ids, method-not-found -32601, invalid params -32602, malformed JSON -32700. GET /mcp -> 405 allowed for stateless transport. shared/mcp-tools.json contains tool name, description, inputSchema and HTTP mapping. tools/list strips mapping. Calls reuse native API business rules, return content:[{type:"text",text:JSON_STRING}], isError on operation error. No arbitrary URL dispatch; map declared tool only. Unknown tools return JSON-RPC invalid params.

## Browser

Serve identical web/index.html, app.js, style.css for both. SPA routes fall back to index outside /api, /mcp and .git. CSP self assets only, no inline scripts, X-Content-Type-Options nosniff, Referrer-Policy same-origin, frame-ancestors none. UI uses cookies plus X-GitClub-Request:1. No localStorage tokens. Store draft text and UI preferences only, namespaced by user/repo. Display implementation label for comparison, never invented repo data. Keyboard switcher Ctrl/Cmd+K and accessible responsive persistent sidebar.

## Comparison

Run same Python stdlib acceptance suite per fresh isolated data dir, same fixtures and request mix. Record actual toolchain versions, release builds, build time, HTTP p50/p95/p99, Git push/clone elapsed, peak server RSS and process-tree RSS if available, source counts by language, dependency counts, failures and unavailable checks. Do not extrapolate local benchmarks to uptime or production scale. No measured result without raw output.
