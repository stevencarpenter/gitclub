use crate::core::{
    ApiError, Context, Reply, Result, boolean, lock_repo, name_ok, now, number, parse_id, rank,
    require_user, text,
};
use crate::git::valid_branch;
use rusqlite::params;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Visibility {
    Private,
    Public,
}
impl Visibility {
    fn as_str(self) -> &'static str {
        match self {
            Self::Private => "private",
            Self::Public => "public",
        }
    }
}
#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Role {
    Read,
    Write,
    Admin,
}
impl Role {
    fn as_str(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Write => "write",
            Self::Admin => "admin",
        }
    }
}
#[derive(Deserialize)]
struct MemberInput {
    username: String,
    role: Role,
}
#[derive(Deserialize)]
struct RepositoryInput {
    owner: String,
    name: String,
    #[serde(default)]
    description: String,
    visibility: Option<Visibility>,
    default_branch: Option<String>,
}
#[derive(Deserialize)]
struct GroupInput {
    name: String,
    #[serde(default)]
    shared: bool,
}

fn input<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T> {
    T::deserialize(value).map_err(|_| ApiError::new(400, "Invalid request fields"))
}
fn group_name(name: &str) -> Result<&str> {
    let name = name.trim();
    if name.is_empty() || name.chars().count() > 80 {
        return Err(ApiError::new(
            400,
            "Group name must have 1 to 80 characters",
        ));
    }
    Ok(name)
}

impl Context {
    pub(crate) fn role(&self, repo: &Value, user: &Value) -> Result<String> {
        let mut best = if text(repo, "visibility") == "public" {
            "read".to_owned()
        } else {
            String::new()
        };
        if !user.is_null() {
            for row in self.rows("SELECT role FROM namespace_members WHERE namespace=? AND user_id=? UNION ALL SELECT role FROM repo_members WHERE repo_id=? AND user_id=?", &[&text(repo,"owner"), &number(user,"id"), &number(repo,"id"), &number(user,"id")])? {
                let candidate = text(&row,"role");
                if rank(candidate) > rank(&best) { best = candidate.to_owned(); }
            }
        }
        Ok(best)
    }

    pub(crate) fn repo(&self, id: i64, user: &Value, min_role: &str) -> Result<Value> {
        let repo = self.one("SELECT * FROM repositories WHERE id=?", &[&id])?;
        if repo.is_null() {
            return Err(ApiError::new(404, "Repository not found"));
        }
        let role = self.role(&repo, user)?;
        if rank(&role) == 0 {
            return Err(ApiError::new(404, "Repository not found"));
        }
        if rank(&role) < rank(min_role) {
            require_user(user)?;
            return Err(ApiError::new(
                403,
                format!("Repository {min_role} permission required"),
            ));
        }
        Ok(repo)
    }

    pub(crate) fn repository_view(&self, repo: &Value, user: &Value) -> Result<Value> {
        let pinned = !user.is_null()
            && !self
                .one(
                    "SELECT 1 FROM pins WHERE repo_id=? AND user_id=?",
                    &[&number(repo, "id"), &number(user, "id")],
                )?
                .is_null();
        Ok(
            json!({"id":repo["id"],"owner":repo["owner"],"name":repo["name"],"description":repo["description"],"visibility":repo["visibility"],"default_branch":repo["default_branch"],"created_at":repo["created_at"],"updated_at":repo["updated_at"],"full_name":format!("{}/{}",text(repo,"owner"),text(repo,"name")),"require_review":boolean(repo,"require_review"),"role":self.role(repo,user)?,"pinned":pinned}),
        )
    }

