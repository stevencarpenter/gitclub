-module(gitclub_ffi).
-compile({no_auto_import,[now/0]}).
-export([now/0,env/2,absolute/1,mkdir/1,read_file/1,write_file/2,delete_file/1,random/0,sha256/1,password_hash/1,password_check/2,regex/2,command/5,lock_repo/3,basic_token/1,install_hooks/2,rate_allow/1,init/0,null/0,valid_utf8/1,valid_quarantine/2,append/2,file_head/1,protect/1,timed/2,read_optional/1,blob_text/2]).
now() -> erlang:system_time(millisecond).
env(Name,Default) -> case os:getenv(binary_to_list(Name)) of false -> Default; S -> list_to_binary(S) end.
absolute(Path) -> list_to_binary(canonical(filename:split(filename:absname(binary_to_list(Path))),"",0)).
canonical([],Acc,_) -> Acc;
canonical([Part|Rest],Acc,N) when N<40 -> Joined=filename:join(Acc,Part), case file:read_link(Joined) of {ok,Target} -> Abs=case filename:pathtype(Target) of absolute->Target;_->filename:join(filename:dirname(Joined),Target) end, canonical(filename:split(filename:absname(Abs))++Rest,"",N+1); _ -> canonical(Rest,Joined,N) end;
canonical(_,Acc,_) -> Acc.
mkdir(Path) -> ok = filelib:ensure_dir(filename:join(Path,<<".keep">>)), nil.
read_file(Path) -> case file:read_file(Path) of {ok,B} -> {ok,B}; _ -> {error,<<"Cannot read file">>} end.
write_file(Path,Data) ->
 Temp= <<Path/binary,".tmp-",(random())/binary>>,
 case file:write_file(Temp,Data,[sync,exclusive]) of
  ok -> case file:rename(Temp,Path) of
   ok -> case command(<<"python3">>,[<<"-c">>,<<"import os,sys; f=os.open(sys.argv[1],os.O_RDONLY); os.fsync(f); os.close(f)">>,filename:dirname(Path)],[],30000,4096) of {ok,_}->{ok,nil}; _->{error,<<"Cannot sync parent directory">>} end;
   _ -> file:delete(Temp),{error,<<"Cannot publish file">>}
  end;
  _ -> file:delete(Temp),{error,<<"Cannot write file">>}
 end.
delete_file(Path) -> file:delete(Path), nil.
random() -> binary:encode_hex(crypto:strong_rand_bytes(32),lowercase).
sha256(Text) -> binary:encode_hex(crypto:hash(sha256,Text),lowercase).
password_hash(P) -> S=crypto:strong_rand_bytes(16), H=crypto:pbkdf2_hmac(sha256,P,S,600000,32), <<"pbkdf2_sha256$600000$",(binary:encode_hex(S,lowercase))/binary,"$",(binary:encode_hex(H,lowercase))/binary>>.
password_check(P,Hash) -> try [<<"pbkdf2_sha256">>,<<"600000">>,S,H]=binary:split(Hash,<<"$">>,[global]), Expected=binary:decode_hex(H), Actual=crypto:pbkdf2_hmac(sha256,P,binary:decode_hex(S),600000,32), crypto:hash_equals(Expected,Actual) catch _:_ -> false end.
regex(Text,Pattern) -> case re:run(Text,Pattern,[{capture,none}]) of match->true; _->false end.
lock_repo(_Ctx,Id,Fun) -> gitclub_mutex:lock(Id,Fun).
init() -> {ok,_}=gitclub_mutex:start_link(), ets:new(gitclub_limits,[named_table,public,set]), ets:insert(gitclub_limits,{git,0}), nil.
rate_allow(Peer) ->
 T=now() div 60000, Key={rate,Peer,T},
 case ets:info(gitclub_limits,size)>=10000 of true -> ets:select_delete(gitclub_limits,[{{{rate,'_','$1'},'_'},[{'<','$1',T}], [true]}]); false -> ok end,
 case ets:member(gitclub_limits,Key) orelse ets:info(gitclub_limits,size)<10000 of
  true -> ets:update_counter(gitclub_limits,Key,{2,1},{Key,0})=<30;
  false -> false
 end.

command(Executable,Args,Extra,Timeout,Limit) ->
 N=ets:update_counter(gitclub_limits,git,{2,1}),
 try case N>8 of true -> {error,<<"Git operation capacity reached">>}; false ->
  case os:find_executable(binary_to_list(Executable)) of false -> {error,<<"Executable unavailable">>}; Exe ->
   Sanitized=[{K,false} || K<- ["GIT_DIR","GIT_WORK_TREE","GIT_CONFIG","GIT_CONFIG_COUNT","GIT_CONFIG_PARAMETERS","GIT_INDEX_FILE","GIT_OBJECT_DIRECTORY","GIT_ALTERNATE_OBJECT_DIRECTORIES","GIT_TRACE","GIT_TRACE_PACKET","GIT_SSH_COMMAND","GIT_EXTERNAL_DIFF","GIT_PROXY_COMMAND"]],
   Env=Sanitized++[{"GIT_CONFIG_NOSYSTEM","1"},{"GIT_CONFIG_GLOBAL","/dev/null"},{"GIT_TERMINAL_PROMPT","0"},{"GIT_NO_REPLACE_OBJECTS","1"}]++[{binary_to_list(K),binary_to_list(V)} || {K,V}<-Extra],
   Python=os:find_executable("python3"),
   Port=open_port({spawn_executable,Python},[binary,exit_status,use_stdio,hide,{args,["-c",binary_to_list(command_script()),integer_to_list(Timeout),integer_to_list(Limit),Exe|[binary_to_list(A)||A<-Args]]},{env,Env}]),
   collect(Port,now()+Timeout,Limit,[],0)
  end
 end after ets:update_counter(gitclub_limits,git,{2,-1}) end.
