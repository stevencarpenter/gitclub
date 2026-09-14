import gitclub/common as c
import gitclub/auth
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option,None,Some}
import gleam/result
import gleam/string
import mist
import mist/internal/http as mist_http
import sqlight

pub fn serve(ctx: c.Context,req: request.Request(mist.Connection)) {
 let token=auth.token_from(req) let user=auth.authenticate(ctx,token)
 let segments=request.path_segments(req)
 case segments {
 [owner,name,..suffix] -> {
 let name=string.drop_end(name,4)
 let found=c.one(ctx,"SELECT json_object('id',id) FROM repositories WHERE owner=? AND name=?",[sqlight.text(owner),sqlight.text(name)])
 case found { Error(_) -> failure(404,"Repository not found") Ok(found) -> case c.repo(ctx,c.i(found,"id"),c.i(user,"id")) { Error(_) -> failure(401,"Git authentication required") Ok(repo) -> {
 let query=request.get_query(req) |> result.unwrap([])
 let service=list.key_find(query,"service") |> result.unwrap("")
 let receive=service=="git-receive-pack" || suffix==["git-receive-pack"]
 let allowed=case req.method,suffix { http.Get,["info","refs"] -> list.contains(["git-upload-pack","git-receive-pack"],service) http.Post,["git-upload-pack"] | http.Post,["git-receive-pack"] -> True _,_ -> False }
 case allowed { False -> failure(404,"Git endpoint not found") True -> case receive && !c.writer(repo) { True -> failure(403,"Repository write role required") False -> execute(ctx,req,c.i(repo,"id"),c.s(user,"username"),token,suffix) } }
 } } }
 }
 _ -> failure(404,"Git endpoint not found")
 }
}
fn execute(ctx: c.Context,req: request.Request(mist.Connection),id: Int,username: String,token: String,suffix: List(String)) {
 let length=request.get_header(req,"content-length") |> result.unwrap("")
 case int.parse(length) |> result.unwrap(0) > 268435456 {
 True -> failure(413,"Git request exceeds 256 MiB")
 False -> {
 let env=[#("GIT_CONFIG_NOSYSTEM","1"),#("GIT_CONFIG_GLOBAL","/dev/null"),#("GIT_TERMINAL_PROMPT","0"),#("GIT_NO_REPLACE_OBJECTS","1"),#("REQUEST_METHOD",http.method_to_string(req.method)),#("QUERY_STRING",case req.query { None -> "" Some(q) -> q }),#("CONTENT_TYPE",request.get_header(req,"content-type") |> result.unwrap("")),#("CONTENT_LENGTH",length),#("GIT_PROJECT_ROOT",ctx.data_dir <> "/repos"),#("PATH_INFO","/" <> int.to_string(id) <> ".git/" <> string.join(suffix,"/")),#("GIT_HTTP_EXPORT_ALL","1"),#("REMOTE_USER",username),#("GIT_PROTOCOL",request.get_header(req,"git-protocol") |> result.unwrap("")),#("GITCLUB_URL",c.env("GITCLUB_INTERNAL_URL",ctx.public_url)),#("GITCLUB_TOKEN",token),#("GITCLUB_REPO_ID",int.to_string(id))]
 case start("git",["http-backend"],env) {
 Error(_) -> failure(503,"Git transfer unavailable or capacity reached")
 Ok(pipe) -> case stream(req,268435456) {
 Error(_) -> { close(pipe) failure(400,"Cannot read Git request") }
 Ok(next) -> {
 let _=input(pipe,fn(){case forward(next,pipe,0) { Ok(_) -> Nil Error(_) -> close(pipe) }})
 case headers(pipe,<<>>) {
 Error(_) -> {close(pipe) failure(502,"Git backend did not return valid headers")}
 Ok(#(header,initial)) -> {
 let headers=string.split(header,"\r\n") |> list.filter_map(fn(line){case string.split_once(line,":") { Ok(#(key,value)) -> Ok(#(string.lowercase(key),string.trim(value))) Error(_) -> Error(Nil) }})
 let status=list.key_find(headers,"status") |> result.unwrap("200") |> string.split(" ") |> list.first |> result.unwrap("200") |> int.parse |> result.unwrap(502)
 let reply=response.Response(status,[#("connection","close"),..list.filter(headers,fn(h){h.0!="status" && h.0!="content-length" && h.0!="transfer-encoding" && h.0!="connection"})],Nil)
 mist.chunked(req,reply,fn(subject){
   let _=attach(pipe)
   process.send(subject,Nil)
   #(subject,initial)
 },fn(state,_message,connection){
   let #(subject,pending)=state
   let chunk=case pending { <<>> -> read(pipe) _ -> Ok(pending) }
   case chunk {
    Error(_) -> {close(pipe) mist.chunk_stop_abnormal("Git transfer failed or timed out")}
    Ok(<<>>) -> {close(pipe) mist.chunk_stop()}
    Ok(data) -> case mist.send_chunk(connection,data) {
      Error(_) -> {close(pipe) mist.chunk_stop_abnormal("Git client disconnected")}
      Ok(_) -> {process.send(subject,Nil) mist.chunk_continue(#(subject,<<>>))}
    }
   }
 })
 }
 }
 }
 }
 }
 }
 }
}
fn forward(next: fn(Int)->Result(mist.Chunk,mist.ReadError),pipe: Pipe,size: Int) -> Result(Nil,String) {
 case next(65536) {
 Error(_) -> Error("Git request disconnected")
 Ok(mist.Done) -> finish_input(pipe)
 Ok(mist.Chunk(data,next)) -> {
 let size=size+bit_array.byte_size(data)
 case size>268435456 {
 True -> Error("Git request exceeds 256 MiB")
 False -> {use _ <- result.try(write(pipe,data)) forward(next,pipe,size)}
 }
 }
 }
}
// CGI headers are bounded to 16 KiB; response data remains binary throughout.
fn headers(pipe: Pipe,data: BitArray) -> Result(#(String,BitArray),String) {
 case header_end(data,0) {
 Some(at) if at<=16384 -> {
 let assert Ok(head)=bit_array.slice(data,0,at)
 let assert Ok(rest)=bit_array.slice(data,at+4,bit_array.byte_size(data)-at-4)
 bit_array.to_string(head) |> result.map(fn(text){#(text,rest)}) |> result.replace_error("Invalid CGI header encoding")
 }
 _ -> case bit_array.byte_size(data)>16384 {
 True -> Error("CGI headers exceed 16 KiB")
 False -> {use chunk <- result.try(read(pipe)) case chunk {<<>> -> Error("Missing CGI headers") _ -> headers(pipe,bit_array.append(data,chunk))}}
 }
 }
}
fn header_end(data: BitArray,at: Int) -> Option(Int) {
 case data {
 <<13,10,13,10,_rest:bytes>> -> Some(at)
 <<_,rest:bytes>> -> header_end(rest,at+1)
 _ -> None
 }
}
fn failure(status,text) { response.new(status) |> response.set_header("www-authenticate","Basic realm=\"GitClub\"") |> response.set_header("connection","close") |> response.set_body(mist.Bytes(bytes_tree.from_string(text))) }
pub type Pipe
@external(erlang,"gitclub_transport_ffi","start") fn start(executable: String,args: List(String),env: List(#(String,String))) -> Result(Pipe,String)
@external(erlang,"gitclub_transport_ffi","write") fn write(pipe: Pipe,data: BitArray) -> Result(Nil,String)
@external(erlang,"gitclub_transport_ffi","finish_input") fn finish_input(pipe: Pipe) -> Result(Nil,String)
@external(erlang,"gitclub_transport_ffi","read") fn read(pipe: Pipe) -> Result(BitArray,String)
@external(erlang,"gitclub_transport_ffi","close") fn close(pipe: Pipe) -> Nil
@external(erlang,"gitclub_transport_ffi","attach") fn attach(pipe: Pipe) -> Result(Nil,String)
@external(erlang,"gitclub_transport_ffi","input") fn input(pipe: Pipe,run: fn()->Nil) -> Result(Nil,String)

// Mist 6 buffers an entire HTTP chunk before yielding. Decode framing here so
// a peer's chunk-size field cannot determine our allocation size.
type Framing { Fixed(Int) Size Data(Int) End Trailers(Int) }
pub fn stream(req: request.Request(mist.Connection),limit: Int) -> Result(fn(Int)->Result(mist.Chunk,mist.ReadError),mist.ReadError) {
 use _ <- result.try(mist_http.handle_continue(req) |> result.replace_error(mist.MalformedBody))
 let assert mist_http.Initial(buffer)=req.body.body
 let encoding=request.get_header(req,"transfer-encoding")
 let length=request.get_header(req,"content-length")
 let framing=case encoding,length {
 Ok("chunked"),Error(_) -> Ok(Size)
 Error(_),Error(_) -> Ok(Fixed(0))
 Error(_),Ok(text) -> case int.parse(text) {
  Ok(n) if n>=0 && n<=limit -> Ok(Fixed(n))
  Ok(n) if n>limit -> Error(mist.ExcessBody)
  _ -> Error(mist.MalformedBody)
 }
 _,_ -> Error(mist.MalformedBody)
 }
 use framing <- result.map(framing)
 consume(req,buffer,framing,0,limit)
}
fn consume(req,buffer,framing,total,limit) -> fn(Int)->Result(mist.Chunk,mist.ReadError) {
 fn(size){next_chunk(req,buffer,framing,total,limit,int.max(1,int.min(size,65536)))}
}
fn next_chunk(req,buffer,framing,total,limit,size) -> Result(mist.Chunk,mist.ReadError) {
 case framing {
 Fixed(0) -> Ok(mist.Done)
 Fixed(left) | Data(left) -> {
 let take=int.min(left,size)
 use #(data,rest) <- result.try(take_bytes(req,buffer,take))
 let received=bit_array.byte_size(data)
 let framing=case framing {Fixed(_) -> Fixed(left-received) _ -> case left==received {True -> End False -> Data(left-received)}}
 Ok(mist.Chunk(data,consume(req,rest,framing,total+received,limit)))
 }
 Size -> {
 use #(line,rest) <- result.try(read_line(req,buffer,<<>>,1024))
 let text=bit_array.to_string(line) |> result.unwrap("") |> string.split(";") |> list.first |> result.unwrap("")
 case c.regex(text,"^[0-9A-Fa-f]+$") {False -> Error(mist.MalformedBody) True -> case int.base_parse(text,16) {
  Ok(n) if n>limit-total -> Error(mist.ExcessBody)
  Ok(0) -> next_chunk(req,rest,Trailers(0),total,limit,size)
  Ok(n) if n>0 -> next_chunk(req,rest,Data(n),total,limit,size)
  _ -> Error(mist.MalformedBody)
 }}
 }
 End -> {
 use #(line,rest) <- result.try(read_line(req,buffer,<<>>,2))
 case line {<<>> -> next_chunk(req,rest,Size,total,limit,size) _ -> Error(mist.MalformedBody)}
 }
 Trailers(count) -> {
 use #(line,rest) <- result.try(read_line(req,buffer,<<>>,8192-count))
 case line {<<>> -> Ok(mist.Done) _ -> next_chunk(req,rest,Trailers(count+bit_array.byte_size(line)+2),total,limit,size)}
 }
 }
}
fn take_bytes(req: request.Request(mist.Connection),buffer: BitArray,size: Int) -> Result(#(BitArray,BitArray),mist.ReadError) {
 case buffer {
 <<>> -> socket_read(req.body.socket,req.body.transport,size) |> result.map(fn(data){#(data,<<>> )}) |> result.replace_error(mist.MalformedBody)
 _ -> {
 let amount=int.min(size,bit_array.byte_size(buffer))
 let assert Ok(data)=bit_array.slice(buffer,0,amount)
 let assert Ok(rest)=bit_array.slice(buffer,amount,bit_array.byte_size(buffer)-amount)
 Ok(#(data,rest))
 }
 }
}
fn read_line(req,buffer,line,limit) -> Result(#(BitArray,BitArray),mist.ReadError) {
 case bit_array.byte_size(line)>limit {True -> Error(mist.MalformedBody) False -> {
 use #(byte,rest) <- result.try(take_bytes(req,buffer,1))
 case byte {
 <<13>> -> {
 use #(lf,rest) <- result.try(take_bytes(req,rest,1))
 case lf {<<10>> -> Ok(#(line,rest)) _ -> Error(mist.MalformedBody)}
 }
 <<10>> | <<>> -> Error(mist.MalformedBody)
 _ -> read_line(req,rest,bit_array.append(line,byte),limit)
 }
 }}
}
@external(erlang,"gitclub_transport_ffi","socket_read") fn socket_read(socket: socket,transport: transport,size: Int) -> Result(BitArray,Nil)