    pub(crate) fn namespaces(&mut self, rest: &[&str]) -> Result<Reply> {
        require_user(&self.user)?;
        let user_id = number(&self.user, "id");
        if rest.is_empty() {
            return match self.method.as_str() {
                "GET" => Ok(Reply::ok(
                    json!({"namespaces":self.rows("SELECT namespaces.name,kind,role FROM namespaces JOIN namespace_members ON namespace=name WHERE user_id=? ORDER BY name", &[&user_id])?}),
                )),
                "POST" => {
                    let name = text(&self.body, "name");
                    if !name_ok(name) {
                        return Err(ApiError::new(
                            400,
                            "Use a lowercase namespace name of 1 to 63 characters",
                        ));
                    }
                    let tx = self.db.transaction()?;
                    tx.execute(
                        "INSERT INTO namespaces(name,kind) VALUES(?,'organization')",
                        [name],
                    )?;
                    tx.execute(
                        "INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,'admin')",
                        params![name, user_id],
                    )?;
                    tx.commit()?;
                    Ok(Reply::created(
                        json!({"namespace":{"name":name,"kind":"organization","role":"admin"}}),
                    ))
                }
                _ => Err(ApiError::new(405, "Use GET or POST")),
            };
        }
        if rest.len() == 2 && rest[1] == "members" && self.method == "POST" {
            let member: MemberInput = input(&self.body)?;
            let tx = self.db.unchecked_transaction()?;
            let membership = self.one("SELECT role,kind FROM namespace_members JOIN namespaces ON namespaces.name=namespace WHERE namespace=? AND user_id=?", &[&rest[0],&user_id])?;
            if text(&membership, "role") != "admin" {
                return Err(ApiError::new(403, "Namespace admin permission required"));
            }
            if text(&membership, "kind") == "user" {
                return Err(ApiError::new(
                    403,
                    "Use repository memberships to share a personal namespace",
                ));
            }
            let target = self.one("SELECT id FROM users WHERE username=?", &[&member.username])?;
            if target.is_null() {
                return Err(ApiError::new(400, "Provide an existing username"));
            }
            if number(&target, "id") == user_id && member.role.as_str() != "admin" {
                return Err(ApiError::new(
                    409,
                    "Cannot remove your own namespace admin role",
                ));
            }
            tx.execute("INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,?) ON CONFLICT(namespace,user_id) DO UPDATE SET role=excluded.role", params![rest[0],number(&target,"id"),member.role.as_str()])?;
            tx.commit()?;
            return Ok(Reply::ok(json!({"ok":true})));
        }
        Err(ApiError::new(404, "Endpoint not found"))
    }

    pub(crate) fn repositories(&mut self, rest: &[&str]) -> Result<Reply> {
        if rest.is_empty() {
            return match self.method.as_str() {
                "GET" => self.repository_list(),
                "POST" => self.create_repository(),
                _ => Err(ApiError::new(405, "Use GET or POST")),
            };
        }
        let id = parse_id(rest[0])?;
        let repo = self.repo(id, &self.user, "read")?;
        if rest.len() == 1 {
            return match self.method.as_str() {
                "GET" => {
                    let lock = self.app.repo_lock(id);
                    let _guard = lock_repo(&lock)?;
                    let repo = self.repo(id, &self.user, "read")?;
                    self.reconcile_merges(&repo)?;
                    Ok(Reply::ok(
                        json!({"repository":self.repository_view(&self.refresh(&repo)?,&self.user)?}),
                    ))
                }
                "PATCH" => self.patch_repository(id),
                _ => Err(ApiError::new(405, "Use GET or PATCH")),
            };
        }
        if rest.len() == 2 && rest[1] == "pin" && self.method == "POST" {
            require_user(&self.user)?;
            let pinned = self
                .body
                .get("pinned")
                .and_then(Value::as_bool)
                .ok_or_else(|| ApiError::new(400, "pinned must be boolean"))?;
            let query = if pinned {
                "INSERT OR IGNORE INTO pins(repo_id,user_id) VALUES(?,?)"
            } else {
                "DELETE FROM pins WHERE repo_id=? AND user_id=?"
            };
            self.exec(query, &[&id, &number(&self.user, "id")])?;
            return Ok(Reply::ok(json!({"ok":true})));
        }
        if rest.len() == 2 && rest[1] == "members" && self.method == "POST" {
            let member: MemberInput = input(&self.body)?;
            let lock = self.app.repo_lock(id);
            let _guard = lock_repo(&lock)?;
            self.repo(id, &self.user, "admin")?;
            let target = self.one("SELECT id FROM users WHERE username=?", &[&member.username])?;
            if target.is_null() {
                return Err(ApiError::new(400, "Provide an existing username"));
            }
            self.exec("INSERT INTO repo_members(repo_id,user_id,role) VALUES(?,?,?) ON CONFLICT(repo_id,user_id) DO UPDATE SET role=excluded.role", &[&id,&number(&target,"id"),&member.role.as_str()])?;
            return Ok(Reply::ok(json!({"ok":true})));
        }
        if let Some(reply) = self.git_routes(&repo, &rest[1..])? {
            return Ok(reply);
        }
        if let Some(reply) = self.collaboration_routes(&repo, &rest[1..])? {
            return Ok(reply);
        }
        Err(ApiError::new(404, "Endpoint not found"))
    }

