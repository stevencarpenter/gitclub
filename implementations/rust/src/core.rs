use axum::{
    Json, Router,
    body::{Body, to_bytes},
    extract::{ConnectInfo, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use pbkdf2::pbkdf2_hmac;
use rand::{TryRng, rngs::SysRng};
use rusqlite::{Connection, ToSql, types::ValueRef};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    net::SocketAddr,
    path::{Component, Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard, TryLockError},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use tokio::sync::Semaphore;

pub(crate) type Result<T> = std::result::Result<T, ApiError>;

#[derive(Debug)]
pub(crate) struct ApiError {
    pub(crate) status: u16,
    pub(crate) message: String,
}
impl ApiError {
    pub(crate) fn new(status: u16, message: impl Into<String>) -> Self {
        Self {
            status,
            message: message.into(),
        }
    }
}
impl From<rusqlite::Error> for ApiError {
    fn from(error: rusqlite::Error) -> Self {
        match error.sqlite_error_code() {
            Some(rusqlite::ErrorCode::ConstraintViolation)
                if error.sqlite_error().is_some_and(|error| {
                    matches!(
                        error.extended_code,
                        rusqlite::ffi::SQLITE_CONSTRAINT_UNIQUE
                            | rusqlite::ffi::SQLITE_CONSTRAINT_PRIMARYKEY
                            | rusqlite::ffi::SQLITE_CONSTRAINT_FOREIGNKEY
                            | rusqlite::ffi::SQLITE_CONSTRAINT_CHECK
                    )
                }) =>
            {
                Self::new(
                    409,
                    "That name or entry already exists, or conflicts with stored data",
                )
            }
            Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked) => {
                Self::new(503, "Database is busy; retry shortly")
            }
            _ => Self::new(500, "Database operation failed"),
        }
    }
}
impl From<std::io::Error> for ApiError {
    fn from(_: std::io::Error) -> Self {
        Self::new(500, "Filesystem or process operation failed")
    }
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            Json(json!({"error": self.message})),
        )
            .into_response()
    }
}

pub(crate) struct Reply {
    pub(crate) status: u16,
    pub(crate) value: Value,
    pub(crate) cookie: Option<String>,
}
impl Reply {
    pub(crate) fn ok(value: Value) -> Self {
        Self {
            status: 200,
            value,
            cookie: None,
        }
    }
    pub(crate) fn created(value: Value) -> Self {
        Self {
            status: 201,
            value,
            cookie: None,
        }
    }
}
impl IntoResponse for Reply {
    fn into_response(self) -> Response {
        let mut response = (
            StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            Json(self.value),
        )
            .into_response();
        if let Some(cookie) = self.cookie.and_then(|v| HeaderValue::from_str(&v).ok()) {
            response.headers_mut().insert(header::SET_COOKIE, cookie);
        }
        response
    }
}

pub(crate) fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub(crate) fn number(v: &Value, key: &str) -> i64 {
    v[key].as_i64().unwrap_or(0)
}
pub(crate) fn boolean(v: &Value, key: &str) -> bool {
    v[key].as_bool().unwrap_or_else(|| number(v, key) != 0)
}
pub(crate) fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|v| i64::try_from(v.as_millis()).ok())
        .unwrap_or(0)
}
pub(crate) fn rank(role: &str) -> u8 {
    match role {
        "admin" => 3,
        "write" => 2,
        "read" => 1,
        _ => 0,
    }
}
pub(crate) fn name_ok(name: &str) -> bool {
    (1..=63).contains(&name.len())
        && name
            .bytes()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || b"._-".contains(&c))
}
pub(crate) fn parse_id(value: &str) -> Result<i64> {
    value
        .parse::<i64>()
        .ok()
        .filter(|&id| id > 0)
        .ok_or_else(|| ApiError::new(404, "Resource not found"))
}
pub(crate) fn require_user(user: &Value) -> Result<()> {
    if user.is_null() {
        Err(ApiError::new(401, "Sign in to continue"))
    } else {
        Ok(())
    }
}
pub(crate) fn token_hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}
fn random_hex<const N: usize>() -> Result<String> {
    let mut bytes = [0; N];
    SysRng
        .try_fill_bytes(&mut bytes)
        .map_err(|_| ApiError::new(500, "Secure random generation failed"))?;
    Ok(hex::encode(bytes))
}
fn password_hash(password: &str) -> Result<String> {
    let salt = random_hex::<16>()?;
    let bytes = hex::decode(&salt).map_err(|_| ApiError::new(500, "Password generation failed"))?;
    let mut hash = [0; 32];
    pbkdf2_hmac::<Sha256>(password.as_bytes(), &bytes, 600_000, &mut hash);
    Ok(format!("pbkdf2_sha256$600000${salt}${}", hex::encode(hash)))
}
fn password_matches(password: &str, stored: &str) -> bool {
    let fields: Vec<_> = stored.split('$').collect();
    if fields.len() != 4
        || fields[0] != "pbkdf2_sha256"
        || fields[1] != "600000"
        || password.len() > 256
    {
        return false;
    }
    let (Ok(salt), Ok(expected)) = (hex::decode(fields[2]), hex::decode(fields[3])) else {
        return false;
    };
    if salt.len() != 16 || expected.len() != 32 {
        return false;
    }
    let mut actual = [0; 32];
    pbkdf2_hmac::<Sha256>(password.as_bytes(), &salt, 600_000, &mut actual);
    bool::from(actual.as_slice().ct_eq(&expected))
}

