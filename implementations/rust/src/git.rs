use crate::core::{
    ApiError, Context, Reply, Result, boolean, name_ok, now, number, parse_id, require_user, text,
    token_hash,
};
use axum::{
    body::{Body, Bytes},
    extract::Request,
    response::Response,
};
use futures_util::{Stream, StreamExt};
use nix::{
    sys::signal::{Signal, killpg},
    unistd::Pid,
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    os::unix::{
        fs::{OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    pin::Pin,
    process::{Command, Stdio},
    task::{Context as TaskContext, Poll},
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    sync::{mpsc, oneshot},
};

const READ_LIMIT: usize = 2 << 20;
const TRANSFER_LIMIT: u64 = 256 << 20;

pub(crate) fn oid_ok(oid: &str) -> bool {
    matches!(oid.len(), 40 | 64)
        && oid
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn stored_ref_ok(reference: &str) -> bool {
    reference.starts_with("refs/")
        && reference.len() <= 1024
        && !reference.contains("..")
        && !reference.contains("@{")
        && !reference
            .bytes()
            .any(|b| b <= 32 || b == 127 || b"\\~^:?*[".contains(&b))
        && reference.split('/').all(|p| {
            !p.is_empty() && !p.starts_with('.') && !p.ends_with('.') && !p.ends_with(".lock")
        })
}
pub(crate) fn valid_branch(reference: &str) -> bool {
    !reference.is_empty()
        && reference.len() <= 255
        && !reference.starts_with('-')
        && stored_ref_ok(&format!("refs/heads/{reference}"))
}
pub(crate) fn valid_path(path: &str) -> bool {
    !path.starts_with('/')
        && !path.contains(['\0', '\r', '\n', '\\'])
        && (path.is_empty() || path.split('/').all(|part| !matches!(part, "" | "." | "..")))
}
fn safe_command(program: &str) -> Command {
    let mut command = Command::new(program);
    command
        .env_clear()
        .env("PATH", std::env::var_os("PATH").unwrap_or_default())
        .env("HOME", "/nonexistent")
        .env("LANG", "C.UTF-8")
        .env("LC_ALL", "C")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_REPLACE_OBJECTS", "1")
        // Automatic maintenance must remain inside the transfer process group.
        .env("GIT_CONFIG_COUNT", "2")
        .env("GIT_CONFIG_KEY_0", "maintenance.autoDetach")
        .env("GIT_CONFIG_VALUE_0", "false")
        .env("GIT_CONFIG_KEY_1", "gc.autoDetach")
        .env("GIT_CONFIG_VALUE_1", "false")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    command
}
static GROUPS: std::sync::LazyLock<std::sync::Mutex<HashSet<i32>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(HashSet::new()));
static STOPPING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn shutdown() {
    STOPPING.store(true, std::sync::atomic::Ordering::SeqCst);
    let groups = GROUPS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    for id in groups.iter() {
        let _ = killpg(Pid::from_raw(*id), Signal::SIGKILL);
    }
}
struct ProcessGroup(Pid);
impl ProcessGroup {
    fn new(id: u32) -> Result<Self> {
        let group =
            Self(Pid::from_raw(i32::try_from(id).map_err(|_| {
                ApiError::new(503, "Invalid subprocess identifier")
            })?));
        {
            let mut groups = GROUPS
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if !STOPPING.load(std::sync::atomic::Ordering::SeqCst) {
                groups.insert(group.0.as_raw());
                return Ok(group);
            }
        }
        Err(ApiError::new(503, "Server is shutting down"))
    }
    fn kill(&self) {
        let _ = killpg(self.0, Signal::SIGKILL);
    }
}
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        let mut groups = GROUPS
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.kill();
        groups.remove(&self.0.as_raw());
    }
}
fn run_bounded(
    mut command: Command,
    input: &[u8],
    limit: usize,
    timeout: Duration,
) -> Result<(Vec<u8>, bool)> {
    let mut child = command.spawn()?;
    let group = match ProcessGroup::new(child.id()) {
        Ok(group) => group,
        Err(error) => {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    };
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| ApiError::new(503, "Git input unavailable"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ApiError::new(503, "Git output unavailable"))?;
    std::thread::scope(|scope| {
        let writer = scope.spawn(move || {
            let mut stdin = stdin;
            stdin.write_all(input)
        });
        let reader = scope.spawn(move || -> std::io::Result<(Vec<u8>, bool)> {
            let mut stdout = stdout;
            let mut output = Vec::new();
            let mut buffer = [0u8; 65536];
            let mut truncated = false;
            loop {
                let count = stdout.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                let take = count.min(limit.saturating_sub(output.len()));
                truncated |= take < count;
                output.extend_from_slice(&buffer[..take]);
            }
            Ok((output, truncated))
        });
        let start = Instant::now();
        let outcome = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) if start.elapsed() < timeout => {
                    std::thread::sleep(Duration::from_millis(5))
                }
                Ok(None) => break Err(ApiError::new(503, "Git command exceeded its time limit")),
                Err(error) => break Err(error.into()),
            }
        };
        group.kill();
        let _ = child.wait();
        let _ = writer.join();
        let output = reader
            .join()
            .map_err(|_| ApiError::new(503, "Git output reader failed"))??;
        if !outcome?.success() {
            return Err(ApiError::new(400, "Git operation failed"));
        }
        Ok(output)
    })
}
fn bounded_file(path: &Path, limit: u64) -> std::io::Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(std::io::Error::other("Invalid reference file"));
    }
    let mut data = Vec::new();
    File::open(path)?.take(limit + 1).read_to_end(&mut data)?;
    if u64::try_from(data.len()).unwrap_or(u64::MAX) > limit {
        return Err(std::io::Error::other("Reference exceeds limit"));
    }
    Ok(data)
}
fn read_default_oid(root: &Path, branch: &str) -> Result<String> {
    let mut reference = format!("refs/heads/{branch}");
    let mut seen = HashSet::new();
    for _ in 0..8 {
        if !stored_ref_ok(&reference) || !seen.insert(reference.clone()) {
            return Err(ApiError::new(503, "Invalid symbolic reference"));
        }
        match bounded_file(&root.join(&reference), 1024) {
            Ok(raw) => {
                let value = std::str::from_utf8(&raw)
                    .map_err(|_| ApiError::new(503, "Invalid reference"))?
                    .trim();
                if let Some(target) = value.strip_prefix("ref: ") {
                    reference = target.to_owned();
                    continue;
                }
                if oid_ok(value) && value.bytes().any(|b| b != b'0') {
                    return Ok(value.to_owned());
                }
                return Err(ApiError::new(503, "Invalid reference object ID"));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let packed = match bounded_file(&root.join("packed-refs"), 8 << 20) {
            Ok(raw) => raw,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
            Err(error) => return Err(error.into()),
        };
        for line in std::str::from_utf8(&packed)
            .map_err(|_| ApiError::new(503, "Invalid packed references"))?
            .lines()
        {
            if line.is_empty() || line.starts_with(['#', '^']) {
                continue;
            }
            let (oid, name) = line
                .split_once(' ')
                .ok_or_else(|| ApiError::new(503, "Invalid packed reference"))?;
            if !oid_ok(oid) || !stored_ref_ok(name) {
                return Err(ApiError::new(503, "Invalid packed reference"));
            }
            if name == reference {
                if oid.bytes().all(|b| b == b'0') {
                    return Err(ApiError::new(503, "Invalid packed object ID"));
                }
                return Ok(oid.to_owned());
            }
        }
        return Ok(String::new());
    }
    Err(ApiError::new(503, "Symbolic reference depth exceeded"))
}
impl Context {
    pub(crate) fn repo_path(&self, id: i64) -> PathBuf {
        self.app.data_dir.join("repos").join(format!("{id}.git"))
    }
    pub(crate) fn git_read(
        &self,
        id: i64,
        limit: usize,
        extra_env: &[(&str, &str)],
        input: &[u8],
        args: &[&str],
    ) -> Result<(Vec<u8>, bool)> {
        let _permit = self
            .app
            .git_slots
            .try_acquire()
            .map_err(|_| ApiError::new(503, "Git command capacity exhausted; retry shortly"))?;
        let mut command = safe_command("git");
        command
            .arg(format!("--git-dir={}", self.repo_path(id).display()))
            .args([
                "-c",
                "core.quotepath=false",
                "-c",
                "diff.external=",
                "-c",
                "protocol.file.allow=never",
                "-c",
                "protocol.ext.allow=never",
            ])
            .args(args)
            .envs(extra_env.iter().copied());
        run_bounded(command, input, limit, Duration::from_secs(30))
    }
    pub(crate) fn git_run(&self, id: i64, args: &[&str]) -> Result<Vec<u8>> {
        self.git_run_input(id, &[], args)
    }
    pub(crate) fn git_run_input(&self, id: i64, input: &[u8], args: &[&str]) -> Result<Vec<u8>> {
        let (bytes, truncated) = self.git_read(id, READ_LIMIT, &[], input, args)?;
        if truncated {
            return Err(ApiError::new(503, "Git result exceeds limit"));
        }
        Ok(bytes)
    }
    pub(crate) fn configure_maintenance(&self, id: i64) -> Result<()> {
        // The shared SSH adapter starts native Git with its own environment.
        for key in ["maintenance.autoDetach", "gc.autoDetach"] {
            self.git_run(id, &["config", "--local", key, "false"])?;
        }
        Ok(())
    }
    pub(crate) fn initialize_repo(&self, repo: &Value) -> Result<()> {
        let id = number(repo, "id");
        let branch = text(repo, "default_branch");
        if !valid_branch(branch) {
            return Err(ApiError::new(400, "Invalid default branch"));
        }
        fs::create_dir_all(self.app.data_dir.join("repos"))?;
        fs::create_dir(self.repo_path(id))?;
        self.git_run(
            id,
            &["init", "--bare", &self.repo_path(id).to_string_lossy()],
        )?;
        self.git_run(
            id,
            &["symbolic-ref", "HEAD", &format!("refs/heads/{branch}")],
        )?;
        self.git_run(id, &["config", "http.receivepack", "true"])?;
        self.git_run(id, &["config", "transfer.hideRefs", "refs/gitclub/"])?;
        self.configure_maintenance(id)?;
        let hook = fs::read(self.app.shared_dir.join("git-hook.py"))?;
        for name in ["pre-receive", "post-receive"] {
            let path = self.repo_path(id).join("hooks").join(name);
            fs::write(&path, &hook)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        }
        Ok(())
    }
    pub(crate) fn resolve(&self, repo: &Value, reference: &str) -> Result<String> {
        let reference = if reference.is_empty() {
            text(repo, "default_branch")
        } else {
            reference
        };
        if !(oid_ok(reference) || valid_branch(reference)) {
            return Err(ApiError::new(400, "Invalid Git reference"));
        }
        let raw = self.git_run(
            number(repo, "id"),
            &[
                "rev-parse",
                "--verify",
                "--end-of-options",
                &format!("{reference}^{{commit}}"),
            ],
        )?;
        let oid = String::from_utf8_lossy(&raw).trim().to_owned();
        if !oid_ok(&oid) {
            return Err(ApiError::new(400, "Ref does not identify a commit"));
        }
        Ok(oid)
    }
    pub(crate) fn default_oid(&self, repo: &Value) -> Result<String> {
        read_default_oid(
            &self.repo_path(number(repo, "id")),
            text(repo, "default_branch"),
        )
    }
    pub(crate) fn refresh(&self, repo: &Value) -> Result<Value> {
        let mut result = repo.clone();
        let oid = match self.default_oid(repo) {
            Ok(oid) if !oid.is_empty() => oid,
            _ => return Ok(result),
        };
        let id = number(repo, "id");
        if oid == text(repo, "default_oid") {
            return Ok(result);
        }
        self.exec("UPDATE repositories SET default_oid=?,updated_at=? WHERE id=? AND default_oid=? AND default_branch=?", &[&oid, &now(), &id, &text(repo, "default_oid"), &text(repo, "default_branch")])?;
        let current = self.one(
            "SELECT default_oid,updated_at FROM repositories WHERE id=?",
            &[&id],
        )?;
        if !current.is_null() {
            result["default_oid"] = current["default_oid"].clone();
            result["updated_at"] = current["updated_at"].clone();
        }
        Ok(result)
    }
    pub(crate) fn git_routes(&mut self, repo: &Value, rest: &[&str]) -> Result<Option<Reply>> {
        if let ["git", phase] = rest
            && self.method == "POST"
        {
            return self.git_hook(repo, phase).map(Some);
        }
        if self.method != "GET" || rest.len() != 1 {
            return Ok(None);
        }
        let id = number(repo, "id");
        let reference = if self.q("ref").is_empty() {
            text(repo, "default_branch")
        } else {
            self.q("ref")
        };
        let value = match rest[0] {
            "branches" => {
                let raw = self.git_run(
                    id,
                    &[
                        "for-each-ref",
                        "--format=%(refname:short)%09%(objectname)",
                        "refs/heads",
                    ],
                )?;
                let branches: Vec<Value> = String::from_utf8_lossy(&raw)
                    .lines()
                    .filter_map(|line| line.split_once('\t'))
                    .map(|(name, oid)| json!({"name":name,"oid":oid}))
                    .collect();
                json!({"branches":branches,"default_branch":text(repo,"default_branch")})
            }
            "tree" | "blob" | "commits" => {
                let oid = match self.resolve(repo, reference) {
                    Ok(oid) => oid,
                    Err(error) => {
                        if rest[0] != "blob"
                            && (self.q("ref").is_empty()
                                || reference == text(repo, "default_branch"))
                            && self
                                .git_run(id, &["for-each-ref", "--count=1", "refs/heads"])?
                                .is_empty()
                        {
                            return Ok(Some(Reply::ok(if rest[0] == "tree" {
                                json!({"entries":[],"ref":reference})
                            } else {
                                json!({"commits":[]})
                            })));
                        }
                        return Err(error);
                    }
                };
                let path = self.q("path");
                if !valid_path(path) {
                    return Err(ApiError::new(400, "Invalid repository path"));
                }
                if rest[0] == "commits" {
                    let raw = self.git_run(
                        id,
                        &[
                            "log",
                            "-50",
                            "--format=%H%x00%h%x00%s%x00%an%x00%aI%x00",
                            &oid,
                            "--",
                        ],
                    )?;
                    let source = String::from_utf8_lossy(&raw);
                    let fields: Vec<&str> = source.split('\0').collect();
                    let commits: Vec<Value> = fields.as_chunks::<5>().0.iter().map(|p| json!({"oid":p[0].trim(),"short_oid":p[1],"subject":p[2],"author":p[3],"date":p[4]})).collect();
                    json!({"commits":commits})
                } else if rest[0] == "tree" {
                    let target = if path.is_empty() {
                        oid
                    } else {
                        format!("{oid}:{path}")
                    };
                    let raw = self
                        .git_run(id, &["ls-tree", "-z", "-l", &target])
                        .map_err(|_| ApiError::new(404, "Directory not found"))?;
                    let source = String::from_utf8_lossy(&raw);
                    let mut entries = Vec::new();
                    for entry in source.split('\0') {
                        let Some((meta, name)) = entry.split_once('\t') else {
                            continue;
                        };
                        let fields: Vec<&str> = meta.split_whitespace().collect();
                        if fields.len() != 4 {
                            continue;
                        }
                        entries.push(json!({"name":name,"path":if path.is_empty(){name.to_owned()}else{format!("{path}/{name}")},"type":if fields[1]=="tree"{"directory"}else{"file"},"size":fields[3].parse::<i64>().unwrap_or(0)}));
                    }
                    json!({"entries":entries,"ref":reference})
                } else {
                    if path.is_empty() {
                        return Err(ApiError::new(400, "A file path is required"));
                    }
                    let object = format!("{oid}:{path}");
                    let size = self
                        .git_run(id, &["cat-file", "-s", &object])
                        .map_err(|_| ApiError::new(404, "File not found"))?;
                    let size = String::from_utf8_lossy(&size)
                        .trim()
                        .parse::<u64>()
                        .map_err(|_| ApiError::new(503, "Invalid object size"))?;
                    let (raw, truncated) = self
                        .git_read(id, 512 << 10, &[], &[], &["cat-file", "blob", &object])
                        .map_err(|_| ApiError::new(404, "File not found"))?;
                    let binary = raw.contains(&0) || std::str::from_utf8(&raw).is_err();
                    json!({"path":path,"size":size,"truncated":truncated,"binary":binary,"content":if binary {""}else{std::str::from_utf8(&raw).unwrap_or("")}})
                }
            }
            "diff" => {
                let base = self.resolve(repo, self.q("base"))?;
                let head = self.resolve(repo, self.q("head"))?;
                let (raw, truncated) = self.git_read(
                    id,
                    1 << 20,
                    &[],
                    &[],
                    &[
                        "diff",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--no-color",
                        &base,
                        &head,
                        "--",
                    ],
                )?;
                json!({"diff":String::from_utf8_lossy(&raw),"base_oid":base,"head_oid":head,"truncated":truncated})
            }
            _ => return Ok(None),
        };
        Ok(Some(Reply::ok(value)))
    }
    fn git_hook(&self, repo: &Value, phase: &str) -> Result<Reply> {
        let repo = self.repo(number(repo, "id"), &self.user, "write")?;
        if !matches!(phase, "pre-receive" | "post-receive") {
            return Err(ApiError::new(404, "Git hook not found"));
        }
        let updates = self.body["updates"]
            .as_array()
            .filter(|u| !u.is_empty() && u.len() <= 2048)
            .ok_or_else(|| ApiError::new(400, "Updates are required"))?;
        let id = number(&repo, "id");
        let objects = self.repo_path(id).join("objects");
        let quarantine = text(&self.body, "quarantine_path");
        let objects_string = objects.to_string_lossy();
        let mut extra = Vec::new();
        if !quarantine.is_empty() {
            let path = Path::new(quarantine);
            let metadata = fs::symlink_metadata(path)
                .map_err(|_| ApiError::new(400, "Invalid quarantine directory"))?;
            let actual = fs::canonicalize(path)
                .map_err(|_| ApiError::new(400, "Invalid quarantine directory"))?;
            if !metadata.is_dir()
                || metadata.file_type().is_symlink()
                || !path
                    .file_name()
                    .and_then(|p| p.to_str())
                    .is_some_and(|p| p.starts_with("tmp_objdir-incoming-"))
                || actual.parent() != Some(fs::canonicalize(&objects)?.as_path())
            {
                return Err(ApiError::new(400, "Invalid quarantine directory"));
            }
            extra.push(("GIT_OBJECT_DIRECTORY", quarantine));
            extra.push(("GIT_ALTERNATE_OBJECT_DIRECTORIES", objects_string.as_ref()));
        }
        for update in updates {
            let (old, new, reference) = (
                text(update, "old"),
                text(update, "new"),
                text(update, "ref"),
            );
            if !oid_ok(old) || !oid_ok(new) || !stored_ref_ok(reference) {
                return Err(ApiError::new(400, "Invalid ref update"));
            }
            if reference.starts_with("refs/gitclub/") {
                return Err(ApiError::new(
                    403,
                    "GitClub internal references cannot be pushed",
                ));
            }
            if phase == "post-receive"
                || reference != format!("refs/heads/{}", text(&repo, "default_branch"))
                || old.bytes().all(|b| b == b'0')
            {
                continue;
            }
            if new.bytes().all(|b| b == b'0') {
                return Err(ApiError::new(403, "Default branch cannot be deleted"));
            }
            if boolean(&repo, "require_review") {
                return Err(ApiError::new(
                    403,
                    "Default branch requires a reviewed pull request",
                ));
            }
            self.git_read(
                id,
                1024,
                &extra,
                &[],
                &["merge-base", "--is-ancestor", old, new],
            )
            .map_err(|_| ApiError::new(403, "Default branch only accepts fast-forward updates"))?;
        }
        if phase == "post-receive" {
            self.refresh(&repo)?;
        }
        Ok(Reply::ok(json!({"ok":true})))
    }
    pub(crate) fn ssh_routes(&mut self) -> Result<Option<Reply>> {
        if self.path.starts_with("/api/ssh/") {
            let provided = self
                .headers
                .get("X-GitClub-SSH-Secret")
                .and_then(|h| h.to_str().ok())
                .unwrap_or("");
            if self.app.ssh_secret.is_empty()
                || !bool::from(self.app.ssh_secret.as_bytes().ct_eq(provided.as_bytes()))
            {
                return Err(ApiError::new(404, "SSH endpoint not found"));
            }
            if self.path == "/api/ssh/authorized-keys" && self.method == "GET" {
                return Ok(Some(Reply::ok(
                    json!({"keys":self.rows("SELECT id,public_key FROM ssh_keys ORDER BY id",&[])?}),
                )));
            }
            if self.path == "/api/ssh/authorize" && self.method == "POST" {
                let key = self.one("SELECT k.user_id,u.username FROM ssh_keys k JOIN users u ON u.id=k.user_id WHERE k.id=?", &[&number(&self.body,"key_id")])?;
                if key.is_null() {
                    return Err(ApiError::new(403, "SSH key is not authorized"));
                }
                let (operation, owner, name) = parse_ssh_command(text(&self.body, "command"))?;
                let identity = json!({"id":key["user_id"],"username":key["username"]});
                let found = self.one(
                    "SELECT id FROM repositories WHERE owner=? AND name=?",
                    &[&owner, &name],
                )?;
                if found.is_null() {
                    return Err(ApiError::new(404, "Repository not found"));
                }
                let repo = self.repo(
                    number(&found, "id"),
                    &identity,
                    if operation == "git-receive-pack" {
                        "write"
                    } else {
                        "read"
                    },
                )?;
                let token = self.new_token(number(&identity, "id"))?;
                self.exec(
                    "UPDATE tokens SET expires_at=? WHERE token_hash=?",
                    &[&(now() + 180000), &token_hash(&token)],
                )?;
                return Ok(Some(Reply::ok(
                    json!({"repo_id":repo["id"],"user_id":identity["id"],"token":token,"repository_path":self.repo_path(number(&repo,"id")),"operation":operation,"internal_url":self.app.internal_url}),
                )));
            }
            return Err(ApiError::new(404, "SSH endpoint not found"));
        }
        if self.path != "/api/ssh-keys" && !self.path.starts_with("/api/ssh-keys/") {
            return Ok(None);
        }
        require_user(&self.user)?;
        let uid = number(&self.user, "id");
        if self.path == "/api/ssh-keys" {
            if self.method == "GET" {
                return Ok(Some(Reply::ok(
                    json!({"ssh_keys":self.rows("SELECT id,title,public_key,created_at FROM ssh_keys WHERE user_id=? ORDER BY id",&[&uid])?}),
                )));
            }
            if self.method == "POST" {
                let title = text(&self.body, "title").trim();
                let key = text(&self.body, "public_key").trim();
                if title.is_empty()
                    || title.len() > 120
                    || key.len() > 16384
                    || key.contains(['\r', '\n'])
                {
                    return Err(ApiError::new(
                        400,
                        "Provide a title and one OpenSSH public key",
                    ));
                }
                let mut fields = key.split_whitespace();
                let kind = fields.next().unwrap_or("");
                let data = fields.next().unwrap_or("");
                if !matches!(
                    kind,
                    "ssh-ed25519"
                        | "ssh-rsa"
                        | "ecdsa-sha2-nistp256"
                        | "ecdsa-sha2-nistp384"
                        | "ecdsa-sha2-nistp521"
                ) || data.is_empty()
                {
                    return Err(ApiError::new(400, "Unsupported SSH public key"));
                }
                let canonical = format!("{kind} {data}");
                let path = self
                    .app
                    .data_dir
                    .join(format!(".ssh-key-{}", rand::random::<u128>()));
                let mut file = OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&path)?;
                let validation = (|| -> Result<()> {
                    writeln!(file, "{canonical}")?;
                    let _permit = self
                        .app
                        .git_slots
                        .try_acquire()
                        .map_err(|_| ApiError::new(503, "Key validation capacity exhausted"))?;
                    let mut command = safe_command("ssh-keygen");
                    command.args(["-l", "-f"]).arg(&path);
                    run_bounded(command, &[], 1024, Duration::from_secs(5))
                        .map_err(|_| ApiError::new(400, "Invalid OpenSSH public key"))?;
                    Ok(())
                })();
                drop(file);
                let _ = fs::remove_file(path);
                validation?;
                if !self
                    .one(
                        "SELECT id FROM ssh_keys WHERE public_key=? OR public_key LIKE ?",
                        &[&canonical, &format!("{canonical} %")],
                    )?
                    .is_null()
                {
                    return Err(ApiError::new(409, "SSH key is already registered"));
                }
                let stamp = now();
                let id = self.exec(
                    "INSERT INTO ssh_keys(user_id,title,public_key,created_at) VALUES(?,?,?,?)",
                    &[&uid, &title, &canonical, &stamp],
                )?;
                return Ok(Some(Reply::created(
                    json!({"ssh_key":{"id":id,"title":title,"public_key":canonical,"created_at":stamp}}),
                )));
            }
        } else if self.method == "DELETE" {
            let id = parse_id(self.path.trim_start_matches("/api/ssh-keys/"))?;
            if self
                .one(
                    "SELECT id FROM ssh_keys WHERE id=? AND user_id=?",
                    &[&id, &uid],
                )?
                .is_null()
            {
                return Err(ApiError::new(404, "SSH key not found"));
            }
            self.exec(
                "DELETE FROM ssh_keys WHERE id=? AND user_id=?",
                &[&id, &uid],
            )?;
            return Ok(Some(Reply::ok(json!({"ok":true}))));
        }
        Err(ApiError::new(405, "Method not supported"))
    }
}
fn parse_ssh_command(command: &str) -> Result<(&str, &str, &str)> {
    let invalid = || {
        ApiError::new(
            400,
            "Only Git upload-pack and receive-pack commands are allowed",
        )
    };
    let (operation, quoted) = command.split_once(' ').ok_or_else(invalid)?;
    if !matches!(operation, "git-upload-pack" | "git-receive-pack") {
        return Err(invalid());
    }
    let path = quoted
        .strip_prefix('\'')
        .and_then(|p| p.strip_suffix('\''))
        .and_then(|p| p.strip_suffix(".git"))
        .ok_or_else(invalid)?;
    let (owner, name) = path.split_once('/').ok_or_else(invalid)?;
    if !name_ok(owner) || !name_ok(name) || name.ends_with(".git") {
        return Err(invalid());
    }
    Ok((operation, owner, name))
}

struct AbortOnDrop(tokio::task::JoinHandle<()>);
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}
struct TransferBody {
    receiver: mpsc::Receiver<std::io::Result<Bytes>>,
    _task: AbortOnDrop,
}
impl Stream for TransferBody {
    type Item = std::io::Result<Bytes>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Option<Self::Item>> {
        self.receiver.poll_recv(cx)
    }
}

