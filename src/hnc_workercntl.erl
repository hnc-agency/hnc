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

-module(hnc_workercntl).

-behavior(gen_statem).

-export([start_link/3]).
-export([accepted/2, rejected/2]).
-export([callback_mode/0, init/1, command/3, accept_reject/3, terminate/3, code_change/4]).

-record(state, {pool, worker_sup, worker}).

-spec start_link(pid(), pid(), start_worker | {stop_worker, hnc:worker()} | {return_worker, hnc:worker(), hnc:on_return()}) -> {ok, pid()}.
start_link(Pool, WorkerSup, Action) ->
	{ok, Pid}=gen_statem:start_link(?MODULE, {Pool, WorkerSup}, []),
	ok=gen_statem:cast(Pid, Action),
	{ok, Pid}.

-spec accepted(pid(), hnc:worker()) -> ok.
accepted(Pid, Worker) ->
	gen_statem:cast(Pid, {worker_accepted, Worker}).

-spec rejected(pid(), hnc:worker()) -> ok.
rejected(Pid, Worker) ->
	gen_statem:cast(Pid, {worker_rejected, Worker}).

callback_mode() ->
	state_functions.

init({Pool, WorkerSup}) ->
	{ok, command, #state{pool=Pool, worker_sup=WorkerSup}}.

command(cast, start_worker, State=#state{pool=Pool, worker_sup=WorkerSup}) ->
	{ok, Worker}=hnc_worker_sup:start_worker(WorkerSup),
	true=is_pid(Worker),
	ok=hnc_pool:offer_worker(Pool, Worker),
	{next_state, accept_reject, State#state{worker=Worker}};
command(cast, {stop_worker, Worker}, #state{worker_sup=WorkerSup}) ->
	catch hnc_worker_sup:stop_worker(WorkerSup, Worker),
	stop;
command(cast, {return_worker, Worker, undefined}, State=#state{pool=Pool}) ->
	ok=hnc_pool:offer_worker(Pool, Worker),
	{next_state, accept_reject, State#state{worker=Worker}};
command(cast, {return_worker, Worker, {Fun, Timeout}}, State=#state{pool=Pool}) ->
	WorkerRef=monitor(process, Worker),
	{Returner, ReturnerRef}=spawn_monitor(fun () -> Fun(Worker) end),
	receive
		{'DOWN', ReturnerRef, process, Returner, normal} ->
			ok=hnc_pool:offer_worker(Pool, Worker),
			{next_state, accept_reject, State#state{worker=Worker}};
		{'DOWN', ReturnerRef, process, Returner, Reason} ->
			{stop, Reason};
		{'DOWN', WorkerRef, process, Worker, Reason} ->
			exit(Returner, kill),
			{stop, Reason}
	after Timeout ->
		exit(Returner, kill),
		stop
	end.

accept_reject(cast, {worker_accepted, Worker}, #state{worker=Worker}) ->
	stop;
accept_reject(cast, {worker_rejected, Worker}, #state{worker_sup=WorkerSup, worker=Worker}) ->
	catch hnc_worker_sup:stop_worker(WorkerSup, Worker),
	stop.

terminate(_, _, _) ->
	ok.

code_change(_, StateName, State, _) ->
	{ok, StateName, State}.
