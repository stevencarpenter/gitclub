import gitclub/auth
import gitclub/collab
import gitclub/common as c
import gitclub/repos
import gitclub/transport
import gleam/bit_array
import gleam/bytes_tree
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import mist
import sqlight

pub fn main() {
  init()
  let port = c.env("PORT", "7702") |> int.parse |> result.unwrap(7702)
  let data = c.absolute(c.env("DATA_DIR", ".data/gleam"))
  let shared = c.absolute(c.env("SHARED_DIR", "shared"))
  c.mkdir(data <> "/repos")
  c.mkdir(data <> "/tmp")
  let assert Ok(db) = sqlight.open(data <> "/gitclub.db")
  let assert Ok(schema) = c.read_file(shared <> "/schema.sql")
  let assert Ok(_) = sqlight.exec(schema, db)
  let ctx =
    c.Context(
      data,
      shared,
      c.absolute(c.env("WEB_DIR", "web")),
      c.env("PUBLIC_URL", "http://localhost:" <> int.to_string(port)),
      db,
    )
  let _ =
    list.map(
      c.rows(
        ctx,
        "SELECT json_object('id',id,'default_branch',default_branch) FROM repositories",
        [],
      ),
      fn(repo) {
        let id = c.i(repo, "id")
        let assert Ok(_) = c.install_hooks(c.repo_path(ctx, id), shared)
        let assert Ok(_) =
          c.git(ctx, id, ["config", "transfer.hideRefs", "refs/gitclub/"])
        let expected = "ref: refs/heads/" <> c.s(repo, "default_branch") <> "\n"
        case c.read_file(c.repo_path(ctx, id) <> "/HEAD") == Ok(expected) {
          True -> Nil
          False -> {
            let assert Ok(_) =
              c.git(ctx, id, [
                "symbolic-ref",
                "HEAD",
                "refs/heads/" <> c.s(repo, "default_branch"),
              ])
            Nil
          }
        }
      },
    )
  collab.recover(ctx)
  let assert Ok(_) =
    fn(req) { protect(fn() { handle(ctx, req) }) }
    |> mist.new
    |> mist.port(port)
    |> mist.bind(c.env("HOST", "127.0.0.1"))
    |> mist.start
  io.println("GitClub gleam ready")
  process.sleep_forever()
}

fn handle(ctx: c.Context, req: request.Request(mist.Connection)) {
  let path = request.path_segments(req)
  let result = case path {
    ["health"] ->
      wire(c.reply(
        200,
        c.obj([
          #("status", json.string("ok")),
          #("implementation", json.string("gleam")),
        ]),
      ))
    [_, name, ..] if name != "" ->
      case string.ends_with(name, ".git") {
        True -> transport.serve(ctx, req)
        False -> normal(ctx, req, path)
      }
    _ -> normal(ctx, req, path)
  }
  result
  |> response.set_header(
    "content-security-policy",
    "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
  )
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "same-origin")
}

fn normal(
  ctx: c.Context,
  req: request.Request(mist.Connection),
  path: List(String),
) {
  case path {
    ["api", ..] | ["mcp"] -> {
      let token = case request.get_header(req, "x-gitclub-ssh-secret") {
        Ok(secret) -> secret
        Error(_) -> auth.token_from(req)
      }
      let user = auth.authenticate(ctx, token)
      let mutation = req.method != http.Get && req.method != http.Head
      let cookie_auth =
        request.get_header(req, "authorization") |> result.is_error
        && request.get_header(req, "cookie") |> result.is_ok
      let origin = request.get_header(req, "origin") |> result.unwrap("")
      let csrf =
        {
          path != ["mcp"]
          || string.starts_with(
            request.get_header(req, "authorization") |> result.unwrap(""),
            "Bearer ",
          )
        }
        && {
          !mutation
          || !cookie_auth
          || {
            {
              origin == ctx.public_url
              || request.get_header(req, "x-gitclub-request") == Ok("1")
            }
            && string.starts_with(
              request.get_header(req, "content-type") |> result.unwrap(""),
              "application/json",
            )
          }
        }
      let peer =
        mist.get_connection_info(req.body)
        |> result.map(fn(x) { string.inspect(x.ip_address) })
        |> result.unwrap("unknown")
      case csrf {
        False ->
          wire(case path {
            ["mcp"] -> c.err(401, "MCP requires a bearer token")
            _ -> c.err(403, "Send a same-origin JSON request")
          })
        True ->
          case
            path == ["api", "auth", "login"]
            || path == ["api", "auth", "register"]
          {
            True ->
              case c.rate_allow(peer) {
                False ->
                  wire(c.err(
                    429,
                    "Too many authentication attempts; retry in one minute",
                  ))
                True -> api_request(ctx, req, path, token, user)
              }
            False -> api_request(ctx, req, path, token, user)
          }
      }
    }
    _ -> static(ctx, path)
  }
}