pub(crate) fn http_command(ctx: &Context, uri: &axum::http::Uri) -> Result<Command> {
    let parts: Vec<&str> = ctx.path.trim_start_matches('/').split('/').collect();
    if parts.len() < 3 || !parts[1].ends_with(".git") {
        return Err(ApiError::new(404, "Git endpoint not found"));
    }
    let tail = parts[2..].join("/");
    let service = ctx.q("service");
    if !(ctx.method == "GET"
        && tail == "info/refs"
        && matches!(service, "git-upload-pack" | "git-receive-pack")
        || ctx.method == "POST" && matches!(tail.as_str(), "git-upload-pack" | "git-receive-pack"))
    {
        return Err(ApiError::new(404, "Git endpoint not found"));
    }
    let receive = tail == "git-receive-pack" || service == "git-receive-pack";
    let found = ctx.one(
        "SELECT id,visibility FROM repositories WHERE owner=? AND name=?",
        &[&parts[0], &parts[1].trim_end_matches(".git")],
    )?;
    if found.is_null() {
        return Err(ApiError::new(404, "Repository not found"));
    }
    if ctx.user.is_null() && (receive || text(&found, "visibility") != "public") {
        return Err(ApiError::new(
            401,
            "Git credentials required; use your token as the password",
        ));
    }
    let repo = ctx.repo(
        number(&found, "id"),
        &ctx.user,
        if receive { "write" } else { "read" },
    )?;
    let mut command = safe_command("git");
    command
        .arg("http-backend")
        .env("GIT_PROJECT_ROOT", ctx.app.data_dir.join("repos"))
        .env("PATH_INFO", format!("/{}.git/{tail}", number(&repo, "id")))
        .env("GIT_HTTP_EXPORT_ALL", "1")
        .env("REQUEST_METHOD", &ctx.method)
        .env("QUERY_STRING", uri.query().unwrap_or(""))
        .env(
            "CONTENT_TYPE",
            ctx.headers
                .get("Content-Type")
                .and_then(|h| h.to_str().ok())
                .unwrap_or(""),
        )
        .env("REMOTE_USER", text(&ctx.user, "username"))
        .env(
            "GIT_PROTOCOL",
            ctx.headers
                .get("Git-Protocol")
                .and_then(|h| h.to_str().ok())
                .unwrap_or(""),
        )
        .env("GITCLUB_URL", &ctx.app.internal_url)
        .env("GITCLUB_TOKEN", &ctx.token)
        .env("GITCLUB_REPO_ID", number(&repo, "id").to_string());
    if let Some(length) = ctx
        .headers
        .get("Content-Length")
        .and_then(|h| h.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
    {
        if length > TRANSFER_LIMIT {
            return Err(ApiError::new(413, "Git request exceeds 256 MiB"));
        }
        command.env("CONTENT_LENGTH", length.to_string());
    }
    Ok(command)
}
pub(crate) async fn http(ctx: Context, request: Request, command: Command) -> Result<Response> {
    let permit = ctx
        .app
        .transfer_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| ApiError::new(503, "Git transfer capacity exhausted; retry shortly"))?;
    drop(ctx);
    let mut command = tokio::process::Command::from(command);
    command.kill_on_drop(true);
    let mut child = command.spawn()?;
    let group = ProcessGroup::new(
        child
            .id()
            .ok_or_else(|| ApiError::new(503, "Git process unavailable"))?,
    )?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| ApiError::new(503, "Git input unavailable"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| ApiError::new(503, "Git output unavailable"))?;
    let (header_tx, header_rx) = oneshot::channel::<Result<(u16, Vec<(String, String)>)>>();
    let (body_tx, body_rx) = mpsc::channel(1);
    // The response body owns this task; disconnect drops the body and aborts the
    // task, whose process-group guard kills Git and all hook/pack descendants.
    let task = AbortOnDrop(tokio::spawn(async move {
        let _permit = permit;
        let _group = group;
        let mut headers = Some(header_tx);
        let operation = async {
            let input = async move {
                let mut stream = request.into_body().into_data_stream();
                let mut total = 0u64;
                while let Some(bytes) = stream.next().await {
                    let bytes = bytes.map_err(std::io::Error::other)?;
                    total = total.saturating_add(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
                    if total > TRANSFER_LIMIT {
                        return Err(std::io::Error::other("Git request exceeds 256 MiB"));
                    }
                    for chunk in bytes.chunks(65536) {
                        stdin.write_all(chunk).await?;
                    }
                }
                stdin.shutdown().await?;
                drop(stdin);
                Ok::<(), std::io::Error>(())
            };
            let output = async {
                let mut reader = BufReader::with_capacity(65536, stdout);
                let mut header_bytes = Vec::new();
                loop {
                    let mut byte = [0u8; 1];
                    if reader.read(&mut byte).await? == 0 {
                        return Err(std::io::Error::other("Missing Git response headers"));
                    }
                    header_bytes.push(byte[0]);
                    if header_bytes.len() > 16384 {
                        return Err(std::io::Error::other("Git response headers exceed limit"));
                    }
                    if header_bytes.ends_with(b"\r\n\r\n") || header_bytes.ends_with(b"\n\n") {
                        break;
                    }
                }
                let (status, values) = parse_cgi_headers(&header_bytes)?;
                if let Some(sender) = headers.take() {
                    let _ = sender.send(Ok((status, values)));
                }
                loop {
                    let mut buffer = vec![0u8; 65536];
                    let count = reader.read(&mut buffer).await?;
                    if count == 0 {
                        break;
                    }
                    buffer.truncate(count);
                    body_tx
                        .send(Ok(Bytes::from(buffer)))
                        .await
                        .map_err(|_| std::io::Error::other("Client disconnected"))?;
                }
                Ok::<(), std::io::Error>(())
            };
            tokio::try_join!(input, output)?;
            let status = child.wait().await?;
            if !status.success() {
                return Err(std::io::Error::other("Git transfer failed"));
            }
            Ok::<(), std::io::Error>(())
        };
        let outcome = tokio::select! {
            result=tokio::time::timeout(Duration::from_secs(120),operation)=>result.unwrap_or_else(|_|Err(std::io::Error::other("Git transfer exceeded 120 seconds"))),
            ()=body_tx.closed()=>Err(std::io::Error::other("Client disconnected")),
        };
        if let Err(error) = outcome {
            _group.kill();
            let _ = child.wait().await;
            if let Some(sender) = headers.take() {
                let _ = sender.send(Err(ApiError::new(502, "Git transfer failed")));
            } else {
                let _ = body_tx.try_send(Err(error));
            }
        }
    }));
    let (status, headers) = header_rx
        .await
        .map_err(|_| ApiError::new(502, "Git transfer failed"))??;
    let mut response = Response::builder().status(status);
    for (key, value) in headers {
        response = response.header(key, value);
    }
    response
        .body(Body::from_stream(TransferBody {
            receiver: body_rx,
            _task: task,
        }))
        .map_err(|_| ApiError::new(502, "Invalid Git response headers"))
}
fn parse_cgi_headers(raw: &[u8]) -> std::io::Result<(u16, Vec<(String, String)>)> {
    let text = std::str::from_utf8(raw).map_err(std::io::Error::other)?;
    let mut status = 200;
    let mut headers = Vec::new();
    for line in text.lines().filter(|line| !line.is_empty()) {
        let (key, value) = line
            .split_once(':')
            .ok_or_else(|| std::io::Error::other("Invalid CGI header"))?;
        let value = value.trim();
        if key.eq_ignore_ascii_case("Status") {
            status = value
                .split_whitespace()
                .next()
                .unwrap_or("")
                .parse()
                .map_err(std::io::Error::other)?;
            if !(200..=599).contains(&status) {
                return Err(std::io::Error::other("Invalid CGI status"));
            }
        } else {
            axum::http::HeaderName::from_bytes(key.as_bytes()).map_err(std::io::Error::other)?;
            axum::http::HeaderValue::from_str(value).map_err(std::io::Error::other)?;
            headers.push((key.to_owned(), value.to_owned()));
        }
    }
    Ok((status, headers))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn refs_paths_and_ssh_commands_reject_injection() {
        for branch in [
            "../main",
            "-evil",
            "a..b",
            "a@{1}",
            "main.lock",
            "a//b",
            "a\nb",
            "refs/*",
        ] {
            assert!(!valid_branch(branch), "{branch}");
        }
        for branch in ["main", "feature/one", "release-1.0"] {
            assert!(valid_branch(branch));
        }
        for path in ["../secret", "/secret", "a/../b", "a//b", "a\\b"] {
            assert!(!valid_path(path));
        }
        assert!(parse_ssh_command("git-upload-pack 'owner/repo.git'").is_ok());
        for command in [
            "sh -c 'ls'",
            "git-upload-pack '../repo.git'",
            "git-upload-pack 'owner/repo.git';id",
            "git-upload-pack 'owner/repo.git' x",
        ] {
            assert!(parse_ssh_command(command).is_err());
        }
    }
    #[test]
    fn freshness_handles_packed_refs_and_symbolic_cycles() -> Result<()> {
        let root =
            std::env::temp_dir().join(format!("gitclub-rust-refs-{}", rand::random::<u128>()));
        fs::create_dir_all(root.join("refs/heads"))?;
        let oid = "a".repeat(40);
        assert_eq!(read_default_oid(&root, "main")?, "");
        fs::write(root.join("packed-refs"), format!("{oid} refs/heads/main\n"))?;
        assert_eq!(read_default_oid(&root, "main")?, oid);
        fs::write(root.join("refs/heads/main"), "ref: refs/heads/next\n")?;
        fs::write(root.join("refs/heads/next"), "ref: refs/heads/main\n")?;
        assert!(read_default_oid(&root, "main").is_err());
        fs::write(root.join("refs/heads/next"), format!("{oid}\n"))?;
        assert_eq!(read_default_oid(&root, "main")?, oid);
        fs::remove_dir_all(root)?;
        Ok(())
    }
    #[test]
    fn output_cap_drains_and_deadline_kills() -> Result<()> {
        let mut command = safe_command("python3");
        command.args(["-c", "import sys; sys.stdout.buffer.write(b'x' * 1000000)"]);
        let (output, truncated) = run_bounded(command, &[], 1234, Duration::from_secs(5))?;
        assert_eq!(output.len(), 1234);
        assert!(truncated);
        let mut command = safe_command("python3");
        command.args(["-c", "import time; time.sleep(60)"]);
        let start = Instant::now();
        assert!(run_bounded(command, &[], 1024, Duration::from_millis(50)).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
        Ok(())
    }
    #[test]
    fn maintenance_stays_in_process_group_for_commands_and_ssh() -> Result<()> {
        let context = crate::core::test_context();
        let data_dir = context.app.data_dir.clone();
        fs::create_dir_all(data_dir.join("repos"))?;
        context.git_run(
            1,
            &["init", "--bare", &context.repo_path(1).to_string_lossy()],
        )?;
        context.configure_maintenance(1)?;
        for key in ["maintenance.autoDetach", "gc.autoDetach"] {
            let mut command = safe_command("git");
            command.args(["config", "--get", key]);
            let (value, _) = run_bounded(command, &[], 1024, Duration::from_secs(5))?;
            assert_eq!(
                value, b"false\n",
                "trusted environment must disable detachment"
            );
            let local = context.git_run(1, &["config", "--local", "--get", key])?;
            assert_eq!(
                local, b"false\n",
                "SSH must inherit persistent repository policy"
            );
        }
        fs::remove_dir_all(data_dir)?;
        Ok(())
    }
    #[test]
    fn cgi_status_and_headers_are_validated() {
        assert_eq!(
            parse_cgi_headers(b"Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n")
                .expect("valid headers")
                .0,
            403
        );
        assert!(parse_cgi_headers(b"Status: 999 Bad\n\n").is_err());
        assert!(parse_cgi_headers(b"malformed\n\n").is_err());
    }
    #[tokio::test]
    async fn transfer_closes_input_before_waiting_for_cgi_output() -> Result<()> {
        let context = crate::core::test_context();
        let data_dir = context.app.data_dir.clone();
        let mut command = safe_command("python3");
        command.args(["-c", "import sys; data = sys.stdin.buffer.read(); sys.stdout.buffer.write(b'Content-Type: text/plain\\r\\n\\r\\n' + data); sys.stdout.flush()"]);
        let request = Request::builder()
            .body(Body::from("streamed input"))
            .expect("valid request");
        let response =
            tokio::time::timeout(Duration::from_secs(2), http(context, request, command))
                .await
                .expect("CGI receives input EOF")?;
        let body = axum::body::to_bytes(response.into_body(), 1024)
            .await
            .expect("read CGI body");
        assert_eq!(body, "streamed input");
        fs::remove_dir_all(data_dir)?;
        Ok(())
    }
    #[tokio::test]
    async fn dropping_transfer_kills_inherited_descendants() -> Result<()> {
        let context = crate::core::test_context();
        let data_dir = context.app.data_dir.clone();
        let marker = data_dir.join("descendant-survived");
        let mut command = safe_command("python3");
        command.args(["-c", "import os,sys,time; child=os.fork(); time.sleep(0.4) if child == 0 else None; open(sys.argv[1], 'w').close() if child == 0 else None; sys.stdout.write('Content-Type: text/plain\\r\\n\\r\\n'); sys.stdout.flush(); time.sleep(60)"]).arg(&marker);
        let request = Request::builder()
            .body(Body::empty())
            .expect("valid request");
        let response =
            tokio::time::timeout(Duration::from_secs(2), http(context, request, command))
                .await
                .expect("CGI starts")?;
        drop(response);
        tokio::time::sleep(Duration::from_millis(600)).await;
        assert!(
            !marker.exists(),
            "descendant must be killed on response drop"
        );
        fs::remove_dir_all(data_dir)?;
        Ok(())
    }
}
