import gitclub/collab
import gitclub/common as c
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{Some}
import gleam/string
import sqlight

@external(erlang, "gitclub_ffi", "init")
fn init() -> Nil

@external(erlang, "gitclub_input_ffi", "git_input")
fn input(
  path: String,
  args: List(String),
  data: String,
) -> Result(String, String)

@external(erlang, "gitclub_input_ffi", "git_diff")
fn diff(path: String, args: List(String)) -> Result(#(String, Bool), String)

fn request(ctx, uid, method, path, body) {
  let user =
    c.parse(
      "{\"id\":"
      <> int.to_string(uid)
      <> ",\"username\":\"user"
      <> int.to_string(uid)
      <> "\"}",
    )
  let assert Some(response) =
    collab.route(ctx, c.Request(method, path, [], c.parse(body), user, ""))
  response
}

fn review_body(head: String, decision: String) {
  c.obj([
    #("expected_head_oid", json.string(head)),
    #("decision", json.string(decision)),
    #("body", json.string("Review note")),
  ])
  |> json.to_string
}

fn payload(response: c.Response) {
  c.parse(json.to_string(response.body))
}

fn git(ctx, id, args) {
  let assert Ok(output) = c.git(ctx, id, args)
  output
}

pub fn main() {
  init()
  let path = "/tmp/gitclub-collab-" <> c.random()
  c.mkdir(path <> "/repos")
  let assert Ok(db) = sqlight.open(path <> "/gitclub.db")
  let assert Ok(schema) = c.read_file("../../shared/schema.sql")
  let assert Ok(_) = sqlight.exec(schema, db)
  let ctx = c.Context(path, "../../shared", "../../web", "http://localhost", db)
  let assert Ok(_) =
    sqlight.exec(
      "INSERT INTO users VALUES(1,'user1','unused',0),(2,'user2','unused',0),(3,'user3','unused',0); INSERT INTO namespaces VALUES('user1','user'); INSERT INTO namespace_members VALUES('user1',1,'admin'); INSERT INTO repositories(id,owner,name,created_at,updated_at) VALUES(1,'user1','private',0,0),(2,'user1','hidden',0,0); INSERT INTO repo_members VALUES(1,2,'write');",
      db,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["init", "--bare", path <> "/repos/1.git"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["init", "--bare", path <> "/repos/2.git"],
      [],
      30_000,
      4096,
    )
  let assert 401 =
    request(ctx, 0, "POST", ["api", "groups"], "{\"name\":\"Work\"}").status
  let created =
    request(
      ctx,
      1,
      "POST",
      ["api", "groups"],
      "{\"name\":\"Work\",\"shared\":true}",
    )
  let assert 201 = created.status
  let assert 400 =
    request(
      ctx,
      1,
      "POST",
      ["api", "groups"],
      "{\"name\":\"Work\",\"shared\":1}",
    ).status
  let group_id = c.i(c.field(payload(created), "group"), "id") |> int.to_string
  let group_path = ["api", "groups", group_id]
  let assert 200 =
    request(ctx, 1, "PATCH", group_path, "{\"repo_ids\":[1,2]}").status
  let other =
    request(ctx, 2, "GET", group_path, "{}") |> payload |> c.field("group")
  let assert [visible] = c.array(other, "repo_ids")
  let assert "1" = json.to_string(c.j(visible))
  let assert 403 =
    request(ctx, 2, "PATCH", group_path, "{\"name\":\"Other\"}").status
  let assert 200 =
    request(ctx, 1, "POST", ["api", "repos", "1", "pin"], "{\"pinned\":true}").status
  let assert 400 =
    request(ctx, 1, "POST", ["api", "repos", "1", "pin"], "{\"pinned\":1}").status
  let assert 404 =
    request(ctx, 3, "GET", ["api", "repos", "1", "issues"], "{}").status
  let issue =
    request(
      ctx,
      2,
      "POST",
      ["api", "repos", "1", "issues"],
      "{\"title\":\"A defect\",\"body\":\"Details\"}",
    )
  let assert 201 = issue.status
  let issue_id = c.i(c.field(payload(issue), "issue"), "id") |> int.to_string
  let assert 200 =
    request(
      ctx,
      1,
      "PATCH",
      ["api", "repos", "1", "issues", issue_id],
      "{\"state\":\"closed\"}",
    ).status
  let assert 201 =
    request(
      ctx,
      2,
      "POST",
      ["api", "repos", "1", "issues", issue_id, "comments"],
      "{\"body\":\"Confirmed\"}",
    ).status
  let assert Ok(_) =
    c.command("git", ["init", "-b", "main", path <> "/work"], [], 30_000, 4096)
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "config", "user.name", "user1"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "config", "user.email", "user1@gitclub.local"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) = c.write_file(path <> "/work/README", "First\n")
  let assert Ok(_) =
    c.command("git", ["-C", path <> "/work", "add", "README"], [], 30_000, 4096)
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "commit", "-m", "Initial"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "push", path <> "/repos/1.git", "main"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "checkout", "-b", "feature"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) = c.write_file(path <> "/work/README", "First\nChange\n")
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "commit", "-am", "Change"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "push", path <> "/repos/1.git", "feature"],
      [],
      30_000,
      4096,
    )
  let pull =
    request(
      ctx,
      1,
      "POST",
      ["api", "repos", "1", "pulls"],
      "{\"title\":\"Review change\",\"head_branch\":\"feature\"}",
    )
  let assert 201 = pull.status
  let pid = c.i(c.field(payload(pull), "pull"), "id") |> int.to_string
  let reviews_path = ["api", "repos", "1", "pulls", pid, "reviews"]
  let assert Ok(head) = c.oid(ctx, 1, "refs/heads/feature")
  let merge_path = ["api", "repos", "1", "pulls", pid, "merge"]
  let assert 400 =
    request(ctx, 2, "POST", reviews_path, "{\"decision\":\"approve\"}").status
  let assert 403 =
    request(ctx, 1, "POST", reviews_path, review_body(head, "approve")).status
  let assert 409 =
    request(ctx, 1, "POST", merge_path, "{\"expected_head_oid\":\"wrong\"}").status
  let assert Ok(head) = c.oid(ctx, 1, "refs/heads/feature")
  let merge_body =
    json.to_string(c.obj([#("expected_head_oid", json.string(head))]))
  let assert 409 = request(ctx, 1, "POST", merge_path, merge_body).status
  let assert 201 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "request_changes")).status
  let assert 409 = request(ctx, 1, "POST", merge_path, merge_body).status
  let assert 201 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "approve")).status
  let assert 201 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "comment")).status
  let assert 400 =
    request(
      ctx,
      2,
      "POST",
      ["api", "repos", "1", "pulls", pid, "comments"],
      "{\"body\":\"inline\",\"path\":\"../secret\",\"line\":1}",
    ).status
  let assert Ok(_) =
    c.write_file(path <> "/work/README", "First\nChange\nSecond change\n")
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "commit", "-am", "Second change"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "push", path <> "/repos/1.git", "feature"],
      [],
      30_000,
      4096,
    )
  let assert 409 = request(ctx, 1, "POST", merge_path, merge_body).status
  let assert 409 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "approve")).status
  let assert 409 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "request_changes")).status
  let assert 409 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "comment")).status
  let assert Ok(head) = c.oid(ctx, 1, "refs/heads/feature")
  let merge_body =
    json.to_string(c.obj([#("expected_head_oid", json.string(head))]))
  let assert 409 = request(ctx, 1, "POST", merge_path, merge_body).status
  let assert 201 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "approve")).status
  let assert Ok(_) =
    c.exec(
      ctx,
      "UPDATE repo_members SET role='read' WHERE repo_id=1 AND user_id=2",
      [],
    )
  let assert 409 = request(ctx, 1, "POST", merge_path, merge_body).status
  let assert 403 =
    request(ctx, 2, "POST", reviews_path, review_body(head, "approve")).status
  let assert Ok(_) =
    c.exec(
      ctx,
      "UPDATE repo_members SET role='write' WHERE repo_id=1 AND user_id=2",
      [],
    )
  let merged = request(ctx, 1, "POST", merge_path, merge_body)
  let assert 200 = merged.status
  let assert "merged" = c.s(c.field(payload(merged), "pull"), "state")
  let assert 409 =
    request(
      ctx,
      1,
      "PATCH",
      ["api", "repos", "1", "pulls", pid],
      "{\"state\":\"open\"}",
    ).status
  let _ = git(ctx, 1, ["merge-base", "--is-ancestor", head, "refs/heads/main"])
  let historical =
    request(ctx, 1, "GET", ["api", "repos", "1", "pulls", pid], "{}") |> payload
  let assert True = c.s(historical, "diff") != ""
  let assert True = head == c.s(historical, "head_oid")
  let merged_oid = c.s(payload(merged), "commit_oid")
  let old_base = c.s(historical, "base_oid")
  let marker_path = path <> "/repos/1.git/gitclub-merge-" <> pid <> ".json"
  let marker =
    c.obj([
      #("repo_id", json.int(1)),
      #("pull_id", json.int(c.i(c.field(payload(merged), "pull"), "id"))),
      #("base_branch", json.string("main")),
      #("old_oid", json.string(old_base)),
      #("new_oid", json.string(merged_oid)),
    ])
    |> json.to_string
  let assert Ok(_) = c.write_file(marker_path, marker)
  let assert Ok(_) =
    c.exec(ctx, "UPDATE pull_requests SET state='open',merged_oid=''", [])
  let assert Ok(proof) = c.oid(ctx, 1, "refs/gitclub/merges/" <> pid)
  let assert True = proof == merged_oid
  let _ = git(ctx, 1, ["update-ref", "refs/heads/main", old_base, merged_oid])
  collab.recover(ctx)
  let assert Ok(reset_base) = c.oid(ctx, 1, "refs/heads/main")
  let assert True = reset_base == old_base
  let recovered =
    request(ctx, 1, "GET", ["api", "repos", "1", "pulls", pid], "{}") |> payload
  let assert "merged" = c.s(c.field(recovered, "pull"), "state")
  let assert Error(_) = c.read_file(marker_path)
  let _ = git(ctx, 1, ["update-ref", "refs/heads/main", merged_oid, old_base])
  let assert Error(_) =
    input(
      path <> "/repos/1.git",
      ["update-ref", "--stdin"],
      "start\nverify refs/heads/feature "
        <> old_base
        <> "\nupdate refs/heads/main "
        <> old_base
        <> " "
        <> merged_oid
        <> "\nprepare\ncommit\n",
    )
  let assert Ok(current) = c.oid(ctx, 1, "refs/heads/main")
  let assert True = current == merged_oid
  let assert Ok(_) =
    c.write_file(
      path <> "/work/large.txt",
      string.repeat("a long changed line of source text\n", 40_000),
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "add", "large.txt"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "commit", "-m", "Large diff"],
      [],
      30_000,
      4096,
    )
  let assert Ok(_) =
    c.command(
      "git",
      ["-C", path <> "/work", "push", path <> "/repos/1.git", "feature"],
      [],
      30_000,
      4096,
    )
  let assert Ok(#(large, True)) =
    diff(path <> "/repos/1.git", [
      "diff",
      "--no-ext-diff",
      "--no-textconv",
      "refs/heads/main...refs/heads/feature",
      "--",
    ])
  let assert True = string.byte_size(large) == 1_048_576
  let assert Ok(_) = sqlight.close(db)
  io.println(
    "PASS collab checks: group privacy, pins, issue roles, review policy, stale head, inline validation, native merge, ledger recovery after base reset, atomic ref transaction, bounded diff",
  )
}