fn api_request(
  ctx: c.Context,
  req: request.Request(mist.Connection),
  path,
  token,
  user,
) {
  let body =
    timed(10_000, fn() {
      case transport.stream(req, 1_048_576) {
        Error(_) -> Error("Cannot read request")
        Ok(next) -> read_body(next, <<>>)
      }
    })
  case body {
    Error(msg) -> wire(c.err(413, msg))
    Ok(bits) -> {
      let text = bit_array.to_string(bits) |> result.unwrap("")
      let parsed = case text {
        "" -> Ok(c.parse("{}"))
        _ ->
          json.parse(text, decode.dynamic)
          |> result.replace_error("Invalid JSON")
      }
      case parsed {
        Error(_) ->
          wire(case path {
            ["mcp"] -> rpc(c.null(), -32_700, "Parse error")
            _ -> c.err(400, "Invalid JSON body")
          })
        Ok(body) -> {
          let request =
            c.Request(
              http.method_to_string(req.method),
              path,
              request.get_query(req) |> result.unwrap([]),
              body,
              user,
              token,
            )
          let run = fn() {
            sqlight.with_connection(ctx.data_dir <> "/gitclub.db", fn(db) {
              let assert Ok(_) =
                sqlight.exec(
                  "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
                  db,
                )
              let local = c.Context(..ctx, db: db)
              case path {
                ["mcp"] -> mcp(local, request)
                _ -> dispatch(local, request)
              }
            })
          }
          // ponytail: serialize metadata operations; per-namespace queues if measured contention requires it.
          let answer = case path {
            ["api", "repos", _, "git", _] -> run()
            _ -> c.lock_repo(ctx, -1, run)
          }
          wire(answer)
        }
      }
    }
  }
}

fn read_body(
  next: fn(Int) -> Result(mist.Chunk, mist.ReadError),
  data: BitArray,
) -> Result(BitArray, String) {
  case next(65_536) {
    Error(_) -> Error("Request disconnected")
    Ok(mist.Done) -> Ok(data)
    Ok(mist.Chunk(chunk, next)) ->
      case bit_array.byte_size(data) + bit_array.byte_size(chunk) > 1_048_576 {
        True -> Error("JSON body exceeds 1 MiB")
        False -> read_body(next, bit_array.append(data, chunk))
      }
  }
}

pub fn dispatch(ctx: c.Context, req: c.Request) {
  case auth.route(ctx, req) {
    Some(resp) -> resp
    None ->
      case collab.route(ctx, req) {
        Some(resp) -> resp
        None ->
          case repos.route(ctx, req) {
            Some(resp) -> resp
            None -> c.err(404, "Route not found")
          }
      }
  }
}

fn wire(resp: c.Response) {
  response.Response(
    resp.status,
    [
      #("content-type", "application/json; charset=utf-8"),
      #("cache-control", "no-store"),
      ..resp.headers
    ],
    mist.Bytes(bytes_tree.from_string(json.to_string(resp.body))),
  )
}

fn static(ctx: c.Context, path: List(String)) {
  let file = case path {
    ["app.js"] -> "app.js"
    ["style.css"] -> "style.css"
    ["favicon.svg"] -> "favicon.svg"
    _ -> "index.html"
  }
  let mime = case file {
    "app.js" -> "text/javascript; charset=utf-8"
    "style.css" -> "text/css; charset=utf-8"
    "favicon.svg" -> "image/svg+xml"
    _ -> "text/html; charset=utf-8"
  }
  case mist.send_file(ctx.web_dir <> "/" <> file, 0, None) {
    Ok(body) ->
      response.new(200)
      |> response.set_header("content-type", mime)
      |> response.set_body(body)
    Error(_) -> wire(c.err(404, "Web assets not installed"))
  }
}

