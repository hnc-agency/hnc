-module(pool_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

all() ->
	[
		checkout_checkin,
		transaction,
		strategy_fifo,
		strategy_lifo,
		blocking,
		blocking_userdeath,
		blocking_workerdeath,
		linger,
		change_opts
	].

checkout_checkin(_) ->
	{ok, _}=hnc:start_pool(test, #{size=>{3, 5}}, hnc_test_worker, undefined),
	#{idle:=3, out:=0, starting:=0, returning:=0}=hnc:pool_status(test),
	W=hnc:checkout(test),
	true=is_pid(W),
	true=erlang:is_process_alive(W),
	#{idle:=2, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	"TEST"=hnc_test_worker:echo(W, "TEST"),
	ok=hnc:checkin(test, W),
	#{idle:=Idle, out:=0, starting:=0, returning:=Returning}=hnc:pool_status(test),
	3=Idle+Returning,
	ok=hnc:stop_pool(test),
	ok.

transaction(_) ->
	{ok, _}=hnc:start_pool(test, #{}, hnc_test_worker, undefined),
	"TEST"=hnc:transaction(
		test,
		fun (W) ->
			true=is_pid(W),
			true=erlang:is_process_alive(W),
			hnc_test_worker:echo(W, "TEST")
		end
	),
	ok=hnc:stop_pool(test),
	ok.

strategy_fifo(_) ->
	{ok, _}=hnc:start_pool(test, #{strategy=>fifo, size=>{2, 2}}, hnc_test_worker, undefined),
	W1=hnc:checkout(test),
	W2=hnc:checkout(test),
	ok=hnc:checkin(test, W2),
	timer:sleep(100),
	idle=hnc:worker_status(test, W2),
	ok=hnc:checkin(test, W1),
	timer:sleep(100),
	idle=hnc:worker_status(test, W1),
	W2=hnc:checkout(test),
	W1=hnc:checkout(test),
	ok=hnc:stop_pool(test),
	ok.

strategy_lifo(_) ->
	{ok, _}=hnc:start_pool(test, #{strategy=>lifo, size=>{2, 2}}, hnc_test_worker, undefined),
	W1=hnc:checkout(test),
	W2=hnc:checkout(test),
	ok=hnc:checkin(test, W2),
	timer:sleep(100),
	idle=hnc:worker_status(test, W2),
	ok=hnc:checkin(test, W1),
	timer:sleep(100),
	idle=hnc:worker_status(test, W1),
	ok=hnc:checkin(test, W2),
	W1=hnc:checkout(test),
	ok=hnc:stop_pool(test),
	ok.

blocking(_) ->
	{ok, _}=hnc:start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{idle:=0, out:=0, starting:=0, returning:=0}=hnc:pool_status(test),
	_=hnc:checkout(test),
	#{idle:=0, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	ok=try
		hnc:checkout(test, 100)
	of
		_ -> error(unexpected_success)
	catch
		exit:timeout -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

blocking_userdeath(_) ->
	{ok, _}=hnc:start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{idle:=0, out:=0, starting:=0, returning:=0}=hnc:pool_status(test),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			_=hnc:checkout(test),
			Self ! {self(), ok},
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	Ref=monitor(process, Pid),
	ok=receive {Pid, ok} -> ok after 1000 -> exit(timeout) end,
	#{idle:=0, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	Pid ! {self(), ok},
	ok=receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> exit(timeout) end,
	_=hnc:checkout(test),
	#{idle:=0, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

blocking_workerdeath(_) ->
	{ok, _}=hnc:start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{idle:=0, out:=0, starting:=0, returning:=0}=hnc:pool_status(test),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			W=hnc:checkout(test),
			Self ! {self(), ok, W},
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end,
			exit(W, kill),
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	W=receive {Pid, ok, W1} -> W1 after 1000 -> exit(timeout) end,
	Ref=monitor(process, W),
	#{idle:=0, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	Pid ! {self(), ok},
	ok=receive {'DOWN', Ref, process, W, killed} -> ok after 1000 -> exit(timeout) end,
	Pid ! {self(), ok},
	_=hnc:checkout(test),
	#{idle:=0, out:=1, starting:=0, returning:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

linger(_) ->
	{ok, _}=hnc:start_pool(test, #{size=>{1, 2}, linger=>{10, 100}}, hnc_test_worker, undefined),
	W1=hnc:checkout(test),
	W2=hnc:checkout(test),
	#{idle:=0, out:=2, starting:=0, returning:=0}=hnc:pool_status(test),
	ok=hnc:checkin(test, W1),
	ok=hnc:checkin(test, W2),
	#{out:=0, starting:=0}=hnc:pool_status(test),
	timer:sleep(200),
	#{idle:=1, out:=0, starting:=0, returning:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

change_opts(_) ->
	{ok, _}=hnc:start_pool(test, #{}, hnc_test_worker, undefined),
	ok=hnc:set_strategy(test, fifo),
	fifo=hnc:get_strategy(test),
	ok=hnc:set_strategy(test, lifo),
	lifo=hnc:get_strategy(test),
	ok=hnc:set_size(test, {0, 1}),
	{0, 1}=hnc:get_size(test),
	ok=hnc:set_size(test, {1, 2}),
	{1, 2}=hnc:get_size(test),
	ok=hnc:set_linger(test, infinity),
	infinity=hnc:get_linger(test),
	ok=hnc:set_linger(test, {1000, 1000}),
	{1000, 1000}=hnc:get_linger(test),
	ok=hnc:stop_pool(test),
	ok.
