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

-module(hnc_agent).

-behavior(gen_statem).

%% --- API --
-export([start_link/4]).
-export([checkin/3]).
-export([checkout/3]).
-export([give_away/4]).
-export([status/2]).
-export([worker/3]).

%% --- gen_statem ---
-export([callback_mode/0]).
-export([init/1]).
-export([starting/3]).
-export([idle/3]).
-export([out/3]).
-export([returning/3]).
-export([terminate/3]).
-export([code_change/4]).

-record(state, {
		parent,
		pool,
		opts,
		mod,
		args,
		worker,
		user,
		on_return,
		returner
	}).

%% --- API ---

-spec start_link(Pool, Opts, WorkerMod, WorkerArgs) -> gen_statem:start_ret() when
	Pool :: pid(),
	Opts :: hnc:opts(),
	WorkerMod :: module(),
	WorkerArgs :: term().
start_link(Pool, Opts, Mod, Args) ->
	gen_statem:start_link(?MODULE, {self(), Pool, Opts, Mod, Args}, []).

-spec checkout(Agent, User, Timeout) -> ok | {error, Reason} when
	Agent :: pid(),
	User :: pid(),
	Timeout :: timeout(),
	Reason :: out.
checkout(Pid, User, Timeout) ->
	gen_statem:call(Pid, {checkout, User}, Timeout).

-spec checkin(Agent, User, Timeout) -> ok | {error, Reason} when
	Agent :: pid(),
	User :: pid(),
	Timeout :: timeout(),
	Reason :: not_owner | idle.
checkin(Pid, User, Timeout) ->
	gen_statem:call(Pid, {checkin, User}, Timeout).

-spec give_away(Agent, OldUser, NewUser, Timeout) -> ok | {error, Reason} when
	Agent :: pid(),
	OldUser :: pid(),
	NewUser :: pid(),
	Timeout :: timeout(),
	Reason :: not_owner | idle.
give_away(Pid, OldUser, NewUser, Timeout) ->
	gen_statem:call(Pid, {give_away, OldUser, NewUser}, Timeout).

-spec status(Agent, Timeout) -> Status when
	Agent :: pid(),
	Timeout :: timeout(),
	Status :: starting | idle | out | returning.
status(Pid, Timeout) ->
	gen_statem:call(Pid, status, Timeout).

-spec worker(Agent, User, Timeout) -> {ok, Worker} | {error, Reason} when
	Agent :: pid(),
	User :: pid(),
	Timeout :: timeout(),
	Worker :: pid(),
	Reason :: not_owner.
worker(Pid, User, Timeout) ->
	gen_statem:call(Pid, {worker, User}, Timeout).

%% --- gen_statem ---

callback_mode() ->
	[state_functions, state_enter].

init({Parent, Pool, Opts, Mod, Args}) ->
	OnReturn=maps:get(on_return, Opts, undefined),
	{
		ok,
		starting,
		#state{
			parent=Parent,
			pool=Pool,
			opts=Opts,
			mod=Mod,
			args=Args,
			on_return=OnReturn
		}
	}.