    fn repository_list(&self) -> Result<Reply> {
        let group = if self.q("group").is_empty() {
            None
        } else {
            Some(self.group(parse_id(self.q("group"))?, false)?)
        };
        let query = self.q("q").to_lowercase();
        let owner = self.q("owner");
        let mut repositories = Vec::new();
        for repo in self.rows("SELECT * FROM repositories", &[])? {
            if (!owner.is_empty() && text(&repo, "owner") != owner)
                || rank(&self.role(&repo, &self.user)?) == 0
            {
                continue;
            }
            if !query.is_empty()
                && !format!(
                    "{}/{} {}",
                    text(&repo, "owner"),
                    text(&repo, "name"),
                    text(&repo, "description")
                )
                .to_lowercase()
                .contains(&query)
            {
                continue;
            }
            if let Some(group) = &group
                && self
                    .one(
                        "SELECT 1 FROM group_repos WHERE group_id=? AND repo_id=?",
                        &[&number(group, "id"), &number(&repo, "id")],
                    )?
                    .is_null()
            {
                continue;
            }
            let lock = self.app.repo_lock(number(&repo, "id"));
            let guard = match lock.try_lock() {
                Ok(guard) => Some(guard),
                Err(std::sync::TryLockError::WouldBlock) => None,
                Err(std::sync::TryLockError::Poisoned(_)) => {
                    return Err(ApiError::new(
                        503,
                        "Repository mutation interrupted; restart to recover",
                    ));
                }
            };
            let repo = self.one(
                "SELECT * FROM repositories WHERE id=?",
                &[&number(&repo, "id")],
            )?;
            if rank(&self.role(&repo, &self.user)?) == 0 {
                continue;
            }
            // A busy mutation must not stall navigation. Its next read reconciles freshness.
            let repo = if guard.is_some() {
                self.reconcile_merges(&repo)?;
                self.refresh(&repo)?
            } else {
                repo
            };
            repositories.push(self.repository_view(&repo, &self.user)?);
        }
        repositories.sort_by(|a, b| {
            boolean(b, "pinned")
                .cmp(&boolean(a, "pinned"))
                .then_with(|| number(b, "updated_at").cmp(&number(a, "updated_at")))
                .then_with(|| number(a, "id").cmp(&number(b, "id")))
        });
        Ok(Reply::ok(json!({"repositories":repositories})))
    }

