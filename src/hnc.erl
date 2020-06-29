-module(hnc).

-export([start_pool/4]).
-export([stop_pool/1]).
-export([child_spec/4]).
-export([checkout/1, checkout/2]).
-export([checkin/2]).
-export([transaction/2, transaction/3]).
-export([set_strategy/2, get_strategy/1, get_strategy/2]).
-export([set_size/2, get_size/1, get_size/2]).
-export([set_linger/2, get_linger/1, get_linger/2]).
-export([pool_status/1, pool_status/2]).
-export([worker_status/2, worker_status/3]).
-export([validate_opts/1]).

-type pool() :: atom().
-type worker() :: pid().
-type transaction_fun(Result) :: fun((worker()) -> Result).
-type size() :: {non_neg_integer(), pos_integer() | infinity}.
-type strategy() :: fifo | lifo.
-type linger() :: infinity | {non_neg_integer(), non_neg_integer()}.
-type on_return() :: undefined | {fun((worker()) -> any()), timeout()}.
-type shutdown() :: timeout() | brutal_kill.
-type worker_status() :: idle | out | returning.
-type pool_status() :: #{
	idle:=non_neg_integer(),
	out:=non_neg_integer(),
	starting:=non_neg_integer(),
	returning:=non_neg_integer()
}.
-type opts() :: #{
	size => size(),
	strategy => strategy(),
	linger => linger(),
	on_return => on_return(),
	shutdown => shutdown()
}.

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

-spec start_pool(pool(), opts(), module(), term()) -> {ok, pid()}.
start_pool(Name, PoolOpts, WorkerModule, WorkerStartArgs) when is_atom(Name), is_atom(WorkerModule) ->
	ok=validate_opts(PoolOpts),
	hnc_sup:start_pool(Name, PoolOpts, WorkerModule, WorkerStartArgs);
start_pool(_, _, _, _) ->
	error(badarg).

-spec stop_pool(pool()) -> ok.
stop_pool(Pool) when is_atom(Pool) ->
	hnc_sup:stop_pool(Pool).

-spec child_spec(pool(), opts(), module(), term()) -> supervisor:child_spec().
child_spec(Pool, PoolOpts, WorkerModule, WorkerStartArgs) when is_atom(Pool), is_atom(WorkerModule) ->
	ok=validate_opts(PoolOpts),
	#{
		id => {hnc_embedded_sup, Pool},
		start => {hnc_embedded_sup, start_link, [Pool, PoolOpts, WorkerModule, WorkerStartArgs]},
		type => supervisor
	}.


-spec checkout(pool()) -> worker().
checkout(Pool) ->
	checkout(Pool, infinity).

-spec checkout(pool(), timeout()) -> worker().
checkout(Pool, Timeout) ->
	hnc_pool:checkout(Pool, Timeout).

-spec checkin(pool(), worker()) -> ok.
checkin(Pool, Worker) ->
	hnc_pool:checkin(Pool, Worker).

-spec transaction(pool(), transaction_fun(Result)) -> Result.
transaction(Pool, Fun) ->
	transaction(Pool, Fun, infinity).

-spec transaction(pool(), transaction_fun(Result), timeout()) -> Result.
transaction(Pool, Fun, Timeout) when is_function(Fun, 1) ->
	Worker=checkout(Pool, Timeout),
	try
		Fun(Worker)
	after
		checkin(Pool, Worker)
	end.

-spec set_strategy(pool(), strategy()) -> ok.
set_strategy(Pool, Strategy) ->
	true=validate_setopt(strategy, Strategy),
	hnc_pool:set_strategy(Pool, Strategy).

-spec get_strategy(pool()) -> strategy().
get_strategy(Pool) ->
	get_strategy(Pool, 5000).

-spec get_strategy(pool(), timeout()) -> strategy().
get_strategy(Pool, Timeout) ->
	hnc_pool:get_strategy(Pool, Timeout).

-spec set_size(pool(), size()) -> ok.
set_size(Pool, Size) ->
	true=validate_setopt(size, Size),
	hnc_pool:set_size(Pool, Size).

-spec get_size(pool()) -> size().
get_size(Pool) ->
	get_size(Pool, 5000).

-spec get_size(pool(), timeout()) -> size().
get_size(Pool, Timeout) ->
	hnc_pool:get_size(Pool, Timeout).

-spec set_linger(pool(), linger()) -> ok.
set_linger(Pool, Linger) ->
	true=validate_setopt(linger, Linger),
	hnc_pool:set_linger(Pool, Linger).

-spec get_linger(pool()) -> linger().
get_linger(Pool) ->
	get_linger(Pool, 5000).

-spec get_linger(pool(), timeout()) -> linger().
get_linger(Pool, Timeout) ->
	hnc_pool:get_linger(Pool, Timeout).

-spec pool_status(pool()) -> pool_status().
pool_status(Pool) ->
	pool_status(Pool, 5000).

-spec pool_status(pool(), timeout()) -> pool_status().
pool_status(Pool, Timeout) ->
	hnc_pool:pool_status(Pool, Timeout).

-spec worker_status(pool(), worker()) -> worker_status() | undefined.
worker_status(Pool, Worker) ->
	worker_status(Pool, Worker, 5000).

-spec worker_status(pool(), worker(), timeout()) -> worker_status() | undefined.
worker_status(Pool, Worker, Timeout) ->
	hnc_pool:worker_status(Pool, Worker, Timeout).

-spec validate_opts(opts()) -> ok.
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

validate_opt({size, {Min, infinity}}) when is_integer(Min), Min>0 ->
	true;
validate_opt({size, {Min, Max}}) when is_integer(Min), Min>=0, is_integer(Max), Max>0, Max>=Min ->
	true;
validate_opt({strategy, fifo}) ->
	true;
validate_opt({strategy, lifo}) ->
	true;
validate_opt({on_return, undefinded}) ->
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