starting(enter, _, #state{parent=Parent, opts=Opts, mod=Mod, args=Args}) ->
	Self=self(),
	_=spawn_link(
		fun () ->
			Shutdown=maps:get(shutdown, Opts, brutal_kill),
			Result=hnc_worker_sup:start_worker(Parent, Mod, Args, Shutdown),
			gen_statem:cast(Self, {worker_start_result, Result})
		end
	),
	keep_state_and_data;
starting(cast, {worker_start_result, {ok, Worker}}, State) when is_pid(Worker) ->
	WorkerRef=monitor(process, Worker),
	{next_state, idle, State#state{worker={Worker, WorkerRef}}};
starting(cast, {worker_start_result, {ok, NotAWorker}}, _) ->
	{stop, {error, {not_a_worker, NotAWorker}}};
starting(cast, {worker_start_result, {error, {Reason, _}}}, _) ->
	{stop, {error, Reason}};
starting({call, From}, status, _) ->
	gen_statem:reply(From, starting),
	keep_state_and_data;
starting(_, _, _) ->
	{keep_state_and_data, postpone}.

idle(enter, starting, #state{pool=Pool}) ->
	hnc_pool:agent_available(Pool, self()),
	keep_state_and_data;
idle(enter, out, #state{pool=Pool}) ->
	hnc_pool:agent_available(Pool, self()),
	keep_state_and_data;
idle(enter, returning, #state{pool=Pool}) ->
	hnc_pool:agent_available(Pool, self()),
	keep_state_and_data;
idle({call, From}, {checkout, User}, State) ->
	gen_statem:reply(From, ok),
	UserRef=monitor(process, User),
	{next_state, out, State#state{user={User, UserRef}}};
idle({call, From}, status, _) ->
	gen_statem:reply(From, idle),
	keep_state_and_data;
idle(info, {'DOWN', WorkerRef, process, Worker, shutdown}, State=#state{worker={Worker, WorkerRef}}) ->
	{keep_state, State#state{worker=undefined}};
idle(info, {'DOWN', WorkerRef, process, Worker, _}, #state{worker={Worker, WorkerRef}}) ->
	stop;
idle({call, From}, {checkin, _}, _) ->
	gen_statem:reply(From, {error, idle}),
	keep_state_and_data;
idle({call, From}, {give_away, _}, _) ->
	gen_statem:reply(From, {error, idle}),
	keep_state_and_data;
idle(_, _, _) ->
	keep_state_and_data.

out(enter, idle, #state{pool=Pool}) ->
	hnc_pool:agent_unavailable(Pool, self()),
	keep_state_and_data;
out({call, From}, {checkin, User}, State=#state{user={User, UserRef}, on_return=undefined}) ->
	demonitor(UserRef, [flush]),
	gen_statem:reply(From, ok),
	{next_state, idle, State#state{user=undefined}};
out({call, From}, {checkin, User}, State=#state{user={User, UserRef}}) ->
	demonitor(UserRef, [flush]),
	gen_statem:reply(From, ok),
	{next_state, returning, State#state{user=undefined}};
out({call, From}, {checkin, _}, _) ->
	gen_statem:reply(From, {error, not_owner}),
	keep_state_and_data;
out({call, From}, {give_away, OldUser, NewUser}, State=#state{user={OldUser, OldUserRef}}) ->
	gen_statem:reply(From, ok),
	demonitor(OldUserRef),
	NewUserRef=monitor(process, NewUser),
	{keep_state, State#state{user={NewUser, NewUserRef}}};
out({call, From}, {give_away, _, _}, _) ->
	gen_statem:reply(From, {error, not_owner}),
	keep_state_and_data;
out({call, From}, status, _) ->
	gen_statem:reply(From, out),
	keep_state_and_data;
out({call, From}, {worker, User}, #state{user={User, _}, worker={Worker, _}}) ->
	gen_statem:reply(From, {ok, Worker}),
	keep_state_and_data;
out({call, From}, {worker, _}, _) ->
	gen_statem:reply(From, {error, not_owner}),
	keep_state_and_data;
out(info, {'DOWN', UserRef, process, User, _}, State=#state{user={User, UserRef}, on_return=undefined}) ->
	{next_state, idle, State#state{user=undefined}};
out(info, {'DOWN', UserRef, process, User, _}, State=#state{user={User, UserRef}}) ->
	{next_state, returning, State#state{user=undefined}};
out(info, {'DOWN', WorkerRef, process, Worker, shutdown}, State=#state{worker={Worker, WorkerRef}}) ->
	{keep_state, State#state{worker=undefined}};
out(info, {'DOWN', WorkerRef, process, Worker, _}, #state{worker={Worker, WorkerRef}}) ->
	stop;
out({call, From}, {checkout, _}, _) ->
	gen_statem:reply(From, {error, out}),
	keep_state_and_data;
out(_, _, _) ->
	keep_state_and_data.

returning(enter, out, State=#state{worker={Worker, _}, on_return={Fun, Timeout}}) ->
	Returner=spawn_monitor(
		fun
			() ->
				link(Worker),
				_=timer:kill_after(Timeout),
				_=Fun(Worker),
				unlink(Worker)
		end
	),
	{keep_state, State#state{returner=Returner}};
returning({call, From}, status, _) ->
	gen_statem:reply(From, returning),
	keep_state_and_data;
returning(info, {'DOWN', ReturnerRef, process, Returner, normal}, State=#state{returner={Returner, ReturnerRef}}) ->
	{next_state, idle, State#state{returner=undefined}};
returning(info, {'DOWN', ReturnerRef, process, Returner, Reason}, State=#state{returner={Returner, ReturnerRef}}) ->
	#state{worker={Worker, WorkerRef}}=State,
	demonitor(WorkerRef, [flush]),
	exit(Worker, Reason),
	stop;
returning(_, _, _) ->
	{keep_state_and_data, postpone}.

terminate(_, _, _) ->
	ok.

code_change(_, StateName, State, _) ->
	{ok, StateName, State}.
