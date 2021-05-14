%% Copyright (c) 2020-2021, Jan Uhlig <juhlig@hnc-agency.org>
%% Copyright (c) 2020-2021, Maria Scott <maria-12648430@hnc-agency.org>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(pool_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-import(ct_helper, [doc/1]).

all() ->
	[{group, Group} || {Group, _, _} <- groups()].

groups() ->
	[
		{
			opts,
			[],
			[
				valid_opts,
				invalid_opts,
				change_opts
			]
		},
		{
			non_blocking,
			[],
			[
				checkout_checkin,
				checkout_start,
				checkin_not_owner,
				get_worker_not_owner,
				transaction,
				strategy_fifo,
				strategy_lifo
			]
		},
		{
			blocking,
			[],
			[
				blocking,
				blocking_userdeath,
				blocking_workerdeath
			]
		},
		{
			worker_start,
			[],
			[
				worker_start_ignore,
				worker_start_error,
				worker_start_crash,
				worker_start_junk,
				start_parallel,
				stop_parallel
			]
		},
		{
			on_return,
			[],
			[
				on_return,
				on_return_timeout,
				on_return_funcrash,
				on_return_workercrash
			]
		},
		{
			give_away,
			[],
			[
				give_away,
				give_away_not_owner
			]
		},
		{
			shrinking,
			[],
			[
				prune,
				linger
			]
		},
		{
			misc,
			[],
			[
				proxy,
				embedded,
				worker_status
			]
		}
	].

valid_opts(_) ->
	true=lists:all(
		fun ({Opt, Vals}) ->
			lists:all(
				fun (Val) ->
					ok=:=hnc:validate_opts(#{Opt => Val})
				end,
				Vals
			)
		end,
		[
			{size, [{0, 1}, {0, infinity}, {1, 1}, {1, 2}]},
			{strategy, [fifo, lifo]},
			{linger, [infinity, {0, 0}, {0, 1}, {1, 0}, {1, 1}]},
			{on_return, [undefined, {fun (_) -> ok end, infinity}, {fun (_) -> ok end, 0}, {fun (_) -> ok end, 1}]},
			{shutdown, [brutal_kill, infinity, 0, 1]}
		]
	),
	ok.

invalid_opts(_) ->
	true=lists:all(
		fun ({Opt, Vals}) ->
			lists:all(
				fun (Val) ->
					try
						hnc:validate_opts(#{Opt => Val})
					of
						ok -> false
					catch
						error:{badopt, Opt} ->
							true
					end
				end,
				Vals
			)
		end,
		[
			{size, [undefined, {undefined}, {undefined, 1}, {0, undefined}, {0, 0}, {-1, 0}, {-1, 1}, {-1, -1}, {-1, infinity}, {1, 0}]},
			{strategy, [undefined]},
			{linger, [undefined, {-1, 0}, {0, -1}, {-1, -1}, {undefined, 0}, {0, undefined}, {undefined, undefined}]},
			{on_return, [foo, {undefined, 0}, {fun (_) -> ok end, undefined}, {fun (_, _) -> ok end, 0}, {fun (_) -> ok end, -1}]},
			{shutdown, [undefined, -1]},
			{undefined, [undefined]}
		]
	),
	ok.

checkout_checkin(_) ->
	doc("Ensure that checking workers out and back in works."),
	{ok, _}=do_start_pool(test, #{size=>{2, 2}}, hnc_test_worker, undefined),
	#{available:=2, unavailable:=0, starting:=0}=hnc:pool_status(test),
	WRef=hnc:checkout(test),
	W=hnc:get_worker(WRef),
	true=is_pid(W),
	true=erlang:is_process_alive(W),
	#{available:=1, unavailable:=1, starting:=0}=hnc:pool_status(test),
	"TEST"=hnc_test_worker:echo(W, "TEST"),
	ok=hnc:checkin(WRef),
	timer:sleep(100),
	#{available:=2, unavailable:=0, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

checkout_start(_) ->
	doc("Ensure that checking workers out starts new workers when none available and below maximum."),
	{ok, _}=do_start_pool(test, #{size=>{1, 3}}, hnc_test_worker, undefined),
	#{available:=1, unavailable:=0, starting:=0}=hnc:pool_status(test),
	WRef1=hnc:checkout(test),
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	WRef2=hnc:checkout(test),
	#{available:=0, unavailable:=2, starting:=0}=hnc:pool_status(test),
	WRef3=hnc:checkout(test, 100),
	#{available:=0, unavailable:=3, starting:=0}=hnc:pool_status(test),
	{Pid, Ref}=spawn_monitor(
		fun () ->
			ok=try
				hnc:checkout(test, 200)
			of
				ok -> exit(unexpected_success)
			catch
				exit:timeout -> ok
			end
		end
	),
	ok=try
		hnc:checkout(test, 100)
	of
		ok -> exit(unexpected_success)
	catch
		exit:timeout -> ok
	end,
	ok=receive
		{'DOWN', Ref, process, Pid, normal} -> ok;
		{'DOWN', Ref, process, Pid, Reason} -> exit(Reason)
	after 1000 -> exit(timeout)
	end,
	ok=try
		hnc:checkout(test, 100)
	of
		ok -> exit(unexpected_success)
	catch
		exit:timeout -> ok
	end,
	ok=hnc:checkin(WRef1),
	ok=hnc:checkin(WRef2),
	ok=hnc:checkin(WRef3),
	timer:sleep(100),
	#{available:=3, unavailable:=0, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

get_worker_not_owner(_) ->
	doc("Ensure that only the owner of a worker can retrieve it from the identifier."),
	{ok, _}=do_start_pool(test, #{size=>{1, 1}}, hnc_test_worker, undefined),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			WRef=hnc:checkout(test),
			Self ! {self(), ok, WRef},
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	WRef=receive {Pid, ok, WRef1} -> WRef1 after 1000 -> exit(timeout) end,
	ok=try
		hnc:get_worker(WRef)
	of
		_ -> exit(unexpected_success)
	catch
		error:not_owner -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

checkin_not_owner(_) ->
	doc("Ensure that only the owner of a worker can check it in."),
	{ok, _}=do_start_pool(test, #{}, hnc_test_worker, undefined),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			WRef=hnc:checkout(test),
			Self ! {self(), ok, WRef},
			receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	WRef=receive {Pid, ok, WRef1} -> WRef1 after 1000 -> exit(timeout) end,
	ok=try
		   hnc:checkin(WRef)
	of
		ok -> exit(unexpected_succss)
	catch
		   error:not_owner -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

transaction(_) ->
	doc("Ensure that transactions work."),
	{ok, _}=do_start_pool(test, #{}, hnc_test_worker, undefined),
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
	doc("Ensure that checking out with the fifo strategy works."),
	{ok, _}=do_start_pool(test, #{strategy=>fifo, size=>{2, 2}}, hnc_test_worker, undefined),
	W1=hnc:checkout(test),
	W2=hnc:checkout(test),
	ok=hnc:checkin(W2),
	timer:sleep(100),
	idle=hnc:worker_status(W2),
	ok=hnc:checkin(W1),
	timer:sleep(100),
	idle=hnc:worker_status(W1),
	W2=hnc:checkout(test),
	W1=hnc:checkout(test),
	ok=hnc:stop_pool(test),
	ok.

strategy_lifo(_) ->
	doc("Ensure that checking out with the lifo strategy works."),
	{ok, _}=do_start_pool(test, #{strategy=>lifo, size=>{2, 2}}, hnc_test_worker, undefined),
	W1=hnc:checkout(test),
	W2=hnc:checkout(test),
	ok=hnc:checkin(W2),
	timer:sleep(100),
	idle=hnc:worker_status(W2),
	ok=hnc:checkin(W1),
	timer:sleep(100),
	idle=hnc:worker_status(W1),
	W1=hnc:checkout(test),
	ok=hnc:stop_pool(test),
	ok.

blocking(_) ->
	doc("Ensure that a pool blocks checkout requests when it is at max."),
	{ok, _}=do_start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{available:=0, unavailable:=0, starting:=0}=hnc:pool_status(test),
	_=hnc:checkout(test),
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	ok=try
		hnc:checkout(test, 0)
	of
		_ -> error(unexpected_success)
	catch
		exit:timeout -> ok
	end,
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
	doc("Ensure that a pool serves a blocked checkout request when the user that owns a checked out worker dies."),
	{ok, _}=do_start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{available:=0, unavailable:=0, starting:=0}=hnc:pool_status(test),
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
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	Pid ! {self(), ok},
	ok=receive {'DOWN', Ref, process, Pid, normal} -> ok after 1000 -> exit(timeout) end,
	_=hnc:checkout(test),
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

blocking_workerdeath(_) ->
	doc("Ensure that a pool serves a blocked checkout request when the checked out worker dies."),
	{ok, _}=do_start_pool(test, #{size=>{0, 1}}, hnc_test_worker, undefined),
	#{available:=0, unavailable:=0, starting:=0}=hnc:pool_status(test),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			WRef=hnc:checkout(test),
			W=hnc:get_worker(WRef),
			Self ! {self(), ok, W},
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end,
			exit(W, kill),
			ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	W=receive {Pid, ok, W1} -> W1 after 1000 -> exit(timeout) end,
	Ref=monitor(process, W),
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	Pid ! {self(), ok},
	ok=receive {'DOWN', Ref, process, W, killed} -> ok after 1000 -> exit(timeout) end,
	Pid ! {self(), ok},
	_=hnc:checkout(test),
	#{available:=0, unavailable:=1, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

worker_start_ignore(_) ->
	doc("Ensure that worker start ignores result in the appropriate checkout failure."),
	{ok, _}=do_start_pool(test, #{size=>{0,1}}, hnc_test_worker, start_ignore),
	_=try
		hnc:checkout(test)
	of
		_ -> exit(unexpected_success)
	catch
		error:{not_a_worker, _} -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

worker_start_error(_) ->
	doc("Ensure that worker start errors result in the appropriate checkout failure."),
	{ok, _}=do_start_pool(test, #{size=>{0,1}}, hnc_test_worker, start_error),
	_=try
		hnc:checkout(test)
	of
		_ -> exit(unexpected_success)
	catch
		error:start_error -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

worker_start_junk(_) ->
	doc("Ensure that worker start junk results in the appropriate checkout failure."),
	{ok, _}=do_start_pool(test, #{size=>{0,1}}, hnc_test_worker, start_junk),
	_=try
		hnc:checkout(test)
	of
		_ -> exit(unexpected_success)
	catch
		error:start_junk -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

worker_start_crash(_) ->
	doc("Ensure that worker start crashes result in the appropriate checkout error."),
	{ok, _}=do_start_pool(test, #{size=>{0,1}}, hnc_test_worker, start_crash),
	_=try
		hnc:checkout(test)
	of
		_ -> exit(unexpected_success)
	catch
		error:{'EXIT', start_crash} -> ok
	end,
	ok=hnc:stop_pool(test),
	ok.

on_return(_) ->
	doc("Ensure that an on_return callback works."),
	Self=self(),
	Tag=make_ref(),
	{ok, _}=do_start_pool(test, #{on_return => {fun (Worker) -> Self ! {Tag, Worker} end, 1000}}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	W=hnc:get_worker(WRef),
	ok=hnc:checkin(WRef),
	ok=receive {Tag, W} -> ok after 1000 -> exit(timeout) end,
	ok=hnc:stop_pool(test),
	ok.

on_return_timeout(_) ->
	doc("Ensure that when an on_return callback times out it takes down the worker."),
	Self=self(),
	Tag=make_ref(),
	{ok, _}=do_start_pool(test, #{on_return => {fun (Worker) -> Self ! {Tag, Worker}, timer:sleep(1000) end, 100}}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	W=hnc:get_worker(WRef),
	Ref=monitor(process, W),
	ok=hnc:checkin(WRef),
	ok=receive {Tag, W} -> ok after 1000 -> exit(timeout) end,
	ok=receive {'DOWN', Ref, process, W, _} -> ok after 1000 -> exit(timeout) end,
	ok=hnc:stop_pool(test),
	ok.

on_return_funcrash(_) ->
	doc("Ensure that when an on_return callback crashes it takes down the worker."),
	Self=self(),
	Tag=make_ref(),
	{ok, _}=do_start_pool(test, #{on_return => {fun (Worker) -> Self ! {Tag, Worker}, exit(crash) end, 1000}}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	W=hnc:get_worker(WRef),
	Ref=monitor(process, W),
	ok=hnc:checkin(WRef),
	ok=receive {Tag, W} -> ok after 1000 -> exit(timeout) end,
	ok=receive {'DOWN', Ref, process, W, crash} -> ok after 1000 -> exit(timeout) end,
	ok=hnc:stop_pool(test),
	ok.

on_return_workercrash(_) ->
	doc("Ensure that when a worker crashes in an on_return callback it takes down the returner."),
	Self=self(),
	Tag=make_ref(),
	ReturnFun=fun (Worker) ->
		Self ! {Tag, self(), Worker},
		ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end,
		Worker ! crash,
		ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end
	end,
	{ok, _}=do_start_pool(test, #{on_return => {ReturnFun, 1000}}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	W=hnc:get_worker(WRef),
	Ref=monitor(process, W),
	ok=hnc:checkin(WRef),
	{ok, Returner}=receive {Tag, Ret, W} -> {ok, Ret} after 1000 -> exit(timeout) end,
	Ref2=monitor(process, Returner),
	Returner ! {self(), ok},
	ok=receive {'DOWN', Ref, process, W, crash} -> ok after 1000 -> exit(timeout) end,
	ok=receive {'DOWN', Ref2, process, Returner, crash} -> ok after 1000 -> exit(timeout) end,
	ok=hnc:stop_pool(test),
	ok.

give_away(_) ->
	doc("Ensure that giving away a worker works."),
	Self=self(),
	{ok, _}=do_start_pool(test, #{}, hnc_test_worker, undefined),
	Pid=spawn_link(
		fun () ->
			WRef=hnc:checkout(test),
			Self ! {self(), ok, WRef},
			ok=receive {Self, ok} ->ok after 1000 -> exit(timeout) end,
			ok=hnc:give_away(WRef, Self, {a_gift_from, self()}),
			ok=try
				hnc:checkin(WRef)
			of
				ok -> exit(unexpected_success)
			catch
				error:not_owner -> ok
			end
		end
	),
	WRef=receive {Pid, ok, WRef1} -> WRef1 after 1000 -> exit(timeout) end,
	ok=try
		   hnc:checkin(WRef)
	of
		   ok -> exit(unexpectd_success)
	catch
		   error:not_owner -> ok
	end,
	Pid ! {Self, ok},
	ok=receive {'HNC-AGENT-TRANSFER', WRef, Pid, {a_gift_from, Pid}} -> ok after 1000 -> exit(timeout) end,
	out=hnc:worker_status(WRef),
	ok=hnc:checkin(WRef),
	ok=hnc:stop_pool(test),
	ok.

give_away_not_owner(_) ->
	doc("Ensure that only the owner of a worker can give it away."),
	{ok, _}=do_start_pool(test, #{}, hnc_test_worker, undefined),
	Self=self(),
	Pid=spawn_link(
		fun () ->
			WRef=hnc:checkout(test),
			Self ! {self(), ok, WRef},
			receive {Self, ok} -> ok after 1000 -> exit(timeout) end
		end
	),
	WRef=receive {Pid, ok, WRef1} -> WRef1 after 1000 -> exit(timeout) end,
	ok=try
		   hnc:give_away(WRef, self(), undefined)
	of
		   ok -> exit(unexpected_success)
	catch
		   error:not_owner -> ok
	end,
	Pid ! {self(), ok},
	ok=hnc:stop_pool(test),
	ok.

prune(_) ->
	doc("Ensure that pruning a pool works."),
	{ok, _}=do_start_pool(test, #{size=>{1, 2}}, hnc_test_worker, undefined),
	WRef1=hnc:checkout(test),
	WRef2=hnc:checkout(test),
	WMon1=monitor(process, hnc:get_worker(WRef1)),
	WMon2=monitor(process, hnc:get_worker(WRef2)),
	#{available:=0, unavailable:=2, starting:=0}=hnc:pool_status(test),
	ok=hnc:checkin(WRef1),
	ok=hnc:checkin(WRef2),
	#{available:=2, unavailable:=0, starting:=0}=hnc:pool_status(test),
	ok=hnc:prune(test),
	ok=receive
		{'DOWN', WMon1, process, _, _} -> ok;
		{'DOWN', WMon2, process, _, _} -> ok
	after 1000 -> exit(timeout)
	end,
	#{available:=1, unavailable:=0, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

linger(_) ->
	doc("Ensure that a pool drops idle workers after the linger time has expired."),
	{ok, _}=do_start_pool(test, #{size=>{1, 2}, linger=>{10, 100}}, hnc_test_worker, undefined),
	WRef1=hnc:checkout(test),
	WRef2=hnc:checkout(test),
	#{available:=0, unavailable:=2, starting:=0}=hnc:pool_status(test),
	ok=hnc:checkin(WRef1),
	ok=hnc:checkin(WRef2),
	#{unavailable:=0, starting:=0}=hnc:pool_status(test),
	timer:sleep(200),
	#{available:=1, unavailable:=0, starting:=0}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

change_opts(_) ->
	doc("Ensure that changing options at runtime works."),
	{ok, _}=do_start_pool(test, #{}, hnc_test_worker, undefined),
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

proxy(_) ->
	doc("Ensure that worker proxies work."),
	[hnc_test_worker]=hnc_test_workerproxy:get_modules(),
	{ok, PoolSup}=do_start_pool(test, #{}, hnc_test_workerproxy, undefined),
	[WorkerSupSup]=[Pid || {hnc_worker_sup_sup, Pid, supervisor, _} <- supervisor:which_children(PoolSup)],
	[WorkerSup|_]=[Pid || {undefined, Pid, supervisor, _} <- supervisor:which_children(WorkerSupSup)],
	{ok,
		#{
			start:={hnc_test_workerproxy, _, _},
			modules:=[hnc_test_worker]
		}
	}=supervisor:get_childspec(WorkerSup, hnc_worker),
	_=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

embedded(_) ->
	doc("Ensure that embedding pools in own supervisors works."),
	{ok, EmbeddedSup}=embedded_sup:start_link(test, #{}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	#{unavailable:=1}=hnc:pool_status(test),
	ok=hnc:checkin(WRef),
	#{unavailable:=0}=hnc:pool_status(test),
	exit(EmbeddedSup, normal),
	ok.

worker_status(_) ->
	doc("Ensure that retrieving a worker's status works."),
	OnReturn=fun (_) -> timer:sleep(100) end,
	{ok, _}=do_start_pool(test, #{size => {1, 1}, on_return => {OnReturn, infinity}}, hnc_test_worker, undefined),
	WRef=hnc:checkout(test),
	out=hnc:worker_status(WRef),
	ok=hnc:checkin(WRef),
	returning=hnc:worker_status(WRef),
	_=timer:sleep(200),
	idle=hnc:worker_status(WRef),
	ok=hnc:stop_pool(test),
	ok.

start_parallel(_) ->
	doc("Ensure that workers are started in parallel."),
	{ok, _}=do_start_pool(test, #{size => {0, 5}}, hnc_test_worker, {delay_start, 1000}),
	Self=self(),
	Pids=lists:map(
		fun (_) ->
			spawn_link(
				fun () ->
					WRef=hnc:checkout(test),
					Self ! {self(), WRef},
					ok=receive {Self, ok} -> ok after 1000 -> exit(timeout) end,
					hnc:checkin(WRef)
				end
			)
		end,
		lists:seq(1, 5)
	),
	{Time, ok}=timer:tc(
		fun () ->
			lists:foreach(
				fun (Pid) ->
					_=receive {Pid, _} -> Pid ! {self(), ok} after 5000 -> exit(timeout) end
				end,
				Pids
			)
		end
	),
	true=Time<2000000, %% timer:tc returns time in microseconds
	ok=hnc:stop_pool(test),
	ok.

stop_parallel(_) ->
	doc("Ensure that workers are stopped in parallel."),
	{ok, _}=do_start_pool(test, #{size => {0, 5}, shutdown => 5000}, hnc_test_worker, {delay_stop, 1000}),
	WRefs=[hnc:checkout(test) || _ <- lists:seq(1, 5)],
	[ok=hnc:checkin(WRef) || WRef <- WRefs],
	#{available:=5}=hnc:pool_status(test),
	ok=hnc:set_size(test, {0, 1}),
	#{available:=5}=hnc:pool_status(test),
	ok=hnc:prune(test),
	{Time, WRef}=timer:tc(fun () -> hnc:checkout(test) end),
	true=Time<2000,
	#{unavailable:=1, available:=0}=hnc:pool_status(test),
	ok=hnc:checkin(WRef),
	#{unavailable:=0, available:=1}=hnc:pool_status(test),
	ok=hnc:stop_pool(test),
	ok.

do_start_pool(PoolName, PoolOpts, WorkerMod, WorkerArgs) ->
	R=hnc:start_pool(PoolName, PoolOpts, WorkerMod, WorkerArgs),
	timer:sleep(100),
	R.
