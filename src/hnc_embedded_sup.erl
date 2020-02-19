-module(hnc_embedded_sup).

-behavior(supervisor).

-export([start_link/4]).
-export([child_spec/4]).
-export([init/1]).

-spec start_link(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_link(Name, Opts, Mod, Args) ->
        supervisor:start_link(?MODULE, {Name, Opts, Mod, Args}).

child_spec(Name, PoolOpts, WorkerModule, WorkerStartArgs) when is_atom(Name), is_atom(WorkerModule) ->
	ok=hnc:validate_opts(PoolOpts),
	#{
		id => {hnc_embedded_sup, Name},
		start => {hnc_embedded_sup, start_link, [Name, PoolOpts, WorkerModule, WorkerStartArgs]},
		type => supervisor
	}.

init({Name, Opts, Mod, Args}) ->
	{
		ok,
		{
			#{
				strategy => rest_for_one
			},
			[
				#{
					id => hnc_workercntl_sup_proxy,
					start => {hnc_workercntl_sup_proxy, start_link, []},
					shutdown => brutal_kill
				},
				#{
					id => {hnc_pool, Name},
					start => {hnc_pool_sup, start_link, [Name, Opts, Mod, Args]},
					type => supervisor
				}
			]
		}
	}.