struct RateEntry {
    count: u8,
    since: Instant,
}
pub(crate) struct App {
    pub(crate) data_dir: PathBuf,
    pub(crate) shared_dir: PathBuf,
    pub(crate) web_dir: PathBuf,
    pub(crate) public_url: String,
    pub(crate) internal_url: String,
    pub(crate) ssh_secret: String,
    pub(crate) git_slots: Arc<Semaphore>,
    pub(crate) transfer_slots: Arc<Semaphore>,
    repo_locks: Mutex<HashMap<i64, Arc<Mutex<()>>>>,
    rates: Mutex<HashMap<String, RateEntry>>,
    metadata_slots: Arc<Semaphore>,
    control_slots: Arc<Semaphore>,
    tools: Vec<Value>,
}
impl App {
    pub(crate) fn connection(&self) -> Result<Connection> {
        let db = Connection::open(self.data_dir.join("gitclub.db"))?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.pragma_update(None, "foreign_keys", "ON")?;
        Ok(db)
    }
    pub(crate) fn repo_lock(&self, id: i64) -> Arc<Mutex<()>> {
        let mut locks = self.repo_locks.lock().unwrap_or_else(|e| e.into_inner());
        Arc::clone(locks.entry(id).or_insert_with(|| Arc::new(Mutex::new(()))))
    }
    fn check_rate(&self, peer: &str) -> Result<()> {
        let mut rates = self
            .rates
            .lock()
            .map_err(|_| ApiError::new(503, "Authentication unavailable"))?;
        rates.retain(|_, entry| entry.since.elapsed() < Duration::from_secs(60));
        if !rates.contains_key(peer) && rates.len() >= 4096 {
            return Err(ApiError::new(
                429,
                "Authentication busy; retry in one minute",
            ));
        }
        let entry = rates.entry(peer.to_owned()).or_insert(RateEntry {
            count: 0,
            since: Instant::now(),
        });
        if entry.count >= 20 {
            return Err(ApiError::new(
                429,
                "Too many authentication attempts; retry in one minute",
            ));
        }
        Ok(())
    }
    fn record_failure(&self, peer: &str) {
        if let Ok(mut rates) = self.rates.lock()
            && let Some(entry) = rates.get_mut(peer)
        {
            entry.count = entry.count.saturating_add(1);
        }
    }
    fn cookie(&self, token: &str) -> String {
        format!(
            "gc_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={}{}",
            if token.is_empty() { 0 } else { 2_592_000 },
            if self.public_url.starts_with("https://") {
                "; Secure"
            } else {
                ""
            }
        )
    }
}
pub(crate) fn lock_repo(lock: &Mutex<()>) -> Result<MutexGuard<'_, ()>> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        match lock.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::Poisoned(_)) => {
                return Err(ApiError::new(
                    503,
                    "Repository operation failed; restart to reconcile its state",
                ));
            }
            Err(TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(10))
            }
            Err(TryLockError::WouldBlock) => {
                return Err(ApiError::new(503, "Repository is busy; retry shortly"));
            }
        }
    }
}

