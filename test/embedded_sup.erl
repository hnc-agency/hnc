-module(embedded_sup).
-behavior(supervisor).

-export([start_link/4]).
-export([init/1]).

start_link(Pool, Opts, WorkerMod, WorkerArgs) ->
	supervisor:start_link(?MODULE, {Pool, Opts, WorkerMod, WorkerArgs}).

init({Pool, Opts, WorkerMod, WorkerArgs}) ->
	{
		ok,
		{
			#{},
			[
				hnc:child_spec(Pool, Opts, WorkerMod, WorkerArgs)
			]
		}
	}.
