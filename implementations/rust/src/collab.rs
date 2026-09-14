use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    core::{
        ApiError, Context, Reply, Result, boolean, lock_repo, now, number, parse_id, rank,
        require_user, text,
    },
    git::{oid_ok, valid_branch, valid_path},
};

#[derive(Clone, Copy)]
enum DiscussionKind {
    Issue,
    Pull,
}

impl DiscussionKind {
    fn table(self) -> &'static str {
        match self {
            Self::Issue => "issues",
            Self::Pull => "pull_requests",
        }
    }
    fn singular(self) -> &'static str {
        match self {
            Self::Issue => "issue",
            Self::Pull => "pull",
        }
    }
    fn plural(self) -> &'static str {
        match self {
            Self::Issue => "issues",
            Self::Pull => "pulls",
        }
    }
    fn is_pull(self) -> bool {
        matches!(self, Self::Pull)
    }
}

#[derive(PartialEq)]
enum ReviewDecision {
    Approve,
    RequestChanges,
    Comment,
}

impl ReviewDecision {
    fn parse(value: &str) -> Result<Self> {
        match value {
            "approve" => Ok(Self::Approve),
            "request_changes" => Ok(Self::RequestChanges),
            "comment" => Ok(Self::Comment),
            _ => Err(ApiError::new(
                400,
                "Decision must be approve, request_changes, or comment",
            )),
        }
    }
}

fn git_error(error: ApiError, status: u16, message: &str) -> ApiError {
    if error.status >= 500 {
        error
    } else {
        ApiError::new(status, message)
    }
}

fn discussion_text<'a>(
    body: &'a Value,
    key: &str,
    required: bool,
    limit: usize,
) -> Result<&'a str> {
    let value = match body.get(key) {
        None if !required => return Ok(""),
        Some(Value::String(value)) => value.as_str(),
        _ => return Err(ApiError::new(400, format!("{key} must be a string"))),
    };
    if value.len() > limit || value.contains('\0') || (required && value.trim().is_empty()) {
        return Err(ApiError::new(
            400,
            format!(
                "{key} must {}contain at most {limit} bytes and no NUL",
                if required { "be nonempty and " } else { "" }
            ),
        ));
    }
    Ok(value)
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
struct MergeMarker {
    pull_id: i64,
    base_branch: String,
    base_oid: String,
    commit_oid: String,
    updated_at: i64,
}

impl MergeMarker {
    fn validate(&self, file_name: &str) -> bool {
        self.pull_id > 0
            && self.updated_at > 0
            && valid_branch(&self.base_branch)
            && oid_ok(&self.base_oid)
            && oid_ok(&self.commit_oid)
            && file_name == format!("gitclub-merge-{}.json", self.pull_id)
    }
}

fn durable_marker(path: &Path, marker: &MergeMarker) -> Result<()> {
    let data = serde_json::to_vec(marker)
        .map_err(|_| ApiError::new(500, "Cannot encode merge recovery state"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    let persist = (|| -> std::io::Result<()> {
        file.write_all(&data)?;
        file.sync_all()?;
        sync_parent(path)
    })();
    if let Err(error) = persist {
        // This invocation created the file, so removing a partial write cannot erase another intent.
        let _ = fs::remove_file(path);
        return Err(error.into());
    }
    Ok(())
}

fn sync_parent(path: &Path) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("Recovery path has no parent"))?;
    File::open(parent)?.sync_all()
}

fn clear_marker(path: &Path) -> Result<()> {
    fs::remove_file(path)
        .and_then(|()| sync_parent(path))
        .map_err(|_| ApiError::new(503, "Cannot clear merge recovery state"))
}

impl Context {
    fn discussion(&self, repo_id: i64, id: i64, kind: DiscussionKind) -> Result<Value> {
        let row = self.one(&format!("SELECT d.*,u.username AS author FROM {} d JOIN users u ON u.id=d.author_id WHERE d.repo_id=? AND d.id=?", kind.table()), &[&repo_id, &id])?;
        if row.is_null() {
            return Err(ApiError::new(404, "Discussion not found"));
        }
        Ok(row)
    }

    fn discussion_comments(&self, id: i64, kind: DiscussionKind) -> Result<Vec<Value>> {
        self.rows("SELECT c.id,c.author_id,u.username AS author,c.body,c.path,c.line,c.commit_oid,c.created_at FROM comments c JOIN users u ON u.id=c.author_id WHERE c.target_type=? AND c.target_id=? ORDER BY c.id", &[&kind.singular(), &id])
    }