pub(crate) struct Context {
    pub(crate) app: Arc<App>,
    pub(crate) db: Connection,
    pub(crate) user: Value,
    pub(crate) token: String,
    pub(crate) method: String,
    pub(crate) path: String,
    pub(crate) query: HashMap<String, String>,
    pub(crate) body: Value,
    pub(crate) headers: HeaderMap,
    pub(crate) peer: String,
}
impl Context {
    pub(crate) fn rows(&self, sql: &str, params: &[&dyn ToSql]) -> Result<Vec<Value>> {
        let mut stmt = self.db.prepare(sql)?;
        let names: Vec<String> = stmt
            .column_names()
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        let rows = stmt.query_map(params, |row| {
            let mut value = Map::new();
            for (i, name) in names.iter().enumerate() {
                let field = match row.get_ref(i)? {
                    ValueRef::Null => Value::Null,
                    ValueRef::Integer(n) => json!(n),
                    ValueRef::Real(n) => json!(n),
                    ValueRef::Text(s) => Value::String(String::from_utf8_lossy(s).into_owned()),
                    ValueRef::Blob(s) => Value::String(hex::encode(s)),
                };
                value.insert(name.clone(), field);
            }
            Ok(Value::Object(value))
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }
    pub(crate) fn one(&self, sql: &str, params: &[&dyn ToSql]) -> Result<Value> {
        Ok(self
            .rows(sql, params)?
            .into_iter()
            .next()
            .unwrap_or(Value::Null))
    }
    pub(crate) fn exec(&self, sql: &str, params: &[&dyn ToSql]) -> Result<i64> {
        self.db.execute(sql, params)?;
        Ok(self.db.last_insert_rowid())
    }
    pub(crate) fn new_token(&self, uid: i64) -> Result<String> {
        let token = random_hex::<32>()?;
        self.exec(
            "INSERT INTO tokens(token_hash,user_id,created_at) VALUES(?,?,?)",
            &[&token_hash(&token), &uid, &now()],
        )?;
        Ok(token)
    }
    pub(crate) fn q(&self, key: &str) -> &str {
        self.query.get(key).map_or("", String::as_str)
    }
    fn authenticate(&mut self) -> Result<()> {
        let authorization = header_text(&self.headers, "authorization");
        if let Some(token) = authorization.strip_prefix("Bearer ") {
            self.token = token.to_owned();
        } else if self.path.contains(".git/")
            && let Some(encoded) = authorization.strip_prefix("Basic ")
            && let Ok(decoded) = STANDARD.decode(encoded)
            && let Ok(credentials) = String::from_utf8(decoded)
            && let Some((_, token)) = credentials.split_once(':')
        {
            self.token = token.to_owned();
        }
        if self.headers.contains_key(header::AUTHORIZATION) {
            if self.token.is_empty() {
                return Err(ApiError::new(401, "Provide a valid authorization token"));
            }
        } else {
            self.token = session_cookie(&self.headers).unwrap_or("").to_owned();
        }
        if !self.token.is_empty() {
            self.user = self.one("SELECT users.id,users.username FROM users JOIN tokens ON users.id=tokens.user_id WHERE token_hash=? AND (expires_at=0 OR expires_at>?)", &[&token_hash(&self.token), &now()])?;
        }
        Ok(())
    }
    fn auth(&mut self) -> Result<Reply> {
        self.app.check_rate(&self.peer)?;
        let result = self.auth_inner();
        if result
            .as_ref()
            .err()
            .is_some_and(|e| (400..500).contains(&e.status))
        {
            self.app.record_failure(&self.peer);
        }
        result
    }
    fn auth_inner(&mut self) -> Result<Reply> {
        let username = text(&self.body, "username");
        let password = text(&self.body, "password");
        let (user, status) = if self.path.ends_with("/register") {
            if !name_ok(username) || !(12..=256).contains(&password.len()) {
                return Err(ApiError::new(
                    400,
                    "Use a lowercase username and a password of 12 to 256 bytes",
                ));
            }
            let hash = password_hash(password)?;
            let tx = self.db.transaction()?;
            tx.execute(
                "INSERT INTO users(username,password_hash,created_at) VALUES(?,?,?)",
                rusqlite::params![username, hash, now()],
            )?;
            let id = tx.last_insert_rowid();
            tx.execute(
                "INSERT INTO namespaces(name,kind) VALUES(?,'user')",
                [username],
            )?;
            tx.execute(
                "INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,'admin')",
                rusqlite::params![username, id],
            )?;
            tx.commit()?;
            (json!({"id":id,"username":username}), 201)
        } else {
            let user = self.one(
                "SELECT id,username,password_hash FROM users WHERE username=?",
                &[&username],
            )?;
            let stored = if user.is_null() {
                "pbkdf2_sha256$600000$00000000000000000000000000000000$0000000000000000000000000000000000000000000000000000000000000000"
            } else {
                text(&user, "password_hash")
            };
            if !password_matches(password, stored) || user.is_null() {
                return Err(ApiError::new(401, "Incorrect username or password"));
            }
            (json!({"id":user["id"],"username":user["username"]}), 200)
        };
        let token = self.new_token(number(&user, "id"))?;
        Ok(Reply {
            status,
            cookie: Some(self.app.cookie(&token)),
            value: json!({"user":user,"token":token}),
        })
    }
}

pub(crate) fn api(ctx: &mut Context) -> Result<Reply> {
    match (ctx.method.as_str(), ctx.path.as_str()) {
        ("POST", "/api/auth/register" | "/api/auth/login") => return ctx.auth(),
        ("POST", "/api/auth/logout") => {
            ctx.exec(
                "DELETE FROM tokens WHERE token_hash=?",
                &[&token_hash(&ctx.token)],
            )?;
            return Ok(Reply {
                cookie: Some(ctx.app.cookie("")),
                ..Reply::ok(json!({"ok":true}))
            });
        }
        ("GET", "/api/session") => return Ok(Reply::ok(json!({"user":ctx.user}))),
        ("GET", "/api/users") => {
            require_user(&ctx.user)?;
            return Ok(Reply::ok(
                json!({"users":ctx.rows("SELECT id,username FROM users WHERE username LIKE ? ORDER BY username LIMIT 100", &[&format!("%{}%",ctx.q("q"))])?}),
            ));
        }
        _ => {}
    }
    if let Some(reply) = ctx.ssh_routes()? {
        return Ok(reply);
    }
    let path = ctx.path.clone();
    let parts: Vec<_> = path.trim_matches('/').split('/').collect();
    match parts.as_slice() {
        ["api", "namespaces", rest @ ..] => ctx.namespaces(rest),
        ["api", "groups", rest @ ..] => ctx.groups(rest),
        ["api", "repos", rest @ ..] => ctx.repositories(rest),
        _ => Err(ApiError::new(404, "Endpoint not found")),
    }
}

fn header_text<'a>(headers: &'a HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|s| s.to_str().ok())
        .unwrap_or("")
}
fn session_cookie(headers: &HeaderMap) -> Option<&str> {
    headers
        .get_all(header::COOKIE)
        .iter()
        .filter_map(|h| h.to_str().ok())
        .flat_map(|h| h.split(';'))
        .find_map(|pair| pair.trim().strip_prefix("gc_session="))
}
fn csrf(app: &App, method: &str, headers: &HeaderMap) -> Result<()> {
    if matches!(method, "GET" | "HEAD") {
        return Ok(());
    }
    let origin = header_text(headers, "origin");
    if !origin.is_empty() && origin.trim_end_matches('/') != app.public_url.trim_end_matches('/') {
        return Err(ApiError::new(403, "Use a same-origin request"));
    }
    if header_text(headers, "authorization").is_empty()
        && session_cookie(headers).is_some()
        && ((origin.is_empty() && header_text(headers, "x-gitclub-request") != "1")
            || header_text(headers, "content-type").split(';').next() != Some("application/json"))
    {
        return Err(ApiError::new(403, "Use a same-origin JSON request"));
    }
    Ok(())
}

