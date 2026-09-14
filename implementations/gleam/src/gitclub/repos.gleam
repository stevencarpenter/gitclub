import gitclub/auth
import gitclub/common as c
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import sqlight

pub fn route(ctx: c.Context, req: c.Request) {
  case req.path {
    ["api", "repos"] ->
      Some(case req.method {
        "GET" -> directory(ctx, req)
        "POST" -> create(ctx, req)
        _ -> c.err(405, "Method not allowed")
      })
    ["api", "repos", id, ..rest] -> {
      let id = int.parse(id) |> result.unwrap(0)
      case c.repo(ctx, id, c.uid(req)) {
        Error(_) -> Some(c.err(404, "Repository not found"))
        Ok(repo) ->
          case rest {
            [] ->
              Some(case req.method {
                "GET" -> c.reply(200, c.obj([#("repository", c.j(repo))]))
                "PATCH" -> update(ctx, req, repo)
                _ -> c.err(405, "Method not allowed")
              })
            ["members"] ->
              Some(case req.method == "POST" && c.admin(repo) {
                True -> auth.member(ctx, req, id, "")
                False -> c.err(403, "Repository admin role required")
              })
            ["branches"] | ["tree"] | ["blob"] | ["commits"] | ["diff"] ->
              Some(case req.method {
                "GET" -> browse(ctx, req, repo, rest)
                _ -> c.err(405, "Method not allowed")
              })
            ["git", hook] -> Some(hooks(ctx, req, repo, hook))
            _ -> None
          }
      }
    }
    _ -> None
  }
}

fn directory(ctx: c.Context, req: c.Request) {
  let group = c.query(req, "group", "")
  let allowed = case group {
    "" -> True
    _ ->
      c.one(
        ctx,
        "SELECT json_object('id',id) FROM groups WHERE id=? AND (creator_id=? OR shared=1)",
        [sqlight.text(group), sqlight.int(c.uid(req))],
      )
      |> result.is_ok
  }
  case allowed {
    False -> c.err(404, "Group not found")
    True -> {
      let repos =
        c.rows(ctx, "SELECT json_object('id',id) FROM repositories", [])
        |> list.filter_map(fn(row) { c.repo(ctx, c.i(row, "id"), c.uid(req)) })
      let q = string.lowercase(c.query(req, "q", ""))
      let owner = c.query(req, "owner", "")
      let repos =
        list.filter(repos, fn(repo) {
          string.contains(
            string.lowercase(
              c.s(repo, "full_name") <> " " <> c.s(repo, "description"),
            ),
            q,
          )
          && { owner == "" || owner == c.s(repo, "owner") }
          && {
            group == ""
            || c.one(
              ctx,
              "SELECT json_object('id',repo_id) FROM group_repos WHERE group_id=? AND repo_id=?",
              [sqlight.text(group), sqlight.int(c.i(repo, "id"))],
            )
            |> result.is_ok
          }
        })
        |> list.sort(fn(a, b) {
          case c.b(a, "pinned"), c.b(b, "pinned") {
            True, False -> order.Lt
            False, True -> order.Gt
            _, _ ->
              case int.compare(c.i(b, "updated_at"), c.i(a, "updated_at")) {
                order.Eq -> int.compare(c.i(a, "id"), c.i(b, "id"))
                x -> x
              }
          }
        })
      c.reply(200, c.obj([#("repositories", json.array(repos, c.j))]))
    }
  }
}

fn create(ctx: c.Context, req: c.Request) {
  let owner = c.s(req.body, "owner")
  let name = c.s(req.body, "name")
  let branch = case c.s(req.body, "default_branch") {
    "" -> "main"
    x -> x
  }
  let visibility = case c.s(req.body, "visibility") {
    "" -> "private"
    x -> x
  }
  case c.uid(req) == 0 {
    True -> c.err(401, "Sign in to create a repository")
    False ->
      case
        list.contains(
          ["admin", "write"],
          auth.namespace_role(ctx, owner, c.uid(req)),
        )
      {
        False -> c.err(403, "Namespace write role required")
        True ->
          case
            c.valid_name(name)
            && !string.ends_with(name, ".git")
            && c.valid_branch(branch)
            && list.contains(["public", "private"], visibility)
            && string.length(c.s(req.body, "description")) <= 4000
          {
            False ->
              c.err(
                400,
                "Invalid repository name, branch, visibility, or description",
              )
            True ->
              case
                c.one(
                  ctx,
                  "INSERT INTO repositories(owner,name,description,visibility,default_branch,created_at,updated_at) VALUES(?,?,?,?,?,?,?) RETURNING json_object('id',id)",
                  [
                    sqlight.text(owner),
                    sqlight.text(name),
                    sqlight.text(c.s(req.body, "description")),
                    sqlight.text(visibility),
                    sqlight.text(branch),
                    sqlight.int(c.now()),
                    sqlight.int(c.now()),
                  ],
                )
              {
                Error(_) -> c.err(409, "Repository already exists")
                Ok(row) -> {
                  let id = c.i(row, "id")
                  let initialized =
                    c.command(
                      "git",
                      [
                        "init",
                        "--bare",
                        "--initial-branch=" <> branch,
                        c.repo_path(ctx, id),
                      ],
                      [],
                      30_000,
                      8192,
                    )
                  let hooks =
                    c.install_hooks(c.repo_path(ctx, id), ctx.shared_dir)
                  let config =
                    c.git(ctx, id, ["config", "http.receivepack", "true"])
                    |> result.try(fn(_) {
                      c.git(ctx, id, [
                        "config",
                        "transfer.hideRefs",
                        "refs/gitclub/",
                      ])
                    })
                  case initialized, hooks, config {
                    Ok(_), Ok(_), Ok(_) ->
                      case c.repo(ctx, id, c.uid(req)) {
                        Ok(repo) ->
                          c.reply(201, c.obj([#("repository", c.j(repo))]))
                        Error(_) ->
                          c.err(500, "Repository initialization failed")
                      }
                    _, _, _ -> {
                      let _ =
                        c.exec(ctx, "DELETE FROM repositories WHERE id=?", [
                          sqlight.int(id),
                        ])
                      c.err(500, "Repository initialization failed")
                    }
                  }
                }
              }
          }
      }
  }
}

fn update(ctx: c.Context, req: c.Request, repo: Dynamic) {
  case c.admin(repo) {
    False -> c.err(403, "Repository admin role required")
    True -> {
      let desc = case c.has(req.body, "description") {
        True -> c.s(req.body, "description")
        False -> c.s(repo, "description")
      }
      let vis = case c.has(req.body, "visibility") {
        True -> c.s(req.body, "visibility")
        False -> c.s(repo, "visibility")
      }
      let branch = case c.has(req.body, "default_branch") {
        True -> c.s(req.body, "default_branch")
        False -> c.s(repo, "default_branch")
      }
      let review = case c.has(req.body, "require_review") {
        True -> c.b(req.body, "require_review")
        False -> c.b(repo, "require_review")
      }
      case
        c.valid_branch(branch)
        && list.contains(["public", "private"], vis)
        && string.length(desc) <= 4000
        && {
          !c.has(req.body, "require_review")
          || decode.run(c.field(req.body, "require_review"), decode.bool)
          |> result.is_ok
        }
      {
        False -> c.err(400, "Invalid branch, visibility, or description")
        True -> {
          let id = c.i(repo, "id")
          let old = c.s(repo, "default_branch")
          let changed = branch != old
          let head = case changed {
            True ->
              c.git(ctx, id, ["symbolic-ref", "HEAD", "refs/heads/" <> branch])
            False -> Ok("")
          }
          case head {
            Error(_) ->
              c.err(
                500,
                "Default branch was not changed; check repository storage",
              )
            Ok(_) ->
              case
                c.exec(
                  ctx,
                  "UPDATE repositories SET description=?,visibility=?,default_branch=?,require_review=?,updated_at=CASE WHEN default_branch!=? THEN ? ELSE updated_at END WHERE id=?",
                  [
                    sqlight.text(desc),
                    sqlight.text(vis),
                    sqlight.text(branch),
                    sqlight.bool(review),
                    sqlight.text(branch),
                    sqlight.int(c.now()),
                    sqlight.int(id),
                  ],
                )
              {
                Error(_) -> {
                  let restored = case changed {
                    True ->
                      c.git(ctx, id, [
                        "symbolic-ref",
                        "HEAD",
                        "refs/heads/" <> old,
                      ])
                    False -> Ok("")
                  }
                  case restored {
                    Ok(_) ->
                      c.err(
                        500,
                        "Repository settings were not saved; check database storage",
                      )
                    Error(_) ->
                      c.err(
                        500,
                        "Repository HEAD needs repair after a storage failure",
                      )
                  }
                }
                Ok(_) -> {
                  let assert Ok(repo) = c.repo(ctx, id, c.uid(req))
                  c.reply(200, c.obj([#("repository", c.j(repo))]))
                }
              }
          }
        }
      }
    }
  }
}

fn browse(ctx: c.Context, req: c.Request, repo: Dynamic, kind: List(String)) {
  let id = c.i(repo, "id")
  let ref = c.query(req, "ref", c.s(repo, "default_branch"))
  let path = c.query(req, "path", "")
  case kind {
    ["branches"] -> {
      let branches =
        c.git(ctx, id, [
          "for-each-ref",
          "--format=%(refname:short)\t%(objectname)",
          "refs/heads/",
        ])
        |> result.unwrap("")
        |> string.trim
        |> string.split("\n")
        |> list.filter_map(fn(line) {
          case string.split(line, "\t") {
            [name, oid] ->
              Ok(
                c.obj([#("name", json.string(name)), #("oid", json.string(oid))]),
              )
            _ -> Error(Nil)
          }
        })
      c.reply(
        200,
        c.obj([
          #("branches", json.preprocessed_array(branches)),
          #("default_branch", json.string(c.s(repo, "default_branch"))),
        ]),
      )
    }
    ["diff"] -> {
      let base = c.query(req, "base", c.s(repo, "default_branch"))
      let head = c.query(req, "head", "")
      case c.oid(ctx, id, base), c.oid(ctx, id, head) {
        Ok(base), Ok(head) ->
          case
            git_diff(c.repo_path(ctx, id), [
              "diff",
              "--no-ext-diff",
              "--no-textconv",
              base <> "..." <> head,
              "--",
            ])
          {
            Ok(#(diff, truncated)) ->
              c.reply(
                200,
                c.obj([
                  #("diff", json.string(string.slice(diff, 0, 1_048_576))),
                  #("base_oid", json.string(base)),
                  #("head_oid", json.string(head)),
                  #("truncated", json.bool(truncated)),
                ]),
              )
            Error(_) -> c.err(400, "Cannot compute diff")
          }
        _, _ -> c.err(400, "Invalid base or head reference")
      }
    }
    _ ->
      case c.oid(ctx, id, ref) {
        Error(_) ->
          case
            ref == c.s(repo, "default_branch")
            && c.one(
              ctx,
              "SELECT json_object('oid',default_oid) FROM repositories WHERE id=?",
              [sqlight.int(id)],
            )
            |> result.map(fn(row) { c.s(row, "oid") == "" })
            |> result.unwrap(False)
          {
            False -> c.err(404, "Reference not found")
            True ->
              case kind {
                ["tree"] ->
                  c.reply(
                    200,
                    c.obj([
                      #("entries", json.preprocessed_array([])),
                      #("ref", json.string(ref)),
                    ]),
                  )
                ["commits"] ->
                  c.reply(
                    200,
                    c.obj([#("commits", json.preprocessed_array([]))]),
                  )
                _ -> c.err(404, "Reference not found")
              }
          }
        Ok(oid) ->
          case c.valid_path(path) {
            False -> c.err(400, "Invalid file path")
            True ->
              case kind {
                ["tree"] -> {
                  let tree =
                    oid
                    <> case path {
                      "" -> ""
                      _ -> ":" <> path
                    }
                  case c.git(ctx, id, ["ls-tree", "-l", "-z", tree]) {
                    Error(_) -> c.err(404, "Directory not found")
                    Ok(raw) -> {
                      let entries =
                        string.split(raw, "\u{0}")
                        |> list.filter_map(fn(line) {
                          case string.split(line, "\t") {
                            [meta, name] -> {
                              let fields =
                                string.split(meta, " ")
                                |> list.filter(fn(x) { x != "" })
                              case fields {
                                [_, kind, _, size] ->
                                  Ok(
                                    c.obj([
                                      #("name", json.string(name)),
                                      #(
                                        "path",
                                        json.string(case path {
                                          "" -> name
                                          _ -> path <> "/" <> name
                                        }),
                                      ),
                                      #(
                                        "type",
                                        json.string(case kind {
                                          "tree" -> "directory"
                                          _ -> "file"
                                        }),
                                      ),
                                      #(
                                        "size",
                                        json.int(
                                          int.parse(size) |> result.unwrap(0),
                                        ),
                                      ),
                                    ]),
                                  )
                                _ -> Error(Nil)
                              }
                            }
                            _ -> Error(Nil)
                          }
                        })
                      c.reply(
                        200,
                        c.obj([
                          #("entries", json.preprocessed_array(entries)),
                          #("ref", json.string(ref)),
                        ]),
                      )
                    }
                  }
                }
                ["blob"] -> {
                  case c.git(ctx, id, ["cat-file", "-s", oid <> ":" <> path]) {
                    Error(_) -> c.err(404, "File not found")
                    Ok(size_text) -> {
                      let size =
                        int.parse(string.trim(size_text)) |> result.unwrap(0)
                      case
                        git_blob(c.repo_path(ctx, id), [
                          "show",
                          oid <> ":" <> path,
                        ])
                      {
                        Error(_) -> c.err(404, "File not found")
                        Ok(#(content, truncated)) -> {
                          let #(content, binary) = blob_text(content, truncated)
                          c.reply(
                            200,
                            c.obj([
                              #("path", json.string(path)),
                              #(
                                "content",
                                json.string(case binary {
                                  True -> ""
                                  False -> content
                                }),
                              ),
                              #("size", json.int(size)),
                              #("binary", json.bool(binary)),
                              #("truncated", json.bool(truncated)),
                            ]),
                          )
                        }
                      }
                    }
                  }
                }
                ["commits"] -> {
                  let commits =
                    c.git(ctx, id, [
                      "log",
                      "-50",
                      "--format=%H%x00%h%x00%s%x00%an%x00%aI",
                      oid,
                      "--",
                    ])
                    |> result.unwrap("")
                    |> string.trim
                    |> string.split("\n")
                    |> list.filter_map(fn(line) {
                      case string.split(line, "\u{0}") {
                        [oid, short, subject, author, date] ->
                          Ok(
                            c.obj([
                              #("oid", json.string(oid)),
                              #("short_oid", json.string(short)),
                              #("subject", json.string(subject)),
                              #("author", json.string(author)),
                              #("date", json.string(date)),
                            ]),
                          )
                        _ -> Error(Nil)
                      }
                    })
                  c.reply(
                    200,
                    c.obj([#("commits", json.preprocessed_array(commits))]),
                  )
                }
                _ -> c.err(404, "Route not found")
              }
          }
      }
  }
}

fn hooks(ctx: c.Context, req: c.Request, repo: Dynamic, hook: String) {
  case req.method == "POST" && c.writer(repo) {
    False -> c.err(403, "Write access required")
    True ->
      case hook {
        "post-receive" -> {
          c.refresh(ctx, c.i(repo, "id"))
          c.ok()
        }
        "pre-receive" -> {
          let updates = c.array(req.body, "updates")
          let blocked =
            list.any(updates, fn(update) {
              string.starts_with(c.s(update, "ref"), "refs/replace/")
              || string.starts_with(c.s(update, "ref"), "refs/gitclub/")
            })
            || list.any(updates, fn(update) {
              let old = c.s(update, "old")
              let new = c.s(update, "new")
              let ref = c.s(update, "ref")
              case
                ref == "refs/heads/" <> c.s(repo, "default_branch")
                && old != "0000000000000000000000000000000000000000"
              {
                False -> False
                True ->
                  c.b(repo, "require_review")
                  || new == "0000000000000000000000000000000000000000"
                  || {
                    let quarantine = c.s(req.body, "quarantine_path")
                    let env = case
                      valid_quarantine(
                        c.repo_path(ctx, c.i(repo, "id")),
                        quarantine,
                      )
                    {
                      True -> [
                        #("GIT_OBJECT_DIRECTORY", quarantine),
                        #(
                          "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                          c.repo_path(ctx, c.i(repo, "id")) <> "/objects",
                        ),
                      ]
                      False -> []
                    }
                    c.command(
                      "git",
                      [
                        "--git-dir=" <> c.repo_path(ctx, c.i(repo, "id")),
                        "merge-base",
                        "--is-ancestor",
                        old,
                        new,
                      ],
                      env,
                      30_000,
                      4096,
                    )
                    |> result.is_error
                  }
              }
            })
          case blocked {
            True ->
              c.err(
                403,
                "Default branch rejects direct protected, non-fast-forward, or deletion updates; use a reviewed pull request",
              )
            False -> c.ok()
          }
        }
        _ -> c.err(404, "Hook not found")
      }
  }
}

@external(erlang, "gitclub_ffi", "blob_text")
fn blob_text(text: String, truncated: Bool) -> #(String, Bool)

@external(erlang, "gitclub_ffi", "valid_quarantine")
fn valid_quarantine(repo: String, path: String) -> Bool

@external(erlang, "gitclub_input_ffi", "git_diff")
fn git_diff(path: String, args: List(String)) -> Result(#(String, Bool), String)

@external(erlang, "gitclub_input_ffi", "git_blob")
fn git_blob(path: String, args: List(String)) -> Result(#(String, Bool), String)
