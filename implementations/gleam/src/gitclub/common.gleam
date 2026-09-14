import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Context {
  Context(
    data_dir: String,
    shared_dir: String,
    web_dir: String,
    public_url: String,
    db: sqlight.Connection,
  )
}

pub type Request {
  Request(
    method: String,
    path: List(String),
    query: List(#(String, String)),
    body: Dynamic,
    user: Dynamic,
    token: String,
  )
}

pub type Response {
  Response(status: Int, body: Json, headers: List(#(String, String)))
}

pub fn obj(fields) {
  json.object(fields)
}

pub fn reply(status, body) {
  Response(status, body, [])
}

pub fn err(status, message) {
  reply(status, obj([#("error", json.string(message))]))
}

pub fn ok() {
  reply(200, obj([#("ok", json.bool(True))]))
}

pub fn parse(text: String) -> Dynamic {
  json.parse(text, decode.dynamic) |> result.unwrap(null())
}

pub fn field(v: Dynamic, key: String) -> Dynamic {
  decode.run(v, decode.at([key], decode.dynamic)) |> result.unwrap(null())
}

pub fn has(v: Dynamic, key: String) -> Bool {
  decode.run(v, decode.at([key], decode.dynamic)) |> result.is_ok
}

pub fn s(v: Dynamic, key: String) -> String {
  decode.run(v, decode.at([key], decode.string)) |> result.unwrap("")
}

pub fn i(v: Dynamic, key: String) -> Int {
  decode.run(v, decode.at([key], decode.int)) |> result.unwrap(0)
}

pub fn b(v: Dynamic, key: String) -> Bool {
  case decode.run(field(v, key), decode.bool) {
    Ok(x) -> x
    Error(_) -> i(v, key) != 0
  }
}

pub fn array(v: Dynamic, key: String) -> List(Dynamic) {
  decode.run(field(v, key), decode.list(decode.dynamic)) |> result.unwrap([])
}

pub fn j(v: Dynamic) -> Json {
  case decode.run(v, decode.string) {
    Ok(x) -> json.string(x)
    Error(_) ->
      case decode.run(v, decode.int) {
        Ok(x) -> json.int(x)
        Error(_) ->
          case decode.run(v, decode.bool) {
            Ok(x) -> json.bool(x)
            Error(_) ->
              case decode.run(v, decode.list(decode.dynamic)) {
                Ok(x) -> json.array(x, j)
                Error(_) ->
                  case
                    decode.run(v, decode.dict(decode.string, decode.dynamic))
                  {
                    Ok(x) ->
                      json.object(
                        dict.to_list(x) |> list.map(fn(kv) { #(kv.0, j(kv.1)) }),
                      )
                    Error(_) -> json.null()
                  }
              }
          }
      }
  }
}

pub fn rows(
  ctx: Context,
  sql: String,
  params: List(sqlight.Value),
) -> List(Dynamic) {
  let assert Ok(xs) =
    sqlight.query(sql, ctx.db, params, decode.at([0], decode.string))
  list.map(xs, parse)
}

pub fn one(ctx: Context, sql, params) -> Result(Dynamic, String) {
  sqlight.query(sql, ctx.db, params, decode.at([0], decode.string))
  |> result.replace_error("Database operation failed")
  |> result.try(fn(xs) { list.first(xs) |> result.replace_error("Not found") })
  |> result.map(parse)
}

pub fn exec(ctx: Context, sql, params) -> Result(Nil, String) {
  sqlight.query(sql, ctx.db, params, decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.replace_error("Database operation failed")
}

pub fn uid(req: Request) {
  i(req.user, "id")
}

pub fn query(req: Request, key: String, fallback: String) {
  list.key_find(req.query, key) |> result.unwrap(fallback)
}

pub fn writer(repo: Dynamic) {
  list.contains(["admin", "write"], s(repo, "role"))
}

pub fn admin(repo: Dynamic) {
  s(repo, "role") == "admin"
}

pub fn valid_name(name: String) {
  regex(name, "^[a-z0-9][a-z0-9._-]{0,62}$") && name != "." && name != ".."
}

pub fn valid_path(path: String) {
  !string.starts_with(path, "/")
  && !string.contains(path, "\\")
  && !string.contains(path, "\u{0}")
  && !list.contains(string.split(path, "/"), "..")
}

pub fn valid_branch(branch: String) {
  !string.starts_with(branch, "-")
  && case
    command("git", ["check-ref-format", "--branch", branch], [], 30_000, 4096)
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn repo_path(ctx: Context, id: Int) {
  ctx.data_dir <> "/repos/" <> int.to_string(id) <> ".git"
}

pub fn git(ctx: Context, id: Int, args: List(String)) {
  command(
    "git",
    ["--git-dir=" <> repo_path(ctx, id), ..args],
    [],
    30_000,
    2_097_152,
  )
}

pub fn oid(ctx: Context, id: Int, ref: String) {
  case
    ref == "" || string.starts_with(ref, "-") || string.contains(ref, "\u{0}")
  {
    True -> Error("Invalid Git reference")
    False ->
      git(ctx, id, ["rev-parse", "--verify", ref <> "^{commit}"])
      |> result.map(string.trim)
  }
}

pub fn refresh(ctx: Context, id: Int) -> Nil {
  case
    one(
      ctx,
      "SELECT json_object('default_branch',default_branch,'default_oid',default_oid) FROM repositories WHERE id=?",
      [sqlight.int(id)],
    )
  {
    Error(_) -> Nil
    Ok(repo) ->
      case
        read_ref(
          repo_path(ctx, id),
          "refs/heads/" <> s(repo, "default_branch"),
          4,
        )
      {
        Error(_) -> Nil
        Ok(current) ->
          case current != s(repo, "default_oid") {
            False -> Nil
            True -> {
              let _ =
                exec(
                  ctx,
                  "UPDATE repositories SET default_oid=?,updated_at=? WHERE id=? AND default_oid!=?",
                  [
                    sqlight.text(current),
                    sqlight.int(now()),
                    sqlight.int(id),
                    sqlight.text(current),
                  ],
                )
              Nil
            }
          }
      }
  }
}

pub fn repo(ctx: Context, id: Int, user_id: Int) -> Result(Dynamic, String) {
  case repo_record(ctx, id, user_id) {
    Error(reason) -> Error(reason)
    Ok(_) -> {
      refresh(ctx, id)
      repo_record(ctx, id, user_id)
    }
  }
}

fn repo_record(ctx: Context, id: Int, user_id: Int) -> Result(Dynamic, String) {
  one(
    ctx,
    "SELECT json_object('id',r.id,'owner',r.owner,'name',r.name,'full_name',r.owner||'/'||r.name,'description',r.description,'visibility',r.visibility,'default_branch',r.default_branch,'require_review',json(CASE r.require_review WHEN 1 THEN 'true' ELSE 'false' END),'created_at',r.created_at,'updated_at',r.updated_at,'pinned',json(CASE WHEN EXISTS(SELECT 1 FROM pins WHERE repo_id=r.id AND user_id=?1) THEN 'true' ELSE 'false' END),'role',CASE MAX(COALESCE((SELECT CASE role WHEN 'admin' THEN 3 WHEN 'write' THEN 2 ELSE 1 END FROM namespace_members WHERE namespace=r.owner AND user_id=?1),0),COALESCE((SELECT CASE role WHEN 'admin' THEN 3 WHEN 'write' THEN 2 ELSE 1 END FROM repo_members WHERE repo_id=r.id AND user_id=?1),0)) WHEN 3 THEN 'admin' WHEN 2 THEN 'write' ELSE 'read' END) FROM repositories r WHERE r.id=?2 AND (r.visibility='public' OR EXISTS(SELECT 1 FROM namespace_members WHERE namespace=r.owner AND user_id=?1) OR EXISTS(SELECT 1 FROM repo_members WHERE repo_id=r.id AND user_id=?1))",
    [sqlight.int(user_id), sqlight.int(id)],
  )
}

@external(erlang, "gitclub_ffi", "now")
pub fn now() -> Int

@external(erlang, "gitclub_ffi", "env")
pub fn env(name: String, fallback: String) -> String

@external(erlang, "gitclub_ffi", "absolute")
pub fn absolute(path: String) -> String

@external(erlang, "gitclub_ffi", "mkdir")
pub fn mkdir(path: String) -> Nil

@external(erlang, "gitclub_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, String)

@external(erlang, "gitclub_ffi", "write_file")
pub fn write_file(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "gitclub_ffi", "delete_file")
pub fn delete_file(path: String) -> Nil

@external(erlang, "gitclub_ffi", "random")
pub fn random() -> String

@external(erlang, "gitclub_ffi", "sha256")
pub fn sha256(text: String) -> String

@external(erlang, "gitclub_ffi", "password_hash")
pub fn password_hash(password: String) -> String

@external(erlang, "gitclub_ffi", "password_check")
pub fn password_check(password: String, hash: String) -> Bool

@external(erlang, "gitclub_ffi", "regex")
pub fn regex(text: String, pattern: String) -> Bool

@external(erlang, "gitclub_ffi", "command")
pub fn command(
  executable: String,
  args: List(String),
  env: List(#(String, String)),
  timeout: Int,
  limit: Int,
) -> Result(String, String)

@external(erlang, "gitclub_ffi", "lock_repo")
pub fn lock_repo(ctx: Context, id: Int, run: fn() -> a) -> a

@external(erlang, "gitclub_ffi", "basic_token")
pub fn basic_token(header: String) -> String

@external(erlang, "gitclub_ffi", "install_hooks")
pub fn install_hooks(path: String, shared: String) -> Result(Nil, String)

@external(erlang, "gitclub_ffi", "rate_allow")
pub fn rate_allow(peer: String) -> Bool

@external(erlang, "gitclub_ffi", "null")
pub fn null() -> Dynamic

// Read native Git's files ref backend directly; avoid one subprocess per repository listing.
fn read_ref(path: String, ref: String, depth: Int) -> Result(String, String) {
  case depth <= 0 || !string.starts_with(ref, "refs/") || !valid_path(ref) {
    True -> Error("Invalid symbolic ref")
    False ->
      case read_optional(path <> "/" <> ref) {
        Error(e) -> Error(e)
        Ok(Some(raw)) -> {
          let text = string.trim(raw)
          case string.starts_with(text, "ref: ") {
            True -> read_ref(path, string.drop_start(text, 5), depth - 1)
            False ->
              case regex(text, "^([0-9a-f]{40}|[0-9a-f]{64})$") {
                True -> Ok(text)
                False -> Error("Invalid loose ref")
              }
          }
        }
        Ok(None) ->
          case read_optional(path <> "/packed-refs") {
            Error(e) -> Error(e)
            Ok(None) -> Ok("")
            Ok(Some(raw)) -> {
              let found =
                string.split(raw, "\n")
                |> list.find(fn(line) { string.ends_with(line, " " <> ref) })
              case found {
                Error(_) -> Ok("")
                Ok(line) ->
                  case string.split_once(line, " ") {
                    Ok(#(oid, _)) ->
                      case regex(oid, "^([0-9a-f]{40}|[0-9a-f]{64})$") {
                        True -> Ok(oid)
                        False -> Error("Invalid packed ref")
                      }
                    Error(_) -> Error("Invalid packed ref")
                  }
              }
            }
          }
      }
  }
}

@external(erlang, "gitclub_ffi", "read_optional")
fn read_optional(path: String) -> Result(Option(String), String)