fn rpc_error(id: &Value, code: i32, message: &str) -> Reply {
    Reply::ok(json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}}))
}
fn mcp(ctx: &mut Context, parse_error: bool) -> Result<Reply> {
    if ctx.method != "POST" {
        return Err(ApiError::new(405, "Use POST for stateless MCP"));
    }
    require_user(&ctx.user)?;
    if !header_text(&ctx.headers, "authorization").starts_with("Bearer ") {
        return Err(ApiError::new(401, "MCP requires a Bearer token"));
    }
    let request = std::mem::take(&mut ctx.body);
    let id = &request["id"];
    if parse_error {
        return Ok(rpc_error(&Value::Null, -32700, "Parse error"));
    }
    if !request.is_object() || text(&request, "jsonrpc") != "2.0" {
        return Ok(rpc_error(id, -32600, "Invalid request"));
    }
    let params = &request["params"];
    let result = match text(&request, "method") {
        "initialize" => {
            let version = match text(params, "protocolVersion") {
                v @ ("2024-11-05" | "2025-03-26" | "2025-06-18") => v,
                _ => "2025-06-18",
            };
            json!({"protocolVersion":version,"capabilities":{"tools":{}},"serverInfo":{"name":"gitclub-rust","version":"0.1.0"}})
        }
        "notifications/initialized" => {
            return Ok(Reply {
                status: 202,
                value: Value::Null,
                cookie: None,
            });
        }
        "ping" => json!({}),
        "tools/list" => {
            let tools: Vec<Value> = ctx
                .app
                .tools
                .iter()
                .cloned()
                .map(|mut tool| {
                    if let Some(object) = tool.as_object_mut() {
                        object.remove("http");
                    }
                    tool
                })
                .collect();
            json!({"tools":tools})
        }
        "tools/call" => {
            let Some(tool) = ctx
                .app
                .tools
                .iter()
                .find(|t| text(t, "name") == text(params, "name"))
            else {
                return Ok(rpc_error(id, -32602, "Unknown tool"));
            };
            let args = params
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let Some(args) = args.as_object() else {
                return Ok(rpc_error(id, -32602, "Tool arguments must be an object"));
            };
            let mapping = &tool["http"];
            let mut path = text(mapping, "path").to_owned();
            for (key, value) in args {
                let placeholder = format!("{{{key}}}");
                if path.contains(&placeholder) {
                    let Some(value) = value.as_i64().filter(|&n| n > 0) else {
                        return Ok(rpc_error(id, -32602, "Route IDs must be positive integers"));
                    };
                    path = path.replace(&placeholder, &value.to_string());
                }
            }
            if path.contains(['{', '}']) || !path.starts_with("/api/") {
                return Ok(rpc_error(id, -32602, "Missing route arguments"));
            }
            ctx.query.clear();
            if let Some(keys) = mapping["query"].as_array() {
                for key in keys.iter().filter_map(Value::as_str) {
                    if let Some(value) = args.get(key) {
                        ctx.query.insert(
                            key.to_owned(),
                            value
                                .as_str()
                                .map_or_else(|| value.to_string(), str::to_owned),
                        );
                    }
                }
            }
            let mut body = Map::new();
            if let Some(keys) = mapping["body"].as_array() {
                for key in keys.iter().filter_map(Value::as_str) {
                    if let Some(value) = args.get(key) {
                        body.insert(key.to_owned(), value.clone());
                    }
                }
            }
            ctx.method = text(mapping, "method").to_owned();
            ctx.path = path;
            ctx.body = Value::Object(body);
            let (value, is_error) = match api(ctx) {
                Ok(reply) => (reply.value, false),
                Err(error) => (json!({"error":error.message}), true),
            };
            json!({"content":[{"type":"text","text":value.to_string()}],"isError":is_error})
        }
        _ => return Ok(rpc_error(id, -32601, "Method not found")),
    };
    Ok(Reply::ok(json!({"jsonrpc":"2.0","id":id,"result":result})))
}

