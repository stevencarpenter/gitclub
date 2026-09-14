-module(gitclub_mutex).
-behaviour(gen_server).
-export([start_link/0, lock/2, init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Local synchronization primitive. Work stays in the calling process, so
%% unrelated repository keys remain independent. Queue admission is bounded.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

lock(Key, Work) ->
    Ref = make_ref(),
    try gen_server:call(?MODULE, {acquire, Key, Ref}, 5000) of
        ok ->
            try Work()
            after gen_server:cast(?MODULE, {release, Key, self(), Ref}) end;
        busy -> erlang:error(gitclub_busy)
    catch
        exit:{timeout, _} ->
            gen_server:cast(?MODULE, {cancel, Key, self(), Ref}),
            erlang:error(gitclub_busy)
    end.

init([]) -> {ok, #{}}.

handle_call({acquire, Key, Ref}, From = {Pid, _}, State) ->
    case maps:find(Key, State) of
        error ->
            Monitor = erlang:monitor(process, Pid),
            {reply, ok, State#{Key => {Pid, Monitor, [Ref], queue:new()}}};
        {ok, {Pid, Monitor, Refs, Queue}} ->
            {reply, ok, State#{Key => {Pid, Monitor, [Ref | Refs], Queue}}};
        {ok, {Owner, Monitor, Refs, Queue}} ->
            case queue:len(Queue) >= 128 of
                true -> {reply, busy, State};
                false ->
                    Waiter = {Pid, Ref, From, erlang:monitor(process, Pid)},
                    {noreply, State#{Key => {Owner, Monitor, Refs, queue:in(Waiter, Queue)}}}
            end
    end.

handle_cast({release, Key, Pid, Ref}, State) ->
    {noreply, release(Key, Pid, Ref, State)};
handle_cast({cancel, Key, Pid, Ref}, State) ->
    case maps:find(Key, State) of
        {ok, {Pid, _, Refs, _}} ->
            case lists:member(Ref, Refs) of
                true -> {noreply, release(Key, Pid, Ref, State)};
                false -> {noreply, State}
            end;
        {ok, {Owner, Monitor, Refs, Queue}} ->
            Kept = lists:filter(fun({P, R, _, M}) ->
                case P =:= Pid andalso R =:= Ref of
                    true -> erlang:demonitor(M, [flush]), false;
                    false -> true
                end
            end, queue:to_list(Queue)),
            {noreply, State#{Key => {Owner, Monitor, Refs, queue:from_list(Kept)}}};
        error -> {noreply, State}
    end.

handle_info({'DOWN', Monitor, process, _, _}, State) ->
    Updated = maps:fold(fun(Key, {Owner, M, Refs, Queue}, Acc) ->
        case M =:= Monitor of
            true -> handoff(Key, Queue, Acc);
            false ->
                Kept = queue:from_list([W || W = {_, _, _, WM} <- queue:to_list(Queue), WM =/= Monitor]),
                Acc#{Key => {Owner, M, Refs, Kept}}
        end
    end, #{}, State),
    {noreply, Updated};
handle_info(_, State) -> {noreply, State}.

release(Key, Pid, Ref, State) ->
    case maps:find(Key, State) of
        {ok, {Pid, Monitor, Refs, Queue}} ->
            case lists:delete(Ref, Refs) of
                [] -> erlang:demonitor(Monitor, [flush]), handoff(Key, Queue, maps:remove(Key, State));
                Remaining -> State#{Key => {Pid, Monitor, Remaining, Queue}}
            end;
        _ -> State
    end.

handoff(Key, Queue, State) ->
    case queue:out(Queue) of
        {empty, _} -> maps:remove(Key, State);
        {{value, {Pid, Ref, From, Monitor}}, Rest} ->
            case erlang:is_process_alive(Pid) of
                true ->
                    gen_server:reply(From, ok),
                    State#{Key => {Pid, Monitor, [Ref], Rest}};
                false -> erlang:demonitor(Monitor, [flush]), handoff(Key, Rest, State)
            end
    end.