fn rpc(id, code, msg) {
  c.reply(
    200,
    c.obj([
      #("jsonrpc", json.string("2.0")),
      #("id", c.j(id)),
      #(
        "error",
        c.obj([#("code", json.int(code)), #("message", json.string(msg))]),
      ),
    ]),
  )
}

fn rpc_ok(id, value) {
  c.reply(
    200,
    c.obj([
      #("jsonrpc", json.string("2.0")),
      #("id", c.j(id)),
      #("result", value),
    ]),
  )
}

fn mcp(ctx: c.Context, req: c.Request) {
  let id = c.field(req.body, "id")
  case req.method {
    "POST" ->
      case c.uid(req) {
        0 -> c.err(401, "MCP requires a bearer token")
        _ -> {
          let method = c.s(req.body, "method")
          let tools =
            c.read_file(ctx.shared_dir <> "/mcp-tools.json")
            |> result.unwrap("[]")
            |> c.parse
            |> decode.run(decode.list(decode.dynamic))
            |> result.unwrap([])
          case method {
            "initialize" -> {
              let wanted = c.s(c.field(req.body, "params"), "protocolVersion")
              let version = case
                list.contains(
                  ["2024-11-05", "2025-03-26", "2025-06-18"],
                  wanted,
                )
              {
                True -> wanted
                False -> "2025-06-18"
              }
              rpc_ok(
                id,
                c.obj([
                  #("protocolVersion", json.string(version)),
                  #("capabilities", c.obj([#("tools", c.obj([]))])),
                  #(
                    "serverInfo",
                    c.obj([
                      #("name", json.string("GitClub Gleam")),
                      #("version", json.string("0.1.0")),
                    ]),
                  ),
                ]),
              )
            }
            "notifications/initialized" -> c.reply(202, json.null())
            "ping" -> rpc_ok(id, c.obj([]))
            "tools/list" ->
              rpc_ok(
                id,
                c.obj([
                  #(
                    "tools",
                    json.array(tools, fn(tool) {
                      c.obj([
                        #("name", c.j(c.field(tool, "name"))),
                        #("description", c.j(c.field(tool, "description"))),
                        #("inputSchema", c.j(c.field(tool, "inputSchema"))),
                        #("annotations", c.j(c.field(tool, "annotations"))),
                      ])
                    }),
                  ),
                ]),
              )
            "tools/call" -> {
              let params = c.field(req.body, "params")
              let name = c.s(params, "name")
              let args = c.field(params, "arguments")
              case list.find(tools, fn(tool) { c.s(tool, "name") == name }) {
                Error(_) -> rpc(id, -32_602, "Unknown tool")
                Ok(tool) ->
                  case valid_arguments(args, c.field(tool, "inputSchema")) {
                    False ->
                      rpc(
                        id,
                        -32_602,
                        "Arguments do not match the tool input schema",
                      )
                    True -> {
                      let mapping = c.field(tool, "http")
                      let initial = c.s(mapping, "path")
                      let keys = ["repo_id", "pull_id", "issue_id", "group_id"]
                      let path =
                        list.fold(keys, initial, fn(path, key) {
                          string.replace(
                            path,
                            "{" <> key <> "}",
                            int.to_string(c.i(args, key)),
                          )
                        })
                      let query =
                        c.array(mapping, "query")
                        |> list.filter_map(fn(item) {
                          let key =
                            decode.run(item, decode.string) |> result.unwrap("")
                          case c.has(args, key) {
                            True ->
                              Ok(
                                #(key, case c.s(args, key) {
                                  "" -> int.to_string(c.i(args, key))
                                  x -> x
                                }),
                              )
                            False -> Error(Nil)
                          }
                        })
                      let body =
                        c.array(mapping, "body")
                        |> list.filter_map(fn(item) {
                          let key =
                            decode.run(item, decode.string) |> result.unwrap("")
                          case c.has(args, key) {
                            True -> Ok(#(key, c.j(c.field(args, key))))
                            False -> Error(Nil)
                          }
                        })
                        |> c.obj
                        |> json.to_string
                        |> c.parse
                      let answer =
                        dispatch(
                          ctx,
                          c.Request(
                            c.s(mapping, "method"),
                            string.split(path, "/")
                              |> list.filter(fn(x) { x != "" }),
                            query,
                            body,
                            req.user,
                            req.token,
                          ),
                        )
                      rpc_ok(
                        id,
                        c.obj([
                          #(
                            "content",
                            json.preprocessed_array([
                              c.obj([
                                #("type", json.string("text")),
                                #(
                                  "text",
                                  json.string(json.to_string(answer.body)),
                                ),
                              ]),
                            ]),
                          ),
                          #("isError", json.bool(answer.status >= 400)),
                        ]),
                      )
                    }
                  }
              }
            }
            _ -> rpc(id, -32_601, "Method not found")
          }
        }
      }
    _ -> c.err(405, "MCP accepts POST requests")
  }
}

@external(erlang, "gitclub_ffi", "init")
fn init() -> Nil

@external(erlang, "gitclub_ffi", "protect")
fn protect(
  run: fn() -> response.Response(mist.ResponseData),
) -> response.Response(mist.ResponseData)

fn valid_arguments(args, schema) {
  let properties = c.field(schema, "properties")
  let fields = decode.run(args, decode.dict(decode.string, decode.dynamic))
  case fields {
    Error(_) -> False
    Ok(fields) -> {
      let required =
        c.array(schema, "required")
        |> list.all(fn(key) {
          c.has(args, decode.run(key, decode.string) |> result.unwrap(""))
        })
      required
      && list.all(dict.to_list(fields), fn(pair) {
        let key = pair.0
        let value = pair.1
        let spec = c.field(properties, key)
        c.has(properties, key)
        && case c.s(spec, "type") {
          "string" -> decode.run(value, decode.string) |> result.is_ok
          "integer" -> decode.run(value, decode.int) |> result.is_ok
          "boolean" -> decode.run(value, decode.bool) |> result.is_ok
          "array" ->
            decode.run(value, decode.list(decode.dynamic)) |> result.is_ok
          "object" ->
            decode.run(value, decode.dict(decode.string, decode.dynamic))
            |> result.is_ok
          _ -> False
        }
      })
    }
  }
}

@external(erlang, "gitclub_ffi", "timed")
fn timed(ms: Int, run: fn() -> a) -> a