async fn handle(
    State(app): State<Arc<App>>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    request: Request,
) -> Response {
    let git_http = request.uri().path().contains(".git/");
    let mut response = match route(app, peer, request).await {
        Ok(response) => response,
        Err(error) => error.into_response(),
    };
    if git_http && response.status() == StatusCode::UNAUTHORIZED {
        response.headers_mut().insert(
            header::WWW_AUTHENTICATE,
            HeaderValue::from_static("Basic realm=\"GitClub\""),
        );
    }
    let headers = response.headers_mut();
    headers.insert(
        "x-content-type-options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("referrer-policy", HeaderValue::from_static("same-origin"));
    headers.insert("content-security-policy", HeaderValue::from_static("default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"));
    response
}
async fn route(app: Arc<App>, peer: SocketAddr, request: Request) -> Result<Response> {
    let path = request.uri().path().to_owned();
    let method = request.method().as_str().to_owned();
    if path == "/health" {
        return Ok(Reply::ok(json!({"status":"ok","implementation":"rust"})).into_response());
    }
    csrf(&app, &method, request.headers())?;
    if !path.starts_with("/api") && path != "/mcp" && !path.contains(".git") {
        return static_file(&app, &path, &method).await;
    }
    let query = form_urlencoded::parse(request.uri().query().unwrap_or("").as_bytes())
        .into_owned()
        .collect();
    let headers = request.headers().clone();
    let git_http = path.contains(".git/");
    let control = path.ends_with("/git/pre-receive")
        || path.ends_with("/git/post-receive")
        || path.starts_with("/api/ssh/")
        || git_http;
    let slots = if control {
        &app.control_slots
    } else {
        &app.metadata_slots
    };
    let permit = Arc::clone(slots)
        .try_acquire_owned()
        .map_err(|_| ApiError::new(503, "Server is busy; retry shortly"))?;
    if git_http {
        let uri = request.uri().clone();
        let (ctx, command) = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let mut ctx = Context {
                db: app.connection()?,
                app,
                user: Value::Null,
                token: String::new(),
                method,
                path,
                query,
                body: json!({}),
                headers,
                peer: peer.ip().to_string(),
            };
            ctx.authenticate()?;
            let command = crate::git::http_command(&ctx, &uri)?;
            Ok::<_, ApiError>((ctx, command))
        })
        .await
        .map_err(|_| ApiError::new(500, "Authentication operation failed"))??;
        return crate::git::http(ctx, request, command).await;
    }
    let bytes = tokio::time::timeout(
        Duration::from_secs(10),
        to_bytes(request.into_body(), 1 << 20),
    )
    .await
    .map_err(|_| ApiError::new(408, "Request body timed out"))?
    .map_err(|_| ApiError::new(400, "Provide a JSON object (maximum 1 MiB)"))?;
    let (body, parse_error) = if bytes.is_empty() && path != "/mcp" {
        (json!({}), false)
    } else {
        match serde_json::from_slice::<Value>(&bytes) {
            Ok(value) if value.is_object() || path == "/mcp" => (value, false),
            _ if path == "/mcp" => (Value::Null, true),
            _ => {
                return Err(ApiError::new(
                    400,
                    "Provide one JSON object (maximum 1 MiB)",
                ));
            }
        }
    };
    tokio::task::spawn_blocking(move || {
        let _permit = permit;
        let mut ctx = Context {
            db: app.connection()?,
            app,
            user: Value::Null,
            token: String::new(),
            method,
            path,
            query,
            body,
            headers,
            peer: peer.ip().to_string(),
        };
        ctx.authenticate()?;
        let reply = if ctx.path == "/mcp" {
            mcp(&mut ctx, parse_error)?
        } else {
            api(&mut ctx)?
        };
        Ok(reply.into_response())
    })
    .await
    .map_err(|_| ApiError::new(500, "Request operation failed"))?
}
async fn static_file(app: &App, path: &str, method: &str) -> Result<Response> {
    if !matches!(method, "GET" | "HEAD") {
        return Err(ApiError::new(405, "Use GET"));
    }
    let relative = Path::new(path.trim_start_matches('/'));
    if relative
        .components()
        .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(ApiError::new(404, "File not found"));
    }
    let candidate = app.web_dir.join(relative);
    let file = if tokio::fs::metadata(&candidate)
        .await
        .is_ok_and(|m| m.is_file())
    {
        candidate
    } else {
        app.web_dir.join("index.html")
    };
    let mime = match file.extension().and_then(|e| e.to_str()) {
        Some("js") => "text/javascript; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("svg") => "image/svg+xml",
        Some("png") => "image/png",
        Some("ico") => "image/x-icon",
        _ => "text/html; charset=utf-8",
    };
    let data = tokio::fs::read(file).await?;
    let mut response = Response::new(if method == "HEAD" {
        Body::empty()
    } else {
        Body::from(data)
    });
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(mime));
    Ok(response)
}

