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

-module(hnc).

-export([checkin/1, checkin/2]).
-export([checkout/1, checkout/2]).
-export([child_spec/4]).
-export([get_linger/1, get_linger/2]).
-export([get_size/1, get_size/2]).
-export([get_strategy/1, get_strategy/2]).
-export([get_worker/1, get_worker/2]).
-export([give_away/3, give_away/4]).
-export([pool_status/1, pool_status/2]).
-export([prune/1]).
-export([set_linger/2]).
-export([set_size/2]).
-export([set_strategy/2]).
-export([start_pool/4]).
-export([stop_pool/1]).
-export([transaction/2, transaction/3]).
-export([validate_opts/1]).
-export([worker_status/1, worker_status/2]).

-record(agent, {
		pid :: pid()
	}).

-opaque ref() :: #agent{}.
-type pool() :: atom().
-type worker() :: pid().
-type transaction_fun(Result) :: fun((worker()) -> Result).
-type size() :: {non_neg_integer(), pos_integer() | infinity}.
-type strategy() :: fifo | lifo.
-type linger() :: infinity | {non_neg_integer(), non_neg_integer()}.
-type on_return() :: undefined | {fun((worker()) -> any()), timeout()}.
-type shutdown() :: timeout() | brutal_kill.
-type worker_status() :: starting | idle | out | returning.
-type pool_status() :: #{
	available:=non_neg_integer(),
	unavailable:=non_neg_integer(),
	starting:=non_neg_integer()
}.
-type opts() :: #{
	linger => linger(),
	on_return => on_return(),
	shutdown => shutdown(),
	size => size(),
	strategy => strategy()
}.

-export_type([ref/0]).
-export_type([pool/0]).
-export_type([worker/0]).
-export_type([transaction_fun/1]).
-export_type([size/0]).
-export_type([strategy/0]).
-export_type([linger/0]).
-export_type([on_return/0]).
-export_type([shutdown/0]).
-export_type([worker_status/0]).
-export_type([pool_status/0]).
-export_type([opts/0]).

-spec start_pool(Name, PoolOpts, WorkerMod, WorkerArgs) -> supervisor:startlink_ret() when
	Name :: pool(),
	PoolOpts :: opts(),
	WorkerMod :: module(),
	WorkerArgs :: term().
start_pool(Name, PoolOpts, WorkerModule, WorkerStartArgs) when is_atom(Name), is_atom(WorkerModule) ->
	ok=validate_opts(PoolOpts),
	hnc_sup:start_pool(Name, PoolOpts, WorkerModule, WorkerStartArgs);
start_pool(_, _, _, _) ->
	error(badarg).

-spec stop_pool(Pool) -> ok when
	Pool :: pool().
stop_pool(Pool) when is_atom(Pool) ->
	hnc_sup:stop_pool(Pool).

-spec child_spec(Name, PoolOpts, WorkerMod, WorkerArgs) -> supervisor:child_spec() when
	Name :: pool(),
	PoolOpts :: opts(),
	WorkerMod :: module(),
	WorkerArgs :: term().
child_spec(Name, PoolOpts, WorkerModule, WorkerStartArgs) when is_atom(Name), is_atom(WorkerModule) ->
	ok=validate_opts(PoolOpts),
	#{
		id => {hnc_pool, Name},
		start => {hnc_pool_sup, start_link, [Name, PoolOpts, WorkerModule, WorkerStartArgs]},
		type => supervisor
	}.

-spec checkout(Pool) -> Ref when
	Pool :: pool(),
	Ref :: ref().
checkout(Pool) ->
	checkout(Pool, infinity).

-spec checkout(Pool, Timeout) -> Ref when
	Pool :: pool(),
	Timeout :: timeout(),
	Ref :: ref().
checkout(Pool, Timeout) ->
	{ok, Agent}=hnc_pool:checkout(Pool, Timeout),
	#agent{pid=Agent}.

-spec checkin(Ref) -> ok when
	Ref :: ref().
checkin(WorkerRef) ->
	checkin(WorkerRef, infinity).

-spec checkin(Ref, Timeout) -> ok when
	Ref :: ref(),
	Timeout :: timeout().
