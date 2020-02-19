-module(hnc_pool_sup).

-behavior(supervisor).

-export([start_link/4]).
-export([get_worker_sup/1]).
-export([init/1]).

-spec start_link(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_link(Name, Opts, Mod, Args) ->
	supervisor:start_link(?MODULE, {Name, Opts, Mod, Args}).

-spec get_worker_sup(pid()) -> pid().
get_worker_sup(Sup) ->
	[WorkerSup]=[Pid || {hnc_worker_sup, Pid, supervisor, _} <- supervisor:which_children(Sup)],
	WorkerSup.

init({Name, Opts, Mod, Args}) ->
	Shutdown=maps:get(shutdown, Opts, brutal_kill),
	{
		ok,
		{
			#{
				strategy => one_for_all
			},
			[
				#{
					id => hnc_worker_sup,
					start => {hnc_worker_sup, start_link, [Mod, Args, Shutdown]},
					restart => permanent,
					type => supervisor
				},
				#{
					id => hnc_pool,
					start => {hnc_pool, start_link, [Name, Opts]},
					restart => permanent
				}
			]
		}
	}.
