-module(hnc_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([start_pool/4]).
-export([stop_pool/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()}.
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_pool(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_pool(Name, Opts, Mod, Args) ->
	supervisor:start_child(
		?MODULE,
		#{
			id => {hnc_pool, Name},
			start => {hnc_pool_sup, start_link, [Name, Opts, Mod, Args]},
			restart => temporary,
			type => supervisor
		}
	).

-spec stop_pool(hnc:pool()) -> ok.
stop_pool(Name) ->
	supervisor:terminate_child(?MODULE, {hnc_pool, Name}).

init([]) ->
	{
		ok,
		{
			#{
				strategy => one_for_one
			},
			[
				#{
					id => hnc_workercntl_sup,
					start => {hnc_workercntl_sup, start_link, []},
					restart => permanent,
					type => supervisor
				}
			]
		}
	}.
