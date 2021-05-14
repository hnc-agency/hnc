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

-module(hnc_pool).

-behavior(gen_statem).

%% --- API ---
-export([start_link/4]).
-export([checkout/2]).
-export([pool_status/2]).
-export([prune/1]).
-export([set_strategy/2, get_strategy/2]).
-export([set_size/2, get_size/2]).
-export([set_linger/2, get_linger/2]).

%% --- INTERNAL ---
-export([agent_available/2]).
-export([agent_unavailable/2]).

%% --- gen_statem ---
-export([callback_mode/0]).
-export([init/1]).
-export([setup/3]).
-export([running/3]).
-export([terminate/3]).
-export([code_change/4]).

-record(agent, {
		stamp :: undefined | integer(),
		pid :: pid()
	}
).
-record(waiter, {
		reply_to :: term(),
		user :: pid(),
		timer :: undefined | timer:tref()
	}
).
-record(state, {
		parent :: pid(),
	  	opts :: hnc:opts(),
		worker_mod :: module(),
		worker_args :: term(),
		sup :: undefined | pid(),
		strategy :: hnc:strategy(),
		size :: hnc:size(),
		linger :: hnc:linger(),
		sweep_ref :: undefined | reference(),
		rooster :: ets:tab(),
		agents :: queue:queue(#agent{}),
		waiting :: queue:queue(),
		default_prio :: term()
	}
).

%% --- API ---

-spec start_link(Name, Opts, WorkerMod, WorkerArgs) -> gen_statem:start_ret() when
	Name :: hnc:pool(),
	Opts :: hnc:opts(),
	WorkerMod :: module(),
	WorkerArgs :: term().
start_link(Name, Opts, WorkerMod, WorkerArgs) ->
	gen_statem:start_link(
		{local, Name},
		?MODULE,
		{self(), Opts, WorkerMod, WorkerArgs},
		[]
	).

-spec checkout(Pool, Timeout) -> {ok, Agent} when
	Pool :: hnc:pool(),
	Timeout :: timeout(),
	Agent :: pid().
checkout(Pool, Timeout) ->
	case gen_statem:call(Pool, {checkout, self(), Timeout}) of
		{ok, Agent} -> {ok, Agent};
		{error, timeout} -> exit(timeout);
		{error, Reason} -> error(Reason);
		Other -> exit({unexpected, Other})
	end.

-spec prune(Pool) -> ok when
	Pool :: hnc:pool().
prune(Pool) ->
	gen_statem:cast(Pool, prune).

-spec set_size(Pool, Size) -> ok when
	Pool :: hnc:pool(),
	Size :: hnc:size().
set_size(Pool, Size) ->
	gen_statem:cast(Pool, {set_size, Size}).

-spec get_size(Pool, Timeout) -> Size when
	Pool :: hnc:pool(),
	Timeout :: timeout(),
	Size :: hnc:size().
get_size(Pool, Timeout) ->
	gen_statem:call(Pool, get_size, Timeout).

-spec set_strategy(Pool, Strategy) -> ok when
	Pool :: hnc:pool(),
	Strategy :: hnc:strategy().
set_strategy(Pool, Strategy) ->
	gen_statem:cast(Pool, {set_strategy, Strategy}).

-spec get_strategy(Pool, Timeout) -> Strategy when
	Pool :: hnc:pool(),
	Timeout :: timeout(),
	Strategy :: hnc:strategy().
get_strategy(Pool, Timeout) ->
	gen_statem:call(Pool, get_strategy, Timeout).

-spec set_linger(Pool, Linger) -> ok when
	Pool :: hnc:pool(),
	Linger :: hnc:linger().
set_linger(Pool, Linger) ->
	gen_statem:cast(Pool, {set_linger, Linger}).

-spec get_linger(Pool, Timeout) -> Linger when
	Pool :: hnc:pool(),
	Timeout :: timeout(),
	Linger :: hnc:linger().
get_linger(Pool, Timeout) ->
	gen_statem:call(Pool, get_linger, Timeout).

-spec pool_status(Pool, Timeout) -> Status when
	Pool :: hnc:pool(),
	Timeout :: timeout(),
	Status :: hnc:pool_status().
pool_status(Pool, Timeout) ->
	gen_statem:call(Pool, pool_status, Timeout).

%% --- INTERNAL ---

agent_available(Pool, Agent) ->
	gen_statem:cast(Pool, {agent_available, Agent}).

agent_unavailable(Pool, Agent) ->
	gen_statem:cast(Pool, {agent_unavailable, Agent}).

%% --- gen_statem ---

callback_mode() ->
	[state_functions, state_enter].

init({Parent, Opts, WorkerMod, WorkerArgs}) ->
	Size=maps:get(size, Opts, {5, 5}),
	Strategy=maps:get(strategy, Opts, fifo),
	Linger=maps:get(linger, Opts, infinity),
	gen_statem:cast(self(), {setup, Parent}),
	{
		ok,
		setup,
		#state{
			parent=Parent,
			opts=Opts,
			worker_mod=WorkerMod,
			worker_args=WorkerArgs,
			rooster=ets:new(?MODULE, []),
			agents=queue:new(),
			waiting=queue:new(),
			strategy=Strategy,
			size=Size,
			linger=Linger
		}
	}.

