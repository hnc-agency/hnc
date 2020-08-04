%% Copyright (c) 2020, Jan Uhlig <j.uhlig@mailingwork.de>
%% Copyright (c) 2020, Maria Scott <maria-12648430@gmx.net>
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
	[
		checkout_checkin,
		transaction,
		strategy_fifo,
		strategy_lifo,
		blocking,
		blocking_userdeath,
		blocking_workerdeath,
		linger,
		change_opts,
		proxy,
		embedded
	].

checkout_checkin(_) ->
	doc("Ensure that checking workers out and back in works."),
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
	doc("Ensure that transactions work."),
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
	doc("Ensure that checking out with the fifo strategy works."),
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
	doc("Ensure that checking out with the lifo strategy works."),
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
	doc("Ensure that a pool blocks checkout requests when it is at max."),
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
	doc("Ensure that a pool serves a blocked checkout request when the user that owns a checked out worker dies."),
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
	doc("Ensure that a pool serves a blocked checkout request when the checked out worker dies."),
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
	doc("Ensure that a pool is drops idle workers after the linger time has expired."),
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
	doc("Ensure that changing options at runtime works."),
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

proxy(_) ->
	doc("Ensure that worker proxies work."),
	[hnc_test_worker]=hnc_test_workerproxy:get_modules(),
	{ok, PoolSup}=hnc:start_pool(test, #{}, hnc_test_workerproxy, undefined),
	[WorkerSup]=[Pid || {hnc_worker_sup, Pid, supervisor, _} <- supervisor:which_children(PoolSup)],
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
	W=hnc:checkout(test),
	#{out:=1}=hnc:pool_status(test),
	ok=hnc:checkin(test, W),
	#{out:=0}=hnc:pool_status(test),
	exit(EmbeddedSup, normal),
	ok.
