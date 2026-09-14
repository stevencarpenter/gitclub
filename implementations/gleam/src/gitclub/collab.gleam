import gitclub/common as c
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight as db

pub fn route(ctx: c.Context, req: c.Request) -> Option(c.Response) {
  case req.path {
    ["api", "groups", ..rest] -> Some(groups(ctx, req, rest))
    ["api", "repos", id, "pin"] ->
      Some(with_repo(ctx, req, id, fn(repo) { pin(ctx, req, repo) }))
    ["api", "repos", id, "issues", ..rest] ->
      Some(
        with_repo(ctx, req, id, fn(repo) {
          discussions(ctx, req, repo, "issue", rest)
        }),
      )
    ["api", "repos", id, "pulls", ..rest] ->
      Some(
        with_repo(ctx, req, id, fn(repo) {
          discussions(ctx, req, repo, "pull", rest)
        }),
      )
    _ -> None
  }
}

fn with_repo(ctx: c.Context, req: c.Request, id, next) {
  case req.method != "GET" && c.uid(req) == 0 {
    True -> c.err(401, "Sign in to change repositories")
    False ->
      case int.parse(id) {
        Error(_) -> c.err(404, "Repository not found")
        Ok(id) ->
          case c.repo(ctx, id, c.uid(req)) {
            Error(_) -> c.err(404, "Repository not found")
            Ok(repo) -> next(repo)
          }
      }
  }
}

fn success(out: Result(Nil, String)) {
  case out {
    Ok(_) -> c.ok()
    Error(_) -> c.err(500, "Database write failed")
  }
}

fn pin(ctx: c.Context, req: c.Request, repo) {
  case
    req.method,
    c.uid(req) > 0,
    decode.run(c.field(req.body, "pinned"), decode.bool)
  {
    "POST", False, _ -> c.err(401, "Sign in to pin repositories")
    "POST", True, Ok(pinned) -> {
      let query = case pinned {
        True -> "INSERT OR IGNORE INTO pins(repo_id,user_id) VALUES (?,?)"
        False -> "DELETE FROM pins WHERE repo_id=? AND user_id=?"
      }
      success(c.exec(ctx, query, [db.int(c.i(repo, "id")), db.int(c.uid(req))]))
    }
    "POST", _, _ -> c.err(400, "pinned must be a boolean")
    _, _, _ -> c.err(405, "Method not allowed")
  }
}

const group_sql = "SELECT json_object('id',id,'name',name,'creator_id',creator_id,'shared',json(CASE shared WHEN 1 THEN 'true' ELSE 'false' END)) FROM groups "

fn group_json(ctx: c.Context, req: c.Request, group) {
  let ids =
    c.rows(
      ctx,
      "SELECT json_object('id',repo_id) FROM group_repos WHERE group_id=? ORDER BY repo_id",
      [db.int(c.i(group, "id"))],
    )
    |> list.filter(fn(row) {
      c.repo(ctx, c.i(row, "id"), c.uid(req)) |> result.is_ok
    })
    |> list.map(fn(row) { json.int(c.i(row, "id")) })
  c.obj([
    #("id", json.int(c.i(group, "id"))),
    #("name", json.string(c.s(group, "name"))),
    #("creator_id", json.int(c.i(group, "creator_id"))),
    #("shared", json.bool(c.b(group, "shared"))),
    #("repo_ids", json.array(ids, fn(x) { x })),
  ])
}