fn env(key: &str, fallback: &str) -> String {
    std::env::var(key)
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}
fn absolute(path: &str) -> Result<PathBuf> {
    Ok(std::path::absolute(path)?)
}
pub(crate) async fn serve() -> Result<()> {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let signal = async move {
        tokio::select! { _ = terminate.recv() => {}, _ = interrupt.recv() => {} }
        Ok(())
    };
    tokio::pin!(signal);
    let port = env("PORT", "7703");
    let data_dir = absolute(&env("DATA_DIR", ".data/rust"))?;
    let shared_dir = absolute(&env("SHARED_DIR", "shared"))?;
    std::fs::create_dir_all(data_dir.join("repos"))?;
    let tools = serde_json::from_slice(&std::fs::read(shared_dir.join("mcp-tools.json"))?)
        .map_err(|_| ApiError::new(500, "Invalid MCP tool declarations"))?;
    let app = Arc::new(App {
        data_dir,
        shared_dir,
        web_dir: absolute(&env("WEB_DIR", "web"))?,
        public_url: env("PUBLIC_URL", &format!("http://localhost:{port}")),
        internal_url: format!("http://127.0.0.1:{port}"),
        ssh_secret: env("GITCLUB_SSH_SECRET", ""),
        git_slots: Arc::new(Semaphore::new(8)),
        transfer_slots: Arc::new(Semaphore::new(8)),
        repo_locks: Mutex::new(HashMap::new()),
        rates: Mutex::new(HashMap::new()),
        metadata_slots: Arc::new(Semaphore::new(64)),
        control_slots: Arc::new(Semaphore::new(16)),
        tools,
    });
    let startup_app = Arc::clone(&app);
    let mut startup = tokio::task::spawn_blocking(move || -> Result<()> {
        let db = startup_app.connection()?;
        db.execute_batch(&std::fs::read_to_string(
            startup_app.shared_dir.join("schema.sql"),
        )?)?;
        let ctx = Context {
            app: startup_app,
            db,
            user: Value::Null,
            token: String::new(),
            method: String::new(),
            path: String::new(),
            query: HashMap::new(),
            body: json!({}),
            headers: HeaderMap::new(),
            peer: String::new(),
        };
        for repo in ctx.rows("SELECT * FROM repositories", &[])? {
            let lock = ctx.app.repo_lock(number(&repo, "id"));
            let _guard = lock_repo(&lock)?;
            ctx.configure_maintenance(number(&repo, "id"))?;
            ctx.reconcile_merges(&repo)?;
            let expected = format!("ref: refs/heads/{}\n", text(&repo, "default_branch"));
            let path = ctx.repo_path(number(&repo, "id")).join("HEAD");
            if std::fs::read_to_string(&path)? != expected {
                ctx.git_run(
                    number(&repo, "id"),
                    &[
                        "symbolic-ref",
                        "HEAD",
                        &format!("refs/heads/{}", text(&repo, "default_branch")),
                    ],
                )?;
            }
        }
        Ok(())
    });
    tokio::select! {
        result = &mut startup => result.map_err(|_| ApiError::new(500, "Startup reconciliation failed"))??,
        result = &mut signal => {
            crate::git::shutdown();
            let _ = tokio::time::timeout(Duration::from_secs(15), &mut startup).await;
            return result;
        }
    }

    let listener =
        tokio::net::TcpListener::bind(format!("{}:{port}", env("HOST", "127.0.0.1"))).await?;
    eprintln!("GitClub Rust listening on {}", listener.local_addr()?);
    let router = Router::new().fallback(handle).with_state(app);
    let (stop_tx, _) = tokio::sync::watch::channel(false);
    let connections = Arc::new(Semaphore::new(1024));
    let mut tasks = tokio::task::JoinSet::new();
    let result = loop {
        tokio::select! {
            result = &mut signal => break result,
            Some(_) = tasks.join_next() => {},
            accepted = listener.accept() => {
                let (stream, peer) = match accepted { Ok(connection) => connection, Err(error) => break Err(ApiError::from(error)) };
                let Ok(permit) = Arc::clone(&connections).try_acquire_owned() else { continue; };
                let mut stop = stop_tx.subscribe();
                let service = hyper_util::service::TowerToHyperService::new(router.clone().layer(axum::Extension(ConnectInfo(peer))));
                tasks.spawn(async move {
                    let _permit = permit;
                    let mut builder = hyper::server::conn::http1::Builder::new();
                    builder.timer(hyper_util::rt::TokioTimer::new())
                        .header_read_timeout(Duration::from_secs(5))
                        .max_buf_size(64 << 10);
                    let connection = builder.serve_connection(hyper_util::rt::TokioIo::new(stream), service);
                    tokio::pin!(connection);
                    tokio::select! {
                        _ = &mut connection => {},
                        _ = stop.changed() => {
                            connection.as_mut().graceful_shutdown();
                            let _ = connection.await;
                        }
                    }
                });
            }
        }
    };
    drop(listener);
    crate::git::shutdown();
    let _ = stop_tx.send(true);
    let drain = async { while tasks.join_next().await.is_some() {} };
    if tokio::time::timeout(Duration::from_secs(15), drain)
        .await
        .is_err()
    {
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
    }
    result
}

