-module(hnc_embedded_sup).

-behavior(supervisor).

-export([start_link/4]).
-export([init/1]).

-spec start_link(hnc:pool(), hnc:opts(), module(), term()) -> {ok, pid()}.
start_link(Name, Opts, Mod, Args) ->
        supervisor:start_link(?MODULE, {Name, Opts, Mod, Args}).

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
