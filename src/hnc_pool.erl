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

-module(hnc_pool).

-behavior(gen_statem).

-export([start_link/2]).
-export([checkout/2, checkin/2]).
-export([prune/1]).
-export([set_strategy/2, get_strategy/2]).
-export([set_size/2, get_size/2]).
-export([set_linger/2, get_linger/2]).
-export([pool_status/2]).
-export([worker_status/3]).
-export([offer_worker/2]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-record(state, {strategy, size, linger, on_return, worker_sup, sweep_ref, rooster=#{}, workers=queue:new(), waiting=queue:new(), monitors=#{}}).

-spec start_link(hnc:pool(), hnc:opts()) -> {ok, pid()}.
start_link(Name, Opts) ->
	gen_statem:start_link({local, Name}, ?MODULE, {self(), Opts}, []).

-spec checkout(hnc:pool(), timeout()) -> hnc:worker().
checkout(Pool, Timeout) ->
	case gen_statem:call(Pool, {checkout, self(), Timeout}) of
		{ok, Worker} -> Worker;
		{error, timeout} -> exit(timeout);
		Other -> exit({unexpected, Other})
	end.

-spec checkin(hnc:pool(), hnc:worker()) -> ok.
checkin(Pool, Worker) ->
	gen_statem:cast(Pool, {checkin, Worker}).

-spec prune(hnc:pool()) -> ok.
prune(Pool) ->
	gen_statem:cast(Pool, prune).

-spec set_size(hnc:pool(), hnc:size()) -> ok.
set_size(Pool, Size) ->
	gen_statem:cast(Pool, {set_size, Size}).

-spec get_size(hnc:pool(), timeout()) -> hnc:size().
get_size(Pool, Timeout) ->
	gen_statem:call(Pool, get_size, Timeout).

-spec set_strategy(hnc:pool(), hnc:strategy()) -> ok.
set_strategy(Pool, Strategy) ->
	gen_statem:cast(Pool, {set_strategy, Strategy}).

-spec get_strategy(hnc:pool(), timeout()) -> hnc:strategy().
get_strategy(Pool, Timeout) ->
	gen_statem:call(Pool, get_strategy, Timeout).

-spec set_linger(hnc:pool(), hnc:linger()) -> ok.
set_linger(Pool, Linger) ->
	gen_statem:cast(Pool, {set_linger, Linger}).

-spec get_linger(hnc:pool(), timeout()) -> hnc:linger().
get_linger(Pool, Timeout) ->
	gen_statem:call(Pool, get_linger, Timeout).

-spec pool_status(hnc:pool(), timeout()) -> hnc:pool_status().
pool_status(Pool, Timeout) ->
	gen_statem:call(Pool, pool_status, Timeout).

-spec worker_status(hnc:pool(), hnc:worker(), timeout()) -> hnc:worker_status() | undefined.
worker_status(Pool, Worker, Timeout) ->
	gen_statem:call(Pool, {worker_status, Worker}, Timeout).

-spec offer_worker(pid(), pid()) -> ok.
offer_worker(Pool, Worker) ->
	gen_statem:cast(Pool, {offer_worker, self(), Worker}).

callback_mode() ->
	handle_event_function.

init({Parent, Opts}) ->
	Size=maps:get(size, Opts, {5, 5}),
	Strategy=maps:get(strategy, Opts, fifo),
	Linger=maps:get(linger, Opts, infinity),
	OnReturn=maps:get(on_return, Opts, undefined),
	gen_statem:cast(self(), {setup, Parent}),
	{ok, setup, #state{strategy=Strategy, size=Size, linger=Linger, on_return=OnReturn}}.

handle_event(cast, {setup, Parent}, setup, State) ->
	WorkerSup=hnc_pool_sup:get_worker_sup(Parent),
	gen_statem:cast(self(), init),
	{keep_state, State#state{worker_sup=WorkerSup}};
handle_event(cast, init, setup, State=#state{worker_sup=WorkerSup, size={Min, _}, monitors=Monitors0, rooster=Rooster0}) ->
	{Monitors1, Rooster1}=lists:foldl(
		fun (_, {Monitors2, Rooster2}) ->
			{ok, Starter}=hnc_workercntl_sup:start_worker(WorkerSup),
			StarterRef=monitor(process, Starter),
			Monitors3=maps:put(StarterRef, {starter, Starter}, Monitors2),
			Rooster3=maps:put(Starter, starting, Rooster2),
			{Monitors3, Rooster3}
		end,
		{Monitors0, Rooster0},
		lists:seq(1, Min)
	),
	NextStateName=case Min of
		0 -> running;
		_ -> {setup_wait, Min}
	end,
	{next_state, NextStateName, State#state{worker_sup=WorkerSup, monitors=Monitors1, rooster=Rooster1}};
handle_event(_, _, setup, _) ->
	{keep_state_and_data, postpone};
handle_event(cast, {offer_worker, Cntl, Worker}, {setup_wait, _}, State) ->
	{keep_state, process_offer_worker(Cntl, Worker, State)};
handle_event(info, {'DOWN', Ref, process, Pid, _}, {setup_wait, N}, State=#state{linger=Linger, rooster=Rooster0, monitors=Monitors0}) ->
	case maps:take(Ref, Monitors0) of
		{{starter, Pid}, Monitors1} when N=<1 ->
			Rooster1=maps:remove(Pid, Rooster0),
			SweepRef=schedule_sweep_idle(Linger),
			{next_state, running, State#state{sweep_ref=SweepRef, rooster=Rooster1, monitors=Monitors1}};
		{{starter, Pid}, Monitors1} ->
			Rooster1=maps:remove(Pid, Rooster0),
			{next_state, {setup_wait, N-1}, State#state{rooster=Rooster1, monitors=Monitors1}};
		_ ->
			{keep_state_and_data, postpone}
	end;
handle_event(_, _, {setup_wait, _}, _) ->
	{keep_state_and_data, postpone};
handle_event({call, From}, pool_status, running, #state{rooster=Rooster}) ->
	spawn(
		fun () ->
			Result=maps:fold(
				fun
					(_, idle, Acc=#{idle:=N}) ->
						Acc#{idle => N+1};
					(_, {out, _}, Acc=#{out:=N}) ->
						Acc#{out => N+1};
					(_, starting, Acc=#{starting := N}) ->
						Acc#{starting => N+1};
					(_, returning, Acc=#{returning:=N}) ->
						Acc#{returning => N+1};
					(_, _, Acc) ->
						Acc
				end,
				#{idle => 0, out => 0, starting => 0, returning => 0},
				Rooster
			),
			gen_statem:reply(From, Result)
		end
	),
	keep_state_and_data;
handle_event({call, From}, {worker_status, Worker}, running, #state{rooster=Rooster, monitors=Monitors}) ->
	spawn(
		fun () ->
			Result=case maps:find(Worker, Rooster) of
				{ok, idle} -> idle;
				{ok, {out, _}} -> out;
				error ->
					case lists:any(fun ({returner, _, W}) -> W=:=Worker; (_) -> false end, maps:values(Monitors)) of
						true -> returning;
						false -> undefined
					end
			end,
			gen_statem:reply(From, Result)
		end
	),
	keep_state_and_data;
handle_event(cast, {set_size, Size}, running, State) ->
	{keep_state, State#state{size=Size}};
handle_event({call, From}, get_size, running, #state{size=Size}) ->
	gen_statem:reply(From, Size),
	keep_state_and_data;
handle_event(cast, {set_strategy, Strategy}, running, State) ->
	{keep_state, State#state{strategy=Strategy}};
handle_event({call, From}, get_strategy, running, #state{strategy=Strategy}) ->
	gen_statem:reply(From, Strategy),
	keep_state_and_data;
handle_event(cast, {set_linger, Linger}, running, State) ->
	SweepRef=schedule_sweep_idle(Linger),
	{keep_state, State#state{linger=Linger, sweep_ref=SweepRef}};
handle_event({call, From}, get_linger, running, #state{linger=Linger}) ->
	gen_statem:reply(From, Linger),
	keep_state_and_data;
handle_event({call, From}, {checkout, User, Timeout}, running, State) ->
	{keep_state, process_checkout(From, User, Timeout, State)};
handle_event(cast, {checkout_timeout, UserRef}, running, State=#state{monitors=Monitors0, waiting=Waiting0}) ->
	case maps:take(UserRef, Monitors0) of
		{waiting, Monitors1} ->
			Waiting1=queue:filter(
				fun
					({Ref, ReplyTo}) when Ref=:=UserRef ->
						gen_statem:reply(ReplyTo, {error, timeout}),
						false;
					(_) ->
						true
				end,
				Waiting0
			),
			{keep_state, State#state{monitors=Monitors1, waiting=Waiting1}};
		_ ->
			keep_state_and_data
	end;
handle_event(cast, {checkin, Worker}, running, State=#state{rooster=Rooster0, monitors=Monitors0}) ->
	case maps:take(Worker, Rooster0) of
		{{out, UserRef}, Rooster1} ->
			demonitor(UserRef, [flush]),
			Monitors1=maps:remove(UserRef, Monitors0),
			{keep_state, do_return_worker(Worker, State#state{rooster=Rooster1, monitors=Monitors1})};
		_ ->
			keep_state_and_data
	end;
handle_event(cast, {offer_worker, Cntl, Worker}, running, State) ->
	{keep_state, process_offer_worker(Cntl, Worker, State)};
handle_event(cast, {sweep_idle, SweepRef0}, running, State0=#state{sweep_ref=SweepRef0, linger=Linger={LingerTime, _}}) ->
	Treshold=stamp(-LingerTime),
	State1=process_sweep(Treshold, State0),
	SweepRef1=schedule_sweep_idle(Linger),
	{keep_state, State1#state{sweep_ref=SweepRef1}};
handle_event(cast, prune, running, State0) ->
	Treshold=stamp(),
	State1=process_sweep(Treshold, State0),
	{keep_state, State1};
handle_event(info, {'DOWN', Ref, process, Pid, Reason}, running, State=#state{monitors=Monitors0}) ->
	case maps:take(Ref, Monitors0) of
		{Value, Monitors1} ->
			State1=process_down(Value, Ref, Pid, Reason, State#state{monitors=Monitors1}),
			{keep_state, State1};
		error ->
			keep_state_and_data
	end;
handle_event(_, _, running, _) ->
	keep_state_and_data.

terminate(_, _, _) ->
	ok.

code_change(_, StateName, State, _) ->
	{ok, StateName, State}.

stamp() ->
	stamp(0).

stamp(Offset) ->
	erlang:monotonic_time(millisecond)+Offset.

dequeue(Queue) ->
	dequeue(Queue, fifo).

dequeue(Queue, Strategy) ->
	case dequeue1(Queue, Strategy) of
		{empty, _} ->
			empty;
		{{value, Item}, Queue1} ->
			{Item, Queue1}
	end.

dequeue1(Queue, fifo) ->
	queue:out(Queue);
dequeue1(Queue, lifo) ->
	queue:out_r(Queue).

schedule_checkout_timeout(infinity, _) ->
	ok;
schedule_checkout_timeout(Timeout, UserRef) ->
	{ok, _}=timer:apply_after(Timeout, gen_statem, cast, [self(), {checkout_timeout, UserRef}]),
	ok.

schedule_sweep_idle(infinity) ->
	undefined;
schedule_sweep_idle({_, SweepInterval}) ->
	Ref=make_ref(),
	{ok, _}=timer:apply_after(SweepInterval, gen_statem, cast, [self(), {sweep_idle, Ref}]),
	Ref.

process_waiting(State=#state{strategy=Strategy, rooster=Rooster0, monitors=Monitors0, waiting=Waiting0, workers=Workers0}) ->
	case {dequeue(Waiting0), dequeue(Workers0, Strategy)} of
		{{{UserRef, ReplyTo}, Waiting1}, {{Worker, _}, Workers1}} ->
			gen_statem:reply(ReplyTo, {ok, Worker}),
			Monitors1=maps:update(UserRef, {user, Worker}, Monitors0),
			Rooster1=maps:update(Worker, {out, UserRef}, Rooster0),
			State#state{rooster=Rooster1, monitors=Monitors1, waiting=Waiting1, workers=Workers1};
		_ ->
			State
	end.

process_down(waiting, Ref, _, _, State=#state{waiting=Waiting0}) ->
	Waiting1=queue:filter(fun ({UserRef, _}) -> UserRef=/=Ref end, Waiting0),
	State#state{waiting=Waiting1};
process_down({starter, Pid}, _, Pid, Reason, State=#state{rooster=Rooster0}) ->
	case maps:take(Pid, Rooster0) of
		{Value, Rooster1} ->
			process_down_starter(Value, Reason, State#state{rooster=Rooster1});
		error ->
			State
	end;
process_down({returner, Pid, Worker}, _, Pid, _, State=#state{rooster=Rooster0}) ->
	case maps:take(Pid, Rooster0) of
		{Value, Rooster1} ->
			process_down_returner(Value, Worker, State#state{rooster=Rooster1});
		error ->
			State
	end;
process_down({user, Worker}, Ref, _, _, State=#state{rooster=Rooster0}) ->
	case maps:take(Worker, Rooster0) of
		{Value, Rooster1} ->
			process_down_user(Value, Worker, Ref, State#state{rooster=Rooster1});
		error ->
			State
	end;
process_down(worker, _, Pid, _, State=#state{rooster=Rooster0}) ->
	case maps:take(Pid, Rooster0) of
		{Value, Rooster1} ->
			process_down_worker(Value, Pid, State#state{rooster=Rooster1});
		error ->
			State
	end;
process_down(_, _, _, _, State) ->
	State.

process_down_worker(idle, Pid, State=#state{size={Min, _}, worker_sup=WorkerSup, monitors=Monitors0, rooster=Rooster0, workers=Workers0}) ->
	Workers1=queue:filter(fun ({WorkerPid, _}) -> WorkerPid=/=Pid end, Workers0),
	{Monitors1, Rooster1}=case Min>maps:size(Rooster0) of
		true ->
			{ok, Starter}=hnc_workercntl_sup:start_worker(WorkerSup),
			StarterRef=monitor(process, Starter),
			Monitors2=maps:put(StarterRef, {starter, Starter}, Monitors0),
			Rooster2=maps:put(Starter, starting, Rooster0),
			{Monitors2, Rooster2};
		false ->
			{Monitors0, Rooster0}
	end,
	State#state{monitors=Monitors1, rooster=Rooster1, workers=Workers1};
process_down_worker({out, UserRef}, _, State=#state{size={Min, _}, worker_sup=WorkerSup, monitors=Monitors0, rooster=Rooster0}) ->
	demonitor(UserRef, [flush]),
	Monitors1=maps:remove(UserRef, Monitors0),
	{Monitors2, Rooster1}=case Min>maps:size(Rooster0) of
		true ->
			{ok, Starter}=hnc_workercntl_sup:start_worker(WorkerSup),
			StarterRef=monitor(process, Starter),
			Monitors3=maps:put(StarterRef, {starter, Starter}, Monitors1),
			Rooster2=maps:put(Starter, starting, Rooster0),
			{Monitors3, Rooster2};
		false ->
			{Monitors1, Rooster0}
	end,
	State#state{monitors=Monitors2, rooster=Rooster1};
process_down_worker(stopping, _, State) ->
	State;
process_down_worker(_, _, State) ->
	State.

process_down_user({out, Ref}, Worker, Ref, State) ->
	do_return_worker(Worker, State);
process_down_user(_, _, _, State) ->
	State.

process_down_starter(starting, Reason, State=#state{monitors=Monitors0, waiting=Waiting0}) ->
	case dequeue(Waiting0) of
		{{UserRef, ReplyTo}, Waiting1} ->
			gen_statem:reply(ReplyTo, {error, Reason}),
			demonitor(UserRef, [flush]),
			Monitors1=maps:remove(UserRef, Monitors0),
			State#state{monitors=Monitors1, waiting=Waiting1};
		empty ->
			State
	end;
process_down_starter(_, _, State) ->
	State.

process_down_returner(returning, Worker, State=#state{worker_sup=WorkerSup, monitors=Monitors0, rooster=Rooster0, waiting=Waiting0}) ->
	_=hnc_workercntl_sup:stop_worker(WorkerSup, Worker),
	case dequeue(Waiting0) of
		empty ->
			State;
		_ ->
			{ok, Starter}=hnc_workercntl_sup:start_worker(WorkerSup),
			StarterRef=monitor(process, Starter),
			Monitors1=maps:put(StarterRef, {starter, Starter}, Monitors0),
			Rooster1=maps:put(Starter, starting, Rooster0),
			State#state{monitors=Monitors1, rooster=Rooster1}
	end;
process_down_returner(_, _, State) ->
	State.

process_checkout(ReplyTo, User, Timeout, State=#state{strategy=Strategy, workers=Workers0}) ->
	case dequeue(Workers0, Strategy) of
		{{Worker, _}, Workers1} ->
			process_checkout_available(Worker, ReplyTo, User, State#state{workers=Workers1});
		empty ->
			process_checkout_unavailable(ReplyTo, User, Timeout, State)
	end.

process_checkout_available(Worker, ReplyTo, User, State=#state{rooster=Rooster0, monitors=Monitors0}) ->
	gen_statem:reply(ReplyTo, {ok, Worker}),
	UserRef=monitor(process, User),
	Monitors1=maps:put(UserRef, {user, Worker}, Monitors0),
	Rooster1=maps:update(Worker, {out, UserRef}, Rooster0),
	State#state{rooster=Rooster1, monitors=Monitors1}.

process_checkout_unavailable(ReplyTo, _, 0, State) ->
	gen_statem:reply(ReplyTo, {error, timeout}),
	State;
process_checkout_unavailable(ReplyTo, User, Timeout, State=#state{worker_sup=WorkerSup, size={_, Max}, rooster=Rooster0, monitors=Monitors0, waiting=Waiting0}) when Max=:=infinity; map_size(Rooster0)<Max ->
	UserRef=monitor(process, User),
	Monitors1=maps:put(UserRef, waiting, Monitors0),
	{ok, Starter}=hnc_workercntl_sup:start_worker(WorkerSup),
	StarterRef=monitor(process, Starter),
	Monitors2=maps:put(StarterRef, {starter, Starter}, Monitors1),
	Rooster1=maps:put(Starter, starting, Rooster0),
	Waiting1=queue:in({UserRef, ReplyTo}, Waiting0),
	schedule_checkout_timeout(Timeout, UserRef),
	State#state{monitors=Monitors2, rooster=Rooster1, waiting=Waiting1};
process_checkout_unavailable(ReplyTo, User, Timeout, State=#state{monitors=Monitors0, waiting=Waiting0}) ->
	UserRef=monitor(process, User),
	Monitors1=maps:put(UserRef, waiting, Monitors0),
	Waiting1=queue:in({UserRef, ReplyTo}, Waiting0),
	schedule_checkout_timeout(Timeout, UserRef),
	State#state{monitors=Monitors1, waiting=Waiting1}.

%% Sweep workers that were returned before the given treshold time, but obey minimum pool size.
%% Which workers are stopped depends on strategy, ie the workers that are least likely to be checked out next:
%%    - fifo: stops the workers that returned last
%%    - lifo: stops the workers that returned first
process_sweep(Treshold, State=#state{size={Min, _}, strategy=Strategy, worker_sup=WorkerSup, rooster=Rooster0, workers=Workers0}) ->
	N0=min(maps:size(Rooster0)-Min, queue:len(Workers0)),
	Workers1=queue:to_list(Workers0),
	Workers2=case Strategy of
		fifo -> lists:reverse(Workers1);
		lifo -> Workers1
	end,
	{_, Workers3}=lists:foldl(
		fun
			({Worker, Since}, {N1, Acc}) when N1>0, Since<Treshold ->
				_=hnc_workercntl_sup:stop_worker(WorkerSup, Worker),
				{N1-1, Acc};
			(WorkerSince, {N1, Acc}) ->
				{N1-1, [WorkerSince|Acc]}
		end,
		{N0, []},
		Workers2
	),
	Workers4=case Strategy of
		fifo -> Workers3;
		lifo -> lists:reverse(Workers3)
	end,
	Workers5=queue:from_list(Workers4),
	State#state{workers=Workers5}.

process_offer_worker(Cntl, Worker, State=#state{size={_, Max}, rooster=Rooster0, monitors=Monitors0, workers=Workers0}) ->
	case maps:take(Cntl, Rooster0) of
		{starting, Rooster1} when map_size(Rooster1)<Max ->
			hnc_workercntl:accepted(Cntl, Worker),
			Rooster2=maps:put(Worker, idle, Rooster1),
			WorkerRef=monitor(process, Worker),
			Workers1=queue:in({Worker, stamp()}, Workers0),
			Monitors1=maps:put(WorkerRef, worker, Monitors0),
			process_waiting(State#state{rooster=Rooster2, workers=Workers1, monitors=Monitors1});
		{starting, Rooster1} ->
			hnc_workercntl:rejected(Cntl, Worker),
			State#state{rooster=Rooster1};
		{returning, Rooster1} when map_size(Rooster1)<Max ->
			hnc_workercntl:accepted(Cntl, Worker),
			Rooster2=maps:put(Worker, idle, Rooster1),
			Workers1=queue:in({Worker, stamp()}, Workers0),
			process_waiting(State#state{rooster=Rooster2, workers=Workers1});
		{returning, Rooster1} ->
			hnc_workercntl:rejected(Cntl, Worker),
			State#state{rooster=Rooster1};
		_ ->
			State
	end.

do_return_worker(Worker, State=#state{on_return=OnReturn, worker_sup=WorkerSup, rooster=Rooster0, monitors=Monitors0}) ->
	Rooster1=maps:remove(Worker, Rooster0),
	{ok, Returner}=hnc_workercntl_sup:return_worker(WorkerSup, Worker, OnReturn),
	ReturnerRef=monitor(process, Returner),
	Monitors1=maps:put(ReturnerRef, {returner, Returner, Worker}, Monitors0),
	Rooster2=maps:put(Returner, returning, Rooster1),
	State#state{rooster=Rooster2, monitors=Monitors1}.