fn groups(ctx: c.Context, req: c.Request, rest) {
  case c.uid(req) > 0 {
    False -> c.err(401, "Sign in to use repository groups")
    True ->
      case req.method, rest {
        "GET", [] ->
          c.reply(
            200,
            c.obj([
              #(
                "groups",
                json.array(
                  c.rows(
                    ctx,
                    group_sql
                      <> "WHERE creator_id=? OR shared=1 ORDER BY name,id",
                    [db.int(c.uid(req))],
                  ),
                  fn(g) { group_json(ctx, req, g) },
                ),
              ),
            ]),
          )
        "POST", [] -> create_group(ctx, req)
        _, [id] ->
          case int.parse(id) {
            Error(_) -> c.err(404, "Group not found")
            Ok(id) ->
              case
                c.one(
                  ctx,
                  group_sql <> "WHERE id=? AND (creator_id=? OR shared=1)",
                  [db.int(id), db.int(c.uid(req))],
                )
              {
                Error(_) -> c.err(404, "Group not found")
                Ok(group) ->
                  case req.method {
                    "GET" ->
                      c.reply(
                        200,
                        c.obj([#("group", group_json(ctx, req, group))]),
                      )
                    _ ->
                      case c.i(group, "creator_id") == c.uid(req) {
                        False ->
                          c.err(
                            403,
                            "Only the group creator may change this group",
                          )
                        True ->
                          case req.method {
                            "DELETE" ->
                              success(
                                c.exec(ctx, "DELETE FROM groups WHERE id=?", [
                                  db.int(id),
                                ]),
                              )
                            "PATCH" -> update_group(ctx, req, group)
                            _ -> c.err(405, "Method not allowed")
                          }
                      }
                  }
              }
          }
        _, _ -> c.err(404, "Route not found")
      }
  }
}

fn valid_name(name) {
  string.length(string.trim(name)) > 0 && string.length(name) <= 80
}

fn shared_valid(body) {
  !c.has(body, "shared")
  || result.is_ok(decode.run(c.field(body, "shared"), decode.bool))
}

fn create_group(ctx: c.Context, req: c.Request) {
  let name = string.trim(c.s(req.body, "name"))
  case valid_name(name) && shared_valid(req.body) {
    False ->
      c.err(
        400,
        "Provide a name of 1 to 80 characters and a boolean shared value",
      )
    True ->
      case
        c.one(
          ctx,
          "INSERT INTO groups(name,creator_id,shared,created_at) VALUES (?,?,?,?) RETURNING json_object('id',id,'name',name,'creator_id',creator_id,'shared',json(CASE shared WHEN 1 THEN 'true' ELSE 'false' END))",
          [
            db.text(name),
            db.int(c.uid(req)),
            db.bool(c.b(req.body, "shared")),
            db.int(c.now()),
          ],
        )
      {
        Error(_) -> c.err(500, "Could not create group")
        Ok(group) ->
          c.reply(201, c.obj([#("group", group_json(ctx, req, group))]))
      }
  }
}

fn new_s(body, old, key) {
  case c.has(body, key) {
    True -> c.s(body, key)
    False -> c.s(old, key)
  }
}

fn update_group(ctx: c.Context, req: c.Request, group) {
  let name = string.trim(new_s(req.body, group, "name"))
  let shared = case c.has(req.body, "shared") {
    True -> c.b(req.body, "shared")
    False -> c.b(group, "shared")
  }
  let ids = case c.has(req.body, "repo_ids") {
    True -> decode.run(c.field(req.body, "repo_ids"), decode.list(decode.int))
    False ->
      Ok(
        c.rows(
          ctx,
          "SELECT json_object('id',repo_id) FROM group_repos WHERE group_id=?",
          [db.int(c.i(group, "id"))],
        )
        |> list.map(fn(r) { c.i(r, "id") }),
      )
  }
  case valid_name(name) && shared_valid(req.body), ids {
    False, _ ->
      c.err(
        400,
        "Provide a name of 1 to 80 characters and a boolean shared value",
      )
    _, Error(_) -> c.err(400, "repo_ids must be an array of repository IDs")
    True, Ok(ids) ->
      case
        list.all(ids, fn(id) { c.repo(ctx, id, c.uid(req)) |> result.is_ok })
      {
        False -> c.err(404, "A repository in this group is inaccessible")
        True -> {
          let changed = {
            use _ <- result.try(c.exec(ctx, "BEGIN IMMEDIATE", []))
            use _ <- result.try(
              c.exec(ctx, "UPDATE groups SET name=?,shared=? WHERE id=?", [
                db.text(name),
                db.bool(shared),
                db.int(c.i(group, "id")),
              ]),
            )
            use _ <- result.try(
              c.exec(ctx, "DELETE FROM group_repos WHERE group_id=?", [
                db.int(c.i(group, "id")),
              ]),
            )
            use _ <- result.try(
              list.try_each(list.unique(ids), fn(id) {
                c.exec(
                  ctx,
                  "INSERT INTO group_repos(group_id,repo_id) VALUES (?,?)",
                  [db.int(c.i(group, "id")), db.int(id)],
                )
              }),
            )
            c.exec(ctx, "COMMIT", [])
          }
          case changed {
            Error(_) -> {
              let _ = c.exec(ctx, "ROLLBACK", [])
              c.err(500, "Could not update group")
            }
            Ok(_) ->
              case
                c.one(ctx, group_sql <> "WHERE id=?", [db.int(c.i(group, "id"))])
              {
                Ok(g) ->
                  c.reply(200, c.obj([#("group", group_json(ctx, req, g))]))
                Error(_) -> c.err(500, "Could not read updated group")
              }
          }
        }
      }
  }
}

fn table(kind) {
  case kind {
    "issue" -> "issues"
    _ -> "pull_requests"
  }
}

fn resource(kind) {
  case kind {
    "issue" -> "issue"
    _ -> "pull"
  }
}

fn collection(kind) {
  case kind {
    "issue" -> "issues"
    _ -> "pulls"
  }
}

fn item_sql(kind) {
  let extra = case kind {
    "issue" -> ""
    _ ->
      ",'base_branch',t.base_branch,'head_branch',t.head_branch,'merged_oid',t.merged_oid"
  }
  "SELECT json_object('id',t.id,'repo_id',t.repo_id,'author_id',t.author_id,'author',u.username,'title',t.title,'body',t.body,'state',t.state,'created_at',t.created_at,'updated_at',t.updated_at"
  <> extra
  <> ") FROM "
  <> table(kind)
  <> " t JOIN users u ON u.id=t.author_id "
}

fn get_item(ctx: c.Context, repo, kind, id) {
  c.one(ctx, item_sql(kind) <> "WHERE t.repo_id=? AND t.id=?", [
    db.int(c.i(repo, "id")),
    db.int(id),
  ])
}

fn item_reply(ctx: c.Context, repo, kind, id, status) {
  case get_item(ctx, repo, kind, id) {
    Ok(item) -> c.reply(status, c.obj([#(resource(kind), c.j(item))]))
    Error(_) -> c.err(404, "Discussion not found")
  }
}

fn discussions(ctx: c.Context, req: c.Request, repo, kind, rest) {
  case req.method, rest {
    "GET", [] ->
      c.reply(
        200,
        c.obj([
          #(
            collection(kind),
            json.array(
              c.rows(
                ctx,
                item_sql(kind) <> "WHERE t.repo_id=? ORDER BY t.id DESC",
                [db.int(c.i(repo, "id"))],
              ),
              c.j,
            ),
          ),
        ]),
      )
    "POST", [] ->
      case c.writer(repo) && c.uid(req) > 0 {
        False -> c.err(403, "Write access required")
        True -> create_item(ctx, req, repo, kind)
      }
    _, [id, ..tail] ->
      case int.parse(id) {
        Error(_) -> c.err(404, "Discussion not found")
        Ok(id) ->
          case get_item(ctx, repo, kind, id) {
            Error(_) -> c.err(404, "Discussion not found")
            Ok(item) ->
              case req.method, tail {
                "GET", [] -> details(ctx, req, repo, kind, item)
                "PATCH", [] -> update_item(ctx, req, repo, kind, item)
                "POST", ["comments"] ->
                  case c.writer(repo) && c.uid(req) > 0 {
                    True -> comment(ctx, req, repo, kind, item)
                    False -> c.err(403, "Write access required")
                  }
                "POST", ["reviews"] if kind == "pull" ->
                  case c.writer(repo) && c.uid(req) > 0 {
                    True -> review(ctx, req, repo, item)
                    False -> c.err(403, "Write access required")
                  }
                "POST", ["merge"] if kind == "pull" ->
                  case c.writer(repo) && c.uid(req) > 0 {
                    True ->
                      c.lock_repo(ctx, c.i(repo, "id"), fn() {
                        merge(ctx, req, repo, item)
                      })
                    False -> c.err(403, "Write access required")
                  }
                _, _ -> c.err(404, "Route not found")
              }
          }
      }
    _, _ -> c.err(404, "Route not found")
  }
}

fn strings_valid(body, keys) {
  list.all(keys, fn(key) {
    !c.has(body, key)
    || result.is_ok(decode.run(c.field(body, key), decode.string))
  })
}

fn text_valid(title, body) {
  string.length(string.trim(title)) > 0
  && string.length(title) <= 240
  && string.length(body) <= 100_000
}

fn create_item(ctx: c.Context, req: c.Request, repo, kind) {
  let title = string.trim(c.s(req.body, "title"))
  let body = c.s(req.body, "body")
  case
    text_valid(title, body)
    && strings_valid(req.body, ["title", "body", "base_branch", "head_branch"])
  {
    False ->
      c.err(
        400,
        "Title must be 1 to 240 characters and body at most 100000 characters",
      )
    True -> {
      let now = c.now()
      let params = [
        db.int(c.i(repo, "id")),
        db.int(c.uid(req)),
        db.text(title),
        db.text(body),
        db.int(now),
        db.int(now),
      ]
      let inserted = case kind {
        "issue" ->
          c.one(
            ctx,
            "INSERT INTO issues(repo_id,author_id,title,body,created_at,updated_at) VALUES (?,?,?,?,?,?) RETURNING json_object('id',id)",
            params,
          )
        _ -> {
          let base = case c.s(req.body, "base_branch") {
            "" -> c.s(repo, "default_branch")
            name -> name
          }
          let head = c.s(req.body, "head_branch")
          case branch_tips(ctx, repo, base, head) {
            Error(error) -> Error(error)
            Ok(#(base_oid, head_oid)) ->
              case
                c.git(ctx, c.i(repo, "id"), [
                  "diff",
                  "--no-ext-diff",
                  "--no-textconv",
                  "--name-only",
                  base_oid <> "..." <> head_oid,
                  "--",
                ])
              {
                Error(_) -> Error("Branches must have a common history")
                Ok("") -> Error("The branches contain no changes")
                Ok(_) ->
                  c.one(
                    ctx,
                    "INSERT INTO pull_requests(repo_id,author_id,title,body,created_at,updated_at,base_branch,head_branch) VALUES (?,?,?,?,?,?,?,?) RETURNING json_object('id',id)",
                    list.append(params, [db.text(base), db.text(head)]),
                  )
              }
          }
        }
      }
      case inserted {
        Error(_) if kind == "issue" -> c.err(500, "Could not create issue")
        Error(error) -> c.err(400, error)
        Ok(row) -> item_reply(ctx, repo, kind, c.i(row, "id"), 201)
      }
    }
  }
}

fn branch_tips(ctx: c.Context, repo, base, head) {
  case base != head && c.valid_branch(base) && c.valid_branch(head) {
    False -> Error("Provide distinct valid base and head branches")
    True ->
      case
        c.oid(ctx, c.i(repo, "id"), "refs/heads/" <> base),
        c.oid(ctx, c.i(repo, "id"), "refs/heads/" <> head)
      {
        Ok(base_oid), Ok(head_oid) ->
          case base_oid == head_oid {
            True -> Error("The branches contain no changes")
            False -> Ok(#(base_oid, head_oid))
          }
        _, _ -> Error("Base and head branches must exist")
      }
  }
}

fn update_item(ctx: c.Context, req: c.Request, repo, kind, item) {
  let title = string.trim(new_s(req.body, item, "title"))
  let body = new_s(req.body, item, "body")
  let state = new_s(req.body, item, "state")
  case
    c.uid(req) > 0 && { c.uid(req) == c.i(item, "author_id") || c.admin(repo) }
  {
    False ->
      c.err(403, "Only the author or repository admin may edit this discussion")
    True ->
      case c.s(item, "state") == "merged" {
        True -> c.err(409, "Merged pull requests cannot be edited")
        False ->
          case
            text_valid(title, body)
            && strings_valid(req.body, ["title", "body", "state"])
            && list.contains(["open", "closed"], state)
          {
            False ->
              c.err(
                400,
                "Provide a valid title, body, and open or closed state",
              )
            True ->
              case
                c.exec(
                  ctx,
                  "UPDATE "
                    <> table(kind)
                    <> " SET title=?,body=?,state=?,updated_at=? WHERE id=? AND repo_id=?",
                  [
                    db.text(title),
                    db.text(body),
                    db.text(state),
                    db.int(c.now()),
                    db.int(c.i(item, "id")),
                    db.int(c.i(repo, "id")),
                  ],
                )
              {
                Error(_) -> c.err(500, "Could not update discussion")
                Ok(_) -> item_reply(ctx, repo, kind, c.i(item, "id"), 200)
              }
          }
      }
  }
}

const comment_sql = "SELECT json_object('id',t.id,'author_id',t.author_id,'author',u.username,'body',t.body,'path',t.path,'line',t.line,'commit_oid',t.commit_oid,'created_at',t.created_at) FROM comments t JOIN users u ON u.id=t.author_id "

const review_sql = "SELECT json_object('id',t.id,'author_id',t.author_id,'author',u.username,'decision',t.decision,'body',t.body,'commit_oid',t.commit_oid,'created_at',t.created_at) FROM reviews t JOIN users u ON u.id=t.author_id "

fn comments(ctx: c.Context, kind, item) {
  c.rows(
    ctx,
    comment_sql
      <> "WHERE t.target_type=? AND t.target_id=? AND t.repo_id=? ORDER BY t.id",
    [db.text(kind), db.int(c.i(item, "id")), db.int(c.i(item, "repo_id"))],
  )
}

fn reviews(ctx: c.Context, item) {
  c.rows(ctx, review_sql <> "WHERE t.pull_id=? ORDER BY t.id", [
    db.int(c.i(item, "id")),
  ])
}

fn comment(ctx: c.Context, req: c.Request, repo, kind, item) {
  let body = c.s(req.body, "body")
  let path = case kind {
    "pull" -> c.s(req.body, "path")
    _ -> ""
  }
  let line = case kind {
    "pull" -> c.i(req.body, "line")
    _ -> 0
  }
  let commit = case kind {
    "pull" -> c.s(req.body, "commit_oid")
    _ -> ""
  }
  let location_ok =
    strings_valid(req.body, ["body", "path", "commit_oid"])
    && { path == "" || c.valid_path(path) }
    && line >= 0
    && {
      !c.has(req.body, "line")
      || result.is_ok(decode.run(c.field(req.body, "line"), decode.int))
    }
  let anchor_ok = case
    kind == "pull" && { path != "" || line != 0 || commit != "" }
  {
    False -> True
    True ->
      case
        c.oid(ctx, c.i(repo, "id"), "refs/heads/" <> c.s(item, "head_branch"))
      {
        Ok(oid) -> oid == commit
        Error(_) -> False
      }
  }
  case
    string.length(string.trim(body)) > 0
    && string.length(body) <= 100_000
    && location_ok
    && anchor_ok
  {
    False ->
      c.err(
        400,
        "Provide comment text and a valid location anchored to the current head OID",
      )
    True ->
      case
        c.one(
          ctx,
          "INSERT INTO comments(repo_id,target_type,target_id,author_id,body,path,line,commit_oid,created_at) VALUES (?,?,?,?,?,?,?,?,?) RETURNING json_object('id',id)",
          [
            db.int(c.i(repo, "id")),
            db.text(kind),
            db.int(c.i(item, "id")),
            db.int(c.uid(req)),
            db.text(body),
            db.text(path),
            db.int(line),
            db.text(commit),
            db.int(c.now()),
          ],
        )
      {
        Error(_) -> c.err(500, "Could not save comment")
        Ok(row) ->
          case
            c.one(ctx, comment_sql <> "WHERE t.id=?", [db.int(c.i(row, "id"))])
          {
            Ok(value) -> c.reply(201, c.obj([#("comment", c.j(value))]))
            Error(_) -> c.err(500, "Could not read comment")
          }
      }
  }
}

fn review(ctx: c.Context, req: c.Request, repo, previous) {
  c.lock_repo(ctx, c.i(repo, "id"), fn() {
    case get_item(ctx, repo, "pull", c.i(previous, "id")) {
      Error(_) -> c.err(404, "Pull request not found")
      Ok(item) -> save_review(ctx, req, repo, item)
    }
  })
}

fn save_review(ctx: c.Context, req: c.Request, repo, item) {
  let expected = c.s(req.body, "expected_head_oid")
  let decision = c.s(req.body, "decision")
  let body = c.s(req.body, "body")
  case
    list.contains(["approve", "request_changes", "comment"], decision)
    && string.length(body) <= 100_000
    && strings_valid(req.body, ["decision", "body", "expected_head_oid"])
    && expected != ""
  {
    False ->
      c.err(
        400,
        "Provide expected_head_oid and decision approve, request_changes, or comment",
      )
    True ->
      case decision == "approve" && c.uid(req) == c.i(item, "author_id") {
        True -> c.err(403, "Authors cannot approve their own pull requests")
        False ->
          case c.s(item, "state") == "open" {
            False -> c.err(409, "Only open pull requests can be reviewed")
            True ->
              case
                c.oid(
                  ctx,
                  c.i(repo, "id"),
                  "refs/heads/" <> c.s(item, "head_branch"),
                )
              {
                Error(_) -> c.err(409, "Head branch no longer exists")
                Ok(oid) if oid != expected ->
                  c.err(
                    409,
                    "Head changed. Refresh and review the current diff before submitting a review",
                  )
                Ok(oid) ->
                  case
                    c.one(
                      ctx,
                      "INSERT INTO reviews(pull_id,author_id,decision,body,commit_oid,created_at) VALUES (?,?,?,?,?,?) RETURNING json_object('id',id)",
                      [
                        db.int(c.i(item, "id")),
                        db.int(c.uid(req)),
                        db.text(decision),
                        db.text(body),
                        db.text(oid),
                        db.int(c.now()),
                      ],
                    )
                  {
                    Error(_) -> c.err(500, "Could not save review")
                    Ok(row) ->
                      case
                        c.one(ctx, review_sql <> "WHERE t.id=?", [
                          db.int(c.i(row, "id")),
                        ])
                      {
                        Ok(value) ->
                          c.reply(201, c.obj([#("review", c.j(value))]))
                        Error(_) -> c.err(500, "Could not read review")
                      }
                  }
              }
          }
      }
  }
}

fn blockers(ctx: c.Context, repo, item, head, tree: Result(String, String)) {
  let current =
    c.rows(
      ctx,
      review_sql
        <> "WHERE t.pull_id=? AND t.commit_oid=? AND t.decision!='comment' AND t.id=(SELECT MAX(r.id) FROM reviews r WHERE r.pull_id=t.pull_id AND r.author_id=t.author_id AND r.commit_oid=t.commit_oid AND r.decision!='comment')",
      [db.int(c.i(item, "id")), db.text(head)],
    )
    |> list.filter(fn(r) {
      case c.repo(ctx, c.i(repo, "id"), c.i(r, "author_id")) {
        Ok(access) -> c.writer(access)
        Error(_) -> False
      }
    })
  let approval =
    list.any(current, fn(r) {
      c.s(r, "decision") == "approve"
      && c.i(r, "author_id") != c.i(item, "author_id")
    })
  let changes =
    list.any(current, fn(r) { c.s(r, "decision") == "request_changes" })
  []
  |> add_block(c.s(item, "state") != "open", "Pull request is not open")
  |> add_block(
    result.is_error(tree),
    "Resolve merge conflicts or restore missing branches",
  )
  |> add_block(changes, "A current reviewer has requested changes")
  |> add_block(
    c.b(repo, "require_review") && !approval,
    "A different writer must approve the current head",
  )
  |> list.reverse
}

fn add_block(items, condition, text) {
  case condition {
    True -> [text, ..items]
    False -> items
  }
}

fn merge_tree(ctx: c.Context, repo, base, head) {
  c.git(ctx, c.i(repo, "id"), ["merge-tree", "--write-tree", base, head])
  |> result.map(fn(s) {
    string.split(string.trim(s), "\n") |> list.first |> result.unwrap("")
  })
}

fn details(ctx: c.Context, _req, repo, kind, item) {
  let common = [
    #(resource(kind), c.j(item)),
    #("comments", json.array(comments(ctx, kind, item), c.j)),
  ]
  case kind {
    "issue" -> c.reply(200, c.obj(common))
    _ -> {
      let tips = case c.s(item, "state") {
        "merged" -> {
          use base <- result.try(c.oid(
            ctx,
            c.i(repo, "id"),
            c.s(item, "merged_oid") <> "^1",
          ))
          use head <- result.try(c.oid(
            ctx,
            c.i(repo, "id"),
            c.s(item, "merged_oid") <> "^2",
          ))
          Ok(#(base, head))
        }
        _ ->
          branch_tips(
            ctx,
            repo,
            c.s(item, "base_branch"),
            c.s(item, "head_branch"),
          )
      }
      let #(base, head) = result.unwrap(tips, #("", ""))
      let tree = case tips {
        Error(e) -> Error(e)
        Ok(_) -> merge_tree(ctx, repo, base, head)
      }
      let blocked = blockers(ctx, repo, item, head, tree)
      let diff_result = case tips {
        Error(error) -> Error(error)
        Ok(_) ->
          git_diff(c.repo_path(ctx, c.i(repo, "id")), [
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            base <> "..." <> head,
            "--",
          ])
      }
      let #(diff, truncated) = result.unwrap(diff_result, #("", False))
      let blocked = case diff_result {
        Error(_) ->
          add_block(
            blocked,
            True,
            "Diff unavailable; check branch history and retry",
          )
        Ok(_) -> blocked
      }
      c.reply(
        200,
        c.obj(
          list.append(common, [
            #("reviews", json.array(reviews(ctx, item), c.j)),
            #("diff", json.string(diff)),
            #("base_oid", json.string(base)),
            #("head_oid", json.string(head)),
            #("truncated", json.bool(truncated)),
            #("mergeable", json.bool(list.is_empty(blocked))),
            #("merge_blockers", json.array(blocked, json.string)),
          ]),
        ),
      )
    }
  }
}

fn merge(ctx: c.Context, req: c.Request, repo, previous) {
  recover_unlocked(ctx, c.i(repo, "id"))
  case get_item(ctx, repo, "pull", c.i(previous, "id")) {
    Error(_) -> c.err(404, "Pull request not found")
    Ok(item) ->
      case
        branch_tips(
          ctx,
          repo,
          c.s(item, "base_branch"),
          c.s(item, "head_branch"),
        )
      {
        Error(e) -> c.err(409, e)
        Ok(#(base, head)) ->
          case c.s(req.body, "expected_head_oid") == head {
            False ->
              c.err(
                409,
                "Head changed. Refresh the pull request and review the current diff",
              )
            True -> {
              let tree = merge_tree(ctx, repo, base, head)
              let blocked = blockers(ctx, repo, item, head, tree)
              case blocked, tree {
                [reason, ..], _ -> c.err(409, reason)
                [], Error(_) -> c.err(409, "Resolve merge conflicts")
                [], Ok(tree_oid) -> {
                  let username = c.s(req.user, "username")
                  case
                    c.git(ctx, c.i(repo, "id"), [
                      "-c",
                      "user.name=" <> username,
                      "-c",
                      "user.email=" <> username <> "@gitclub.local",
                      "commit-tree",
                      tree_oid,
                      "-p",
                      base,
                      "-p",
                      head,
                      "-m",
                      "Merge pull request #"
                        <> int.to_string(c.i(item, "id"))
                        <> ": "
                        <> c.s(item, "title"),
                    ])
                  {
                    Error(_) -> c.err(500, "Could not create merge commit")
                    Ok(commit) ->
                      save_merge(
                        ctx,
                        repo,
                        item,
                        base,
                        head,
                        string.trim(commit),
                      )
                  }
                }
              }
            }
          }
      }
  }
}

fn save_merge(ctx: c.Context, repo, item, base, head, commit) {
  let marker = marker_path(ctx, c.i(repo, "id"), c.i(item, "id"))
  case c.read_file(marker) {
    Ok(_) ->
      c.err(
        409,
        "A previous merge requires metadata recovery before another merge",
      )
    Error(_) -> save_merge_unmarked(ctx, repo, item, base, head, commit)
  }
}

fn save_merge_unmarked(ctx: c.Context, repo, item, base, head, commit) {
  let rid = c.i(repo, "id")
  let pid = c.i(item, "id")
  let marker = marker_path(ctx, rid, pid)
  let payload =
    c.obj([
      #("repo_id", json.int(rid)),
      #("pull_id", json.int(pid)),
      #("base_branch", json.string(c.s(item, "base_branch"))),
      #("old_oid", json.string(base)),
      #("new_oid", json.string(commit)),
    ])
    |> json.to_string
  case c.oid(ctx, rid, "refs/heads/" <> c.s(item, "head_branch")) == Ok(head) {
    False -> c.err(409, "Head changed during merge. Refresh and retry")
    True ->
      case c.write_file(marker, payload) {
        Error(_) -> c.err(500, "Could not persist merge recovery marker")
        Ok(_) ->
          case
            git_input(
              c.repo_path(ctx, rid),
              ["update-ref", "--stdin"],
              "start\nverify refs/heads/"
                <> c.s(item, "head_branch")
                <> " "
                <> head
                <> "\nupdate refs/heads/"
                <> c.s(item, "base_branch")
                <> " "
                <> commit
                <> " "
                <> base
                <> "\ncreate refs/gitclub/merges/"
                <> int.to_string(pid)
                <> " "
                <> commit
                <> "\nprepare\ncommit\n",
            )
          {
            Error(_) -> {
              // A transport failure does not prove the ref transaction failed.
              recover_unlocked(ctx, rid)
              case get_item(ctx, repo, "pull", pid) {
                Ok(pull) ->
                  case c.s(pull, "merged_oid") == commit {
                    True ->
                      c.reply(
                        200,
                        c.obj([
                          #("pull", c.j(pull)),
                          #("commit_oid", json.string(commit)),
                        ]),
                      )
                    False ->
                      c.err(
                        409,
                        "A branch changed or merge recovery is pending. Refresh and retry",
                      )
                  }
                Error(_) ->
                  c.err(500, "Merge result requires metadata recovery")
              }
            }
            Ok(_) ->
              case
                c.exec(
                  ctx,
                  "UPDATE pull_requests SET state='merged',merged_oid=?,updated_at=? WHERE id=?",
                  [db.text(commit), db.int(c.now()), db.int(pid)],
                )
              {
                Error(_) ->
                  c.err(
                    500,
                    "Git merge succeeded; metadata recovery is pending",
                  )
                Ok(_) -> {
                  let _ = c.delete_file(marker)
                  c.refresh(ctx, rid)
                  case get_item(ctx, repo, "pull", pid) {
                    Error(_) ->
                      c.err(
                        500,
                        "Merge completed but response could not be read",
                      )
                    Ok(pull) ->
                      c.reply(
                        200,
                        c.obj([
                          #("pull", c.j(pull)),
                          #("commit_oid", json.string(commit)),
                        ]),
                      )
                  }
                }
              }
          }
      }
  }
}

@external(erlang, "gitclub_input_ffi", "git_input")
fn git_input(
  path: String,
  args: List(String),
  input: String,
) -> Result(String, String)

@external(erlang, "gitclub_input_ffi", "git_diff")
fn git_diff(path: String, args: List(String)) -> Result(#(String, Bool), String)

// The ledger ref is committed atomically with the base update and survives resets.
// Recovery remains idempotent when the mutable base no longer contains the merge.
// Ambiguous markers remain on disk and block merging that pull until resolved.
pub fn recover(ctx: c.Context) {
  c.rows(ctx, "SELECT json_object('id',id) FROM repositories", [])
  |> list.each(fn(row) { recover_repo(ctx, c.i(row, "id")) })
}

pub fn recover_repo(ctx: c.Context, id: Int) {
  c.lock_repo(ctx, id, fn() { recover_unlocked(ctx, id) })
}

fn marker_path(ctx: c.Context, id: Int, pid: Int) {
  c.repo_path(ctx, id) <> "/gitclub-merge-" <> int.to_string(pid) <> ".json"
}

fn recover_unlocked(ctx: c.Context, id: Int) {
  c.rows(ctx, "SELECT json_object('id',id) FROM pull_requests WHERE repo_id=?", [
    db.int(id),
  ])
  |> list.each(fn(row) { recover_pull_marker(ctx, id, c.i(row, "id")) })
}

fn recover_pull_marker(ctx: c.Context, id: Int, pid: Int) {
  let path = marker_path(ctx, id, pid)
  case c.read_file(path) {
    Error(_) -> Nil
    Ok(text) -> {
      let marker = c.parse(text)
      let new = c.s(marker, "new_oid")
      let old = c.s(marker, "old_oid")
      let branch = c.s(marker, "base_branch")
      case
        c.i(marker, "repo_id") == id
        && c.i(marker, "pull_id") == pid
        && c.valid_branch(branch)
        && c.regex(new, "^[0-9a-f]{40,64}$")
        && c.regex(old, "^[0-9a-f]{40,64}$")
      {
        False -> Nil
        True -> {
          let ledger = "refs/gitclub/merges/" <> int.to_string(pid)
          case
            c.git(ctx, id, [
              "for-each-ref",
              "--format=%(refname) %(objectname)",
              ledger,
            ])
          {
            Error(_) -> Nil
            Ok(output) ->
              case
                list.find(string.split(output, "\n"), fn(line) {
                  string.starts_with(line, ledger <> " ")
                })
              {
                Error(_) -> c.delete_file(path)
                Ok(entry) ->
                  case entry == ledger <> " " <> new {
                    True -> finish_recovery(ctx, id, pid, branch, new, path)
                    False -> Nil
                  }
              }
          }
        }
      }
    }
  }
}

fn finish_recovery(
  ctx: c.Context,
  id: Int,
  pid: Int,
  branch: String,
  oid: String,
  path: String,
) {
  case
    c.exec(
      ctx,
      "UPDATE pull_requests SET state='merged',merged_oid=?,updated_at=? WHERE id=? AND repo_id=? AND base_branch=?",
      [db.text(oid), db.int(c.now()), db.int(pid), db.int(id), db.text(branch)],
    )
  {
    Error(_) -> Nil
    Ok(_) -> {
      c.delete_file(path)
      c.refresh(ctx, id)
    }
  }
}
