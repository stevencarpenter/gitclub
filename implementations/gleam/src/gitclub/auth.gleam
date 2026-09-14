import gitclub/common as c
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import sqlight

pub fn authenticate(ctx: c.Context, token: String) {
  c.one(
    ctx,
    "SELECT json_object('id',u.id,'username',u.username) FROM tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=? AND (t.expires_at=0 OR t.expires_at>?)",
    [sqlight.text(c.sha256(token)), sqlight.int(c.now())],
  )
  |> result.unwrap(c.null())
}

pub fn token_from(req) {
  let auth = request.get_header(req, "authorization") |> result.unwrap("")
  case string.starts_with(auth, "Bearer ") {
    True -> string.drop_start(auth, 7)
    False ->
      case string.starts_with(auth, "Basic ") {
        True -> c.basic_token(auth)
        False -> {
          request.get_header(req, "cookie")
          |> result.unwrap("")
          |> string.split(";")
          |> list.map(string.trim)
          |> list.find(fn(x) { string.starts_with(x, "gc_session=") })
          |> result.unwrap("")
          |> string.drop_start(11)
        }
      }
  }
}

pub fn token(ctx: c.Context, user_id: Int, expires: Int) {
  let _ =
    c.exec(ctx, "DELETE FROM tokens WHERE expires_at>0 AND expires_at<=?", [
      sqlight.int(c.now()),
    ])
  let raw = c.random()
  let assert Ok(_) =
    c.exec(
      ctx,
      "INSERT INTO tokens(token_hash,user_id,created_at,expires_at) VALUES(?,?,?,?)",
      [
        sqlight.text(c.sha256(raw)),
        sqlight.int(user_id),
        sqlight.int(c.now()),
        sqlight.int(expires),
      ],
    )
  raw
}

fn cookie(ctx: c.Context, token: String) {
  "gc_session="
  <> token
  <> "; HttpOnly; SameSite=Strict; Path=/"
  <> case string.starts_with(ctx.public_url, "https://") {
    True -> "; Secure"
    False -> ""
  }
}