collect(Port,Deadline,Limit,Acc,Size) ->
 receive {Port,{data,B}} when Size+byte_size(B)=<Limit -> collect(Port,Deadline,Limit,[B|Acc],Size+byte_size(B));
 {Port,{data,_}} -> try port_close(Port) catch _:_ -> ok end, {error,<<"Git output exceeds limit">>};
 {Port,{exit_status,0}} -> {ok,iolist_to_binary(lists:reverse(Acc))};
 {Port,{exit_status,_}} -> {error,<<"Git operation failed">>}
 after max(0,Deadline-now()) -> try port_close(Port) catch _:_ -> ok end, {error,<<"Git operation timed out">>}
 end.
basic_token(Header) -> try <<"Basic ",Encoded/binary>>=Header, [_U,Token]=binary:split(base64:decode(Encoded),<<":">>), Token catch _:_ -> <<>> end.
install_hooks(Path,Shared) ->
 try lists:foreach(fun(Name) -> Target=filename:join([Path,<<"hooks">>,Name]), file:delete(Target), ok=file:make_symlink(filename:join(Shared,<<"git-hook.py">>),Target) end,[<<"pre-receive">>,<<"post-receive">>]),{ok,nil} catch _:_ -> {error,<<"Cannot install Git hooks">>} end.

null() -> null.
valid_utf8(B) -> is_binary(unicode:characters_to_binary(B)).
valid_quarantine(Repo,Path) -> Prefix= <<(absolute(Repo))/binary,"/objects/tmp_objdir-incoming-">>, case Path of <<Prefix:(byte_size(Prefix))/binary,Rest/binary>> -> binary:match(Rest,<<"/">>)=:=nomatch andalso binary:match(Rest,<<"..">>)=:=nomatch andalso filelib:is_dir(Path); _ -> false end.
append(Path,Data) -> case file:write_file(Path,Data,[append,raw]) of ok -> {ok,nil}; _ -> {error,<<"Cannot append file">>} end.
file_head(Path) -> case file:open(Path,[read,binary,raw]) of {ok,F} -> R=file:read(F,65536), file:close(F), case R of {ok,B} -> case binary:match(B,<<"\r\n\r\n">>) of {P,4} -> {ok,{binary:part(B,0,P),P+4}}; _ -> {error,<<"Invalid CGI headers">>} end; _ -> {error,<<"Empty CGI response">>} end; _ -> {error,<<"Cannot open CGI response">>} end.
protect(Run) -> try Run() catch error:gitclub_busy -> {response,503,[{<<"content-type">>,<<"application/json">>},{<<"retry-after">>,<<"1">>}],{bytes,<<"{\"error\":\"Server busy; retry shortly\"}">>}}; Class:_Reason:_Stack -> logger:error("request failed (~p)",[Class]), {response,500,[{<<"content-type">>,<<"application/json">>}],{bytes,<<"{\"error\":\"Internal operation failed\"}">>}} end.

timed(Millis,Run) -> {ok,Timer}=timer:exit_after(Millis,self(),kill), try Run() after timer:cancel(Timer) end.

command_script() -> <<
"import os,sys,subprocess,selectors,time,signal\n"
"timeout,limit=map(int,sys.argv[1:3]);p=subprocess.Popen(sys.argv[3:],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)\n"
"s=selectors.DefaultSelector();s.register(p.stdout,selectors.EVENT_READ);s.register(sys.stdin,selectors.EVENT_READ);deadline=time.monotonic()+timeout/1000;size=0\n"
"try:\n"
" while p.stdout in [k.fileobj for k in s.get_map().values()]:\n"
"  if time.monotonic()>deadline: raise TimeoutError()\n"
"  for key,_ in s.select(0.1):\n"
"   if key.fileobj is sys.stdin: raise BrokenPipeError()\n"
"   b=os.read(key.fd,65536)\n"
"   if not b: s.unregister(key.fileobj);continue\n"
"   size+=len(b)\n"
"   if size>limit: raise OverflowError()\n"
"   sys.stdout.buffer.write(b);sys.stdout.buffer.flush()\n"
" sys.exit(p.wait(timeout=max(.1,deadline-time.monotonic())))\n"
"except (TimeoutError,subprocess.TimeoutExpired,BrokenPipeError,OverflowError): sys.exit(1)\n"
"finally:\n"
" try: os.killpg(p.pid,signal.SIGKILL)\n"
" except ProcessLookupError: pass\n"
" p.wait()\n"
>>.

read_optional(Path) -> case file:open(Path,[read,binary,raw]) of {error,enoent} -> {ok,none}; {ok,F} -> Result=file:read(F,8388609),file:close(F),case Result of eof -> {ok,{some,<<>>}}; {ok,B} when byte_size(B)=<8388608 -> {ok,{some,B}}; _ -> {error,<<"Cannot read Git ref metadata">>} end; _ -> {error,<<"Cannot read Git ref metadata">>} end.

blob_text(B,Truncated) -> case binary:match(B,<<0>>) of nomatch -> case unicode:characters_to_binary(B) of Text when is_binary(Text) -> {Text,false}; {incomplete,Text,_} when Truncated -> {Text,false}; _ -> {<<>>,true} end; _ -> {<<>>,true} end.
