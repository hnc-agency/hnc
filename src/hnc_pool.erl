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

-record(user, {
		ref :: reference(),
		workers :: sets:set(),
		waiting :: non_neg_integer()
	}
).
-record(worker, {
		stamp :: undefined | integer(),
		worker :: hnc:worker()
	}
).
-record(waiter, {
		reply_to :: term(),
		user :: pid(),
		timer :: undefined | timer:tref()
	}
).
-record(starter_cntl, {
		ref :: reference()
	}
).
-record(returner_cntl, {
		ref :: reference(),
		worker :: hnc:worker()
	}
).
-record(state, {
		strategy :: hnc:strategy(),
		size :: hnc:size(),
		linger :: hnc:linger(),
		on_return :: hnc:on_return(),
		sweep_ref :: undefined | reference(),
		worker_sup :: undefined | pid(),
		rooster :: ets:tab(),
		workers :: queue:queue(#worker{}),
		users :: #{pid() => #user{}},
		waiting :: queue:queue(#waiter{}),
		cntls :: #{pid() => term()}
	}
).

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
	{
		ok,
		setup,
		#state{
			rooster=ets:new(?MODULE, []),
			workers=queue:new(),
			users=#{},
			waiting=queue:new(),
			cntls=#{},
			strategy=Strategy,
			size=Size,
			linger=Linger,
			on_return=OnReturn
		}
	}.

handle_event(cast, {setup, Parent, WorkerMod, WorkerArgs, Shutdown}, setup, State) ->
	{ok, WorkerSup}=hnc_pool_sup:start_worker_sup(Parent, WorkerMod, WorkerArgs, Shutdown),
	gen_statem:cast(self(), init),
	{keep_state, State#state{worker_sup=WorkerSup}};
handle_event(cast, init, setup, State=#state{size={0, _}}) ->
	{next_state, running, State};
handle_event(cast, init, setup, State=#state{linger=Linger, size={Min, _}, worker_sup=WorkerSup, rooster=Rooster, cntls=Cntls0}) ->
	Cntls1=lists:foldl(
		fun (_, Acc) ->
			start_worker(WorkerSup, Rooster, Acc)
		end,
		Cntls0,
		lists:seq(1, Min)
	),
	SweepRef=schedule_sweep_idle(Linger),
	{next_state, running, State#state{sweep_ref=SweepRef, cntls=Cntls1}};
handle_event(_, _, setup, _) ->
	{keep_state_and_data, postpone};
handle_event(_, _, {setup_wait, _}, _) ->
	{keep_state_and_data, postpone};
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
handle_event({call, From}, {worker_status, Worker}, running, #state{rooster=Rooster}) ->
	spawn(
		fun () ->
			Status=case ets:lookup(Rooster, Worker) of
				[{Worker, _, WorkerStatus, _}] ->
					WorkerStatus;
				[] ->
					undefined
			end,
			gen_statem:reply(From, Status)
		end
	),
	keep_state_and_data;
handle_event({call, From}, pool_status, running, #state{rooster=Rooster}) ->
	spawn(
		fun () ->
			gen_statem:reply(From, status_sizes(Rooster))
		end
	),
	keep_state_and_data;
handle_event({call, From}, {checkout, User, Timeout}, running, State=#state{strategy=Strategy, size={_, Max}, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0, users=Users0, waiting=Waiting0, cntls=Cntls0}) ->
	case dequeue(Workers0, Strategy) of
		{#worker{worker=Worker}, Workers1} ->
			ets:update_element(Rooster, Worker, [{3, out}, {4, User}]),
			gen_statem:reply(From, {ok, Worker}),
			Users1=add_user_worker(User, Worker, Users0),
			{keep_state, State#state{workers=Workers1, users=Users1}};
		empty when Timeout=<0 ->
			gen_statem:reply(From, {error, timeout}),
			keep_state_and_data;
		empty when Timeout=:=infinity ->
			Users1=add_user(User, Users0),
			Users2=inc_user_waiting(User, Users1),
			Waiting1=queue:in(#waiter{reply_to=From, user=User}, Waiting0),
			Cntls1=case Max=:=infinity orelse ets:info(Rooster, size)<Max of
				true ->
					start_worker(WorkerSup, Rooster, Cntls0);
				false ->
					Cntls0
			end,
			{keep_state, State#state{users=Users2, waiting=Waiting1, cntls=Cntls1}};
		empty ->
			{ok, TRef}=timer:send_after(Timeout, {checkout_timeout, User, From}),
			Users1=add_user(User, Users0),
			Users2=inc_user_waiting(User, Users1),
			Waiting1=queue:in(#waiter{reply_to=From, user=User, timer=TRef}, Waiting0),
			Cntls1=case Max=:=infinity orelse ets:info(Rooster, size)<Max of
				true ->
					start_worker(WorkerSup, Rooster, Cntls0);
				false ->
					Cntls0
			end,
			{keep_state, State#state{users=Users2, waiting=Waiting1, cntls=Cntls1}}
	end;
handle_event(info, {checkout_timeout, User, ReplyTo}, running, State=#state{waiting=Waiting0, users=Users0}) ->
	Waiting1=queue:filter(
		fun
			(#waiter{reply_to=QReplyTo}) when QReplyTo=:=ReplyTo ->
				gen_statem:reply(ReplyTo, {error, timeout}),
				false;
			(_) ->
				true
		end,
		Waiting0
	),
	Users1=dec_user_waiting(User, Users0),
	Users2=remove_empty_user(User, Users1),
	{keep_state, State#state{waiting=Waiting1, users=Users2}};
handle_event({call, From}, {checkin, Worker, User}, running, State=#state{on_return=OnReturn, rooster=Rooster, users=Users0, cntls=Cntls0}) ->
	case ets:lookup(Rooster, Worker) of
		[{Worker, _Ref, out, User}] ->
			gen_statem:reply(From, ok),
			Cntls1=return_worker(Worker, OnReturn, Cntls0),
			Users1=remove_user_worker(User, Worker, Users0),
			{keep_state, State#state{users=Users1, cntls=Cntls1}};
		[{Worker, _Ref, out, _OtherUser}] ->
			gen_statem:reply(From, {error, not_owner}),
			keep_state_and_data;
		_ ->
			gen_statem:reply(From, {error, not_found}),
			keep_state_and_data
	end;
handle_event({call, From}, {give_away, Worker, OldUser, NewUser}, running, State=#state{rooster=Rooster, users=Users0}) ->
	case ets:lookup(Rooster, Worker) of
		[{Worker, _Ref, out, OldUser}] ->
			gen_statem:reply(From, ok),
			ets:update_element(Rooster, Worker, {4, NewUser}),
			Users1=remove_user_worker(OldUser, Worker, Users0),
			Users2=add_user_worker(NewUser, Worker, Users1),
			{keep_state, State#state{users=Users2}};
		[{Worker, _Ref, out, _OtherUser}] ->
			gen_statem:reply(From, {error, not_owner}),
			keep_state_and_data;
		_ ->
			gen_statem:reply(From, {error, not_found}),
			keep_state_and_data
	end;
handle_event(info, {started_worker, Cntl, Worker}, running, State=#state{size={_, Max}, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0, users=Users0, waiting=Waiting0, cntls=Cntls0}) ->
	{#starter_cntl{ref=CntlRef}, Cntls1}=maps:take(Cntl, Cntls0),
	demonitor(CntlRef, [flush]),
	ets:delete(Rooster, Cntl),
	case Max=:=infinity orelse ets:info(Rooster, size)=<Max of
		true ->
			Ref=monitor(process, Worker),
			ets:insert_new(Rooster, {Worker, Ref, idle, undefined}),
			{Workers1, Users1, Waiting1}=idle_or_assign_worker(undefined, Worker, Rooster, Workers0, Users0, Waiting0),
			{keep_state, State#state{workers=Workers1, users=Users1, waiting=Waiting1, cntls=Cntls1}};
		false ->
			Workers1=stop_worker(WorkerSup, Worker, Rooster, Workers0),
			{keep_state, State#state{workers=Workers1, cntls=Cntls1}}
	end;
handle_event(info, {returned_worker, Cntl, Worker}, running, State=#state{size={_, Max}, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0, users=Users0, waiting=Waiting0, cntls=Cntls0}) ->
	{#returner_cntl{ref=CntlRef, worker=Worker}, Cntls1}=maps:take(Cntl, Cntls0),
	demonitor(CntlRef, [flush]),
	case Max=:=infinity orelse ets:info(Rooster, size)=<Max of
		true ->
			ets:update_element(Rooster, Worker, [{3, idle}, {4, undefined}]),
			{Workers1, Users1, Waiting1}=idle_or_assign_worker(undefined, Worker, Rooster, Workers0, Users0, Waiting0),
			{keep_state, State#state{workers=Workers1, users=Users1, waiting=Waiting1, cntls=Cntls1}};
		false ->
			Workers1=stop_worker(WorkerSup, Worker, Rooster, Workers0),
			{keep_state, State#state{workers=Workers1, cntls=Cntls1}}
	end;
handle_event(info, {sweep_idle, SweepRef0}, running, State=#state{strategy=Strategy, size={Min, _}, linger=Linger={LingerTime, _}, sweep_ref=SweepRef0, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0}) ->
	Treshold=stamp(-LingerTime),
	Workers1=prune_workers(Min, Treshold, Strategy, WorkerSup, Rooster, Workers0),
	SweepRef1=schedule_sweep_idle(Linger),
	{keep_state, State#state{sweep_ref=SweepRef1, workers=Workers1}};
handle_event(cast, prune, running, State=#state{strategy=Strategy, size={Min, _}, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0}) ->
	Treshold=stamp(),
	Workers1=prune_workers(Min, Treshold, Strategy, WorkerSup, Rooster, Workers0),
	{keep_state, State#state{workers=Workers1}};
handle_event(info, {'DOWN', Ref, process, Pid, Reason}, running, State=#state{size={_, Max}, worker_sup=WorkerSup, rooster=Rooster, workers=Workers0, users=Users0, waiting=Waiting0, cntls=Cntls0}) ->
	case ets:take(Rooster, Pid) of
		%% Idle worker exited.
		[{Pid, Ref, idle, undefined}] ->
			Workers1=queue:filter(fun (#worker{worker=QPid}) -> QPid=/=Pid end, Workers0),
			{keep_state, State#state{workers=Workers1}};
		%% Checked out worker exited.
		[{Pid, Ref, out, User}] ->
			Users1=remove_user_worker(User, Pid, Users0),
			Cntls1=maybe_restart_worker(WorkerSup, Max, Rooster, Waiting0, Cntls0),
			{keep_state, State#state{users=Users1, cntls=Cntls1}};
		%% Returning worker exited.
		[{Pid, Ref, returning, Cntl}] ->
			Cntls1=case maps:take(Cntl, Cntls0) of
				{#returner_cntl{ref=CntlRef, worker=Pid}, Cntls2} ->
					demonitor(CntlRef, [flush]),
					Cntls2;
				error ->
					Cntls0
			end,
			exit(Cntl, kill),
			Cntls3=maybe_restart_worker(WorkerSup, Max, Rooster, Waiting0, Cntls1),
			{keep_state, State#state{cntls=Cntls3}};
		%% Starter exited.
		[{Pid, Ref, starting, undefined}] ->
			Cntls1=maps:remove(Pid, Cntls0),
			{Users1, Waiting1, Cntls2}=case dequeue(Waiting0) of
				{#waiter{reply_to=ReplyTo, user=User, timer=TRef}, Waiting2} ->
					_=timer:cancel(TRef),
					gen_statem:reply(ReplyTo, {error, Reason}),
					Users2=dec_user_waiting(User, Users0),
					Cntls3=maybe_restart_worker(WorkerSup, Max, Rooster, Waiting2, Cntls1),
					{Users2, Waiting2, Cntls3};
				empty ->
					{Users0, Waiting0, Cntls1}
			end,
			{keep_state, State#state{users=Users1, waiting=Waiting1, cntls=Cntls2}};
		%% User exited.
		[] when is_map_key(Pid, Users0) ->
			{#user{ref=Ref, workers=UserWorkers, waiting=UserWaiting}, Users1}=maps:take(Pid, Users0),
			Waiting1=case UserWaiting>0 of
				true ->
					queue:filter(
						fun
							(#waiter{reply_to=ReplyTo, user=QPid, timer=TRef}) when QPid=:=Pid ->
								_=timer:cancel(TRef),
								gen_statem:reply(ReplyTo, {error, noproc}),
								false;
							(_) ->
								true
						end,
						Waiting0
					);
				false ->
					Waiting0
			end,
			{Workers1, Users2, Waiting1}=sets:fold(
				fun (Worker, {WorkerAcc, UserAcc, WaitingAcc}) ->
					idle_or_assign_worker(Pid, Worker, Rooster, WorkerAcc, UserAcc, WaitingAcc)
				end,
				{Workers0, Users1, Waiting0},
				UserWorkers
			),
			{keep_state, State#state{workers=Workers1, users=Users2, waiting=Waiting1}};
		%% Returner exited.
		[] when is_map_key(Pid, Cntls0) ->
			{#returner_cntl{ref=Ref, worker=Worker}, Cntls1}=maps:take(Pid, Cntls0),
			Workers1=stop_worker(WorkerSup, Worker, Rooster, Workers0),
			{keep_state, State#state{workers=Workers1, cntls=Cntls1}};
		%% ???
		[] ->
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

schedule_sweep_idle(infinity) ->
	undefined;
schedule_sweep_idle({_, SweepInterval}) ->
	Ref=make_ref(),
	{ok, _}=timer:send_after(SweepInterval, {sweep_idle, Ref}),
	Ref.

start_worker(WorkerSup, Rooster, Cntls) ->
	Self=self(),
	{Pid, Ref}=spawn_monitor(
		fun () ->
			{ok, Worker}=hnc_worker_sup:start_worker(WorkerSup),
			Self ! {started_worker, self(), Worker}
		end
	),
	ets:insert_new(Rooster, {Pid, Ref, starting, undefined}),
	Cntls#{Pid => #starter_cntl{ref=Ref}}.

return_worker(Worker, OnReturn, Cntls) ->
	Self=self(),
	{Pid, Ref}=spawn_monitor(
		fun
			() when OnReturn=:=undefined ->
				Self ! {returned_worker, self(), Worker};
			() ->
				{Fun, Timeout}=OnReturn,
				_=timer:kill_after(Timeout),
				link(Worker),
				Fun(Worker),
				Self ! {returned_worker, self(), Worker}
		end
	),
	Cntls#{Pid => #returner_cntl{ref=Ref, worker=Worker}}.

maybe_restart_worker(WorkerSup, Max, Rooster, Waiting, Cntls) ->
	NW=queue:len(Waiting),
	case NW>0 andalso (Max=:=infinity orelse ets:info(Rooster, size)<Max) andalso status_sizes(Rooster) of
		#{starting:=NS, returning:=NR} when NS+NR<NW ->
			start_worker(WorkerSup, Rooster, Cntls);
		_ ->
			Cntls
	end.

stop_worker(WorkerSup, Worker, Rooster, Workers0) ->
	_=case ets:take(Rooster, Worker) of
		[{Worker, Ref, _, _}] ->
			demonitor(Ref, [flush]);
		_ ->
			ok
	end,
	spawn(fun () -> hnc_worker_sup:stop_worker(WorkerSup, Worker) end),
	queue:filter(fun (#worker{worker=QPid}) -> QPid=/=Worker end, Workers0).

status_sizes(Rooster) ->
	ets:foldl(
		fun ({_, _, Status, _}, Acc) ->
			maps:update_with(Status, fun (Old) -> Old+1 end, Acc)
		end,
		#{starting => 0, idle => 0, out => 0, returning => 0},
		Rooster
	).

prune_workers(Min, Treshold, Strategy, WorkerSup, Rooster, Workers0) ->
	WList=case Strategy of
		fifo -> lists:reverse(queue:to_list(Workers0));
		lifo -> queue:to_list(Workers0)
	end,
	N0=max(0, min(ets:info(Rooster, size)-Min, length(WList))),
	{_, Workers1}=lists:foldl(
		fun
			(#worker{stamp=Stamp, worker=Worker}, {N1, Workers2}) when N1>0, Stamp=<Treshold ->
				{N1-1, stop_worker(WorkerSup, Worker, Rooster, Workers2)};
			(_, Acc) ->
				Acc
		end,
		{N0, Workers0},
		WList
	),
	Workers1.

dequeue(Queue) ->
	dequeue(Queue, fifo).

dequeue(Queue, fifo) ->
	dequeue_transform_result(queue:out(Queue));
dequeue(Queue, lifo) ->
	dequeue_transform_result(queue:out_r(Queue)).

dequeue_transform_result({empty, _}) ->
	empty;
dequeue_transform_result({{value, Value}, Queue}) ->
	{Value, Queue}.

add_user(User, Users) when is_map_key(User, Users) ->
	Users;
add_user(User, Users) ->
	Users#{User => #user{ref=monitor(process, User), workers=sets:new(), waiting=0}}.

add_user_worker(User, Worker, Users) when is_map_key(User, Users) ->
	maps:update_with(User, fun (Old=#user{workers=Workers}) -> Old#user{workers=sets:add_element(Worker, Workers)} end, Users);
add_user_worker(User, Worker, Users) ->
	add_user_worker(User, Worker, add_user(User, Users)).

inc_user_waiting(User, Users) when is_map_key(User, Users) ->
	maps:update_with(User, fun (Old=#user{waiting=Waiting}) -> Old#user{waiting=Waiting+1} end, Users);
inc_user_waiting(_, Users) ->
	Users.

dec_user_waiting(User, Users) when is_map_key(User, Users) ->
	maps:update_with(User, fun (Old=#user{waiting=Waiting}) -> Old#user{waiting=max(0, Waiting-1)} end, Users);
dec_user_waiting(_, Users) ->
	Users.

remove_empty_user(User, Users0) when is_map_key(User, Users0) ->
	{#user{ref=Ref, workers=Workers, waiting=Waiting}, Users1}=maps:take(User, Users0),
	case Waiting=<0 andalso sets:is_empty(Workers) of
		true ->
			demonitor(Ref, [flush]),
			Users1;
		false ->
			Users0
	end;
remove_empty_user(_, Users) ->
	Users.

remove_user_worker(User, Worker, Users0) when is_map_key(User, Users0) ->
	Users1=maps:update_with(User, fun (Old=#user{workers=Workers}) -> Old#user{workers=sets:del_element(Worker, Workers)} end, Users0),
	remove_empty_user(User, Users1);
remove_user_worker(_, _, Users) ->
	Users.

idle_or_assign_worker(OldUser, Worker, Rooster, Workers0, Users0, Waiting0) ->
	Users1=remove_user_worker(OldUser, Worker, Users0),
	case dequeue(Waiting0) of
		empty ->
			ets:update_element(Rooster, Worker, [{3, idle}, {4, undefined}]),
			Workers1=queue:in(#worker{stamp=stamp(), worker=Worker}, Workers0),
			{Workers1, Users1, Waiting0};
		{#waiter{reply_to=ReplyTo, user=NewUser, timer=TRef}, Waiting1} ->
			_=timer:cancel(TRef),
			ets:update_element(Rooster, Worker, [{3, out}, {4, NewUser}]),
			gen_statem:reply(ReplyTo, {ok, Worker}),
			Users2=dec_user_waiting(NewUser, Users1),
			Users3=add_user_worker(NewUser, Worker, Users2),
			{Workers0, Users3, Waiting1}
	end.