setup(enter, setup, State=#state{parent=Parent}) ->
	{ok, Sup}=hnc_pool_sup:start_worker_sup_sup(Parent),
	gen_statem:cast(self(), init),
	{keep_state, State#state{sup=Sup}};
setup(cast, init, State=#state{size={0, _}}) ->
	{next_state, running, State};
setup(cast, init, State) ->
	#state{
		opts=Opts, worker_mod=Mod, worker_args=Args,
		sup=Sup, linger=Linger, size={Min, _},
		rooster=Rooster
	}=State,
	[start_agent(Rooster, Sup, Opts, Mod, Args) || _ <- lists:seq(1, Min)],
	SweepRef=schedule_sweep_idle(Linger),
	{next_state, running, State#state{sweep_ref=SweepRef}};
setup(_, _, _) ->
	{keep_state_and_data, postpone}.

running(cast, {agent_unavailable, Agent}, State) ->
	#state{rooster=Rooster, agents=Agents0}=State,
	ets:update_element(Rooster, Agent, {4, unavailable}),
	Agents1=remove_agent(Agent, Agents0),
	{keep_state, State#state{agents=Agents1}};
running(cast, {agent_available, Agent}, State) ->
	#state{rooster=Rooster, agents=Agents0, waiting=Waiting0}=State,
	{Agents1, Waiting1}=case dequeue_waiting(Waiting0) of
		empty ->
			ets:update_element(Rooster, Agent, {4, available}),
			Agents2=put_agent(Agent, Agents0),
			{Agents2, Waiting0};
		{#waiter{reply_to=ReplyTo, user=User, timer=TRef}, Waiting2} ->
			_=timer:cancel(TRef),
			try
				hnc_agent:checkout(Agent, User, infinity)
			of
				ok ->
					_=timer:cancel(TRef),
					gen_statem:reply(ReplyTo, {ok, Agent}),
					{Agents0, Waiting2};
				{error, _} ->
					{Agents0, Waiting0}
			catch
				_:_ ->
					{Agents0, Waiting0}
			end
	end,
	{keep_state, State#state{agents=Agents1, waiting=Waiting1}};
running(cast, {set_size, Size}, State) ->
	{keep_state, State#state{size=Size}};
running({call, From}, get_size, #state{size=Size}) ->
	gen_statem:reply(From, Size),
	keep_state_and_data;
running(cast, {set_strategy, Strategy}, State) ->
	{keep_state, State#state{strategy=Strategy}};
running({call, From}, get_strategy, #state{strategy=Strategy}) ->
	gen_statem:reply(From, Strategy),
	keep_state_and_data;
running(cast, {set_linger, Linger}, State) ->
	SweepRef=schedule_sweep_idle(Linger),
	{keep_state, State#state{linger=Linger, sweep_ref=SweepRef}};
running({call, From}, get_linger, #state{linger=Linger}) ->
	gen_statem:reply(From, Linger),
	keep_state_and_data;
running({call, From}, pool_status, #state{rooster=Rooster}) ->
	gen_statem:reply(From, status_sizes(Rooster)),
	keep_state_and_data;
running(Event={call, From}, Msg={checkout, User, Timeout}, State) ->
	#state{
		opts=Opts, worker_mod=Mod, worker_args=Args,
		sup=Sup, strategy=Strategy, size={_, Max},
		rooster=Rooster, agents=Agents0, waiting=Waiting0
	}=State,
	case
		select_agent(Strategy, Agents0)
	of
		false ->
			gen_statem:reply(From, {error, badpriority}),
			keep_state_and_data;
		{Agent, Agents1} ->
			try
				hnc_agent:checkout(Agent, User, infinity)
			of
				ok ->
					gen_statem:reply(From, {ok, Agent}),
					{keep_state, State#state{agents=Agents1}};
				{error, _} ->
					{
						keep_state,
						State#state{agents=Agents1},
						{next_event, Event, Msg}
					}
			catch
				_:_ ->
					{
						keep_state,
						State#state{agents=Agents1},
						{next_event, Event, Msg}
					}
			end;
		empty when Timeout=<0 ->
			gen_statem:reply(From, {error, timeout}),
			keep_state_and_data;
		empty when Timeout=:=infinity ->
			Waiting1=enqueue_waiting(
				#waiter{reply_to=From, user=User},
				Waiting0
			),
			case Max=:=infinity orelse ets:info(Rooster, size)<Max of
				true ->
					start_agent(Rooster, Sup, Opts, Mod, Args);
				false ->
					ok
			end,
			{keep_state, State#state{waiting=Waiting1}};
		empty ->
			{ok, TRef}=timer:send_after(Timeout, {checkout_timeout, From}),
			Waiting1=enqueue_waiting(
				#waiter{reply_to=From, user=User, timer=TRef},
				Waiting0
			),
			case Max=:=infinity orelse ets:info(Rooster, size)<Max of
				true ->
					start_agent(Rooster, Sup, Opts, Mod, Args);
				false ->
					ok
			end,
			{keep_state, State#state{waiting=Waiting1}}
	end;
running(info, {checkout_timeout, ReplyTo}, State=#state{waiting=Waiting0}) ->
	Waiting1=queue:delete_with(
		fun
			(#waiter{reply_to=QReplyTo}) when QReplyTo=:=ReplyTo ->
				gen_statem:reply(ReplyTo, {error, timeout}),
				true;
			(_) ->
				false
		end,
		Waiting0
	),
	{keep_state, State#state{waiting=Waiting1}};
running(info, {sweep_idle, SweepRef0}, State) ->
	#state{
		size={Min, _}, linger=Linger={LingerTime, _}, sweep_ref=SweepRef0,
		sup=Sup, rooster=Rooster, agents=Agents0
	}=State,
	Treshold=stamp(-LingerTime),
	Agents1=prune_agents(Min, Treshold, Sup, Rooster, Agents0),
	SweepRef1=schedule_sweep_idle(Linger),
	{keep_state, State#state{sweep_ref=SweepRef1, agents=Agents1}};
running(cast, prune, State) ->
	#state{
		size={Min, _}, sup=Sup, rooster=Rooster, agents=Agents0
	}=State,
	Treshold=stamp(),
	Agents1=prune_agents(Min, Treshold, Sup, Rooster, Agents0),
	{keep_state, State#state{agents=Agents1}};
running(info, {'DOWN', Ref, process, Pid, Reason}, State) ->
	#state{
		opts=Opts, worker_mod=Mod, worker_args=Args, sup=Sup,
		size={Min, Max}, rooster=Rooster, agents=Agents0,
		waiting=Waiting0
	}=State,
	case ets:take(Rooster, Pid) of
		[{Pid, Ref, _, starting}] ->
			Waiting1=case dequeue_waiting(Waiting0) of
				empty ->
					Waiting0;
				{#waiter{reply_to=ReplyTo}, Waiting2} ->
					gen_statem:reply(ReplyTo, Reason),
					Waiting2
			end,
			{keep_state, State#state{waiting=Waiting1}};
		[{Pid, Ref, _, available}] ->
			Agents1=remove_agent(Pid, Agents0),
			RoosterSize=ets:info(Rooster, size),
			_=case RoosterSize<Min of
				true ->
					start_agent(Rooster, Sup, Opts, Mod, Args);
				false ->
					ok
			end,
			{keep_state, State#state{agents=Agents1}};
		[{Pid, Ref, _, unavailable}] ->
			RoosterSize=ets:info(Rooster, size),
			_=case
				RoosterSize<Min
				orelse RoosterSize<Max
				andalso not queue:is_empty(Waiting0)
			of
				true ->
					start_agent(Rooster, Sup, Opts, Mod, Args);
				false ->
					ok
			end,
			{keep_state, State};
		%% ???
		[] ->
			keep_state_and_data
	end;
running(_, _, _) ->
	keep_state_and_data.

terminate(_, _, _) ->
	ok.

code_change(_, StateName, State, _) ->
	{ok, StateName, State}.

%% --- INTERNAL ---

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

start_agent(Rooster, Sup, Opts, Mod, Args) ->
	{ok, WorkerSup}=hnc_worker_sup_sup:start_worker_sup(Sup),
	{ok, Agent}=hnc_worker_sup:start_agent(WorkerSup, self(), Opts, Mod, Args),
	AgentRef=monitor(process, Agent),
	ets:insert_new(Rooster, {Agent, AgentRef, WorkerSup, starting}),
	ok.

stop_agent(Rooster, Sup, Agent) ->
	_=case ets:lookup(Rooster, Agent) of
		[{Agent, AgentRef, WorkerSup, _}] ->
			demonitor(AgentRef, [flush]),
			ets:delete(Rooster, Agent),
			spawn(
				fun () ->
					hnc_worker_sup:stop_worker(WorkerSup),
					hnc_worker_sup:stop_agent(WorkerSup),
					hnc_worker_sup_sup:stop_worker_sup(Sup, WorkerSup)
				end
			);
		_ ->
			ok
	end,
	ok.

status_sizes(Rooster) ->
	ets:foldl(
		fun ({_, _, _, Status}, Acc) ->
			maps:update_with(Status, fun (Old) -> Old+1 end, Acc)
		end,
		#{starting => 0, available => 0, unavailable => 0},
		Rooster
	).

prune_agents(Min, Treshold, Sup, Rooster, Agents) ->
	N=max(0, min(ets:info(Rooster, size)-Min, queue:len(Agents))),
	prune_agents1(N, Treshold, Sup, Rooster, Agents).

prune_agents1(0, _, _, _, Agents) ->
	Agents;
prune_agents1(N, Treshold, Sup, Rooster, Agents0) ->
	case queue:out(Agents0) of
		{{value, #agent{pid=Pid, stamp=Stamp}}, Agents1} when Stamp=<Treshold ->
			stop_agent(Rooster, Sup, Pid),
			prune_agents1(N-1, Treshold, Sup, Rooster, Agents1);
		_ ->
			Agents0
	end.

enqueue_waiting(Waiter, Waiting) ->
	queue:in(Waiter, Waiting).

dequeue_waiting(Waiting) ->
	case queue:out(Waiting) of
	    {empty, _} -> empty;
	    {{value, V}, Q} -> {V, Q}
	end.

put_agent(Pid, Agents0) ->
	queue:in(#agent{pid=Pid, stamp=stamp()}, Agents0).

remove_agent(Pid, Agents0) ->
	remove_agent(Pid, Agents0, queue:new()).

remove_agent(Pid, Agents0, Acc) ->
	case queue:out(Agents0) of
		{empty, _} ->
			Acc;
		{{value, #agent{pid=Pid}}, Agents1} ->
			queue:join(Acc, Agents1);
		{{value, Agent}, Agents1} ->
			remove_agent(Pid, Agents1, queue:in(Agent, Acc))
	end.

select_agent(fifo, Agents0) ->
	case queue:out(Agents0) of
		{empty, _} -> empty;
		{{value, #agent{pid=Pid}}, Agents1} -> {Pid, Agents1}
	end;
select_agent(lifo, Agents0) ->
	case queue:out_r(Agents0) of
		{empty, _} -> empty;
		{{value, #agent{pid=Pid}}, Agents1} -> {Pid, Agents1}
	end.
