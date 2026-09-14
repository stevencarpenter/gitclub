-module(gitclub_transport_ffi).
-export([start/3,write/2,finish_input/1,read/1,close/1,attach/1,input/2,socket_read/3]).

%% Generic bounded subprocess pipes. Policy, argv and CGI parsing stay in Gleam.
%% Only one 64 KiB read and one 64 KiB write may be outstanding.
script() -> <<
"import os, signal, struct, subprocess, sys, threading\n"
"\n"
"child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE,\n"
"                         stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)\n"
"output_lock = threading.Lock()\n"
"write_slot = threading.Semaphore(1)\n"
"read_slot = threading.Semaphore(1)\n"
"\n"
"def send(tag, data=b''):\n"
"    packet = tag + data\n"
"    with output_lock:\n"
"        sys.stdout.buffer.write(struct.pack('>I', len(packet)) + packet)\n"
"        sys.stdout.buffer.flush()\n"
"\n"
"def write(data):\n"
"    try:\n"
"        if data[:1] == b'E':\n"
"            child.stdin.close()\n"
"        else:\n"
"            view = memoryview(data)[1:]\n"
"            while view:\n"
"                view = view[os.write(child.stdin.fileno(), view):]\n"
"        send(b'w')\n"
"    except (OSError, ValueError):\n"
"        send(b'x')\n"
"    finally:\n"
"        write_slot.release()\n"
"\n"
"def read():\n"
"    try:\n"
"        data = os.read(child.stdout.fileno(), 65536)\n"
"        if data:\n"
"            send(b'd', data)\n"
"        else:\n"
"            send(b'z' if child.wait() == 0 else b'x')\n"
"    except (OSError, ValueError):\n"
"        send(b'x')\n"
"    finally:\n"
"        read_slot.release()\n"
"\n"
"def exact(size):\n"
"    data = bytearray()\n"
"    while len(data) < size:\n"
"        part = sys.stdin.buffer.read(size - len(data))\n"
"        if not part:\n"
"            raise EOFError()\n"
"        data.extend(part)\n"
"    return bytes(data)\n"
"\n"
"def timeout(*_):\n"
"    raise TimeoutError()\n"
"\n"
"signal.signal(signal.SIGALRM, timeout)\n"
"signal.alarm(120)\n"
"try:\n"
"    while True:\n"
"        size, = struct.unpack('>I', exact(4))\n"
"        if size < 1 or size > 65537:\n"
"            raise ValueError('invalid pipe frame')\n"
"        data = exact(size)\n"
"        if data[:1] in (b'W', b'E'):\n"
"            write_slot.acquire()\n"
"            threading.Thread(target=write, args=(data,), daemon=True).start()\n"
"        elif data == b'R':\n"
"            read_slot.acquire()\n"
"            threading.Thread(target=read, daemon=True).start()\n"
"        else:\n"
"            raise ValueError('invalid pipe operation')\n"
"except (EOFError, TimeoutError, BrokenPipeError):\n"
"    pass\n"
"finally:\n"
"    try:\n"
"        os.killpg(child.pid, signal.SIGKILL)\n"
"    except ProcessLookupError:\n"
"        pass\n"
"    child.wait()\n"
>>.