    fn pull_reviews(&self, id: i64) -> Result<Vec<Value>> {
        self.rows("SELECT r.id,r.author_id,u.username AS author,r.decision,r.body,r.commit_oid,r.created_at FROM reviews r JOIN users u ON u.id=r.author_id WHERE r.pull_id=? ORDER BY r.id", &[&id])
    }

    fn pull_tips(&self, repo: &Value, pull: &Value) -> Result<(String, String)> {
        Ok((
            self.resolve(repo, &format!("refs/heads/{}", text(pull, "base_branch")))?,
            self.resolve(repo, &format!("refs/heads/{}", text(pull, "head_branch")))?,
        ))
    }

    // The simulated tree uses these exact tips; update-ref verifies both again atomically.
    fn pull_blockers(
        &self,
        repo: &Value,
        pull: &Value,
        base: &str,
        head: &str,
    ) -> Result<(Vec<String>, String)> {
        let mut blockers = Vec::new();
        if text(pull, "state") != "open" {
            blockers.push("Pull request is not open".to_owned());
        }
        if base.is_empty() || head.is_empty() {
            blockers.push("Restore the missing base or head branch".to_owned());
            return Ok((blockers, String::new()));
        }
        if base == head {
            blockers.push("Head has no changes to merge".to_owned());
        }
        let mut seen = HashSet::new();
        let mut approved = false;
        for review in self.rows("SELECT author_id,decision FROM reviews WHERE pull_id=? AND commit_oid=? AND decision<>'comment' ORDER BY id DESC", &[&number(pull, "id"), &head])? {
            let uid = number(&review, "author_id");
            if !seen.insert(uid) || rank(&self.role(repo, &json!({"id":uid}))?) < rank("write") { continue; }
            match ReviewDecision::parse(text(&review, "decision"))? {
                ReviewDecision::RequestChanges => blockers.push("A current reviewer has requested changes".to_owned()),
                ReviewDecision::Approve if uid != number(pull, "author_id") => approved = true,
                _ => {},
            }
        }
        if boolean(repo, "require_review") && !approved {
            blockers.push("Approval of the current head by another writer is required".to_owned());
        }
        match self.git_run(
            number(repo, "id"),
            &["merge-tree", "--write-tree", base, head],
        ) {
            Ok(output) => {
                let tree = String::from_utf8_lossy(&output)
                    .lines()
                    .next()
                    .unwrap_or("")
                    .trim()
                    .to_owned();
                if !oid_ok(&tree) {
                    return Err(ApiError::new(500, "Git returned an invalid merge tree"));
                }
                Ok((blockers, tree))
            }
            Err(error) if error.status >= 500 => Err(error),
            Err(_) => {
                blockers.push("Resolve merge conflicts or incompatible branch history".to_owned());
                Ok((blockers, String::new()))
            }
        }
    }