    fn create_repository(&self) -> Result<Reply> {
        require_user(&self.user)?;
        let body: RepositoryInput = input(&self.body)?;
        if !name_ok(&body.owner) || !name_ok(&body.name) || body.name.ends_with(".git") {
            return Err(ApiError::new(
                400,
                "Use lowercase owner/repository names, without .git suffix",
            ));
        }
        if body.description.len() > 4096 {
            return Err(ApiError::new(400, "Description exceeds 4096 bytes"));
        }
        let branch = body.default_branch.as_deref().unwrap_or("main");
        if !valid_branch(branch) {
            return Err(ApiError::new(400, "Invalid default branch"));
        }
        let tx = self.db.unchecked_transaction()?;
        let membership = self.one(
            "SELECT role FROM namespace_members WHERE namespace=? AND user_id=?",
            &[&body.owner, &number(&self.user, "id")],
        )?;
        if rank(text(&membership, "role")) < 2 {
            return Err(ApiError::new(403, "Namespace write permission required"));
        }
        let timestamp = now();
        // ponytail: SQLite writes wait during Git initialization (each command bounded to 30s).
        // Stage repository creation outside the transaction if creation throughput becomes material.
        tx.execute("INSERT INTO repositories(owner,name,description,visibility,default_branch,created_at,updated_at) VALUES(?,?,?,?,?,?,?)", params![body.owner,body.name,body.description,body.visibility.unwrap_or(Visibility::Private).as_str(),branch,timestamp,timestamp])?;
        let id = tx.last_insert_rowid();
        let repo = self.one("SELECT * FROM repositories WHERE id=?", &[&id])?;
        match std::fs::symlink_metadata(self.repo_path(id)) {
            Ok(_) => {
                return Err(ApiError::new(
                    409,
                    "Unclaimed repository directory exists; recover it before creating repositories",
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        if let Err(error) = self.initialize_repo(&repo) {
            // This directory was allocated by this uncommitted insertion, never an existing repository.
            if let Err(cleanup) = std::fs::remove_dir_all(self.repo_path(id))
                && cleanup.kind() != std::io::ErrorKind::NotFound
            {
                return Err(ApiError::new(
                    500,
                    "Repository initialization failed; directory cleanup required",
                ));
            }
            return Err(error);
        }
        if let Err(error) = tx.commit() {
            std::fs::remove_dir_all(self.repo_path(id)).map_err(|_| {
                ApiError::new(
                    500,
                    "Repository creation failed; directory cleanup required",
                )
            })?;
            return Err(error.into());
        }
        Ok(Reply::created(
            json!({"repository":self.repository_view(&repo,&self.user)?}),
        ))
    }

    fn patch_repository(&self, id: i64) -> Result<Reply> {
        let fields = self
            .body
            .as_object()
            .ok_or_else(|| ApiError::new(400, "Repository fields must be an object"))?;
        let lock = self.app.repo_lock(id);
        let _guard = lock_repo(&lock)?;
        let mut repo = self.repo(id, &self.user, "admin")?;
        let old_branch = text(&repo, "default_branch").to_owned();
        for (key, value) in fields {
            match key.as_str() {
                "description" => {
                    if value.as_str().is_none_or(|v| v.len() > 4096) {
                        return Err(ApiError::new(
                            400,
                            "Description must be text of at most 4096 bytes",
                        ));
                    }
                }
                "visibility" => {
                    let _: Visibility = input(value)?;
                }
                "default_branch" => {
                    if value.as_str().is_none_or(|v| !valid_branch(v)) {
                        return Err(ApiError::new(400, "Invalid default branch"));
                    }
                }
                "require_review" => {
                    if !value.is_boolean() {
                        return Err(ApiError::new(400, "require_review must be boolean"));
                    }
                }
                _ => return Err(ApiError::new(400, "Unsupported repository field")),
            }
            repo[key] = value.clone();
        }
        let branch_changed = old_branch != text(&repo, "default_branch");
        if branch_changed {
            let oid = self.default_oid(&repo)?;
            self.git_run(
                id,
                &[
                    "symbolic-ref",
                    "HEAD",
                    &format!("refs/heads/{}", text(&repo, "default_branch")),
                ],
            )?;
            repo["default_oid"] = json!(oid);
            repo["updated_at"] = json!(now());
        }
        let update = self.exec("UPDATE repositories SET description=?,visibility=?,default_branch=?,require_review=?,updated_at=?,default_oid=? WHERE id=?", &[&text(&repo,"description"),&text(&repo,"visibility"),&text(&repo,"default_branch"),&boolean(&repo,"require_review"),&number(&repo,"updated_at"),&text(&repo,"default_oid"),&id]);
        if let Err(error) = update {
            if branch_changed
                && self
                    .git_run(
                        id,
                        &["symbolic-ref", "HEAD", &format!("refs/heads/{old_branch}")],
                    )
                    .is_err()
            {
                // The database remains authoritative; startup repairs HEAD from default_branch.
                return Err(ApiError::new(
                    500,
                    "Default branch update failed; restart to reconcile repository HEAD",
                ));
            }
            return Err(error);
        }
        Ok(Reply::ok(
            json!({"repository":self.repository_view(&repo,&self.user)?}),
        ))
    }

    fn group(&self, id: i64, edit: bool) -> Result<Value> {
        require_user(&self.user)?;
        let group = self.one("SELECT * FROM groups WHERE id=?", &[&id])?;
        let creator = number(&group, "creator_id") == number(&self.user, "id");
        if group.is_null() || (!creator && !boolean(&group, "shared")) {
            return Err(ApiError::new(404, "Group not found"));
        }
        if edit && !creator {
            return Err(ApiError::new(403, "Only the group creator can edit it"));
        }
        Ok(group)
    }

    fn group_view(&self, group: &Value) -> Result<Value> {
        let mut ids = Vec::new();
        for repo in self.rows("SELECT repositories.* FROM repositories JOIN group_repos ON repo_id=repositories.id WHERE group_id=? ORDER BY updated_at DESC,repositories.id", &[&number(group,"id")])? {
            if rank(&self.role(&repo,&self.user)?) > 0 { ids.push(number(&repo,"id")); }
        }
        Ok(
            json!({"id":group["id"],"name":group["name"],"creator_id":group["creator_id"],"shared":boolean(group,"shared"),"repo_ids":ids}),
        )
    }

    pub(crate) fn groups(&mut self, rest: &[&str]) -> Result<Reply> {
        require_user(&self.user)?;
        let user_id = number(&self.user, "id");
        if rest.is_empty() {
            return match self.method.as_str() {
                "GET" => {
                    let mut groups = Vec::new();
                    for group in self.rows(
                        "SELECT * FROM groups WHERE creator_id=? OR shared=1 ORDER BY name,id",
                        &[&user_id],
                    )? {
                        groups.push(self.group_view(&group)?);
                    }
                    Ok(Reply::ok(json!({"groups":groups})))
                }
                "POST" => {
                    let body: GroupInput = input(&self.body)?;
                    let name = group_name(&body.name)?;
                    let id = self.exec(
                        "INSERT INTO groups(name,creator_id,shared,created_at) VALUES(?,?,?,?)",
                        &[&name, &user_id, &body.shared, &now()],
                    )?;
                    Ok(Reply::created(
                        json!({"group":self.group_view(&self.group(id,false)?)?}),
                    ))
                }
                _ => Err(ApiError::new(405, "Use GET or POST")),
            };
        }
        if rest.len() != 1 {
            return Err(ApiError::new(404, "Endpoint not found"));
        }
        let id = parse_id(rest[0])?;
        // A transaction prevents shared/name/membership updates from losing concurrent edits.
        let tx = self.db.unchecked_transaction()?;
        let mut group = self.group(id, true)?;
        if self.method == "DELETE" {
            tx.execute("DELETE FROM groups WHERE id=?", [id])?;
            tx.commit()?;
            return Ok(Reply::ok(json!({"ok":true})));
        }
        if self.method != "PATCH" {
            return Err(ApiError::new(405, "Use PATCH or DELETE"));
        }
        let fields = self
            .body
            .as_object()
            .ok_or_else(|| ApiError::new(400, "Group fields must be an object"))?;
        for key in fields.keys() {
            if !matches!(key.as_str(), "name" | "shared" | "repo_ids") {
                return Err(ApiError::new(400, "Unsupported group field"));
            }
        }
        if let Some(value) = fields.get("name") {
            let name = value
                .as_str()
                .ok_or_else(|| ApiError::new(400, "Group name must be text"))?;
            group["name"] = json!(group_name(name)?);
        }
        if let Some(value) = fields.get("shared") {
            if !value.is_boolean() {
                return Err(ApiError::new(400, "shared must be boolean"));
            }
            group["shared"] = value.clone();
        }
        let ids = fields
            .get("repo_ids")
            .map(|value| -> Result<Vec<i64>> {
                let values = value
                    .as_array()
                    .filter(|v| v.len() <= 1000)
                    .ok_or_else(|| {
                        ApiError::new(400, "repo_ids must contain at most 1000 repository IDs")
                    })?;
                values
                    .iter()
                    .map(|value| {
                        let id = value
                            .as_i64()
                            .filter(|id| *id > 0)
                            .ok_or_else(|| ApiError::new(400, "Invalid repository ID"))?;
                        self.repo(id, &self.user, "read")?;
                        Ok(id)
                    })
                    .collect()
            })
            .transpose()?;
        tx.execute(
            "UPDATE groups SET name=?,shared=? WHERE id=?",
            params![text(&group, "name"), boolean(&group, "shared"), id],
        )?;
        if let Some(ids) = ids {
            tx.execute("DELETE FROM group_repos WHERE group_id=?", [id])?;
            for repo_id in ids {
                tx.execute(
                    "INSERT OR IGNORE INTO group_repos(group_id,repo_id) VALUES(?,?)",
                    params![id, repo_id],
                )?;
            }
        }
        tx.commit()?;
        Ok(Reply::ok(json!({"group":self.group_view(&group)?})))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_types_reject_wrong_booleans_and_roles() {
        assert!(input::<GroupInput>(&json!({"name":"team","shared":1})).is_err());
        assert!(input::<MemberInput>(&json!({"username":"dev","role":"owner"})).is_err());
        assert!(
            input::<RepositoryInput>(&json!({"owner":"dev","name":"repo","visibility":"hidden"}))
                .is_err()
        );
        assert!(input::<GroupInput>(&json!({"name":"team","shared":true})).is_ok());
    }
    #[test]
    fn group_names_count_characters_and_trim() {
        assert_eq!(group_name("  work  ").unwrap(), "work");
        assert!(group_name(&"é".repeat(80)).is_ok());
        assert!(group_name(&"é".repeat(81)).is_err());
        assert!(group_name(" \n ").is_err());
    }
    fn repository_context() -> Context {
        let mut ctx = crate::core::test_context();
        ctx.db.execute_batch("INSERT INTO users VALUES(1,'dev','test',1);
            INSERT INTO namespaces VALUES('dev','user');
            INSERT INTO namespace_members VALUES('dev',1,'admin');
            INSERT INTO repositories(id,owner,name,created_at,updated_at) VALUES(1,'dev','repo',1,1);")
            .unwrap();
        ctx.user = json!({"id":1,"username":"dev"});
        ctx
    }

    #[test]
    fn directory_returns_persisted_metadata_while_repository_is_busy() {
        let ctx = repository_context();
        let lock = ctx.app.repo_lock(1);
        let guard = lock.lock().unwrap();
        let started = std::time::Instant::now();
        let response = ctx.repository_list().unwrap();
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        assert_eq!(response.value["repositories"][0]["full_name"], "dev/repo");
        assert_eq!(response.value["repositories"][0]["updated_at"], 1);
        drop(guard);
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }

    #[test]
    fn invalid_group_member_does_not_partially_change_group() {
        let mut ctx = repository_context();
        ctx.db
            .execute_batch(
                "INSERT INTO groups VALUES(1,'original',1,0,1);
            INSERT INTO group_repos VALUES(1,1);",
            )
            .unwrap();
        ctx.method = "PATCH".to_owned();
        ctx.body = json!({"name":"changed","shared":true,"repo_ids":[1,999]});
        assert!(ctx.groups(&["1"]).is_err());
        let group = ctx.group_view(&ctx.group(1, false).unwrap()).unwrap();
        assert_eq!(group["name"], "original");
        assert_eq!(group["shared"], false);
        assert_eq!(group["repo_ids"], json!([1]));
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }

    #[test]
    fn failed_default_branch_database_update_restores_head() {
        let ctx = repository_context();
        let repo = ctx.repo(1, &ctx.user, "admin").unwrap();
        ctx.initialize_repo(&repo).unwrap();
        ctx.db.execute_batch("CREATE TRIGGER reject_update BEFORE UPDATE ON repositories BEGIN SELECT RAISE(FAIL,'injected update failure'); END;").unwrap();
        let mut ctx = ctx;
        ctx.body = json!({"default_branch":"published"});
        assert!(ctx.patch_repository(1).is_err());
        assert_eq!(
            ctx.git_run(1, &["symbolic-ref", "HEAD"]).unwrap(),
            b"refs/heads/main\n"
        );
        assert_eq!(
            ctx.repo(1, &ctx.user, "read").unwrap()["default_branch"],
            "main"
        );
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
    #[test]
    fn repository_creation_preserves_orphaned_directory() {
        let mut ctx = repository_context();
        let path = ctx.repo_path(2);
        std::fs::create_dir(&path).unwrap();
        std::fs::write(path.join("recovery-data"), b"preserve me").unwrap();
        ctx.body = json!({"owner":"dev","name":"second"});
        assert!(ctx.create_repository().is_err());
        assert_eq!(
            std::fs::read(path.join("recovery-data")).unwrap(),
            b"preserve me"
        );
        assert!(
            ctx.one("SELECT id FROM repositories WHERE id=2", &[])
                .unwrap()
                .is_null()
        );
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
}
