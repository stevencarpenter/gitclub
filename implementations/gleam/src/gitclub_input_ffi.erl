-module(gitclub_input_ffi).
-export([git_input/3, git_diff/2, git_blob/2]).

%% OS primitive only: bounded subprocess I/O, timeout and process-group cleanup.
%% Git authorization, ref selection, and merge policy are implemented in Gleam.
script() -> <<
"import os,sys,subprocess,selectors,time,signal\n"
"mode,repo,data,*args=sys.argv[1:]\n"
"limit=524288 if mode=='blob' else 1048576\n"
"p=subprocess.Popen(['git','--git-dir='+repo,*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)\n"
"s=selectors.DefaultSelector();s.register(p.stdout,selectors.EVENT_READ)\n"
"out=bytearray();truncated=False;deadline=time.monotonic()+30\n"
"def stop():\n"
" try: p.kill()\n"
" except ProcessLookupError: pass\n"
"try:\n"
" p.stdin.write(data.encode());p.stdin.close()\n"
" while s.get_map():\n"
"  if time.monotonic()>deadline: raise TimeoutError()\n"
"  for key,_ in s.select(min(0.2,max(0,deadline-time.monotonic()))):\n"
"   b=os.read(key.fd,65536)\n"
"   if not b: s.unregister(key.fileobj);continue\n"
"   out.extend(b[:max(0,limit+1-len(out))])\n"
"   if len(out)>limit:\n"
"    truncated=True;stop();s.unregister(key.fileobj);break\n"
" code=p.wait(timeout=max(0.1,deadline-time.monotonic()))\n"
" if code!=0 and not (mode in ('diff','blob') and truncated): sys.exit(1)\n"
" text=bytes(out[:limit]) if mode=='blob' else bytes(out[:limit]).decode('utf8','replace').encode('utf8')\n"
" if len(text)>limit: text=text[:limit].decode('utf8','ignore').encode('utf8');truncated=True\n"
" sys.stdout.buffer.write((b'1' if truncated else b'0')+text)\n"
"except (TimeoutError,subprocess.TimeoutExpired,BrokenPipeError):\n"
" sys.exit(1)\n"
"finally:\n"
" s.close()\n"
" if p.poll() is None:\n"
"  stop();p.wait()\n"
>>.

git_input(Repo,Args,Input) ->
 case gitclub_ffi:command(<<"python3">>,[<<"-c">>,script(),<<"input">>,Repo,Input|Args],[],35000,1048577) of
  {ok,<<"0",Output/binary>>} -> {ok,Output};
  _ -> {error,<<"Git reference transaction failed">>}
 end.

git_diff(Repo,Args) ->
 case gitclub_ffi:command(<<"python3">>,[<<"-c">>,script(),<<"diff">>,Repo,<<>>|Args],[],35000,1048577) of
  {ok,<<"0",Output/binary>>} -> {ok,{Output,false}};
  {ok,<<"1",Output/binary>>} -> {ok,{Output,true}};
  _ -> {error,<<"Git diff failed">>}
 end.

git_blob(Repo,Args) ->
 case gitclub_ffi:command(<<"python3">>,[<<"-c">>,script(),<<"blob">>,Repo,<<>>|Args],[],35000,524289) of
  {ok,<<"0",Output/binary>>} -> {ok,{Output,false}};
  {ok,<<"1",Output/binary>>} -> {ok,{Output,true}};
  _ -> {error,<<"Git blob failed">>}
 end.