    /// Caller holds the repository mutex. The hidden ref proves whether the atomic transaction committed.
    pub(crate) fn reconcile_merges(&self, repo: &Value) -> Result<()> {
        let rid = number(repo, "id");
        let recovery_error = |_| ApiError::new(503, "Merge recovery state cannot be read");
        for entry in fs::read_dir(self.repo_path(rid)).map_err(recovery_error)? {
            let entry = entry.map_err(recovery_error)?;
            let name = entry.file_name();
            let Some(name) = name.to_str() else {
                continue;
            };
            if !name.starts_with("gitclub-merge-") || !name.ends_with(".json") {
                continue;
            }
            if !entry.file_type().map_err(recovery_error)?.is_file() {
                return Err(ApiError::new(
                    503,
                    "Merge recovery state requires operator inspection",
                ));
            }
            let path = entry.path();
            let mut data = Vec::new();
            File::open(&path)
                .map_err(recovery_error)?
                .take(16385)
                .read_to_end(&mut data)
                .map_err(recovery_error)?;
            let marker: MergeMarker = serde_json::from_slice(&data).map_err(|_| {
                ApiError::new(503, "Merge recovery state requires operator inspection")
            })?;
            if data.len() > 16384 || !marker.validate(name) {
                return Err(ApiError::new(
                    503,
                    "Merge recovery state requires operator inspection",
                ));
            }
            let ledger_ref = format!("refs/gitclub/merges/{}", marker.pull_id);
            let ledger = self
                .git_run(
                    rid,
                    &[
                        "for-each-ref",
                        "--format=%(refname) %(objectname)",
                        &ledger_ref,
                    ],
                )
                .map_err(|_| ApiError::new(503, "Cannot read merge transaction ledger"))?;
            let ledger = String::from_utf8_lossy(&ledger);
            if ledger.trim().is_empty() {
                // Git can ignore a corrupt loose ref while returning a successful empty listing.
                // Only absence of the loose ref and of a packed listing proves an unapplied intent.
                match fs::symlink_metadata(self.repo_path(rid).join(&ledger_ref)) {
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    _ => {
                        return Err(ApiError::new(
                            503,
                            "Merge transaction ledger cannot be verified",
                        ));
                    }
                }
                clear_marker(&path)?;
                continue;
            }
            if ledger.trim() != format!("{} {}", ledger_ref, marker.commit_oid) {
                return Err(ApiError::new(
                    503,
                    "Merge transaction ledger mismatch; inspect merge recovery state",
                ));
            }
            let changed = self.db.execute("UPDATE pull_requests SET state='merged',merged_oid=?,updated_at=? WHERE id=? AND repo_id=?", rusqlite::params![marker.commit_oid, marker.updated_at, marker.pull_id, rid])?;
            if changed != 1 {
                return Err(ApiError::new(
                    503,
                    "Merge recovery discussion is missing; inspect recovery state",
                ));
            }
            self.refresh(repo)?;
            clear_marker(&path)?;
        }
        Ok(())
    }

    pub(crate) fn collaboration_routes(
        &mut self,
        repo: &Value,
        rest: &[&str],
    ) -> Result<Option<Reply>> {
        let kind = match rest.first() {
            Some(&"issues") => DiscussionKind::Issue,
            Some(&"pulls") => DiscussionKind::Pull,
            _ => return Ok(None),
        };
        let rid = number(repo, "id");
        let mutex = self.app.repo_lock(rid);
        let _guard = lock_repo(&mutex)?;
        let repo = self.repo(rid, &self.user, "read")?;
        self.reconcile_merges(&repo)?;
        if self.method != "GET" {
            require_user(&self.user)?;
            if rank(&self.role(&repo, &self.user)?) < rank("write") {
                return Err(ApiError::new(403, "Repository write access required"));
            }
        }
        if rest.len() == 1 {
            let reply = match self.method.as_str() {
                "GET" => Reply::ok(
                    json!({kind.plural():self.rows(&format!("SELECT d.*,u.username AS author FROM {} d JOIN users u ON u.id=d.author_id WHERE d.repo_id=? ORDER BY d.id DESC", kind.table()), &[&rid])?}),
                ),
                "POST" => self.create_discussion(&repo, kind)?,
                _ => return Err(ApiError::new(405, "Method not allowed")),
            };
            return Ok(Some(reply));
        }
        let id = parse_id(rest[1]).map_err(|_| ApiError::new(404, "Discussion not found"))?;
        let discussion = self.discussion(rid, id, kind)?;
        let reply = match (rest.len(), self.method.as_str()) {
            (2, "GET") => self.read_discussion(&repo, &discussion, kind)?,
            (2, "PATCH") => self.patch_discussion(&repo, &discussion, kind)?,
            (2, _) => return Err(ApiError::new(405, "Method not allowed")),
            (3, "POST") => match rest[2] {
                "comments" => self.add_comment(&repo, &discussion, kind)?,
                "reviews" if kind.is_pull() => self.add_review(&repo, &discussion)?,
                "merge" if kind.is_pull() => self.merge_pull(&repo, &discussion)?,
                _ => return Err(ApiError::new(404, "Route not found")),
            },
            (3, _) => return Err(ApiError::new(405, "Method not allowed")),
            _ => return Err(ApiError::new(404, "Route not found")),
        };
        Ok(Some(reply))
    }

