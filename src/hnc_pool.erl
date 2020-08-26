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

-export([start_link/4]).
-export([checkout/2, checkin/3]).
-export([give_away/4]).
-export([prune/1]).
-export([set_strategy/2, get_strategy/2]).
-export([set_size/2, get_size/2]).
-export([set_linger/2, get_linger/2]).
-export([pool_status/2]).
-export([worker_status/3]).
-export([offer_worker/2]).
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-record(state, {strategy, size, linger, on_return, cntl_sup, sweep_ref, rooster=#{}, workers=queue:new(), waiting=queue:new(), monitors=#{}}).

-spec start_link(hnc:pool(), module(), term(), hnc:opts()) -> {ok, pid()}.
start_link(Name, Opts, WorkerMod, WorkerArgs) ->
	gen_statem:start_link({local, Name}, ?MODULE, {self(), Opts, WorkerMod, WorkerArgs}, []).

-spec checkout(hnc:pool(), timeout()) -> hnc:worker().
checkout(Pool, Timeout) ->
	case gen_statem:call(Pool, {checkout, self(), Timeout}) of
		{ok, Worker} -> Worker;
		{error, timeout} -> exit(timeout);
		Other -> exit({unexpected, Other})
	end.

-spec checkin(hnc:pool(), hnc:worker(), timeout()) -> ok | {error, term()}.
checkin(Pool, Worker, Timeout) ->
	gen_statem:call(Pool, {checkin, Worker, self()}, Timeout).

-spec give_away(hnc:pool(), hnc:worker(), pid(), timeout()) -> ok | {error, term()}.
give_away(Pool, Worker, NewUser, Timeout) ->
	gen_statem:call(Pool, {give_away, Worker, self(), NewUser}, Timeout).

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

init({Parent, Opts, WorkerMod, WorkerArgs}) ->
	Size=maps:get(size, Opts, {5, 5}),
	Strategy=maps:get(strategy, Opts, fifo),
	Linger=maps:get(linger, Opts, infinity),
	OnReturn=maps:get(on_return, Opts, undefined),
	Shutdown=maps:get(shutdown, Opts, brutal_kill),
	gen_statem:cast(self(), {setup, Parent, WorkerMod, WorkerArgs, Shutdown}),
	{ok, setup, #state{strategy=Strategy, size=Size, linger=Linger, on_return=OnReturn}}.

handle_event(cast, {setup, Parent, WorkerMod, WorkerArgs, Shutdown}, setup, State) ->
	{ok, WorkerSup}=hnc_pool_sup:start_worker_sup(Parent, WorkerMod, WorkerArgs, Shutdown),
	{ok, CntlSup}=hnc_pool_sup:start_cntl_sup(Parent, self(), WorkerSup),
	gen_statem:cast(self(), init),
	{keep_state, State#state{cntl_sup=CntlSup}};
handle_event(cast, init, setup, State=#state{size={0, _}}) ->
	{next_state, running, State};
handle_event(cast, init, setup, State0=#state{size={Min, _}}) ->
	State1=lists:foldl(
		fun (_, AccState) ->
			start_worker(AccState)
		end,
		State0,
		lists:seq(1, Min)
	),
	{next_state, {setup_wait, Min}, State1};
handle_event(_, _, setup, _) ->
	{keep_state_and_data, postpone};
handle_event(cast, {offer_worker, Cntl, Worker}, {setup_wait, _}, State) ->
	{keep_state, process_offer_worker(Cntl, Worker, State)};
handle_event(info, {'DOWN', Ref, process, Pid, _}, {setup_wait, N}, State0=#state{linger=Linger}) ->
	case take_monitor(Ref, State0) of
		{{starter, Pid}, State1} when N=<1 ->
			State2=remove_rooster(Pid, State1),
			SweepRef=schedule_sweep_idle(Linger),
			{next_state, running, State2#state{sweep_ref=SweepRef}};
		{{starter, Pid}, State1} ->
			State2=remove_rooster(Pid, State1),
			{next_state, {setup_wait, N-1}, State2};
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
handle_event(cast, {checkout_timeout, UserRef}, running, State0=#state{waiting=Waiting0}) ->
	case take_monitor(UserRef, State0) of
		{waiting, State1} ->
			Waiting1=queue:filter(
				fun
					({{_, Ref}, ReplyTo}) when Ref=:=UserRef ->
						gen_statem:reply(ReplyTo, {error, timeout}),
						false;
					(_) ->
						true
				end,
				Waiting0
			),
			{keep_state, State1#state{waiting=Waiting1}};
		_ ->
			keep_state_and_data
	end;
handle_event({call, From}, {checkin, Worker, User}, running, State0) ->
	case take_rooster(Worker, State0) of
		{{out, {User, UserRef}}, State1} ->
			gen_statem:reply(From, ok),
			demonitor(UserRef, [flush]),
			State2=remove_monitor(UserRef, State1),
			{keep_state, do_return_worker(Worker, State2)};
		{{out, _}, _} ->
			gen_statem:reply(From, {error, not_owner}),
			keep_state_and_data;
		_ ->
			gen_statem:reply(From, {error, not_found}),
			keep_state_and_data
	end;
handle_event({call, From}, {give_away, Worker, OldUser, NewUser}, running, State0) ->
	case take_rooster(Worker, State0) of
		{{out, {OldUser, OldUserRef}}, State1} ->
			demonitor(OldUserRef, [flush]),
			State2=remove_monitor(OldUserRef, State1),
			NewUserRef=monitor(process, NewUser),
			State3=put_monitor(NewUserRef, {user, Worker}, State2),
			State4=put_rooster(Worker, {out, {NewUser, NewUserRef}}, State3),
			gen_statem:reply(From, ok),
			{keep_state, State4};
		{{out, _}, _} ->
			gen_statem:reply(From, {error, not_owner}),
			keep_state_and_data;
		_ ->
			gen_statem:reply(From, {error, not_found}),
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
handle_event(info, {'DOWN', Ref, process, Pid, Reason}, running, State0) ->
	case take_monitor(Ref, State0) of
		{Value, State1} ->
			State2=process_down(Value, Ref, Pid, Reason, State1),
			{keep_state, State2};
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

process_waiting(State0) ->
	case has_waiting(State0) andalso has_worker(State0) of
		true ->
			{{{User, UserRef}, ReplyTo}, State1}=dequeue_waiting(State0),
			{{Worker, _}, State2}=dequeue_worker(State1),
			gen_statem:reply(ReplyTo, {ok, Worker}),
			State3=update_monitor(UserRef, {user, Worker}, State2),
			update_rooster(Worker, {out, {User, UserRef}}, State3);
		false ->
			State0
	end.

process_down(waiting, Ref, _, _, State=#state{waiting=Waiting0}) ->
	Waiting1=queue:filter(fun ({{_, UserRef}, _}) -> UserRef=/=Ref end, Waiting0),
	State#state{waiting=Waiting1};
process_down({starter, Pid}, _, Pid, Reason, State0) ->
	case take_rooster(Pid, State0) of
		{Value, State1} ->
			process_down_starter(Value, Reason, State1);
		error ->
			State0
	end;
process_down({returner, Pid, Worker}, _, Pid, _, State0) ->
	case take_rooster(Pid, State0) of
		{Value, State1} ->
			process_down_returner(Value, Worker, State1);
		error ->
			State0
	end;
process_down({user, Worker}, Ref, _, _, State0) ->
	case take_rooster(Worker, State0) of
		{Value, State1} ->
			process_down_user(Value, Worker, Ref, State1);
		error ->
			State0
	end;
process_down(worker, _, Pid, _, State0) ->
	case take_rooster(Pid, State0) of
		{Value, State1} ->
			process_down_worker(Value, Pid, State1);
		error ->
			State0
	end;
process_down(_, _, _, _, State) ->
	State.

process_down_worker(idle, Pid, State0=#state{size={Min, _}, rooster=Rooster, workers=Workers0}) ->
	Workers1=queue:filter(fun ({WorkerPid, _}) -> WorkerPid=/=Pid end, Workers0),
	State1=case Min>maps:size(Rooster) of
		true ->
			start_worker(State0);
		false ->
			State0
	end,
	State1#state{workers=Workers1};
process_down_worker({out, {_, UserRef}}, _, State0=#state{size={Min, _}, rooster=Rooster}) ->
	demonitor(UserRef, [flush]),
	State1=remove_monitor(UserRef, State0),
	State2=case Min>maps:size(Rooster) of
		true ->
			start_worker(State1);
		false ->
			State1
	end,
	State2;
process_down_worker(stopping, _, State) ->
	State;
process_down_worker(_, _, State) ->
	State.

process_down_user({out, {_, Ref}}, Worker, Ref, State) ->
	do_return_worker(Worker, State);
process_down_user(_, _, _, State) ->
	State.

process_down_starter(starting, Reason, State0) ->
	case dequeue_waiting(State0) of
		{{{_, UserRef}, ReplyTo}, State1} ->
			gen_statem:reply(ReplyTo, {error, Reason}),
			demonitor(UserRef, [flush]),
			remove_monitor(UserRef, State1);
		empty ->
			State0
	end;
process_down_starter(_, _, State) ->
	State.

process_down_returner(returning, Worker, State=#state{cntl_sup=CntlSup}) ->
	_=hnc_workercntl_sup:stop_worker(CntlSup, Worker),
	case has_waiting(State) of
		false ->
			State;
		true ->
			start_worker(State)
	end;
process_down_returner(_, _, State) ->
	State.

process_checkout(ReplyTo, User, Timeout, State0) ->
	case dequeue_worker(State0) of
		{{Worker, _}, State1} ->
			process_checkout_available(Worker, ReplyTo, User, State1);
		empty ->
			process_checkout_unavailable(ReplyTo, User, Timeout, State0)
	end.

process_checkout_available(Worker, ReplyTo, User, State0) ->
	gen_statem:reply(ReplyTo, {ok, Worker}),
	UserRef=monitor(process, User),
	State1=put_monitor(UserRef, {user, Worker}, State0),
	update_rooster(Worker, {out, {User, UserRef}}, State1).

process_checkout_unavailable(ReplyTo, _, 0, State) ->
	gen_statem:reply(ReplyTo, {error, timeout}),
	State;
process_checkout_unavailable(ReplyTo, User, Timeout, State0=#state{size={_, Max}, rooster=Rooster, waiting=Waiting0}) ->
	State1=case Max=:=infinity orelse map_size(Rooster)<Max of
		true -> start_worker(State0);
		false -> State0
	end,
	UserRef=monitor(process, User),
	State2=put_monitor(UserRef, waiting, State1),
	Waiting1=queue:in({{User, UserRef}, ReplyTo}, Waiting0),
	schedule_checkout_timeout(Timeout, UserRef),
	State2#state{waiting=Waiting1}.

%% Sweep workers that were returned before the given treshold time, but obey minimum pool size.
%% Which workers are stopped depends on strategy, ie the workers that are least likely to be checked out next:
%%    - fifo: stops the workers that returned last
%%    - lifo: stops the workers that returned first
process_sweep(Treshold, State=#state{size={Min, _}, strategy=Strategy, cntl_sup=CntlSup, rooster=Rooster0, workers=Workers0}) ->
	N0=min(maps:size(Rooster0)-Min, queue:len(Workers0)),
	Workers1=queue:to_list(Workers0),
	Workers2=case Strategy of
		fifo -> lists:reverse(Workers1);
		lifo -> Workers1
	end,
	{_, Workers3}=lists:foldl(
		fun
			({Worker, Since}, {N1, Acc}) when N1>0, Since<Treshold ->
				_=hnc_workercntl_sup:stop_worker(CntlSup, Worker),
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

process_offer_worker(Cntl, Worker, State0=#state{size={_, Max}, workers=Workers0}) ->
	case take_rooster(Cntl, State0) of
		{starting, State1=#state{rooster=Rooster}} when map_size(Rooster)<Max ->
			hnc_workercntl:accepted(Cntl, Worker),
			State2=put_rooster(Worker, idle, State1),
			WorkerRef=monitor(process, Worker),
			Workers1=queue:in({Worker, stamp()}, Workers0),
			State3=put_monitor(WorkerRef, worker, State2),
			process_waiting(State3#state{workers=Workers1});
		{starting, State1} ->
			hnc_workercntl:rejected(Cntl, Worker),
			State1;
		{returning, State1=#state{rooster=Rooster}} when map_size(Rooster)<Max ->
			hnc_workercntl:accepted(Cntl, Worker),
			State2=put_rooster(Worker, idle, State1),
			Workers1=queue:in({Worker, stamp()}, Workers0),
			process_waiting(State2#state{workers=Workers1});
		{returning, State1} ->
			hnc_workercntl:rejected(Cntl, Worker),
			State1;
		_ ->
			State0
	end.

do_return_worker(Worker, State0=#state{on_return=OnReturn, cntl_sup=CntlSup}) ->
	State1=remove_rooster(Worker, State0),
	{ok, Returner}=hnc_workercntl_sup:return_worker(CntlSup, Worker, OnReturn),
	ReturnerRef=monitor(process, Returner),
	State2=put_monitor(ReturnerRef, {returner, Returner, Worker}, State1),
	put_rooster(Returner, returning, State2).

take_rooster(Key, State) ->
	do_take(Key, #state.rooster, State).

put_rooster(Key, Value, State) ->
	do_put(Key, Value, #state.rooster, State).

remove_rooster(Key, State) ->
	do_remove(Key, #state.rooster, State).

update_rooster(Key, Value, State) ->
	do_update(Key, Value, #state.rooster, State).

take_monitor(Key, State) ->
	do_take(Key, #state.monitors, State).

put_monitor(Key, Value, State) ->
	do_put(Key, Value, #state.monitors, State).

remove_monitor(Key, State) ->
	do_remove(Key, #state.monitors, State).

update_monitor(Key, Value, State) ->
	do_update(Key, Value, #state.monitors, State).

do_take(Key, Pos, State) ->
	case maps:take(Key, element(Pos, State)) of
		{Value, New} -> {Value, setelement(Pos, State, New)};
		error -> error
	end.

do_put(Key, Value, Pos, State) ->
	setelement(Pos, State, maps:put(Key, Value, element(Pos, State))).

do_remove(Key, Pos, State) ->
	setelement(Pos, State, maps:remove(Key, element(Pos, State))).

do_update(Key, Value, Pos, State) ->
	setelement(Pos, State, maps:update(Key, Value, element(Pos, State))).

dequeue_waiting(State=#state{waiting=Waiting0}) ->
	case queue:out(Waiting0) of
		{empty, _} -> empty;
		{{value, Item}, Waiting1} -> {Item, State#state{waiting=Waiting1}}
	end.

has_waiting(#state{waiting=Waiting}) ->
	not queue:is_empty(Waiting).

dequeue_worker(State=#state{workers=Workers0, strategy=Strategy}) ->
	case
		case Strategy of
			fifo -> queue:out(Workers0);
			lifo -> queue:out_r(Workers0)
		end
	of
		{empty, _} -> empty;
		{{value, Item}, Workers1} -> {Item, State#state{workers=Workers1}}
	end.

has_worker(#state{workers=Workers}) ->
	not queue:is_empty(Workers).

start_worker(State0=#state{cntl_sup=CntlSup}) ->
	{ok, Starter}=hnc_workercntl_sup:start_worker(CntlSup),
	StarterRef=monitor(process, Starter),
	State1=put_monitor(StarterRef, {starter, Starter}, State0),
	put_rooster(Starter, starting, State1).