#[cfg(test)]
pub(crate) fn test_context() -> Context {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let data_dir =
        std::env::temp_dir().join(format!("gitclub-rust-test-{}", random_hex::<12>().unwrap()));
    std::fs::create_dir_all(data_dir.join("repos")).unwrap();
    let app = Arc::new(App {
        data_dir,
        shared_dir: root.join("shared"),
        web_dir: root.join("web"),
        public_url: "http://localhost:7703".to_owned(),
        internal_url: "http://127.0.0.1:7703".to_owned(),
        ssh_secret: String::new(),
        git_slots: Arc::new(Semaphore::new(8)),
        transfer_slots: Arc::new(Semaphore::new(8)),
        repo_locks: Mutex::new(HashMap::new()),
        rates: Mutex::new(HashMap::new()),
        metadata_slots: Arc::new(Semaphore::new(64)),
        control_slots: Arc::new(Semaphore::new(16)),
        tools: serde_json::from_slice(&std::fs::read(root.join("shared/mcp-tools.json")).unwrap())
            .unwrap(),
    });
    let db = app.connection().unwrap();
    db.execute_batch(&std::fs::read_to_string(app.shared_dir.join("schema.sql")).unwrap())
        .unwrap();
    Context {
        app,
        db,
        user: Value::Null,
        token: String::new(),
        method: String::new(),
        path: String::new(),
        query: HashMap::new(),
        body: json!({}),
        headers: HeaderMap::new(),
        peer: "127.0.0.1".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identifiers_reject_injection_and_invalid_shapes() {
        for good in ["a", "0", "a-b.c_d"] {
            assert!(name_ok(good), "{good}");
        }
        for bad in ["", ".", "..", "../a", "a/B", "A", "é", "a\n", "a;b"] {
            assert!(!name_ok(bad), "{bad}");
        }
        assert!(parse_id("0").is_err());
        assert!(parse_id("9223372036854775808").is_err());
    }
    #[test]
    fn cookie_mutations_require_same_origin_json() {
        let ctx = test_context();
        let mut headers = HeaderMap::new();
        headers.insert("cookie", HeaderValue::from_static("gc_session=test"));
        assert!(csrf(&ctx.app, "POST", &headers).is_err());
        headers.insert("x-gitclub-request", HeaderValue::from_static("1"));
        headers.insert("content-type", HeaderValue::from_static("application/json"));
        assert!(csrf(&ctx.app, "POST", &headers).is_ok());
        headers.insert(
            "origin",
            HeaderValue::from_static("https://attacker.example"),
        );
        assert!(csrf(&ctx.app, "POST", &headers).is_err());
        headers.insert("authorization", HeaderValue::from_static("Bearer test"));
        assert!(csrf(&ctx.app, "POST", &headers).is_err());
        headers.remove("origin");
        assert!(csrf(&ctx.app, "GET", &headers).is_ok());
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
    #[test]
    fn invalid_authorization_never_falls_back_to_session_cookie() {
        let mut ctx = test_context();
        ctx.exec(
            "INSERT INTO users(username,password_hash,created_at) VALUES('user','hash',0)",
            &[],
        )
        .unwrap();
        let token = ctx.new_token(1).unwrap();
        ctx.headers.insert(
            "cookie",
            HeaderValue::from_str(&format!("gc_session={token}")).unwrap(),
        );
        for invalid in ["nonsense", "Bearer ", "Basic dXNlcjp0b2tlbg=="] {
            ctx.token.clear();
            ctx.headers
                .insert("authorization", HeaderValue::from_str(invalid).unwrap());
            assert_eq!(ctx.authenticate().unwrap_err().status, 401);
            assert!(ctx.user.is_null());
        }
        ctx.headers.remove("authorization");
        ctx.authenticate().unwrap();
        assert_eq!(number(&ctx.user, "id"), 1);
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
    #[test]
    fn mcp_distinguishes_malformed_json_from_valid_null() {
        let mut ctx = test_context();
        ctx.method = "POST".to_owned();
        ctx.user = json!({"id":1,"username":"user"});
        ctx.headers
            .insert("authorization", HeaderValue::from_static("Bearer test"));
        ctx.body = Value::Null;
        assert_eq!(mcp(&mut ctx, false).unwrap().value["error"]["code"], -32600);
        assert_eq!(mcp(&mut ctx, true).unwrap().value["error"]["code"], -32700);
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
    #[test]
    fn authentication_failures_are_bounded_and_trigger_failures_are_internal() {
        let ctx = test_context();
        for _ in 0..20 {
            assert!(ctx.app.check_rate("127.0.0.1").is_ok());
            ctx.app.record_failure("127.0.0.1");
        }
        assert_eq!(ctx.app.check_rate("127.0.0.1").unwrap_err().status, 429);
        ctx.db.execute_batch("CREATE TRIGGER fail_user BEFORE INSERT ON users BEGIN SELECT RAISE(ABORT, 'injected'); END;").unwrap();
        let error = ctx
            .exec(
                "INSERT INTO users(username,password_hash,created_at) VALUES('u','h',0)",
                &[],
            )
            .unwrap_err();
        assert_eq!(error.status, 500);
        std::fs::remove_dir_all(&ctx.app.data_dir).unwrap();
    }
    #[test]
    fn password_format_and_verification_are_interoperable() {
        // Python hashlib.pbkdf2_hmac with salt bytes 0..16 and 600,000 rounds.
        assert!(password_matches(
            "correct horse battery",
            "pbkdf2_sha256$600000$000102030405060708090a0b0c0d0e0f$bb06c8c0b1dd5bfd4e40f4e297a2d0e64da7ef94b4b8ec20989021c8b41536ad"
        ));
        let hash = password_hash("correct horse battery").unwrap();
        assert!(hash.starts_with("pbkdf2_sha256$600000$"));
        assert!(password_matches("correct horse battery", &hash));
        assert!(!password_matches("wrong horse battery", &hash));
        assert!(!password_matches(
            "correct horse battery",
            "pbkdf2_sha256$600000$00$00"
        ));
        assert_eq!(
            token_hash("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