    fn create_discussion(&self, repo: &Value, kind: DiscussionKind) -> Result<Reply> {
        let title = discussion_text(&self.body, "title", true, 240)?;
        let content = discussion_text(&self.body, "body", false, 65536)?;
        let rid = number(repo, "id");
        let uid = number(&self.user, "id");
        let stamp = now();
        let id = if kind.is_pull() {
            let requested_base = discussion_text(&self.body, "base_branch", false, 1024)?;
            let base = if requested_base.is_empty() {
                text(repo, "default_branch")
            } else {
                requested_base
            };
            let head = discussion_text(&self.body, "head_branch", true, 1024)?;
            if !valid_branch(base) || !valid_branch(head) || base == head {
                return Err(ApiError::new(
                    400,
                    "Choose distinct valid base and head branches",
                ));
            }
            let (base_oid, head_oid) = self
                .pull_tips(repo, &json!({"base_branch":base,"head_branch":head}))
                .map_err(|error| git_error(error, 400, "Both branches must exist"))?;
            let changed = self
                .git_run(
                    rid,
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--name-only",
                        &format!("{base_oid}...{head_oid}"),
                        "--",
                    ],
                )
                .map_err(|error| {
                    git_error(
                        error,
                        409,
                        "Head branch must contain changes relative to base",
                    )
                })?;
            if changed.is_empty() {
                return Err(ApiError::new(
                    409,
                    "Head branch must contain changes relative to base",
                ));
            }
            self.exec("INSERT INTO pull_requests(repo_id,author_id,title,body,base_branch,head_branch,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)", &[&rid,&uid,&title,&content,&base,&head,&stamp,&stamp])?
        } else {
            self.exec("INSERT INTO issues(repo_id,author_id,title,body,created_at,updated_at) VALUES(?,?,?,?,?,?)", &[&rid,&uid,&title,&content,&stamp,&stamp])?
        };
        Ok(Reply::created(
            json!({kind.singular(): self.discussion(rid,id,kind)?}),
        ))
    }

    fn read_discussion(
        &self,
        repo: &Value,
        discussion: &Value,
        kind: DiscussionKind,
    ) -> Result<Reply> {
        let id = number(discussion, "id");
        let mut result =
            json!({kind.singular():discussion,"comments":self.discussion_comments(id, kind)?});
        if kind.is_pull() {
            let rid = number(repo, "id");
            let (mut base, mut head) = match self.pull_tips(repo, discussion) {
                Ok(tips) => tips,
                Err(error) if error.status >= 500 => return Err(error),
                Err(_) => (String::new(), String::new()),
            };
            let (blockers, _) = self.pull_blockers(repo, discussion, &base, &head)?;
            if text(discussion, "state") == "merged" {
                let oid = text(discussion, "merged_oid");
                let parent = |index| -> Result<String> {
                    let output = self.git_run(
                        rid,
                        &[
                            "rev-parse",
                            "--verify",
                            &format!("{oid}^{index}^{{commit}}"),
                        ],
                    )?;
                    Ok(String::from_utf8_lossy(&output).trim().to_owned())
                };
                base = parent(1)?;
                head = parent(2)?;
            }
            let (diff, truncated) = if base.is_empty() || head.is_empty() {
                (Vec::new(), false)
            } else {
                self.git_read(
                    rid,
                    1 << 20,
                    &[],
                    &[],
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        &format!("{base}...{head}"),
                        "--",
                    ],
                )?
            };
            result["reviews"] = json!(self.pull_reviews(id)?);
            result["diff"] = json!(String::from_utf8_lossy(&diff));
            result["base_oid"] = json!(base);
            result["head_oid"] = json!(head);
            result["truncated"] = json!(truncated);
            result["mergeable"] = json!(blockers.is_empty());
            result["merge_blockers"] = json!(blockers);
        }
        Ok(Reply::ok(result))
    }

    fn patch_discussion(
        &self,
        repo: &Value,
        discussion: &Value,
        kind: DiscussionKind,
    ) -> Result<Reply> {
        if number(discussion, "author_id") != number(&self.user, "id")
            && self.role(repo, &self.user)? != "admin"
        {
            return Err(ApiError::new(
                403,
                "Only the author or repository admin can edit this discussion",
            ));
        }
        if text(discussion, "state") == "merged" {
            return Err(ApiError::new(409, "Merged pull requests cannot be edited"));
        }
        let title = if self.body.get("title").is_some() {
            discussion_text(&self.body, "title", true, 240)?
        } else {
            text(discussion, "title")
        };
        let content = if self.body.get("body").is_some() {
            discussion_text(&self.body, "body", false, 65536)?
        } else {
            text(discussion, "body")
        };
        let state = if self.body.get("state").is_some() {
            text(&self.body, "state")
        } else {
            text(discussion, "state")
        };
        if !matches!(state, "open" | "closed") {
            return Err(ApiError::new(400, "State must be open or closed"));
        }
        self.exec(
            &format!(
                "UPDATE {} SET title=?,body=?,state=?,updated_at=? WHERE id=?",
                kind.table()
            ),
            &[&title, &content, &state, &now(), &number(discussion, "id")],
        )?;
        Ok(Reply::ok(
            json!({kind.singular():self.discussion(number(repo,"id"),number(discussion,"id"),kind)?}),
        ))
    }

    fn add_comment(&self, repo: &Value, discussion: &Value, kind: DiscussionKind) -> Result<Reply> {
        let content = discussion_text(&self.body, "body", true, 65536)?;
        let path = discussion_text(&self.body, "path", false, 4096)?;
        let oid = discussion_text(&self.body, "commit_oid", false, 64)?;
        let line = match self.body.get("line") {
            None => 0,
            Some(value) => value
                .as_i64()
                .ok_or_else(|| ApiError::new(400, "Comment line must be an integer"))?,
        };
        if line < 0 || (!path.is_empty() && !valid_path(path)) {
            return Err(ApiError::new(400, "Comment location is invalid"));
        }
        if !path.is_empty() || !oid.is_empty() || line != 0 {
            if !kind.is_pull() || path.is_empty() || oid.is_empty() || line <= 0 {
                return Err(ApiError::new(
                    400,
                    "Inline comments require a file path, positive line, and current head commit_oid",
                ));
            }
            let (_, head) = self.pull_tips(repo, discussion).map_err(|error| {
                git_error(
                    error,
                    409,
                    "Head changed; reload the diff before commenting",
                )
            })?;
            if oid != head {
                return Err(ApiError::new(
                    409,
                    "Head changed; reload the diff before commenting",
                ));
            }
            let (blob, truncated) = self
                .git_read(
                    number(repo, "id"),
                    2 << 20,
                    &[],
                    &[],
                    &["cat-file", "blob", &format!("{head}:{path}")],
                )
                .map_err(|error| {
                    git_error(
                        error,
                        400,
                        "Comment path must name a file at the current head",
                    )
                })?;
            if truncated {
                return Err(ApiError::new(
                    413,
                    "Inline comments support source files up to 2 MiB",
                ));
            }
            let lines = blob
                .iter()
                .filter(|&&byte| byte == b'\n')
                .count()
                .saturating_add(1);
            if usize::try_from(line).map_or(true, |line| line > lines) {
                return Err(ApiError::new(400, "Comment line is outside the file"));
            }
        }
        let id = self.exec("INSERT INTO comments(repo_id,target_type,target_id,author_id,body,path,line,commit_oid,created_at) VALUES(?,?,?,?,?,?,?,?,?)", &[&number(repo,"id"),&kind.singular(),&number(discussion,"id"),&number(&self.user,"id"),&content,&path,&line,&oid,&now()])?;
        Ok(Reply::created(
            json!({"comment":self.one("SELECT c.id,c.author_id,u.username AS author,c.body,c.path,c.line,c.commit_oid,c.created_at FROM comments c JOIN users u ON u.id=c.author_id WHERE c.id=?", &[&id])?}),
        ))
    }

    fn add_review(&self, repo: &Value, pull: &Value) -> Result<Reply> {
        if text(pull, "state") != "open" {
            return Err(ApiError::new(
                409,
                "Only open pull requests can be reviewed",
            ));
        }
        let decision = text(&self.body, "decision");
        if ReviewDecision::parse(decision)? == ReviewDecision::Approve
            && number(pull, "author_id") == number(&self.user, "id")
        {
            return Err(ApiError::new(
                403,
                "Authors cannot approve their own pull requests",
            ));
        }
        let content = discussion_text(&self.body, "body", false, 65536)?;
        let (_, head) = self.pull_tips(repo, pull).map_err(|error| {
            git_error(
                error,
                409,
                "Restore the pull request branches before reviewing",
            )
        })?;
        let expected = text(&self.body, "expected_head_oid");
        if expected.is_empty() {
            return Err(ApiError::new(
                400,
                "expected_head_oid is required to review the displayed commit",
            ));
        }
        if expected != head {
            return Err(ApiError::new(
                409,
                "Head changed; reload and review the current diff",
            ));
        }
        let id = self.exec("INSERT INTO reviews(pull_id,author_id,decision,body,commit_oid,created_at) VALUES(?,?,?,?,?,?)", &[&number(pull,"id"),&number(&self.user,"id"),&decision,&content,&head,&now()])?;
        Ok(Reply::created(
            json!({"review":self.one("SELECT r.id,r.author_id,u.username AS author,r.decision,r.body,r.commit_oid,r.created_at FROM reviews r JOIN users u ON u.id=r.author_id WHERE r.id=?", &[&id])?}),
        ))
    }

    fn merge_pull(&self, repo: &Value, pull: &Value) -> Result<Reply> {
        let (base, head) = self.pull_tips(repo, pull).map_err(|error| {
            git_error(
                error,
                409,
                "Restore the pull request branches before merging",
            )
        })?;
        if text(&self.body, "expected_head_oid") != head {
            return Err(ApiError::new(
                409,
                "Head changed; reload and review the current diff",
            ));
        }
        let (blockers, tree) = self.pull_blockers(repo, pull, &base, &head)?;
        if !blockers.is_empty() {
            return Err(ApiError::new(409, blockers.join("; ")));
        }
        let rid = number(repo, "id");
        let id = number(pull, "id");
        let username = text(&self.user, "username");
        let commit = self
            .git_run(
                rid,
                &[
                    "-c",
                    &format!("user.name={username}"),
                    "-c",
                    &format!("user.email={username}@gitclub.local"),
                    "commit-tree",
                    &tree,
                    "-p",
                    &base,
                    "-p",
                    &head,
                    "-m",
                    &format!("Merge pull request #{id}: {}", text(pull, "title")),
                ],
            )
            .map_err(|_| {
                ApiError::new(
                    500,
                    "Could not create merge commit; branches were unchanged",
                )
            })?;
        let oid = String::from_utf8_lossy(&commit).trim().to_owned();
        if !oid_ok(&oid) {
            return Err(ApiError::new(500, "Git returned an invalid merge commit"));
        }
        let base_branch = text(pull, "base_branch");
        let head_branch = text(pull, "head_branch");
        let marker = MergeMarker {
            pull_id: id,
            base_branch: base_branch.to_owned(),
            base_oid: base.clone(),
            commit_oid: oid.clone(),
            updated_at: now(),
        };
        let path = self.repo_path(rid).join(format!("gitclub-merge-{id}.json"));
        durable_marker(&path, &marker).map_err(|_| {
            ApiError::new(
                503,
                "Cannot persist merge recovery state; branches were unchanged",
            )
        })?;
        let transaction = format!(
            "start\nverify refs/heads/{head_branch} {head}\nupdate refs/heads/{base_branch} {oid} {base}\ncreate refs/gitclub/merges/{id} {oid}\nprepare\ncommit\n"
        );
        let applied = self.git_run_input(rid, transaction.as_bytes(), &["update-ref", "--stdin"]);
        // Timeout or I/O failure may occur after Git committed. Retain intent until the ledger resolves that ambiguity.
        self.reconcile_merges(repo)?;
        let recorded = self.discussion(rid, id, DiscussionKind::Pull)?;
        if applied.is_err() && text(&recorded, "merged_oid") != oid {
            return Err(ApiError::new(
                409,
                "Base or head changed during merge; reload and try again",
            ));
        }
        if text(&recorded, "merged_oid") != oid {
            return Err(ApiError::new(
                503,
                "Merge transaction requires operator inspection",
            ));
        }
        Ok(Reply::ok(json!({"pull":recorded,"commit_oid":oid})))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn command(ctx: &Context, input: &str, args: &[&str]) -> String {
        String::from_utf8(ctx.git_run_input(1, input.as_bytes(), args).unwrap())
            .unwrap()
            .trim()
            .to_owned()
    }

    fn commit(ctx: &Context, content: &str, parent: Option<&str>) -> String {
        let blob = command(ctx, content, &["hash-object", "-w", "--stdin"]);
        let tree = command(
            ctx,
            &format!("100644 blob {blob}\tREADME.md\n"),
            &["mktree"],
        );
        let mut args = vec![
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.test",
            "commit-tree",
            &tree,
            "-m",
            "Fixture",
        ];
        if let Some(parent) = parent {
            args.extend(["-p", parent]);
        }
        command(ctx, "", &args)
    }

    fn request(
        ctx: &mut Context,
        repo: &Value,
        user: i64,
        method: &str,
        rest: &[&str],
        body: Value,
        status: u16,
    ) -> Value {
        ctx.user = ctx
            .one("SELECT id,username FROM users WHERE id=?", &[&user])
            .unwrap();
        ctx.method = method.to_owned();
        ctx.body = body;
        match ctx.collaboration_routes(repo, rest) {
            Ok(Some(reply)) => {
                assert_eq!(reply.status, status);
                reply.value
            }
            Err(error) => {
                assert_eq!(error.status, status, "{}", error.message);
                Value::Null
            }
            Ok(None) => panic!("Discussion route was not handled"),
        }
    }

    #[test]
    fn exact_head_authorization_and_durable_merge_recovery() {
        let mut ctx = crate::core::test_context();
        ctx.db.execute_batch("INSERT INTO users(id,username,password_hash,created_at) VALUES(1,'owner','unused',1),(2,'reviewer','unused',1),(3,'reader','unused',1); INSERT INTO namespaces(name,kind) VALUES('owner','user'); INSERT INTO namespace_members(namespace,user_id,role) VALUES('owner',1,'admin'); INSERT INTO repositories(id,owner,name,created_at,updated_at) VALUES(1,'owner','repo',1,1); INSERT INTO repo_members(repo_id,user_id,role) VALUES(1,2,'write'),(1,3,'read');").unwrap();
        let repo = ctx
            .one("SELECT * FROM repositories WHERE id=1", &[])
            .unwrap();
        ctx.initialize_repo(&repo).unwrap();
        let base = commit(&ctx, "base\n", None);
        let head = commit(&ctx, "head\n", Some(&base));
        command(&ctx, "", &["update-ref", "refs/heads/main", &base]);
        command(&ctx, "", &["update-ref", "refs/heads/feature", &head]);
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls"],
            json!({"title":"Change readme","head_branch":"feature"}),
            201,
        );
        let mut stale = repo.clone();
        stale["require_review"] = json!(false);
        request(
            &mut ctx,
            &stale,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":head}),
            409,
        );
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "reviews"],
            json!({"decision":"approve","expected_head_oid":head}),
            403,
        );
        request(
            &mut ctx,
            &repo,
            3,
            "POST",
            &["pulls", "1", "reviews"],
            json!({"decision":"approve","expected_head_oid":head}),
            403,
        );
        request(
            &mut ctx,
            &repo,
            2,
            "POST",
            &["pulls", "1", "reviews"],
            json!({"decision":"approve","expected_head_oid":head}),
            201,
        );
        let new_head = commit(&ctx, "new head\n", Some(&head));
        command(
            &ctx,
            "",
            &["update-ref", "refs/heads/feature", &new_head, &head],
        );
        request(
            &mut ctx,
            &repo,
            2,
            "POST",
            &["pulls", "1", "reviews"],
            json!({"decision":"approve","expected_head_oid":head}),
            409,
        );
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":new_head}),
            409,
        );
        for decision in ["request_changes", "comment"] {
            request(
                &mut ctx,
                &repo,
                2,
                "POST",
                &["pulls", "1", "reviews"],
                json!({"decision":decision,"expected_head_oid":new_head}),
                201,
            );
        }
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":new_head}),
            409,
        );
        request(
            &mut ctx,
            &repo,
            2,
            "POST",
            &["pulls", "1", "reviews"],
            json!({"decision":"approve","expected_head_oid":new_head}),
            201,
        );
        ctx.db
            .execute(
                "UPDATE repo_members SET role='read' WHERE repo_id=1 AND user_id=2",
                [],
            )
            .unwrap();
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":new_head}),
            409,
        );
        ctx.db
            .execute(
                "UPDATE repo_members SET role='write' WHERE repo_id=1 AND user_id=2",
                [],
            )
            .unwrap();

        // A failed comparison must leave both refs and the recovery ledger unchanged.
        let transaction = format!(
            "start\nverify refs/heads/feature {head}\nupdate refs/heads/main {new_head} {base}\ncreate refs/gitclub/merges/1 {new_head}\nprepare\ncommit\n"
        );
        assert!(
            ctx.git_run_input(1, transaction.as_bytes(), &["update-ref", "--stdin"])
                .is_err()
        );
        assert_eq!(command(&ctx, "", &["rev-parse", "main"]), base);

        ctx.db.execute_batch("CREATE TRIGGER reject_merge BEFORE UPDATE ON pull_requests WHEN NEW.state='merged' BEGIN SELECT RAISE(ABORT,'injected metadata failure'); END;").unwrap();
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":new_head}),
            500,
        );
        let merged = command(&ctx, "", &["rev-parse", "main"]);
        assert_ne!(merged, base);
        let marker_path = ctx.repo_path(1).join("gitclub-merge-1.json");
        assert!(marker_path.exists());
        ctx.db.execute_batch("DROP TRIGGER reject_merge;").unwrap();

        // Even a successful but empty Git listing cannot erase a corrupt loose ledger.
        let ledger_path = ctx.repo_path(1).join("refs/gitclub/merges/1");
        let ledger = fs::read(&ledger_path).unwrap();
        fs::write(&ledger_path, "invalid reference\n").unwrap();
        assert_eq!(ctx.reconcile_merges(&repo).unwrap_err().status, 503);
        assert!(marker_path.exists());
        fs::write(&ledger_path, format!("{base}\n")).unwrap();
        assert_eq!(ctx.reconcile_merges(&repo).unwrap_err().status, 503);
        assert!(marker_path.exists());
        fs::write(&ledger_path, ledger).unwrap();
        let response = request(&mut ctx, &repo, 1, "GET", &["pulls", "1"], json!({}), 200);
        assert_eq!(text(&response["pull"], "state"), "merged");
        assert_eq!(text(&response, "base_oid"), base);
        assert_eq!(text(&response, "head_oid"), new_head);
        assert_eq!(text(&response["pull"], "merged_oid"), merged);
        assert!(!marker_path.exists());
        assert_eq!(
            command(&ctx, "", &["show", "-s", "--format=%an", &merged]),
            "owner"
        );
        request(
            &mut ctx,
            &repo,
            1,
            "POST",
            &["pulls", "1", "merge"],
            json!({"expected_head_oid":new_head}),
            409,
        );

        let unapplied = MergeMarker {
            pull_id: 99,
            base_branch: "main".to_owned(),
            base_oid: base,
            commit_oid: merged,
            updated_at: now(),
        };
        let path = ctx.repo_path(1).join("gitclub-merge-99.json");
        durable_marker(&path, &unapplied).unwrap();
        ctx.reconcile_merges(&repo).unwrap();
        assert!(!path.exists());
        let data = ctx.app.data_dir.clone();
        drop(ctx);
        fs::remove_dir_all(data).unwrap();
    }

    #[test]
    fn rejects_invalid_discussion_and_review_input() {
        for title in [
            Value::Null,
            json!(3),
            json!(""),
            json!(" \n"),
            json!("contains\0nul"),
            json!("x".repeat(241)),
        ] {
            assert!(discussion_text(&json!({"title":title}), "title", true, 240).is_err());
        }
        assert_eq!(
            discussion_text(&json!({"title":"Review access"}), "title", true, 240).unwrap(),
            "Review access"
        );
        assert!(ReviewDecision::parse("APPROVE").is_err());
        assert!(!oid_ok(&"a".repeat(39)));
        assert!(!oid_ok(&format!("{}\n", "a".repeat(39))));
    }

    #[test]
    fn recovery_intent_is_exclusive_and_validated() {
        let directory = std::env::temp_dir().join(format!(
            "gitclub-rust-marker-{}-{}",
            std::process::id(),
            rand::random::<u64>()
        ));
        fs::create_dir(&directory).unwrap();
        let path = directory.join("gitclub-merge-42.json");
        let marker = MergeMarker {
            pull_id: 42,
            base_branch: "main".to_owned(),
            base_oid: "a".repeat(40),
            commit_oid: "b".repeat(40),
            updated_at: 1234,
        };
        assert!(marker.validate("gitclub-merge-42.json"));
        assert!(!marker.validate("gitclub-merge-43.json"));
        durable_marker(&path, &marker).unwrap();
        assert!(durable_marker(&path, &marker).is_err());
        assert_eq!(
            serde_json::from_slice::<MergeMarker>(&fs::read(&path).unwrap()).unwrap(),
            marker
        );
        clear_marker(&path).unwrap();
        assert!(!path.exists());
        fs::remove_dir(directory).unwrap();
    }
}