checkin(#agent{pid=Agent}, Timeout) ->
	case hnc_agent:checkin(Agent, self(), Timeout) of
		ok -> ok;
		{error, not_owner} -> error(not_owner)
	end.

-spec transaction(Pool, TransactionFun) -> Result when
	Pool :: pool(),
	TransactionFun :: transaction_fun(Result),
	Result :: term().
transaction(Pool, Fun) ->
	transaction(Pool, Fun, infinity).

-spec transaction(Pool, TransactionFun, Timeout) -> Result when
	Pool :: pool(),
	TransactionFun :: transaction_fun(Result),
	Timeout :: timeout(),
	Result :: term().
transaction(Pool, Fun, Timeout) when is_function(Fun, 1) ->
	Ref=checkout(Pool, Timeout),
	try
		Fun(get_worker(Ref))
	after
		checkin(Ref)
	end.

-spec give_away(Ref, NewUser, GiftData) -> ok when
	Ref :: ref(),
	NewUser :: pid(),
	GiftData :: term().
give_away(WorkerRef, NewUser, GiftData) ->
	give_away(WorkerRef, NewUser, GiftData, 5000).

-spec give_away(Ref, NewUser, GiftData, Timeout) -> ok when
	Ref :: ref(),
	NewUser :: pid(),
	GiftData :: term(),
	Timeout :: timeout().
give_away(Ref=#agent{pid=Agent}, NewUser, GiftData, Timeout) ->
	case hnc_agent:give_away(Agent, self(), NewUser, Timeout) of
		ok ->
			NewUser ! {'HNC-AGENT-TRANSFER', Ref, self(), GiftData},
			ok;
		{error, not_owner} ->
			error(not_owner)
	end.

-spec set_strategy(Pool, Strategy) -> ok when
	Pool :: pool(),
	Strategy :: strategy().
set_strategy(Pool, Strategy) ->
	true=validate_setopt(strategy, Strategy),
	hnc_pool:set_strategy(Pool, Strategy).

-spec get_strategy(Pool) -> Strategy when
	Pool :: pool(),
	Strategy :: strategy().
get_strategy(Pool) ->
	get_strategy(Pool, 5000).

-spec get_strategy(Pool, Timeout) -> Strategy when
	Pool :: pool(),
	Timeout :: timeout(),
	Strategy :: strategy().
get_strategy(Pool, Timeout) ->
	hnc_pool:get_strategy(Pool, Timeout).

-spec set_size(Pool, Size) -> ok when
	Pool :: pool(),
	Size :: size().
set_size(Pool, Size) ->
	true=validate_setopt(size, Size),
	hnc_pool:set_size(Pool, Size).

-spec get_size(Pool) -> Size when
	Pool :: pool(),
	Size :: size().
get_size(Pool) ->
	get_size(Pool, 5000).

-spec get_size(Pool, Timeout) -> Size when
	Pool :: pool(),
	Timeout :: timeout(),
	Size :: size().
get_size(Pool, Timeout) ->
	hnc_pool:get_size(Pool, Timeout).

-spec set_linger(Pool, Linger) -> ok when
	Pool :: pool(),
	Linger :: linger().
set_linger(Pool, Linger) ->
	true=validate_setopt(linger, Linger),
	hnc_pool:set_linger(Pool, Linger).

-spec get_linger(Pool) -> Linger when
	Pool :: pool(),
	Linger :: linger().
get_linger(Pool) ->
	get_linger(Pool, 5000).

-spec get_linger(Pool, Timeout) -> Linger when
	Pool :: pool(),
	Timeout :: timeout(),
	Linger :: linger().
get_linger(Pool, Timeout) ->
	hnc_pool:get_linger(Pool, Timeout).

-spec pool_status(Pool) -> Status when
	Pool :: pool(),
	Status :: pool_status().
pool_status(Pool) ->
	pool_status(Pool, 5000).

-spec pool_status(Pool, Timeout) -> Status when
	Pool :: pool(),
	Timeout :: timeout(),
	Status :: pool_status().
pool_status(Pool, Timeout) ->
	hnc_pool:pool_status(Pool, Timeout).

-spec prune(Pool) -> ok when
	Pool :: pool().
prune(Pool) ->
	hnc_pool:prune(Pool).

-spec worker_status(Ref) -> Status when
	Ref :: ref(),
	Status :: worker_status().
worker_status(Ref) ->
	worker_status(Ref, 5000).

-spec worker_status(Ref, Timeout) -> Status when
	Ref :: ref(),
	Timeout :: timeout(),
	Status :: worker_status().
worker_status(#agent{pid=Agent}, Timeout) ->
	hnc_agent:status(Agent, Timeout).

-spec get_worker(Ref) -> Worker when
	Ref :: ref(),
	Worker :: worker().
get_worker(Ref) ->
	get_worker(Ref, infinity).

-spec get_worker(Ref, Timeout) -> Worker when
	Ref :: ref(),
	Timeout :: timeout(),
	Worker :: worker().
get_worker(#agent{pid=Agent}, Timeout) ->
	case hnc_agent:worker(Agent, self(), Timeout) of
		{ok, Worker} -> Worker;
		{error, not_owner} -> error(not_owner)
	end.

-spec validate_opts(Opts) -> ok when
	Opts :: opts().
validate_opts(Opts) ->
	lists:foreach(
		fun (Opt={Name, _}) ->
			case validate_opt(Opt) of
				true -> ok;
				false -> error({badopt, Name})
			end
		end,
		maps:to_list(Opts)
	),
	ok.
	
validate_setopt(Name, Value) ->
	case validate_opt({Name, Value}) of
		true -> true;
		false -> error(badarg)
	end.

validate_opt({size, {Min, infinity}}) when is_integer(Min), Min>=0 ->
	true;
validate_opt({size, {Min, Max}}) when is_integer(Min), Min>=0, is_integer(Max), Max>0, Max>=Min ->
	true;
validate_opt({strategy, fifo}) ->
	true;
validate_opt({strategy, lifo}) ->
	true;
validate_opt({on_return, undefined}) ->
	true;
validate_opt({on_return, {Fun, infinity}}) when is_function(Fun, 1) ->
	true;
validate_opt({on_return, {Fun, Timeout}}) when is_function(Fun, 1), is_integer(Timeout), Timeout>=0 ->
	true;
validate_opt({shutdown, brutal_kill}) ->
	true;
validate_opt({shutdown, infinity}) ->
	true;
validate_opt({shutdown, Timeout}) when is_integer(Timeout), Timeout>=0 ->
	true;
validate_opt({linger, infinity}) ->
	true;
validate_opt({linger, {LingerTimeout, SweepInterval}}) when is_integer(LingerTimeout), LingerTimeout>=0, is_integer(SweepInterval), SweepInterval>=0 ->
	true;
validate_opt(_) ->
	false.