start(Executable,Args,Extra) ->
 Owner=self(), Ref=make_ref(),
 Pid=spawn(fun() ->
  Count=ets:update_counter(gitclub_limits,transfer,{2,1},{transfer,0}),
  try
   case Count>8 of true -> Owner!{Ref,{error,<<"Git transfer capacity reached">>}}; false ->
    Mon=monitor(process,Owner),
    %% Start with no inherited environment; only executable lookup and explicit CGI values.
    Clear=[{K,false} || {K,_} <- os:env()],
    Path=case os:getenv("PATH") of false -> "/usr/bin:/bin"; Value -> Value end,
    Env=Clear++[{"PATH",Path},{"LANG","C.UTF-8"}]++
       [{binary_to_list(K),binary_to_list(V)} || {K,V}<-Extra],
    Port=open_port({spawn_executable,os:find_executable("python3")},
      [binary,exit_status,use_stdio,hide,{packet,4},
       {args,["-u","-c",binary_to_list(script()),binary_to_list(Executable)|[binary_to_list(A)||A<-Args]]},
       {env,Env}]),
    Timer=erlang:send_after(120000,self(),deadline),
    Owner!{Ref,{ok,self()}},
    try loop(Port,{Owner,Mon},undefined,undefined,undefined)
    after erlang:cancel_timer(Timer), try port_close(Port) catch _:_ -> ok end end
   end
  catch _:_ -> Owner!{Ref,{error,<<"Cannot start Git transfer">>}}
  after ets:update_counter(gitclub_limits,transfer,{2,-1}) end
 end),
 Mon=monitor(process,Pid),
 receive {Ref,Result} -> demonitor(Mon,[flush]),Result;
 {'DOWN',Mon,process,Pid,_} -> {error,<<"Cannot start Git transfer">>}
 after 5000 -> Pid!stop,demonitor(Mon,[flush]),{error,<<"Cannot start Git transfer">>}
 end.

rpc(Pid,Op) ->
 Ref=make_ref(), Mon=monitor(process,Pid), Pid!{self(),Ref,Op},
 receive {Ref,Reply} -> demonitor(Mon,[flush]),Reply;
 {'DOWN',Mon,process,Pid,_} -> {error,<<"Git transfer closed or timed out">>}
 after 121000 -> demonitor(Mon,[flush]),{error,<<"Git transfer timed out">>}
 end.
write(Pid,Data) when byte_size(Data)=<65536 -> rpc(Pid,{write,<<"W",Data/binary>>}).
finish_input(Pid) -> rpc(Pid,{write,<<"E">>}).
read(Pid) -> rpc(Pid,read).
attach(Pid) -> rpc(Pid,attach).
input(Pid,Fun) -> rpc(Pid,{input,Fun}).
close(Pid) -> Pid!stop,nil.
reply(undefined,_) -> ok;
reply({Pid,Ref},Result) -> Pid!{Ref,Result}.
loop(Port,Owner,Reader,Writer,Input) ->
 receive
  {From,Ref,read} when Reader=:=undefined ->
   true=port_command(Port,<<"R">>),loop(Port,Owner,{From,Ref},Writer,Input);
  {From,Ref,{write,Data}} when Writer=:=undefined ->
   true=port_command(Port,Data),loop(Port,Owner,Reader,{From,Ref},Input);
  {From,Ref,attach} ->
   {_,OldMon}=Owner,demonitor(OldMon,[flush]), Mon=monitor(process,From),
   reply({From,Ref},{ok,nil}),loop(Port,{From,Mon},Reader,Writer,Input);
  {From,Ref,{input,Fun}} when Input=:=undefined ->
   Server=self(), Worker=spawn(fun() -> try Fun() catch _:_ -> Server!stop end end),
   reply({From,Ref},{ok,nil}),loop(Port,Owner,Reader,Writer,Worker);
  {Port,{data,<<"w">>}} -> reply(Writer,{ok,nil}),loop(Port,Owner,Reader,undefined,Input);
  {Port,{data,<<"d",Data/binary>>}} -> reply(Reader,{ok,Data}),loop(Port,Owner,undefined,Writer,Input);
  {Port,{data,<<"z">>}} -> reply(Reader,{ok,<<>>}),loop(Port,Owner,undefined,Writer,Input);
  deadline ->
   {OwnerPid,_}=Owner,exit(OwnerPid,kill),
   case Input of undefined -> ok; _ -> exit(Input,kill) end;
  _ ->
   reply(Reader,{error,<<"Git transfer failed or timed out">>}),
   reply(Writer,{error,<<"Git transfer failed or timed out">>}),
   case Input of undefined -> ok; _ -> exit(Input,kill) end
 end.

socket_read(Socket,Transport,Size) when Size>0,Size=<65536 ->
 Module=case Transport of tcp -> gen_tcp; ssl -> ssl end,
 case Module:recv(Socket,Size,15000) of {ok,Data} -> {ok,Data}; _ -> {error,nil} end.
