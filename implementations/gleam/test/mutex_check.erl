-module(mutex_check).
-export([run/0, global_reproduction/0]).

run() ->
    {ok, _} = gitclub_mutex:start_link(),
    Parent = self(),
    Owner = spawn(fun() -> gitclub_mutex:lock(fifo, fun() -> Parent ! held, receive release -> ok end end) end),
    receive held -> ok after 1000 -> error(owner_not_acquired) end,
    [begin
        spawn(fun() -> gitclub_mutex:lock(fifo, fun() -> Parent ! {order, N} end) end),
        wait_queue(fifo, N)
    end || N <- lists:seq(1, 4)],
    Owner ! release,
    [receive {order, N} -> ok after 1000 -> error({fifo_order, N}) end || N <- lists:seq(1, 4)],
    nested = gitclub_mutex:lock(reentrant, fun() -> gitclub_mutex:lock(reentrant, fun() -> nested end) end),
    Dead = spawn(fun() -> gitclub_mutex:lock(death, fun() -> Parent ! owned, receive never -> ok end end) end),
    receive owned -> ok end,
    spawn(fun() -> gitclub_mutex:lock(death, fun() -> Parent ! recovered end) end),
    wait_queue(death, 1),
    exit(Dead, kill),
    receive recovered -> ok after 1000 -> error(dead_owner_not_released) end,
    TimedOwner = spawn(fun() -> gitclub_mutex:lock(timeout, fun() -> Parent ! held_timeout, receive release -> ok end end) end),
    receive held_timeout -> ok end,
    Started = erlang:monotonic_time(millisecond),
    true = busy(fun() -> gitclub_mutex:lock(timeout, fun() -> error(timed_out_work_ran) end) end),
    Elapsed = erlang:monotonic_time(millisecond) - Started,
    true = Elapsed >= 4900 andalso Elapsed < 6000,
    wait_queue(timeout, 0),
    TimedOwner ! release,
    ok = gitclub_mutex:lock(timeout, fun() -> ok end),
    BoundOwner = spawn(fun() -> gitclub_mutex:lock(bound, fun() -> Parent ! held_bound, receive release -> ok end end) end),
    receive held_bound -> ok end,
    Waiters = [spawn(fun() -> gitclub_mutex:lock(bound, fun() -> Parent ! admitted end) end) || _ <- lists:seq(1, 128)],
    wait_queue(bound, 128),
    true = busy(fun() -> gitclub_mutex:lock(bound, fun() -> error(queue_exceeded) end) end),
    [exit(P, kill) || P <- Waiters],
    wait_queue(bound, 0),
    BoundOwner ! release,
    Stats = contend(fun(F) -> gitclub_mutex:lock(contention, F) end),
    true = lists:all(fun({_, First, Maximum}) -> First < 500 andalso Maximum < 500 end, Stats),
    io:format("PASS FIFO order, reentrancy, owner death, 5s deadline, waiter cleanup, 128 queue cap; contention ~p~n", [Stats]),
    ok.

wait_queue(Key, Expected) -> wait_queue(Key, Expected, 1000).
wait_queue(_, _, 0) -> error(queue_state_timeout);
wait_queue(Key, Expected, Attempts) ->
    State = sys:get_state(gitclub_mutex),
    Size = case maps:find(Key, State) of {ok, {_, _, _, Q}} -> queue:len(Q); error -> 0 end,
    case Size =:= Expected of true -> ok; false -> timer:sleep(1), wait_queue(Key, Expected, Attempts - 1) end.

contend(Lock) ->
    Parent = self(),
    [spawn(fun() ->
        Times = [begin T = erlang:monotonic_time(millisecond), Lock(fun() -> timer:sleep(10) end), erlang:monotonic_time(millisecond) - T end || _ <- lists:seq(1, 100)],
        Parent ! {done, {N, hd(Times), lists:max(Times)}}
    end) || N <- lists:seq(1, 4)],
    [receive {done, Stat} -> Stat after 30000 -> error(contention_timeout) end || _ <- lists:seq(1, 4)].

global_reproduction() ->
    Stats = contend(fun(F) -> global:trans({gitclub_reproduction, self()}, F) end),
    io:format("global:trans {worker,first_ms,max_ms}: ~p~n", [Stats]).

busy(Work) -> try Work() of _ -> false catch error:gitclub_busy -> true end.