fn signin(ctx, user, status) {
  let raw = token(ctx, c.i(user, "id"), 0)
  c.Response(
    status,
    c.obj([#("user", c.j(user)), #("token", json.string(raw))]),
    [#("set-cookie", cookie(ctx, raw))],
  )
}

pub fn route(ctx: c.Context, req: c.Request) {
  case req.method, req.path {
    "GET", ["api", "session"] ->
      Some(c.reply(200, c.obj([#("user", c.j(req.user))])))
    "POST", ["api", "auth", "register"] -> Some(register(ctx, req))
    "POST", ["api", "auth", "login"] -> Some(login(ctx, req))
    "POST", ["api", "auth", "logout"] -> {
      let _ =
        c.exec(ctx, "DELETE FROM tokens WHERE token_hash=?", [
          sqlight.text(c.sha256(req.token)),
        ])
      Some(
        c.Response(200, c.obj([#("ok", json.bool(True))]), [
          #("set-cookie", cookie(ctx, "") <> "; Max-Age=0"),
        ]),
      )
    }
    _, ["api", "users"]
    | _, ["api", "namespaces", ..]
    | _, ["api", "ssh-keys", ..]
    ->
      Some(case c.uid(req) {
        0 -> c.err(401, "Sign in to continue")
        _ -> authenticated(ctx, req)
      })
    _, ["api", "ssh", ..] -> Some(ssh(ctx, req))
    _, _ -> None
  }
}

fn register(ctx: c.Context, req: c.Request) {
  let name = c.s(req.body, "username")
  let password = c.s(req.body, "password")
  case
    c.valid_name(name)
    && string.byte_size(password) >= 12
    && string.byte_size(password) <= 256
  {
    False ->
      c.err(400, "Use a lowercase username and a password of 12 to 256 bytes")
    True ->
      case
        c.one(ctx, "SELECT json_object('id',id) FROM users WHERE username=?", [
          sqlight.text(name),
        ])
      {
        Ok(_) -> c.err(409, "Username already exists")
        Error(_) -> {
          let hash = c.password_hash(password)
          let _ = sqlight.exec("BEGIN IMMEDIATE", ctx.db)
          let user =
            c.one(
              ctx,
              "INSERT INTO users(username,password_hash,created_at) VALUES(?,?,?) RETURNING json_object('id',id,'username',username)",
              [sqlight.text(name), sqlight.text(hash), sqlight.int(c.now())],
            )
          case user {
            Error(_) -> {
              let _ = sqlight.exec("ROLLBACK", ctx.db)
              c.err(409, "Username unavailable")
            }
            Ok(user) -> {
              let a =
                c.exec(
                  ctx,
                  "INSERT INTO namespaces(name,kind) VALUES(?,'user')",
                  [sqlight.text(name)],
                )
              let b =
                c.exec(
                  ctx,
                  "INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,'admin')",
                  [sqlight.text(name), sqlight.int(c.i(user, "id"))],
                )
              case a, b {
                Ok(_), Ok(_) -> {
                  let _ = sqlight.exec("COMMIT", ctx.db)
                  signin(ctx, user, 201)
                }
                _, _ -> {
                  let _ = sqlight.exec("ROLLBACK", ctx.db)
                  c.err(409, "Namespace unavailable")
                }
              }
            }
          }
        }
      }
  }
}

fn login(ctx: c.Context, req: c.Request) {
  let user =
    c.one(
      ctx,
      "SELECT json_object('id',id,'username',username,'password_hash',password_hash) FROM users WHERE username=?",
      [sqlight.text(c.s(req.body, "username"))],
    )
  case user {
    Ok(user) ->
      case
        c.password_check(c.s(req.body, "password"), c.s(user, "password_hash"))
      {
        True ->
          signin(
            ctx,
            c.parse(
              json.to_string(
                c.obj([
                  #("id", json.int(c.i(user, "id"))),
                  #("username", json.string(c.s(user, "username"))),
                ]),
              ),
            ),
            200,
          )
        False -> c.err(401, "Invalid username or password")
      }
    Error(_) -> {
      let _ = c.password_hash("dummy password timing")
      c.err(401, "Invalid username or password")
    }
  }
}

fn authenticated(ctx: c.Context, req: c.Request) {
  case req.method, req.path {
    "GET", ["api", "users"] ->
      c.reply(
        200,
        c.obj([
          #(
            "users",
            json.array(
              c.rows(
                ctx,
                "SELECT json_object('id',id,'username',username) FROM users WHERE username LIKE ? ORDER BY username LIMIT 100",
                [sqlight.text("%" <> c.query(req, "q", "") <> "%")],
              ),
              c.j,
            ),
          ),
        ]),
      )
    "GET", ["api", "namespaces"] ->
      c.reply(
        200,
        c.obj([
          #(
            "namespaces",
            json.array(
              c.rows(
                ctx,
                "SELECT json_object('name',n.name,'kind',n.kind,'role',m.role) FROM namespaces n JOIN namespace_members m ON m.namespace=n.name WHERE m.user_id=? ORDER BY n.name",
                [sqlight.int(c.uid(req))],
              ),
              c.j,
            ),
          ),
        ]),
      )
    "POST", ["api", "namespaces"] -> {
      let name = c.s(req.body, "name")
      case c.valid_name(name) {
        False -> c.err(400, "Invalid namespace name")
        True ->
          case
            c.exec(
              ctx,
              "INSERT INTO namespaces(name,kind) VALUES(?,'organization')",
              [sqlight.text(name)],
            )
          {
            Error(_) -> c.err(409, "Namespace already exists")
            Ok(_) -> {
              let _ =
                c.exec(
                  ctx,
                  "INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,'admin')",
                  [sqlight.text(name), sqlight.int(c.uid(req))],
                )
              c.reply(
                201,
                c.obj([
                  #(
                    "namespace",
                    c.obj([
                      #("name", json.string(name)),
                      #("kind", json.string("organization")),
                      #("role", json.string("admin")),
                    ]),
                  ),
                ]),
              )
            }
          }
      }
    }
    "POST", ["api", "namespaces", name, "members"] -> {
      case namespace_role(ctx, name, c.uid(req)) {
        "admin" -> member(ctx, req, 0, name)
        _ -> c.err(403, "Namespace admin role required")
      }
    }
    "GET", ["api", "ssh-keys"] ->
      c.reply(
        200,
        c.obj([
          #(
            "ssh_keys",
            json.array(
              c.rows(
                ctx,
                "SELECT json_object('id',id,'title',title,'public_key',public_key,'created_at',created_at) FROM ssh_keys WHERE user_id=? ORDER BY id",
                [sqlight.int(c.uid(req))],
              ),
              c.j,
            ),
          ),
        ]),
      )
    "POST", ["api", "ssh-keys"] -> add_key(ctx, req)
    "DELETE", ["api", "ssh-keys", key] -> {
      case
        c.one(
          ctx,
          "DELETE FROM ssh_keys WHERE id=? AND user_id=? RETURNING json_object('id',id)",
          [
            sqlight.int(int.parse(key) |> result.unwrap(0)),
            sqlight.int(c.uid(req)),
          ],
        )
      {
        Ok(_) -> c.ok()
        Error(_) -> c.err(404, "SSH key not found")
      }
    }
    _, _ -> c.err(404, "Route not found")
  }
}

pub fn namespace_role(ctx, name, uid) {
  c.one(
    ctx,
    "SELECT json_object('role',role) FROM namespace_members WHERE namespace=? AND user_id=?",
    [sqlight.text(name), sqlight.int(uid)],
  )
  |> result.map(fn(x) { c.s(x, "role") })
  |> result.unwrap("")
}

pub fn member(ctx: c.Context, req: c.Request, repo_id, namespace) {
  let role = c.s(req.body, "role")
  case list.contains(["read", "write", "admin"], role) {
    False -> c.err(400, "Role must be read, write, or admin")
    True ->
      case
        c.one(ctx, "SELECT json_object('id',id) FROM users WHERE username=?", [
          sqlight.text(c.s(req.body, "username")),
        ])
      {
        Error(_) -> c.err(404, "User not found")
        Ok(user) -> {
          let params = [sqlight.int(c.i(user, "id")), sqlight.text(role)]
          let operation = case repo_id {
            0 ->
              c.exec(
                ctx,
                "INSERT INTO namespace_members(namespace,user_id,role) VALUES(?,?,?) ON CONFLICT(namespace,user_id) DO UPDATE SET role=excluded.role",
                [sqlight.text(namespace), ..params],
              )
            _ ->
              c.exec(
                ctx,
                "INSERT INTO repo_members(repo_id,user_id,role) VALUES(?,?,?) ON CONFLICT(repo_id,user_id) DO UPDATE SET role=excluded.role",
                [sqlight.int(repo_id), ..params],
              )
          }
          case operation {
            Ok(_) -> c.ok()
            Error(_) -> c.err(409, "Could not change membership")
          }
        }
      }
  }
}

fn add_key(ctx: c.Context, req: c.Request) {
  let key = string.trim(c.s(req.body, "public_key"))
  let title = c.s(req.body, "title")
  case
    c.regex(
      key,
      "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( [^\\r\\n]+)?$",
    )
    && !string.contains(key, "\n")
    && title != ""
    && string.length(title) <= 100
  {
    False ->
      c.err(400, "Provide a title and an OpenSSH public key without options")
    True -> {
      let key = string.split(key, " ") |> list.take(2) |> string.join(" ")
      let temp = ctx.data_dir <> "/key-" <> c.random()
      let _ = c.write_file(temp, key <> "\n")
      let valid = c.command("ssh-keygen", ["-lf", temp], [], 30_000, 8192)
      c.delete_file(temp)
      case valid {
        Error(_) -> c.err(400, "Invalid SSH public key")
        Ok(_) ->
          case
            c.one(
              ctx,
              "INSERT INTO ssh_keys(user_id,title,public_key,created_at) VALUES(?,?,?,?) RETURNING json_object('id',id,'title',title,'public_key',public_key,'created_at',created_at)",
              [
                sqlight.int(c.uid(req)),
                sqlight.text(title),
                sqlight.text(key),
                sqlight.int(c.now()),
              ],
            )
          {
            Ok(key) -> c.reply(201, c.obj([#("ssh_key", c.j(key))]))
            Error(_) -> c.err(409, "SSH key already registered")
          }
      }
    }
  }
}

fn ssh(ctx: c.Context, req: c.Request) {
  let secret = c.env("GITCLUB_SSH_SECRET", "")
  case secret != "" && req.token == secret {
    False -> c.err(404, "Route not found")
    True ->
      case req.method, req.path {
        "GET", ["api", "ssh", "authorized-keys"] ->
          c.reply(
            200,
            c.obj([
              #(
                "keys",
                json.array(
                  c.rows(
                    ctx,
                    "SELECT json_object('id',id,'public_key',public_key) FROM ssh_keys",
                    [],
                  ),
                  c.j,
                ),
              ),
            ]),
          )
        "POST", ["api", "ssh", "authorize"] -> {
          let cmd = c.s(req.body, "command")
          let parts = string.split(cmd, " ")
          case parts {
            [operation, quoted] -> {
              let path = string.drop_end(string.drop_start(quoted, 1), 1)
              case
                list.contains(
                  ["git-upload-pack", "git-receive-pack"],
                  operation,
                )
                && string.starts_with(quoted, "'")
                && string.ends_with(quoted, "'")
                && string.ends_with(path, ".git")
              {
                False -> c.err(400, "Unsupported SSH Git command")
                True ->
                  case string.split(string.drop_end(path, 4), "/") {
                    [owner, name] -> {
                      let found =
                        c.one(
                          ctx,
                          "SELECT json_object('repo_id',r.id,'user_id',k.user_id) FROM repositories r,ssh_keys k WHERE r.owner=? AND r.name=? AND k.id=?",
                          [
                            sqlight.text(owner),
                            sqlight.text(name),
                            sqlight.int(c.i(req.body, "key_id")),
                          ],
                        )
                      case found {
                        Error(_) ->
                          c.err(404, "Repository or SSH key not found")
                        Ok(found) ->
                          case
                            c.repo(
                              ctx,
                              c.i(found, "repo_id"),
                              c.i(found, "user_id"),
                            )
                          {
                            Error(_) -> c.err(404, "Repository not found")
                            Ok(repo) ->
                              case
                                operation == "git-receive-pack"
                                && !c.writer(repo)
                              {
                                True -> c.err(403, "Write access required")
                                False ->
                                  c.reply(
                                    200,
                                    c.obj([
                                      #("repo_id", json.int(c.i(repo, "id"))),
                                      #(
                                        "user_id",
                                        json.int(c.i(found, "user_id")),
                                      ),
                                      #(
                                        "token",
                                        json.string(token(
                                          ctx,
                                          c.i(found, "user_id"),
                                          c.now() + 180_000,
                                        )),
                                      ),
                                      #(
                                        "repository_path",
                                        json.string(c.repo_path(
                                          ctx,
                                          c.i(repo, "id"),
                                        )),
                                      ),
                                      #("operation", json.string(operation)),
                                      #(
                                        "internal_url",
                                        json.string(c.env(
                                          "GITCLUB_INTERNAL_URL",
                                          ctx.public_url,
                                        )),
                                      ),
                                    ]),
                                  )
                              }
                          }
                      }
                    }
                    _ -> c.err(400, "Invalid repository path")
                  }
              }
            }
            _ -> c.err(400, "Unsupported SSH Git command")
          }
        }
        _, _ -> c.err(404, "Route not found")
      }
  }
}
