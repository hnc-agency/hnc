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

-behavior(gen_server).

-export([start_link/4]).
-export([accepted/2, rejected/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {pool, worker_sup, worker}).

-spec start_link(pid(), pid(), start_worker | stop_worker | {return_worker, hnc:on_return()}, undefined | hnc:worker()) -> {ok, pid()}.
start_link(Pool, WorkerSup, Action, Worker) ->
	gen_server:start_link(?MODULE, {Action, Pool, WorkerSup, Worker}, []).

-spec accepted(pid(), hnc:worker()) -> ok.
accepted(Pid, Worker) ->
	gen_server:cast(Pid, {worker_accepted, Worker}).

-spec rejected(pid(), hnc:worker()) -> ok.
rejected(Pid, Worker) ->
	gen_server:cast(Pid, {worker_rejected, Worker}).

init({Action, Pool, WorkerSup, Worker}) ->
	gen_server:cast(self(), Action),
	{ok, #state{pool=Pool, worker_sup=WorkerSup, worker=Worker}}.

handle_call(Msg, _, State) ->
	{stop, {error, Msg}, State}.

handle_cast(start_worker, State=#state{pool=Pool, worker_sup=WorkerSup}) ->
	{ok, Pid}=hnc_worker_sup:start_worker(WorkerSup),
	true=is_pid(Pid),
	hnc_pool:offer_worker(Pool, Pid),
	{noreply, State#state{worker=Pid}};
handle_cast({worker_accepted, Worker}, State=#state{worker=Worker}) ->
	{stop, normal, State};
handle_cast({worker_rejected, Worker}, State=#state{worker_sup=WorkerSup, worker=Worker}) ->
	catch hnc_worker_sup:stop_worker(WorkerSup, Worker),
	{stop, normal, State};
handle_cast(stop_worker, State=#state{worker_sup=WorkerSup, worker=Worker}) ->
	catch hnc_worker_sup:stop_worker(WorkerSup, Worker),
	{stop, normal, State};
handle_cast({return_worker, undefined}, State=#state{pool=Pool, worker=Worker}) ->
	hnc_pool:offer_worker(Pool, Worker),
	{noreply, State};
handle_cast({return_worker, {Fun, Timeout}}, State=#state{pool=Pool, worker=Worker}) ->
	{Pid, Ref}=spawn_monitor(fun () -> Fun(Worker) end),
	receive
		{'DOWN', Ref, process, Pid, normal} ->
			hnc_pool:offer_worker(Pool, Worker),
			{noreply, State};
		{'DOWN', Ref, process, Pid, Reason} ->
			{stop, Reason, State}
	after Timeout ->
		exit(Pid, kill),
		{stop, normal, State}
	end;
handle_cast(Msg, State) ->
	{stop, {error, Msg}, State}.

handle_info(Msg, State) ->
	{stop, {error, Msg}, State}.

terminate(_, _) ->
	ok.

code_change(_, State, _) ->
	{ok, State}.
